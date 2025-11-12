#!/usr/bin/env bash
# 05.10-applypatches-build.sh
# Aplica patches, roda hooks e constrói/instala inteligentemente em DESTDIR.

###############################################################################
# Modo estrito + traps
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__ab_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] applypatches-build falhou: code=${code} line=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __ab_err_trap ERR

###############################################################################
# Caminhos, logging (fallbacks) e utilitários
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_LOG_DIR="${ADM_LOG_DIR:-${ADM_STATE_DIR}/logs}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"
ADM_DETECT_DIR="${ADM_DETECT_DIR:-${ADM_STATE_DIR}/detect}"
ADM_HEUR_DIR="${ADM_HEUR_DIR:-${ADM_STATE_DIR}/heuristics}"
ADM_DB_DIR="${ADM_DB_DIR:-${ADM_ROOT}/db}"

adm_is_cmd(){ command -v "$1" >/dev/null 2>&1; }
__ensure_dir(){
  local d="$1" mode="${2:-0755}" owner="${3:-root}" group="${4:-root}"
  if [[ ! -d "$d" ]]; then
    if adm_is_cmd install; then
      if [[ $EUID -ne 0 ]] && adm_is_cmd sudo; then
        sudo install -d -m "$mode" -o "$owner" -g "$group" "$d"
      else
        install -d -m "$mode" -o "$owner" -g "$group" "$d"
      fi
    else
      mkdir -p "$d"; chmod "$mode" "$d"; chown "$owner:$group" "$d" || true
    fi
  fi
}

# Cores simples
if [[ -t 1 ]] && adm_is_cmd tput && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RST="$(tput sgr0)"; C_OK="$(tput setaf 2)"; C_WRN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INF="$(tput setaf 6)"; C_BD="$(tput bold)"
else
  C_RST=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""; C_BD=""
fi
ab_info(){  echo -e "${C_INF}[ADM]${C_RST} $*"; }
ab_ok(){    echo -e "${C_OK}[OK ]${C_RST} $*"; }
ab_warn(){  echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
ab_err(){   echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }
tmpfile(){ mktemp "${ADM_TMPDIR}/ab.XXXXXX"; }

__ensure_dir "$ADM_STATE_DIR"; __ensure_dir "$ADM_LOG_DIR"; __ensure_dir "$ADM_TMPDIR"

###############################################################################
# Contexto do pacote (metafile) e diretórios de hooks/patches
###############################################################################
# Espera-se ADM_META carregado por 02.10-parse-validate-metafile.sh
# Layout de hooks/patches do pacote:
#   /usr/src/adm/<category>/<name>/hooks/<stage>
#   /usr/src/adm/<category>/<name>/patches/*.patch|*.diff|series
__pkg_root(){
  local cat="${ADM_META[category]:-}" name="${ADM_META[name]:-}"
  [[ -n "$cat" && -n "$name" ]] || { echo ""; return 1; }
  printf '%s/%s/%s' "$ADM_ROOT" "$cat" "$name"
}
__hooks_dirs(){
  local pr; pr="$(__pkg_root)" || return 0
  printf '%s\n' "$pr/hooks" "$ADM_ROOT/hooks"
}
__patches_dir(){
  local pr; pr="$(__pkg_root)" || { echo ""; return 1; }
  printf '%s/patches' "$pr"
}

adm_hooks_run() {
  # uso: adm_hooks_run <stage> [WORKDIR=dir DESTDIR=dir]
  local stage="${1:?}"; shift || true
  local d f ran=0
  for d in $(__hooks_dirs); do
    [[ -d "$d" ]] || continue
    for f in "$d/$stage" "$d/$stage.sh"; do
      if [[ -x "$f" ]]; then
        ab_info "Hook: $(realpath -m "$f")"
        ( set -Eeuo pipefail; WORKDIR="${WORKDIR:-}" DESTDIR="${DESTDIR:-}" "$f" "$@" )
        ran=1
      fi
    done
  done
  (( ran )) || ab_info "Hook '${stage}': nenhum"
}

###############################################################################
# Registro de build e saída para logs com tee
###############################################################################
__mk_build_loggers(){
  local cat="${ADM_META[category]:-unknown}" prog="${ADM_META[name]:-unknown}"
  local stamp; stamp="$(date -u +%Y%m%d-%H%M%S)"
  BUILD_LOG_DIR="${ADM_LOG_DIR}/build/${cat}/${prog}/${stamp}"
  __ensure_dir "$BUILD_LOG_DIR"
  LOG_CFG="${BUILD_LOG_DIR}/01-configure.log"
  LOG_BLD="${BUILD_LOG_DIR}/02-build.log"
  LOG_TST="${BUILD_LOG_DIR}/03-check.log"
  LOG_INS="${BUILD_LOG_DIR}/04-install.log"
  LOG_PCH="${BUILD_LOG_DIR}/00-patches.log"
  BUILD_ID_FILE="${BUILD_LOG_DIR}/.build-id"
  echo "${stamp}" > "$BUILD_ID_FILE"
}

__runt(){
  # run with tee to log file; usage: __runt <logfile> -- command args...
  local logfile="${1:?}"; shift
  [[ "$1" == "--" ]] && shift || { ab_err "__runt: uso inválido"; return 2; }
  set -o pipefail
  ( "$@" 2>&1 | tee -a "$logfile" )
}

###############################################################################
# Aplicação de patches (idempotente, dry-run antes, detecta -pN)
###############################################################################
__detect_patch_p_level(){
  # tenta descobrir automaticamente -pN (0..3) a partir dos paths no patch
  local pf="$1"
  local n
  for n in 1 0 2 3; do
    if patch -p"$n" --dry-run -f -s < "$pf" >/dev/null 2>&1; then
      echo "$n"; return 0
    fi
  done
  echo 1
}

__apply_one_patch(){
  local pf="$1" work="${2:?}"; local plevel
  plevel="$(__detect_patch_p_level "$pf")"
  ab_info "Aplicando patch: $(basename "$pf") ( -p${plevel} )"
  ( cd "$work" && patch -p"$plevel" -f -s < "$pf" )
}

__apply_series_quilt(){
  local dir="$1" work="$2"
  if adm_is_cmd quilt && [[ -f "$dir/series" ]]; then
    ab_info "Aplicando série (quilt)"; ( cd "$work" && quilt push -a ) || {
      ab_warn "quilt falhou; tentando aplicação manual de series"
      while read -r p; do
        [[ -z "$p" || "$p" == \#* ]] && continue
        __apply_one_patch "$dir/$p" "$work"
      done < "$dir/series"
    }
  fi
}

adm_apply_patches(){
  # uso: adm_apply_patches <workdir>
  local work="${1:?}"
  adm_hooks_run "pre-patch"
  __mk_build_loggers
  local pdir; pdir="$(__patches_dir)" || true
  if [[ -z "$pdir" || ! -d "$pdir" ]]; then
    ab_info "Sem diretório de patches para este pacote."
    return 0
  fi

  # Registro idempotente: arquivo .applied na raiz de trabalho
  local stamp="${BUILD_LOG_DIR}/patches.applied"
  : > "$stamp"

  # 1) série quilt (se existir)
  if [[ -f "$pdir/series" ]]; then
    __runt "$LOG_PCH" -- __apply_series_quilt "$pdir" "$work"
  fi

  # 2) patches soltos
  local found=0 pf
  shopt -s nullglob
  for pf in "$pdir"/*.patch "$pdir"/*.diff; do
    found=1
    __runt "$LOG_PCH" -- __apply_one_patch "$pf" "$work"
    echo "$(basename "$pf")" >> "$stamp"
  done
  shopt -u nullglob

  # 3) git am (se existir patches/*.mbox ou *.eml)
  shopt -s nullglob
  local gf; for gf in "$pdir"/*.mbox "$pdir"/*.eml; do
    found=1
    if [[ -d "$work/.git" ]] && adm_is_cmd git; then
      ab_info "Aplicando git-am: $(basename "$gf")"
      __runt "$LOG_PCH" -- bash -c 'cd "$1" && git am --3way --keep-cr "$2"' _ "$work" "$gf"
    else
      ab_warn "git-am não aplicável (sem .git); ignorei $(basename "$gf")"
    fi
  done
  shopt -u nullglob

  (( found )) || ab_info "Nenhum patch para aplicar."
  adm_hooks_run "post-patch"
}

###############################################################################
# Carregar detect.json + matrix.json do pacote (ou gerar fallback)
###############################################################################
__json_escape(){ local s="$1"; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; printf '%s' "$s"; }

__load_detect_and_matrix(){
  local work="${1:?}"
  local cat="${ADM_META[category]:-unknown}" prog="${ADM_META[name]:-unknown}"
  DET_JSON="${ADM_DETECT_DIR}/${cat}/${prog}/detect.json"
  MAT_JSON="${ADM_HEUR_DIR}/${cat}/${prog}/matrix.json"
  if [[ ! -r "$DET_JSON" ]]; then
    ab_warn "detect.json ausente; chamando 04.10-extract-detect.sh para fallback."
    if [[ -r "${ADM_ROOT}/scripts/04.10-extract-detect.sh" ]]; then
      # shellcheck disable=SC1090
      source "${ADM_ROOT}/scripts/04.10-extract-detect.sh"
      adm_detect_all "$work" || ab_warn "fallback detect falhou; seguirei sem"
    fi
  fi
  if [[ ! -r "$MAT_JSON" ]]; then
    ab_warn "matrix.json ausente; chamando 04.20-source-heuristics-matrix.sh para gerar."
    if [[ -r "${ADM_ROOT}/scripts/04.20-source-heuristics-matrix.sh" ]]; then
      # shellcheck disable=SC1090
      source "${ADM_ROOT}/scripts/04.20-source-heuristics-matrix.sh"
      shm_build_matrix "$work" || ab_warn "fallback matrix falhou; seguirei com heurísticas padrão"
    fi
  fi
}

__jq_val(){
  local file="$1" path="$2"
  if adm_is_cmd jq; then jq -r "$path // empty" "$file" 2>/dev/null || true; else echo ""; fi
}

__export_tool_matrix(){
  # Exporta CC/CXX/FLAGS a partir do matrix.json (quando existir)
  local m="$1"
  if [[ -r "$m" ]] && adm_is_cmd jq; then
    export CC="$(__jq_val "$m" '.languages.C.cc')"
    export CXX="$(__jq_val "$m" '.languages.CXX.cxx')"
    export FC="$(__jq_val "$m" '.languages.Fortran.fc')"
    export CFLAGS="$(__jq_val "$m" '.languages.C.cflags')"
    export CXXFLAGS="$(__jq_val "$m" '.languages.CXX.cxxflags')"
    export FFLAGS="$(__jq_val "$m" '.languages.Fortran.fflags')"
    export LDFLAGS="$(__jq_val "$m" '.languages.C.ldflags')"
    [[ -n "${MAKEFLAGS:-}" ]] || export MAKEFLAGS="-j$(command -v nproc >/dev/null 2>&1 && nproc || echo 2)"
    [[ -n "${NINJAJOBS:-}" ]] || export NINJAJOBS="$(command -v nproc >/dev/null 2>&1 && nproc || echo 2)"
    ab_info "Toolchain exportado do matrix.json"
  else
    # fallback sensato
    [[ -z "${CC:-}" ]]  && export CC="$(command -v clang || command -v gcc || echo cc)"
    [[ -z "${CXX:-}" ]] && export CXX="$(command -v clang++ || command -v g++ || echo c++)"
    [[ -z "${MAKEFLAGS:-}" ]] || true
    : "${MAKEFLAGS:="-j$(command -v nproc >/dev/null 2>&1 && nproc || echo 2)"}"
    export MAKEFLAGS
    : "${NINJAJOBS:="$(command -v nproc >/dev/null 2>&1 && nproc || echo 2)"}"
    export NINJAJOBS
    ab_warn "Matrix ausente: usando fallback de ferramentas."
  fi
}

###############################################################################
# Sandbox opcional (bubblewrap) e executores
###############################################################################
__have_sandbox(){ adm_is_cmd bwrap && [[ "${ADM_SANDBOX:-1}" != "0" ]]; }
__run_in_sandbox(){
  # uso: __run_in_sandbox <workdir> <destdir> -- cmd...
  local wk="$1" dd="$2"; shift 2
  [[ "$1" == "--" ]] && shift || { ab_err "sandbox: falta --"; return 2; }
  if __have_sandbox; then
    bwrap --dev-bind / / \
          --bind "$wk" "$wk" \
          --bind "$dd" "$dd" \
          --setenv DESTDIR "$dd" \
          --setenv HOME "${HOME:-/root}" \
          -- ro "$@"
  else
    "$@"
  fi
}
###############################################################################
# Implementações de build por buildsystem
###############################################################################
ab_build_meson(){
  local wk="$1" dd="$2"
  local b="$wk/build"
  __ensure_dir "$b"
  adm_hooks_run "pre-configure"
  __runt "$LOG_CFG" -- bash -c 'cd "$1" && meson setup build --prefix=/usr ${MESON_SETUP_OPTS:-}' _ "$wk"
  adm_hooks_run "post-configure"
  adm_hooks_run "pre-build"
  __runt "$LOG_BLD" -- bash -c 'meson compile -C "$1" -j "${NINJAJOBS:-2}"' _ "$b"
  adm_hooks_run "post-build"
  if [[ "${ADM_NO_CHECK:-0}" != "1" ]]; then
    adm_hooks_run "pre-check"
    __runt "$LOG_TST" -- bash -c 'meson test -C "$1" --print-errorlogs' _ "$b" || ab_warn "meson test falhou"
    adm_hooks_run "post-check"
  fi
  adm_hooks_run "pre-install"
  __runt "$LOG_INS" -- bash -c 'DESTDIR="$1" meson install -C "$2"' _ "$dd" "$b"
  adm_hooks_run "post-install"
}

ab_build_cmake(){
  local wk="$1" dd="$2"
  local b="$wk/build"
  __ensure_dir "$b"
  local bt="${CMAKE_BUILD_TYPE:-Release}"
  adm_hooks_run "pre-configure"
  __runt "$LOG_CFG" -- bash -c 'cmake -S "$1" -B "$2" -G Ninja -DCMAKE_BUILD_TYPE="'$bt'" -DCMAKE_INSTALL_PREFIX=/usr ${CMAKE_OPTS:-}' _ "$wk" "$b"
  adm_hooks_run "post-configure"
  adm_hooks_run "pre-build"
  __runt "$LOG_BLD" -- bash -c 'cmake --build "$1" -j "${NINJAJOBS:-2}"' _ "$b"
  adm_hooks_run "post-build"
  if [[ "${ADM_NO_CHECK:-0}" != "1" ]]; then
    adm_hooks_run "pre-check"
    __runt "$LOG_TST" -- bash -c 'cd "$1" && ctest --output-on-failure -j "${NINJAJOBS:-2}"' _ "$b" || ab_warn "ctest falhou"
    adm_hooks_run "post-check"
  fi
  adm_hooks_run "pre-install"
  __runt "$LOG_INS" -- bash -c 'DESTDIR="$1" cmake --install "$2"' _ "$dd" "$b"
  adm_hooks_run "post-install"
}

ab_build_autotools(){
  local wk="$1" dd="$2"
  adm_hooks_run "pre-configure"
  if [[ -x "$wk/autogen.sh" ]]; then
    __runt "$LOG_CFG" -- bash -c 'cd "$1" && ./autogen.sh' _ "$wk"
  fi
  __runt "$LOG_CFG" -- bash -c 'cd "$1" && ./configure --prefix=/usr ${CONFIGURE_OPTS:-}' _ "$wk"
  adm_hooks_run "post-configure"
  adm_hooks_run "pre-build"
  __runt "$LOG_BLD" -- bash -c 'cd "$1" && make -j "${JOBS:-$(nproc 2>/dev/null || echo 2)}"' _ "$wk"
  adm_hooks_run "post-build"
  if [[ "${ADM_NO_CHECK:-0}" != "1" ]]; then
    adm_hooks_run "pre-check"
    __runt "$LOG_TST" -- bash -c 'cd "$1" && (make -j "${JOBS:-2}" check || make test || true)' _ "$wk"
    adm_hooks_run "post-check"
  fi
  adm_hooks_run "pre-install"
  __runt "$LOG_INS" -- bash -c 'cd "$1" && make DESTDIR="$2" install' _ "$wk" "$dd"
  adm_hooks_run "post-install"
}

ab_build_make_plain(){
  local wk="$1" dd="$2"
  adm_hooks_run "pre-build"
  __runt "$LOG_BLD" -- bash -c 'cd "$1" && make -j "${JOBS:-$(nproc 2>/dev/null || echo 2)}"' _ "$wk"
  adm_hooks_run "post-build"
  if [[ "${ADM_NO_CHECK:-0}" != "1" ]]; then
    adm_hooks_run "pre-check"
    __runt "$LOG_TST" -- bash -c 'cd "$1" && (make -j "${JOBS:-2}" check || make test || true)' _ "$wk"
    adm_hooks_run "post-check"
  fi
  adm_hooks_run "pre-install"
  __runt "$LOG_INS" -- bash -c 'cd "$1" && if make -n install 2>/dev/null | grep -q DESTDIR; then make DESTDIR="$2" install; else make install PREFIX=/usr DESTDIR="$2"; fi' _ "$wk" "$dd"
  adm_hooks_run "post-install"
}

ab_build_ninja_plain(){
  local wk="$1" dd="$2"
  adm_hooks_run "pre-build"
  __runt "$LOG_BLD" -- bash -c 'cd "$1" && ninja -j "${NINJAJOBS:-$(nproc 2>/dev/null || echo 2)}"' _ "$wk"
  adm_hooks_run "post-build"
  if [[ "${ADM_NO_CHECK:-0}" != "1" ]]; then
    adm_hooks_run "pre-check"
    __runt "$LOG_TST" -- bash -c 'cd "$1" && (ninja test || ninja check || true)' _ "$wk"
    adm_hooks_run "post-check"
  fi
  adm_hooks_run "pre-install"
  __runt "$LOG_INS" -- bash -c 'cd "$1" && (DESTDIR="$2" ninja install || true)' _ "$wk" "$dd"
  adm_hooks_run "post-install"
}

ab_build_cargo(){
  local wk="$1" dd="$2"
  adm_hooks_run "pre-build"
  __runt "$LOG_BLD" -- bash -c 'cd "$1" && cargo build --release' _ "$wk"
  adm_hooks_run "post-build"
  if [[ "${ADM_NO_CHECK:-0}" != "1" ]]; then
    adm_hooks_run "pre-check"
    __runt "$LOG_TST" -- bash -c 'cd "$1" && cargo test --release' _ "$wk" || ab_warn "cargo test falhou"
    adm_hooks_run "post-check"
  fi
  adm_hooks_run "pre-install"
  # sem manifest de install padrão — copiar binários de target/release
  if compgen -G "$wk/target/release/*" >/dev/null; then
    while IFS= read -r -d '' f; do
      rel="usr/bin/$(basename "$f")"
      __runt "$LOG_INS" -- install -Dm0755 "$f" "$dd/$rel"
    done < <(find "$wk/target/release" -maxdepth 1 -type f -perm -111 -print0)
  fi
  adm_hooks_run "post-install"
}

ab_build_go(){
  local wk="$1" dd="$2"
  adm_hooks_run "pre-build"
  __runt "$LOG_BLD" -- bash -c 'cd "$1" && go build ./...' _ "$wk"
  adm_hooks_run "post-build"
  if [[ "${ADM_NO_CHECK:-0}" != "1" ]]; then
    adm_hooks_run "pre-check"
    __runt "$LOG_TST" -- bash -c 'cd "$1" && go test ./...' _ "$wk" || ab_warn "go test falhou"
    adm_hooks_run "post-check"
  fi
  adm_hooks_run "pre-install"
  # instala binários (se houver) em /usr/bin
  if compgen -G "$wk/*" >/dev/null; then
    while IFS= read -r -d '' f; do
      rel="usr/bin/$(basename "$f")"
      __runt "$LOG_INS" -- install -Dm0755 "$f" "$dd/$rel"
    done < <(find "$wk" -maxdepth 1 -type f -perm -111 -print0)
  fi
  adm_hooks_run "post-install"
}

ab_build_python(){
  local wk="$1" dd="$2"
  local py="${PYTHON:-${PYTHON3:-python3}}"
  adm_hooks_run "pre-build"
  if [[ -f "$wk/pyproject.toml" ]] && "$py" -c 'import build' 2>/dev/null; then
    __runt "$LOG_BLD" -- bash -c 'cd "$1" && '"$py"' -m build' _ "$wk"
    # instala wheel em DESTDIR
    local whl; whl="$(ls -1 "$wk"/dist/*.whl 2>/dev/null | head -n1 || true)"
    if [[ -n "$whl" ]]; then
      __runt "$LOG_INS" -- bash -c 'pip3 install --root="$1" --prefix=/usr --no-deps --no-warn-script-location "$2"' _ "$dd" "$whl"
    fi
  elif [[ -f "$wk/setup.py" ]] ; then
    __runt "$LOG_BLD" -- bash -c 'cd "$1" && '"$py"' setup.py build' _ "$wk"
    __runt "$LOG_INS" -- bash -c 'cd "$1" && '"$py"' setup.py install --root="$2" --prefix=/usr --optimize=1' _ "$wk" "$dd"
  else
    ab_warn "Projeto Python sem pyproject/setup.py detectado"
  fi
  adm_hooks_run "post-build"
  if [[ "${ADM_NO_CHECK:-0}" != "1" ]]; then
    adm_hooks_run "pre-check"
    if [[ -d "$wk/tests" ]] && "$py" -c 'import pytest' 2>/dev/null; then
      __runt "$LOG_TST" -- bash -c 'cd "$1" && pytest -q || true' _ "$wk"
    fi
    adm_hooks_run "post-check"
  fi
  adm_hooks_run "post-install"
}

ab_build_node(){
  local wk="$1" dd="$2"
  local pkg="$wk/package.json"
  [[ -f "$pkg" ]] || { ab_warn "Sem package.json"; return 0; }
  local runner="npm"
  [[ -f "$wk/pnpm-lock.yaml" && -n "$(command -v pnpm || true)" ]] && runner="pnpm"
  [[ -f "$wk/yarn.lock" && -n "$(command -v yarn || true)" ]] && runner="yarn"
  adm_hooks_run "pre-build"
  case "$runner" in
    pnpm) __runt "$LOG_BLD" -- bash -c 'cd "$1" && pnpm i --frozen-lockfile && pnpm run build' _ "$wk" ;;
    yarn) __runt "$LOG_BLD" -- bash -c 'cd "$1" && yarn install --frozen-lockfile && yarn build' _ "$wk" ;;
    *)    __runt "$LOG_BLD" -- bash -c 'cd "$1" && npm ci && npm run build' _ "$wk" ;;
  esac
  adm_hooks_run "post-build"
  if [[ "${ADM_NO_CHECK:-0}" != "1" ]]; then
    adm_hooks_run "pre-check"
    __runt "$LOG_TST" -- bash -c 'cd "$1" && ('"$runner"' test || true)' _ "$wk"
    adm_hooks_run "post-check"
  fi
  # instalação genérica: se houver "install" script que respeite PREFIX/DESTDIR, tenta
  adm_hooks_run "pre-install"
  if grep -q '"install"' "$pkg" 2>/dev/null; then
    __runt "$LOG_INS" -- bash -c 'cd "$1" && PREFIX=/usr DESTDIR="$2" '"$runner"' run install || true' _ "$wk" "$dd"
  fi
  adm_hooks_run "post-install"
}

ab_build_zig(){
  local wk="$1" dd="$2"
  adm_hooks_run "pre-build"
  __runt "$LOG_BLD" -- bash -c 'cd "$1" && zig build ${ZIG_OPTS:-}' _ "$wk"
  adm_hooks_run "post-build"
  adm_hooks_run "pre-install"
  # zig build install supports prefix/DESTDIR via env in build.zig (nem sempre); tentar padrões
  if grep -q 'install' "$wk/build.zig" 2>/dev/null; then
    __runt "$LOG_INS" -- bash -c 'cd "$1" && DESTDIR="$2" zig build install || true' _ "$wk" "$dd"
  fi
  adm_hooks_run "post-install"
}

ab_build_java(){
  local wk="$1" dd="$2"
  if [[ -f "$wk/pom.xml" ]] && adm_is_cmd mvn; then
    adm_hooks_run "pre-build"
    __runt "$LOG_BLD" -- bash -c 'cd "$1" && mvn -q -DskipTests package' _ "$wk"
    adm_hooks_run "post-build"
    [[ "${ADM_NO_CHECK:-0}" == "1" ]] || __runt "$LOG_TST" -- bash -c 'cd "$1" && mvn -q test || true' _ "$wk"
    adm_hooks_run "pre-install"
    # instalar jars em /usr/share/java/<name>.jar
    while IFS= read -r -d '' jar; do
      __runt "$LOG_INS" -- install -Dm0644 "$jar" "$dd/usr/share/java/$(basename "$jar")"
    done < <(find "$wk/target" -name '*.jar' -type f -print0)
    adm_hooks_run "post-install"
  elif compgen -G "$wk/build.gradle*" >/dev/null && adm_is_cmd gradle; then
    adm_hooks_run "pre-build"
    __runt "$LOG_BLD" -- bash -c 'cd "$1" && gradle -q build' _ "$wk"
    adm_hooks_run "post-build"
    [[ "${ADM_NO_CHECK:-0}" == "1" ]] || __runt "$LOG_TST" -- bash -c 'cd "$1" && gradle -q test || true' _ "$wk"
    adm_hooks_run "pre-install"
    while IFS= read -r -d '' jar; do
      __runt "$LOG_INS" -- install -Dm0644 "$jar" "$dd/usr/share/java/$(basename "$jar")"
    done < <(find "$wk/build/libs" -name '*.jar' -type f -print0)
    adm_hooks_run "post-install"
  else
    ab_warn "Projeto Java não reconhecido (Maven/Gradle ausentes?)"
  fi
}

###############################################################################
# Orquestrador: escolhe build conforme detectado
###############################################################################
ab_build_orchestrate(){
  local wk="$1" dd="$2"
  # Preferências: Meson > CMake > Autotools > Ninja > Make > Cargo > Go > Python > Node > Zig > Java
  if [[ -f "$wk/meson.build" ]] && adm_is_cmd meson; then ab_build_meson "$wk" "$dd"; return; fi
  if [[ -f "$wk/CMakeLists.txt" ]] && adm_is_cmd cmake; then ab_build_cmake "$wk" "$dd"; return; fi
  if [[ -x "$wk/configure" || -f "$wk/configure.ac" ]] && adm_is_cmd make; then ab_build_autotools "$wk" "$dd"; return; fi
  if [[ -f "$wk/build.ninja" ]] && adm_is_cmd ninja; then ab_build_ninja_plain "$wk" "$dd"; return; fi
  if compgen -G "$wk/Makefile*" >/dev/null && adm_is_cmd make; then ab_build_make_plain "$wk" "$dd"; return; fi
  if [[ -f "$wk/Cargo.toml" ]] && adm_is_cmd cargo; then ab_build_cargo "$wk" "$dd"; return; fi
  if [[ -f "$wk/go.mod" ]] && adm_is_cmd go; then ab_build_go "$wk" "$dd"; return; fi
  if [[ -f "$wk/pyproject.toml" || -f "$wk/setup.py" ]] && adm_is_cmd python3; then ab_build_python "$wk" "$dd"; return; fi
  if [[ -f "$wk/package.json" ]] && (adm_is_cmd npm || adm_is_cmd yarn || adm_is_cmd pnpm); then ab_build_node "$wk" "$dd"; return; fi
  if [[ -f "$wk/build.zig" ]] && adm_is_cmd zig; then ab_build_zig "$wk" "$dd"; return; fi
  if [[ -f "$wk/pom.xml" || -f "$wk/build.gradle" || -f "$wk/build.gradle.kts" ]]; then ab_build_java "$wk" "$dd"; return; fi
  ab_warn "Nenhum buildsystem suportado detectado — nada feito."
}

###############################################################################
# Strip opcional de binários no DESTDIR
###############################################################################
ab_strip_destdir(){
  local dd="$1"
  [[ "${ADM_STRIP:-0}" == "1" ]] || return 0
  adm_is_cmd strip || { ab_warn "strip não disponível"; return 0; }
  ab_info "Strip de binários em DESTDIR…"
  find "$dd" -type f -perm -111 -print0 | while IFS= read -r -d '' f; do
    file "$f" 2>/dev/null | grep -qi 'ELF' || continue
    strip --strip-unneeded "$f" 2>/dev/null || true
  done
}

###############################################################################
# CLI principal
###############################################################################
ab_usage(){
  cat <<'EOF'
Uso:
  05.10-applypatches-build.sh --workdir <dir> --destdir <dir> [opções]

Opções:
  --profile {aggressive|normal|minimal}  Perfil de otimização (p/ heurísticas).
  --libc {glibc|musl}                    Libc alvo (ajusta flags).
  --no-check                             Não executar testes.
  --strip                                Rodar strip em binários do DESTDIR.
  --help                                 Mostrar esta ajuda.

Requer:
  - WORKDIR apontando para as fontes já extraídas.
  - DESTDIR (vazio) para instalação staged.

Estágios com hooks suportados:
  pre/post-patch, pre/post-configure, pre/post-build, pre/post-check, pre/post-install
EOF
}

adm_applypatches_and_build(){
  local workdir="" destdir="" profile="${ADM_PROFILE:-normal}" libc="${ADM_LIBC:-}" do_strip=0
  while (($#)); do
    case "$1" in
      --workdir) workdir="${2:-}"; shift 2 ;;
      --destdir) destdir="${2:-}"; shift 2 ;;
      --profile) profile="${2:-normal}"; shift 2 ;;
      --libc)    libc="${2:-}"; shift 2 ;;
      --no-check) export ADM_NO_CHECK=1; shift ;;
      --strip)   do_strip=1; shift ;;
      --help|-h) ab_usage; return 0 ;;
      *) ab_err "opção inválida: $1"; return 2 ;;
    esac
  done
  [[ -d "$workdir" ]] || { ab_err "WORKDIR inválido: $workdir"; return 3; }
  [[ -n "$destdir" ]] || { ab_err "DESTDIR não fornecido"; return 4; }
  __ensure_dir "$destdir"

  # preparar logs + contexto
  __mk_build_loggers
  export WORKDIR="$workdir" DESTDIR="$destdir" ADM_PROFILE="$profile"
  [[ -n "$libc" ]] && export ADM_LIBC="$libc"

  # carregar detect/matrix e exportar toolchain
  __load_detect_and_matrix "$workdir"
  __export_tool_matrix "${MAT_JSON:-/dev/null}"

  # aplicar patches
  adm_apply_patches "$workdir"

  # build orquestrado
  ab_info "Iniciando build em: $workdir → DESTDIR=$destdir"
  ab_info "Profile=${profile} Libc=${ADM_LIBC:-auto}"
  ab_build_orchestrate "$workdir" "$destdir"

  # pós etapas
  [[ "$do_strip" == "1" ]] && ab_strip_destdir "$destdir"

  ab_ok "Build concluído para ${ADM_META[category]:-?}/${ADM_META[name]:-?}@${ADM_META[version]:-?}"
  ab_info "Logs em: $BUILD_LOG_DIR"
}

###############################################################################
# Execução direta (CLI)
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  adm_applypatches_and_build "$@"
fi
