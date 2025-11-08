#!/usr/bin/env sh
# adm-build.sh — Orquestrador de build/instalação/empacotamento do ADM
# POSIX sh; compatível com dash/ash/bash.
set -u
# =========================
# 0) Config & defaults
# =========================
: "${ADM_ROOT:=/usr/src/adm}"
: "${ADM_LOG_COLOR:=auto}"
: "${ADM_STAGE:=host}"
: "${ADM_PIPELINE:=build}"

BIN_DIR="$ADM_ROOT/bin"
CACHE_DIR="$ADM_ROOT/cache"
BUILD_BASE="$ADM_ROOT/build"
REG_BUILD_DIR="$ADM_ROOT/registry/build"
REG_PIPE_DIR="$ADM_ROOT/registry/pipeline"
LOG_DIR="$ADM_ROOT/logs/build"
META_DIR="$ADM_ROOT/metafile"

# flags CLI
STAGE_USE=""
PROFILES_IN=""
STRICT=0
WITH_TESTS=0
RECONF=0
FORCE=0
ONLY_STEPS=""
DRYRUN=0
TIMEOUT=0
JOBS=0
DESTDIR_OUT=""
PKG_OUT=""
ROOT_INSTALL=0
DO_UNINSTALL=0
YES=0

# contexto do pacote
PKG_NAME=""
PKG_VERSION=""
PKG_CATEGORY=""
PKG_COUNT=""

MF_FILE=""
SRC_DIR=""     # diretório de trabalho do source (extraído)
WORK_DIR=""    # $BUILD_BASE/<name>-<ver>/work
DESTDIR=""     # $BUILD_BASE/<name>-<ver>/destdir
PKG_DIR=""     # $BUILD_BASE/<name>-<ver>/pkg
DETECT_ENV=""  # $REG_PIPE_DIR/<name>-<version>.detect.env
FETCH_MANIFEST="" # $CACHE_DIR/<name>-<version>/manifest.fetch

# detect/env comandos
BUILD_SYSTEM=""
CONFIGURE_CMD=":"
BUILD_CMD=":"
INSTALL_CMD=":"
TEST_CMD=""

# =========================
# 1) Cores + logging fallback
# =========================
_is_tty(){ [ -t 1 ]; }
_color_on=0
_color_setup(){
  if [ "${ADM_LOG_COLOR}" = "never" ] || [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ]; then
    _color_on=0
  elif [ "${ADM_LOG_COLOR}" = "always" ] || _is_tty; then
    _color_on=1
  else
    _color_on=0
  fi
}
_b(){ [ $_color_on -eq 1 ] && printf '\033[1m'; }
_rst(){ [ $_color_on -eq 1 ] && printf '\033[0m'; }
_c_mag(){ [ $_color_on -eq 1 ] && printf '\033[35;1m'; }  # estágio rosa
_c_yel(){ [ $_color_on -eq 1 ] && printf '\033[33;1m'; }  # path amarelo
_c_gry(){ [ $_color_on -eq 1 ] && printf '\033[38;5;244m';}

have_adm_log=0
command -v adm_log_info >/dev/null 2>&1 && have_adm_log=1

_ts(){ date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([0-9][0-9]\)$/:\1/'; }
_ctx(){
  st="${ADM_STAGE:-host}"; pipe="${ADM_PIPELINE:-build}"; path="${WORK_DIR:-$PWD}"
  if [ $_color_on -eq 1 ]; then
    printf "("; _c_mag; printf "%s" "$st"; _rst; _c_gry; printf ":%s" "$pipe"; _rst
    printf " path="; _c_yel; printf "%s" "$path"; _rst; printf ")"
  else
    printf "(%s:%s path=%s)" "$st" "$pipe" "$path"
  fi
}
say(){
  lvl="$1"; shift; msg="$*"
  if [ $have_adm_log -eq 1 ]; then
    case "$lvl" in
      INFO)  adm_log_info  "$msg";;
      WARN)  adm_log_warn  "$msg";;
      ERROR) adm_log_error "$msg";;
      STEP)  adm_log_step_start "$msg" >/dev/null;;
      OK)    adm_log_step_ok;;
      DEBUG) adm_log_debug "$msg";;
      *)     adm_log_info "$msg";;
    esac
  else
    _color_setup
    case "$lvl" in
      INFO) t="[INFO]";; WARN) t="[WARN]";; ERROR) t="[ERROR]";; STEP) t="[STEP]";; OK) t="[ OK ]";; DEBUG) t="[DEBUG]";;
      *) t="[$lvl]";;
    esac
    printf "%s [%s] %s %s\n" "$t" "$(_ts)" "$(_ctx)" "$msg"
  fi
}
die(){ say ERROR "$*"; exit 40; }

# =========================
# 2) Utilidades gerais
# =========================
ensure_dirs(){
  for d in "$BUILD_BASE" "$REG_BUILD_DIR" "$REG_PIPE_DIR" "$LOG_DIR"; do
    [ -d "$d" ] || mkdir -p "$d" || die "não foi possível criar diretório: $d"
  done
}
lower(){ printf "%s" "$1" | tr 'A-Z' 'a-z'; }
trim(){ printf "%s" "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
exists(){ [ -e "$1" ]; }
is_dir(){ [ -d "$1" ]; }
nproc_auto(){ command -v nproc >/dev/null 2>&1 && nproc || echo 2; }
sha256_file(){ command -v sha256sum >/dev/null 2>&1 || die "sha256sum não encontrado"; sha256sum "$1" | awk '{print $1}'; }
bytes_dir(){ du -sk "$1" 2>/dev/null | awk '{print $1*1024}'; }
join_by_space(){ out=""; for i in "$@"; do out="${out}${out:+ }$i"; done; printf "%s" "$out"; }

# safe rm inside a root (avoid /)
safe_rm_rf(){
  p="$1"
  [ -n "$p" ] || { say ERROR "safe_rm_rf: caminho vazio"; return 1; }
  case "$p" in /|"") say ERROR "safe_rm_rf: caminho proibido: $p"; return 1;; esac
  rm -rf -- "$p" 2>/dev/null || { say WARN "falha ao remover $p"; return 1; }
  return 0
}

# timeout best-effort (se disponível)
with_timeout(){
  t="$1"; shift
  if [ "$t" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
    timeout "$t" "$@"
  else
    "$@"
  fi
}

# Executa comando no host ou no stage via adm-stage.sh
exec_host_or_stage(){
  if [ -n "$STAGE_USE" ]; then
    [ -x "$BIN_DIR/adm-stage.sh" ] || die "adm-stage.sh não encontrado para executar no stage"
    "$BIN_DIR/adm-stage.sh" exec --stage "$STAGE_USE" -- "$@"
  else
    "$@"
  fi
}

# -------------------------
# Hooks (runner no-op seguro)
# -------------------------
run_hook(){
  name="$1"
  # prioridade: pacote/categoria → _hooks comuns
  # paths candidatos
  m_pkg="$META_DIR/${PKG_CATEGORY:-_unknown}/${PKG_NAME:-_unknown}/hooks/${name}.sh"
  m_cat="$META_DIR/_hooks/${name}.sh"
  m_stage="$META_DIR/stage/${ADM_STAGE}/${name}.sh"
  for h in "$m_pkg" "$m_stage" "$m_cat"; do
    if [ -f "$h" ]; then
      say INFO "hook: $name → $h"
      sh "$h" "$PKG_NAME" "$PKG_VERSION" "$ADM_STAGE" || { say ERROR "hook falhou ($name) rc=$? em $h"; return 1; }
      return 0
    fi
  done
  say DEBUG "hook ausente: $name (ok)"
  return 0
}

# =========================
# 3) CLI & Metafile
# =========================
usage(){
  cat <<'EOF'
Uso: adm-build.sh <metafile> [opções]
  --stage {0|1|2}        Executa via chroot do stage
  --profile PERF[,..]    Seleciona perfis antes do build
  --with-tests           Executa testes após build
  --strict               Falta de detect/env vira erro
  --reconfigure          Limpa objdir e reconfigura
  --force                Ignora caches parciais; recompila
  --only steps           Ex.: "configure,build" / "install,package"
  --dry-run              Mostra plano sem executar
  --timeout SECS         Tempo máximo por etapa
  --jobs N               Paralelismo de build
  --destdir PATH         Override do DESTDIR
  --pkg-out PATH         Override do diretório de pacotes
  --root-install         Instala o pacote no /
  --uninstall            Remove pacote previamente instalado (manifest)
  --yes                  Confirmações automáticas
EOF
}
parse_args(){
  [ $# -ge 1 ] || { usage; exit 10; }
  MF_FILE="$1"; shift || true
  [ -f "$MF_FILE" ] || { say ERROR "metafile não encontrado: $MF_FILE"; exit 10; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --stage) shift; STAGE_USE="$1";;
      --profile) shift; PROFILES_IN="$1";;
      --with-tests) WITH_TESTS=1;;
      --strict) STRICT=1;;
      --reconfigure) RECONF=1;;
      --force) FORCE=1;;
      --only) shift; ONLY_STEPS="$1";;
      --dry-run) DRYRUN=1;;
      --timeout) shift; TIMEOUT="$1";;
      --jobs) shift; JOBS="$1";;
      --destdir) shift; DESTDIR_OUT="$1";;
      --pkg-out) shift; PKG_OUT="$1";;
      --root-install) ROOT_INSTALL=1;;
      --uninstall) DO_UNINSTALL=1;;
      --yes) YES=1;;
      -h|--help|help) usage; exit 0;;
      *) say ERROR "argumento desconhecido: $1"; usage; exit 10;;
    esac
    shift || true
  done
}

load_metafile(){
  NAME=""; VERSION=""; CATEGORY=""; SOURCES=""; SHA256SUMS=""; COUNT=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue;;
      NAME=*) NAME="${line#NAME=}";;
      VERSION=*) VERSION="${line#VERSION=}";;
      CATEGORY=*) CATEGORY="${line#CATEGORY=}";;
      SOURCES=*) SOURCES="${line#SOURCES=}";;
      SHA256SUMS=*) SHA256SUMS="${line#SHA256SUMS=}";;
      COUNT=*) COUNT="${line#COUNT=}";;
      *) :;;
    esac
  done < "$MF_FILE"
  [ -n "$NAME" ] || { say ERROR "NAME ausente no metafile"; exit 10; }
  [ -n "$VERSION" ] || { say ERROR "VERSION ausente no metafile"; exit 10; }
  PKG_NAME="$NAME"; PKG_VERSION="$VERSION"; PKG_CATEGORY="${CATEGORY:-misc}"; PKG_COUNT="${COUNT:-0}"
  DETECT_ENV="$REG_PIPE_DIR/${PKG_NAME}-${PKG_VERSION}.detect.env"
  FETCH_MANIFEST="$CACHE_DIR/${PKG_NAME}-${PKG_VERSION}/manifest.fetch"
  WORK_DIR="$BUILD_BASE/${PKG_NAME}-${PKG_VERSION}/work"
  DESTDIR="${DESTDIR_OUT:-$BUILD_BASE/${PKG_NAME}-${PKG_VERSION}/destdir}"
  PKG_DIR="${PKG_OUT:-$BUILD_BASE/${PKG_NAME}-${PKG_VERSION}/pkg}"
  mkdir -p "$WORK_DIR" "$DESTDIR" "$PKG_DIR" || die "não foi possível criar diretórios de build"
}

# Perfis (opcional)
load_profile_env(){
  if [ -x "$BIN_DIR/adm-profile.sh" ]; then
    [ -n "$PROFILES_IN" ] && "$BIN_DIR/adm-profile.sh" set "$PROFILES_IN" >/dev/null 2>&1 || true
    eval "$("$BIN_DIR/adm-profile.sh" export 2>/dev/null)" || say WARN "adm-profile export falhou; seguindo com defaults"
  else
    say WARN "adm-profile.sh não encontrado — seguindo sem perfis"
  fi
  # Paralelismo
  if [ "$JOBS" -le 0 ]; then JOBS="$(nproc_auto)"; fi
  export MAKEFLAGS="-j$JOBS"
}

# Detect/env (preferido)
load_detect_env(){
  if [ -f "$DETECT_ENV" ]; then
    # shellcheck disable=SC1090
    . "$DETECT_ENV"
    BUILD_SYSTEM="${BUILD_SYSTEM:-${BUILD_SYSTEM_PRIMARY:-}}"
    CONFIGURE_CMD="${CONFIGURE_CMD:-:}"
    BUILD_CMD="${BUILD_CMD:-:}"
    INSTALL_CMD="${INSTALL_CMD:-:}"
    TEST_CMD="${TEST_CMD:-:}"
  else
    if [ $STRICT -eq 1 ]; then
      say ERROR "detect.env ausente: $DETECT_ENV (use adm-detect.sh)"
      exit 10
    fi
    say WARN "detect.env ausente — usando heurísticas básicas"
    # heurística mínima pelo source após extrair (definido mais à frente)
  fi
}

# =========================
# 4) Resolver fontes do manifest.fetch
# =========================
map_sources_from_manifest(){
  [ -f "$FETCH_MANIFEST" ] || { say ERROR "manifest.fetch ausente: $FETCH_MANIFEST (rode adm-fetch.sh)"; exit 10; }
  SRC_ITEMS=""
  i=1
  while IFS= read -r L || [ -n "$L" ]; do
    case "$L" in
      ITEM_${i}_SOURCE=*) SRC="${L#ITEM_${i}_SOURCE=}";;
      ITEM_${i}_LOCAL=*) LOC="${L#ITEM_${i}_LOCAL=}";;
      ITEM_${i}_TYPE=*) TYP="${L#ITEM_${i}_TYPE=}";;
      ITEM_${i}_STATUS=*) ST="${L#ITEM_${i}_STATUS=}";;
      "") :;;
    esac
    case "$L" in
      ITEM_${i}_SIZE=* )
        # finalize bloco
        if [ "${ST:-}" = "OK" ] || [ "${ST:-}" = "REUSED" ]; then
          SRC_ITEMS="${SRC_ITEMS}${SRC_ITEMS:+
}${i}|${TYP:-unknown}|${LOC:-}"
        else
          say ERROR "item $i no manifest não está OK/REUSED (status=${ST:-?})"
          exit 20
        fi
        i=$((i+1))
        unset SRC LOC TYP ST
        ;;
    esac
  done < "$FETCH_MANIFEST"
  [ -n "$SRC_ITEMS" ] || { say ERROR "nenhuma fonte válida no manifest"; exit 20; }
}

# =========================
# 5) Preparar árvore de trabalho (extrair/copy)
# =========================
extract_one(){
  typ="$1"; path="$2"; out="$3"
  case "$typ" in
    http|ftp|file)
      case "$path" in
        *.tar|*.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.zst|*.tzst|*.tar.bz2|*.tbz2|*.zip)
          mkdir -p "$out/src.$$" || return 1
          case "$path" in
            *.tar.zst|*.tzst) command -v zstd >/dev/null 2>&1 || return 1; zstd -dc "$path" | (cd "$out/src.$$" && tar xf -) || return 1;;
            *.tar.xz|*.txz)  (cd "$out/src.$$" && tar xJf "$path") || return 1;;
            *.tar.gz|*.tgz)  (cd "$out/src.$$" && tar xzf "$path") || return 1;;
            *.tar.bz2|*.tbz2)(cd "$out/src.$$" && tar xjf "$path") || return 1;;
            *.tar)           (cd "$out/src.$$" && tar xf "$path") || return 1;;
            *.zip)           command -v unzip >/dev/null 2>&1 || return 1; (cd "$out/src.$$" && unzip -qq "$path") || return 1;;
            *) return 1;;
          esac
          # pega primeiro diretório ou conteúdo direto
          sub="$(find "$out/src.$$" -mindepth 1 -maxdepth 1 -type d -print -quit)"
          if [ -n "$sub" ]; then mv "$sub" "$out/src" || return 1; else mv "$out/src.$$" "$out/src" || true; fi
          [ -d "$out/src" ] || { mkdir -p "$out/src" && cp -a "$out/src.$$"/* "$out/src"/ 2>/dev/null || true; }
          rm -rf "$out/src.$$" 2>/dev/null || true
          ;;
        *) # arquivo que não é tarball: copia como-is
          mkdir -p "$out/src" || return 1
          cp -a "$path" "$out/src/" || return 1
          ;;
      esac
      ;;
    git|dir|rsync)
      mkdir -p "$out/src" || return 1
      cp -a "$path" "$out/src/" 2>/dev/null || (cd "$path" && tar cf - .) | (cd "$out/src" && tar xf -) || true
      ;;
    *)
      say WARN "tipo de fonte não reconhecido: $typ (tentando copiar)"
      mkdir -p "$out/src" || return 1
      cp -a "$path" "$out/src/" 2>/dev/null || true
      ;;
  esac
}

prepare_work_tree(){
  say STEP "Preparando árvore de trabalho"
  safe_rm_rf "$WORK_DIR" || true
  mkdir -p "$WORK_DIR" || die "não foi possível criar $WORK_DIR"
  idx=0
  echo "$SRC_ITEMS" | while IFS='|' read -r i typ loc; do
    idx=$((idx+1))
    say INFO "extraindo item #$i ($typ) → $WORK_DIR"
    extract_one "$typ" "$loc" "$WORK_DIR" || { say ERROR "falha ao extrair item #$i"; exit 20; }
  done
  # define SRC_DIR
  if [ -d "$WORK_DIR/src" ]; then
    SRC_DIR="$WORK_DIR/src"
  else
    # fallback: primeiro diretório
    SRC_DIR="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    [ -n "$SRC_DIR" ] || { say ERROR "não foi possível determinar SRC_DIR"; exit 20; }
  fi
  say OK
}

# =========================
# 6) Aplicação automática de patches
# =========================
apply_patches(){
  say STEP "Aplicando patches (automático)"
  # ordem de prioridade:
  # 1) metafile/<categoria>/<nome>/patches/
  # 2) metafile/_common/patches/
  # 3) metafile/stage/<ADM_STAGE>/patches/
  P_LIST=""
  p1="$META_DIR/${PKG_CATEGORY}/${PKG_NAME}/patches"
  p2="$META_DIR/_common/patches"
  p3="$META_DIR/stage/${ADM_STAGE}/patches"
  for pdir in "$p1" "$p2" "$p3"; do
    if [ -d "$pdir" ]; then
      # ordena por nome; aceita .patch, .diff, e scripts *.sh (aplicados como executáveis)
      for f in $(ls -1 "$pdir" 2>/dev/null | sort); do
        case "$f" in
          *.patch|*.diff|*.PATCH|*.DIFF|*.patch.gz|*.patch.xz|*.patch.zst|*.gz|*.xz|*.zst|*.sh)
            P_LIST="${P_LIST}${P_LIST:+
}$pdir/$f"
            ;;
          *) :;;
        esac
      done
    fi
  done
  [ -z "$P_LIST" ] && { say INFO "nenhum patch encontrado (ok)"; say OK; return 0; }

  ( cd "$SRC_DIR" || exit 1
    for pf in $P_LIST; do
      say INFO "patch: $(basename "$pf")"
      case "$pf" in
        *.sh)
          sh "$pf" || { say ERROR "script de patch falhou: $pf"; exit 20; }
          ;;
        *.patch.zst|*.zst)
          command -v zstd >/dev/null 2>&1 || { say ERROR "zstd necessário para $pf"; exit 20; }
          zstd -dc "$pf" | patch -p1 --forward --reject-file=- || { say ERROR "patch falhou: $pf"; exit 20; }
          ;;
        *.patch.xz|*.xz)
          xz -dc "$pf" | patch -p1 --forward --reject-file=- || { say ERROR "patch falhou: $pf"; exit 20; }
          ;;
        *.patch.gz|*.gz)
          gzip -dc "$pf" | patch -p1 --forward --reject-file=- || { say ERROR "patch falhou: $pf"; exit 20; }
          ;;
        *.patch|*.diff|*.PATCH|*.DIFF)
          patch -p1 --forward --reject-file=- < "$pf" || { say ERROR "patch falhou: $pf"; exit 20; }
          ;;
        *)
          say WARN "formato de patch não suportado: $pf (ignorando)"
          ;;
      esac
    done
  ) || exit 20
  say OK
}
# =========================
# 7) Heurísticas mínimas (caso detect.env ausente)
# =========================
infer_minimal_build(){
  [ -n "${BUILD_SYSTEM:-}" ] && return 0
  if [ -f "$SRC_DIR/CMakeLists.txt" ]; then BUILD_SYSTEM="cmake"
  elif [ -f "$SRC_DIR/meson.build" ]; then BUILD_SYSTEM="meson"
  elif [ -f "$SRC_DIR/configure.ac" ] || [ -x "$SRC_DIR/configure" ]; then BUILD_SYSTEM="autotools"
  elif [ -f "$SRC_DIR/Cargo.toml" ]; then BUILD_SYSTEM="cargo"
  elif [ -f "$SRC_DIR/go.mod" ]; then BUILD_SYSTEM="gomod"
  elif [ -f "$SRC_DIR/pyproject.toml" ] || [ -f "$SRC_DIR/setup.py" ]; then BUILD_SYSTEM="pip"
  elif [ -f "$SRC_DIR/package.json" ]; then BUILD_SYSTEM="npm"
  elif [ -f "$SRC_DIR/pom.xml" ]; then BUILD_SYSTEM="maven"
  elif [ -f "$SRC_DIR/build.gradle" ] || [ -f "$SRC_DIR/build.gradle.kts" ]; then BUILD_SYSTEM="gradle"
  elif [ -f "$SRC_DIR/build.zig" ]; then BUILD_SYSTEM="zig"
  elif [ -f "$SRC_DIR/SConstruct" ]; then BUILD_SYSTEM="scons"
  elif [ -f "$SRC_DIR/Makefile" ]; then BUILD_SYSTEM="make"
  elif [ -f "$SRC_DIR/build.ninja" ]; then BUILD_SYSTEM="ninja"
  else
    say ERROR "não foi possível inferir sistema de build"
    exit 10
  fi

  case "$BUILD_SYSTEM" in
    cmake)
      CONFIGURE_CMD='cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr'
      BUILD_CMD='cmake --build build -j$(nproc)'
      INSTALL_CMD='cmake --install build'
      ;;
    meson)
      CONFIGURE_CMD='meson setup build --buildtype=release --prefix /usr'
      BUILD_CMD='meson compile -C build'
      INSTALL_CMD='meson install -C build'
      ;;
    autotools)
      CONFIGURE_CMD='./configure --prefix=/usr'
      BUILD_CMD='make -j$(nproc)'
      INSTALL_CMD='make install DESTDIR="${DESTDIR}"'
      ;;
    cargo)
      CONFIGURE_CMD=':'
      BUILD_CMD='cargo build --release'
      INSTALL_CMD='cargo install --path . --root "${DESTDIR}/usr"'
      ;;
    gomod)
      CONFIGURE_CMD=':'
      BUILD_CMD='go build ./...'
      INSTALL_CMD=':'
      ;;
    pip)
      CONFIGURE_CMD=':'
      BUILD_CMD='python3 -m build'
      INSTALL_CMD='pip3 install --no-deps --root "${DESTDIR}" .'
      ;;
    npm)
      CONFIGURE_CMD=':'
      BUILD_CMD='npm ci && npm run build'
      INSTALL_CMD=':'
      ;;
    maven)
      CONFIGURE_CMD=':'
      BUILD_CMD='mvn -q -DskipTests package'
      INSTALL_CMD=':'
      ;;
    gradle)
      CONFIGURE_CMD=':'
      BUILD_CMD='gradle build -x test'
      INSTALL_CMD=':'
      ;;
    zig)
      CONFIGURE_CMD=':'
      BUILD_CMD='zig build -Doptimize=ReleaseFast'
      INSTALL_CMD='zig build install --prefix "${DESTDIR}/usr"'
      ;;
    scons)
      CONFIGURE_CMD=':'
      BUILD_CMD='scons -j$(nproc)'
      INSTALL_CMD=':'
      ;;
    make)
      CONFIGURE_CMD=':'
      BUILD_CMD='make -j$(nproc)'
      INSTALL_CMD='make install DESTDIR="${DESTDIR}"'
      ;;
    ninja)
      CONFIGURE_CMD=':'
      BUILD_CMD='ninja -j$(nproc)'
      INSTALL_CMD=':'
      ;;
  esac
}

# =========================
# 8) Execução de etapas (configure/build/test/install)
# =========================
pretty_cmd_echo(){
  printf "%s\n" "── cmd: $*"
}
run_configure(){
  step="configure"; say STEP "CONFIGURE ($BUILD_SYSTEM)"
  [ "$DRYRUN" -eq 1 ] && { pretty_cmd_echo "$CONFIGURE_CMD"; say OK; return 0; }
  ( cd "$SRC_DIR" || exit 1
    [ $RECONF -eq 1 ] && { safe_rm_rf build || true; }
    [ -n "${CONFIGURE_CMD:-}" ] || CONFIGURE_CMD=":"
    with_timeout "$TIMEOUT" sh -c "$CONFIGURE_CMD"
  )
  rc=$?
  if [ $rc -ne 0 ]; then
    if [ $RECONF -eq 0 ]; then
      say WARN "configure falhou; tentando reconfigurar após limpar objdir"
      RECONF=1; run_configure; return $?
    fi
    say ERROR "configure falhou definitivamente (rc=$rc)"
    return 20
  fi
  say OK
}

run_build(){
  step="build"; say STEP "BUILD"
  [ "$DRYRUN" -eq 1 ] && { pretty_cmd_echo "$BUILD_CMD"; say OK; return 0; }
  ( cd "$SRC_DIR" || exit 1
    [ -n "${BUILD_CMD:-}" ] || BUILD_CMD=":"
    with_timeout "$TIMEOUT" sh -c "$BUILD_CMD"
  )
  rc=$?
  [ $rc -eq 0 ] || { say ERROR "build falhou (rc=$rc)"; return 20; }
  say OK
}

run_tests(){
  [ $WITH_TESTS -eq 1 ] || return 0
  step="test"; say STEP "TEST"
  # heurística: se TEST_CMD vazio, tente ctest/meson test/make check/cargo test
  if [ -z "${TEST_CMD:-}" ] || [ "$TEST_CMD" = ":" ]; then
    if [ -f "$SRC_DIR/CTestTestfile.cmake" ] || command -v ctest >/dev/null 2>&1; then
      TEST_CMD="ctest --output-on-failure -C Release ${MAKEFLAGS:-}"
    elif [ -f "$SRC_DIR/meson.build" ]; then
      TEST_CMD="meson test -C build --print-errorlogs"
    elif [ -f "$SRC_DIR/Makefile" ]; then
      TEST_CMD="make check"
    elif [ -f "$SRC_DIR/Cargo.toml" ]; then
      TEST_CMD="cargo test --release"
    elif [ -f "$SRC_DIR/go.mod" ]; then
      TEST_CMD="go test ./..."
    elif [ -f "$SRC_DIR/package.json" ]; then
      TEST_CMD="npm test --if-present"
    else
      TEST_CMD=":"
    fi
  fi
  [ "$DRYRUN" -eq 1 ] && { pretty_cmd_echo "$TEST_CMD"; say OK; return 0; }
  ( cd "$SRC_DIR" || exit 1
    with_timeout "$TIMEOUT" sh -c "$TEST_CMD"
  )
  rc=$?
  [ $rc -eq 0 ] || { say ERROR "testes falharam (rc=$rc)"; return 21; }
  say OK
}

run_install_destdir(){
  step="install"; say STEP "INSTALL (DESTDIR)"
  [ "$DRYRUN" -eq 1 ] && { printf "DESTDIR=%s\n" "$DESTDIR"; pretty_cmd_echo "$INSTALL_CMD"; say OK; return 0; }
  mkdir -p "$DESTDIR" || { say ERROR "não foi possível criar DESTDIR: $DESTDIR"; return 22; }
  ( cd "$SRC_DIR" || exit 1
    DESTDIR="$DESTDIR" with_timeout "$TIMEOUT" sh -c "$INSTALL_CMD"
  )
  rc=$?
  [ $rc -eq 0 ] || { say ERROR "install falhou (rc=$rc)"; return 22; }
  say OK
}

# =========================
# 9) Manifests & Package
# =========================
emit_manifest(){
  say STEP "Gerando manifest"
  MANI="$REG_BUILD_DIR/${PKG_NAME}-${PKG_VERSION}/build.manifest"
  META="$REG_BUILD_DIR/${PKG_NAME}-${PKG_VERSION}/build.meta"
  mkdir -p "$(dirname "$MANI")" || return 23
  : >"$MANI" || return 23
  find "$DESTDIR" -type f -o -type l 2>/dev/null | while read -r f; do
    rel="${f#$DESTDIR}"
    h="-"; [ -f "$f" ] && h="$(sha256_file "$f" 2>/dev/null || echo -)"
    st="$(stat -c '%a %u:%g %Y' "$f" 2>/dev/null || echo '000 0:0 0')"
    printf "%s\t%s\t%s\n" "$rel" "$h" "$st" >>"$MANI" || true
  done
  {
    echo "NAME=$PKG_NAME"
    echo "VERSION=$PKG_VERSION"
    echo "STAGE=$ADM_STAGE"
    echo "DESTDIR=$DESTDIR"
    echo "SIZE_BYTES=$(bytes_dir "$DESTDIR")"
    echo "BUILDS=$PKG_COUNT"
    echo "TIMESTAMP=$(_ts)"
  } >"$META" 2>/dev/null || true
  say OK
}

make_package(){
  say STEP "Empacotando pacote"
  out="$PKG_DIR/${PKG_NAME}-${PKG_VERSION}.tar.zst"
  mkdir -p "$PKG_DIR" || return 23
  if command -v zstd >/dev/null 2>&1; then
    (cd "$DESTDIR" && tar cf - .) | zstd -q -T0 -o "$out" || { say WARN "zstd falhou; tentando xz"; out="$PKG_DIR/${PKG_NAME}-${PKG_VERSION}.tar.xz"; (cd "$DESTDIR" && tar cJf "$out" .) || { say WARN "xz falhou; usando .tar"; out="$PKG_DIR/${PKG_NAME}-${PKG_VERSION}.tar"; (cd "$DESTDIR" && tar cf "$out" .) || return 23; }; }
  else
    if command -v xz >/dev/null 2>&1; then
      out="$PKG_DIR/${PKG_NAME}-${PKG_VERSION}.tar.xz"; (cd "$DESTDIR" && tar cJf "$out" .) || { say WARN "xz falhou; usando .tar"; out="$PKG_DIR/${PKG_NAME}-${PKG_VERSION}.tar"; (cd "$DESTDIR" && tar cf "$out" .) || return 23; }
    else
      out="$PKG_DIR/${PKG_NAME}-${PKG_VERSION}.tar"; (cd "$DESTDIR" && tar cf "$out" .) || return 23
    fi
  fi
  say INFO "pacote: $out"
  # hook de package
  run_hook "post_package" || true
  say OK
}

# =========================
# 10) Instalação no / e Uninstall (com hooks)
# =========================
install_to_root(){
  say STEP "Instalação no / (root)"
  MANI="$REG_BUILD_DIR/${PKG_NAME}-${PKG_VERSION}/build.manifest"
  [ -f "$MANI" ] || { say ERROR "manifest ausente: $MANI"; return 24; }
  run_hook "pre_root_install" || true
  if [ $DRYRUN -eq 1 ]; then
    say INFO "dry-run: mostraria cópia de $DESTDIR → /"
    say OK; return 0
  fi
  # Confirmação
  if [ $YES -ne 1 ]; then
    printf "Instalar %s-%s em / ? (yes/no): " "$PKG_NAME" "$PKG_VERSION"
    read ans || ans="no"
    [ "$ans" = "yes" ] || { say ERROR "abandonado pelo usuário"; return 24; }
  fi
  # Copia preservando modos/owner quando possível (não altera dono se não root)
  (cd "$DESTDIR" && tar cf - .) | (cd / && tar xpf -) || { say ERROR "falha ao copiar para /"; return 24; }
  run_hook "post_root_install" || true
  say OK
}

uninstall_from_root(){
  say STEP "Uninstall do /"
  MANI="$REG_BUILD_DIR/${PKG_NAME}-${PKG_VERSION}/build.manifest"
  [ -f "$MANI" ] || { say ERROR "manifest ausente: $MANI"; return 25; }
  run_hook "pre_uninstall" || true
  if [ $DRYRUN -eq 1 ]; then
    say INFO "dry-run: removeria arquivos listados em $MANI"
    say OK; return 0
  fi
  if [ $YES -ne 1 ]; then
    printf "Remover %s-%s do / ? (yes/no): " "$PKG_NAME" "$PKG_VERSION"
    read ans || ans="no"
    [ "$ans" = "yes" ] || { say ERROR "abandonado pelo usuário"; return 25; }
  fi
  rc_all=0
  awk -F'\t' '{print $1}' "$MANI" | while read -r rel; do
    f="/$rel"
    if [ -e "$f" ] || [ -L "$f" ]; then
      rm -f -- "$f" 2>/dev/null || { say WARN "não foi possível remover: $f"; rc_all=1; }
      # tenta remover diretórios vazios ascendentes
      d="$(dirname "$f")"
      while [ "$d" != "/" ] && rmdir "$d" 2>/dev/null; do d="$(dirname "$d")"; done
    else
      say INFO "SKIPPED: $f (não existe)"
    fi
  done
  run_hook "post_uninstall" || true
  [ ${rc_all:-0} -eq 0 ] || { say WARN "uninstall concluiu com avisos"; return 25; }
  say OK
}
# =========================
# 11) Plano & Execução
# =========================
maybe_stage_export_env(){
  # Para execuções em stage, exporta perfis e variáveis úteis (feito pelo stage ao entrar)
  :
}

run_pipeline(){
  steps="configure build"
  [ $WITH_TESTS -eq 1 ] && steps="$steps test"
  steps="$steps install package"
  [ -n "$ONLY_STEPS" ] && steps="$(echo "$ONLY_STEPS" | tr ',' ' ')"

  for s in $steps; do
    case "$s" in
      configure) run_hook "pre_build" || true; run_configure || return $?;;
      build)     run_build || return $?;;
      test)      run_tests || return $?;;
      install)   run_hook "pre_install" || true; run_install_destdir || return $?; run_hook "post_install" || true;;
      package)   run_hook "pre_package" || true; emit_manifest || return $?; make_package || return $?;;
      *) say WARN "etapa desconhecida: $s (ignorando)";;
    esac
  done
  run_hook "post_build" || true
}

# =========================
# 12) Fluxo principal
# =========================
main(){
  _color_setup
  ensure_dirs
  parse_args "$@"
  say INFO "metafile: $MF_FILE"
  load_metafile
  say INFO "pacote: ${PKG_NAME}-${PKG_VERSION} (categoria=${PKG_CATEGORY})"
  say INFO "dirs: work=$WORK_DIR destdir=$DESTDIR pkg=$PKG_DIR"
  [ -n "$PROFILES_IN" ] && say INFO "perfis: $PROFILES_IN"
  [ -n "$STAGE_USE" ]   && { ADM_STAGE="stage$STAGE_USE"; say INFO "executando no $ADM_STAGE"; }

  load_profile_env

  map_sources_from_manifest
  prepare_work_tree
  apply_patches

  load_detect_env
  infer_minimal_build

  if [ $DO_UNINSTALL -eq 1 ]; then
    uninstall_from_root; exit $?
  fi

  if [ $ROOT_INSTALL -eq 1 ]; then
    # Mesmo com root-install, sempre constroem e empacotam; após isso aplica em /
    run_pipeline || { say ERROR "pipeline falhou"; exit $?; }
    install_to_root || { say ERROR "instalação em / falhou"; exit 24; }
    say INFO "concluído com root-install"
    exit 0
  fi

  run_pipeline || { say ERROR "pipeline falhou"; exit $?; }
  say INFO "build concluído com sucesso"
  exit 0
}

# =========================
# 13) Exec
# =========================
main "$@"
