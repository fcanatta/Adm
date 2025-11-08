#!/usr/bin/env sh
# adm-registry.sh — Gerenciador do registro ADM (build/install/pipeline/repo)
# POSIX sh; compatível com dash/ash/bash.
set -u
# =========================
# 0) Config & defaults
# =========================
: "${ADM_ROOT:=/usr/src/adm}"
: "${ADM_LOG_COLOR:=auto}"
: "${ADM_STAGE:=host}"
: "${ADM_PIPELINE:=registry}"

BIN_DIR="$ADM_ROOT/bin"
REG_BUILD_DIR="$ADM_ROOT/registry/build"
REG_INSTALL_DIR="$ADM_ROOT/registry/install"
REG_PIPE_DIR="$ADM_ROOT/registry/pipeline"
PROFILES_DIR="$ADM_ROOT/profiles"
CACHE_DIR="$ADM_ROOT/cache"
BUILD_DIR="$ADM_ROOT/build"
REPO_DIR="$ADM_ROOT/repo"
LOG_DIR="$ADM_ROOT/logs/registry"

JSON=0
LONG=0
YES=0
STRICT=0
VERBOSE=0

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
_c_yel(){ [ $_color_on -eq 1 ] && printf '\033[33;1m'; }  # caminho amarelo
_c_gry(){ [ $_color_on -eq 1 ] && printf '\033[38;5;244m';}

have_adm_log=0
command -v adm_log_info >/dev/null 2>&1 && have_adm_log=1

_ts(){ date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([0-9][0-9]\)$/:\1/'; }
_ctx(){
  st="${ADM_STAGE:-host}"; pipe="${ADM_PIPELINE:-registry}"; path="${PWD:-/}"
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

ensure_dirs(){
  for d in "$REG_BUILD_DIR" "$REG_INSTALL_DIR" "$REG_PIPE_DIR" "$REPO_DIR" "$LOG_DIR"; do
    [ -d "$d" ] || mkdir -p "$d" || die "não foi possível criar: $d"
  done
}

lower(){ printf "%s" "$1" | tr 'A-Z' 'a-z'; }
trim(){ printf "%s" "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
sha256_file(){ command -v sha256sum >/dev/null 2>&1 || die "sha256sum ausente"; sha256sum "$1" | awk '{print $1}'; }
human(){ num="${1:-0}"; awk -v n="$num" 'BEGIN{ split("B KB MB GB TB",u); i=1; while(n>=1024 && i<5){n/=1024;i++} printf("%.1f %s", n, u[i]) }'; }

safe_rm_rf(){
  p="$1"
  [ -n "$p" ] || { say ERROR "safe_rm_rf: caminho vazio"; return 1; }
  case "$p" in /|"") say ERROR "safe_rm_rf: caminho proibido: $p"; return 1;; esac
  rm -rf -- "$p" 2>/dev/null || { say WARN "falha ao remover $p"; return 1; }
  return 0
}

# =========================
# 2) Ajuda / CLI
# =========================
usage(){
  cat <<'EOF'
Uso: adm-registry.sh <subcomando> [opções]

Listagem/consulta:
  ls [build|install|pipeline|all] [--name PAT] [--since DATE] [--until DATE] [--long] [--json]
  info <name> [--version VER] [--where build|install|both] [--json]
  files <name> --version VER [--install|--build] [--bin|--lib|--etc|--share]
  grep <pattern> [--section meta|manifest|depends]

Verificação/auditoria:
  verify <name> --version VER [--install|--build]
  diff <name> --a VER1 --b VER2 [--install|--build]
  audit [--strict]
  check-links
  link <name> --version VER [--build-from VERb]

Limpeza & GC:
  prune
  gc [--aggressive]
  orphans
  purge <name> [--version VER] [--include-install] [--include-build] [--include-cache] [--include-repo] --yes

Repositório:
  repo index [--dir DIR]
  repo verify [--dir DIR]
  repo find <name> [--version VER]

Exportação/Importação/Snapshot:
  export <name> [--version VER] --out DIR
  import --file BUNDLE [--rewrite-paths] [--keep-existing]
  snapshot [--with-packages] --out FILE

Perfis & Estágios:
  profiles show
  stage show
  stage audit

Manifest/Meta util:
  manifest cat <manifest>
  manifest to-json <manifest>
  meta get <meta> <KEY>
  meta set <meta> <KEY>=<VALUE>    # registra journal

Opções comuns:
  --json --long --yes --strict --verbose
EOF
}

parse_common_flags(){
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) JSON=1;;
      --long) LONG=1;;
      --yes) YES=1;;
      --strict) STRICT=1;;
      --verbose) VERBOSE=1;;
      *) echo "$1";; # devolve args não-consumidos
    esac
    shift || true
  done
}

# =========================
# 3) Helpers Registro
# =========================
is_pkg_dirname(){ printf "%s" "$1" | grep -Eq '^[A-Za-z0-9._+-]+-[0-9]'; }
pkg_name(){ printf "%s" "$1" | sed 's/-[0-9].*$//'; }
pkg_ver(){ printf "%s" "$1" | sed 's/^.*-\([0-9].*\)$/\1/'; }

count_manifest_files(){
  m="$1"; [ -f "$m" ] || { echo 0; return; }
  awk 'NF>=1{c++}END{print c+0}' "$m" 2>/dev/null
}

size_manifest_total(){
  m="$1"; [ -f "$m" ] || { echo 0; return; }
  # soma tamanhos reais dos arquivos atuais (instalados), best-effort
  total=0
  awk -F'\t' '{print $1}' "$m" 2>/dev/null | while read -r rel; do
    f="/$rel"
    [ -f "$f" ] && s="$(stat -c %s "$f" 2>/dev/null || echo 0)" || s=0
    echo "$s"
  done | awk '{sum+=$1}END{print sum+0}'
}

print_json_kv(){
  k="$1"; v="$2"
  printf "\"%s\":\"%s\"" "$k" "$(printf "%s" "$v" | sed 's/"/\\"/g')"
}

# =========================
# 4) Subcomando: ls
# =========================
cmd_ls(){
  scope="${1:-all}"; shift || true
  NAME_PAT=""; SINCE=""; UNTIL=""
  # parse flags
  rem="$(parse_common_flags "$@")"; set -- $rem
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) shift; NAME_PAT="$1";;
      --since) shift; SINCE="$1";;
      --until) shift; UNTIL="$1";;
      *) say ERROR "arg desconhecido: $1"; exit 10;;
    esac; shift || true
  done

  ensure_dirs
  list_build(){ ls -1 "$REG_BUILD_DIR" 2>/dev/null | sort || true; }
  list_install(){ ls -1 "$REG_INSTALL_DIR" 2>/dev/null | sort || true; }
  list_pipeline(){ ls -1 "$REG_PIPE_DIR" 2>/dev/null | sort || true; }

  show_entry(){
    base="$1"; where="$2"
    case "$where" in
      build)
        mani="$REG_BUILD_DIR/$base/build.manifest"
        meta="$REG_BUILD_DIR/$base/build.meta"
        ;;
      install)
        mani="$REG_INSTALL_DIR/$base/install.manifest"
        meta="$REG_INSTALL_DIR/$base/install.meta"
        ;;
      pipeline)
        mani=""; meta="$REG_PIPE_DIR/$base"
        ;;
    esac
    name="$(pkg_name "$base")"; ver="$(pkg_ver "$base")"
    if [ $JSON -eq 1 ]; then
      printf "{"
      print_json_kv "where" "$where"; printf ","
      print_json_kv "name" "$name"; printf ","
      print_json_kv "version" "$ver"
      if [ "$where" != "pipeline" ]; then
        cnt="$(count_manifest_files "$mani")"
        printf ","; print_json_kv "files" "$cnt"
      fi
      [ -f "$meta" ] && { ts="$(awk -F'=' '/^TIMESTAMP=/{print $2}' "$meta" 2>/dev/null | head -n1)"; [ -n "$ts" ] && { printf ","; print_json_kv "timestamp" "$ts"; }; }
      printf "}\n"
    else
      if [ $LONG -eq 1 ]; then
        cnt="-"; [ -n "$mani" ] && cnt="$(count_manifest_files "$mani")"
        ts=""; [ -f "$meta" ] && ts="$(awk -F'=' '/^TIMESTAMP=/{print $2}' "$meta" 2>/dev/null | head -n1)"
        printf "%-7s %-28s %-16s files=%-6s %s\n" "[$where]" "$name" "$ver" "$cnt" "$ts"
      else
        printf "%-7s %s %s\n" "[$where]" "$name" "$ver"
      fi
    fi
  }

  case "$scope" in
    all|build|install|pipeline) :;;
    *) say ERROR "escopo inválido: $scope"; exit 10;;
  esac

  if [ "$scope" = "all" ] || [ "$scope" = "build" ]; then
    for b in $(list_build); do
      is_pkg_dirname "$b" || continue
      [ -n "$NAME_PAT" ] && echo "$b" | grep -Eq "$NAME_PAT" || [ -z "$NAME_PAT" ] || continue
      show_entry "$b" "build"
    done
  fi
  if [ "$scope" = "all" ] || [ "$scope" = "install" ]; then
    for b in $(list_install); do
      is_pkg_dirname "$b" || continue
      [ -n "$NAME_PAT" ] && echo "$b" | grep -Eq "$NAME_PAT" || [ -z "$NAME_PAT" ] || continue
      show_entry "$b" "install"
    done
  fi
  if [ "$scope" = "all" ] || [ "$scope" = "pipeline" ]; then
    # pipeline pode ter arquivos variados, filtramos detect/env & manifests
    for f in $(list_pipeline); do
      echo "$f" | grep -Eq '\.(env|fetch|list)$' || continue
      show_entry "$f" "pipeline"
    done
  fi
}

# =========================
# 5) Subcomandos: info / files / grep
# =========================
cmd_info(){
  name="$1"; shift || true
  ver=""; where="both"
  rem="$(parse_common_flags "$@")"; set -- $rem
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) shift; ver="$1";;
      --where) shift; where="$(lower "$1")";;
      *) say ERROR "arg desconhecido: $1"; exit 10;;
    esac; shift || true
  done
  ensure_dirs
  show_one(){
    base="$1"; loc="$2"
    case "$loc" in
      build) m="$REG_BUILD_DIR/$base/build.meta"; mani="$REG_BUILD_DIR/$base/build.manifest";;
      install) m="$REG_INSTALL_DIR/$base/install.meta"; mani="$REG_INSTALL_DIR/$base/install.manifest";;
    esac
    files="$(count_manifest_files "$mani")"
    sz=0
    [ "$loc" = "install" ] && sz="$(size_manifest_total "$mani" 2>/dev/null || echo 0)"
    ts="$(awk -F'=' '/^TIMESTAMP=/{print $2}' "$m" 2>/dev/null | head -n1)"
    stg="$(awk -F'=' '/^STAGE=/{print $2}' "$m" 2>/dev/null | head -n1)"
    if [ $JSON -eq 1 ]; then
      printf "{"
      print_json_kv "where" "$loc"; printf ","
      print_json_kv "name" "$(pkg_name "$base")"; printf ","
      print_json_kv "version" "$(pkg_ver "$base")"; printf ","
      print_json_kv "stage" "$stg"; printf ","
      print_json_kv "files" "$files"; printf ","
      print_json_kv "size_bytes" "$sz"; printf ","
      print_json_kv "timestamp" "$ts"
      printf "}\n"
    else
      printf "%-7s %-28s %-16s stage=%-8s files=%-6s size=%-10s %s\n" \
        "[$loc]" "$(pkg_name "$base")" "$(pkg_ver "$base")" "${stg:-?}" "$files" "$(human "$sz")" "${ts:-}"
    fi
  }

  if [ -n "$ver" ]; then
    base="$name-$ver"
    [ "$where" = "both" ] || [ "$where" = "build" ] && [ -d "$REG_BUILD_DIR/$base" ] && show_one "$base" "build"
    [ "$where" = "both" ] || [ "$where" = "install" ] && [ -d "$REG_INSTALL_DIR/$base" ] && show_one "$base" "install"
    exit 0
  fi

  # sem versão: mostrar mais recentes
  for d in $(ls -1 "$REG_BUILD_DIR" 2>/dev/null | grep -E "^${name}-" | sort); do lastb="$d"; :; done
  for d in $(ls -1 "$REG_INSTALL_DIR" 2>/dev/null | grep -E "^${name}-" | sort); do lasti="$d"; :; done
  [ -n "${lastb:-}" ] && { [ "$where" = "both" ] || [ "$where" = "build" ]; } && show_one "$lastb" "build"
  [ -n "${lasti:-}" ] && { [ "$where" = "both" ] || [ "$where" = "install" ]; } && show_one "$lasti" "install"
}

cmd_files(){
  name="$1"; shift || true
  ver=""; which="install"; filter=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) shift; ver="$1";;
      --install) which="install";;
      --build) which="build";;
      --bin|--lib|--etc|--share) filter="${1#--}";;
      *) say ERROR "arg desconhecido: $1"; exit 10;;
    esac; shift || true
  done
  [ -n "$ver" ] || { say ERROR "use --version"; exit 10; }
  base="$name-$ver"
  case "$which" in
    install) mani="$REG_INSTALL_DIR/$base/install.manifest";;
    build)   mani="$REG_BUILD_DIR/$base/build.manifest";;
  esac
  [ -f "$mani" ] || { say ERROR "manifest não encontrado: $mani"; exit 20; }
  awk -F'\t' '{print $1}' "$mani" | while read -r rel; do
    case "$filter" in
      bin) echo "$rel" | grep -q '^/bin\|^/usr/bin' || continue;;
      lib) echo "$rel" | grep -q '^/lib\|^/usr/lib' || continue;;
      etc) echo "$rel" | grep -q '^/etc/' || continue;;
      share) echo "$rel" | grep -q '^/usr/share/' || continue;;
      "") :;;
    esac
    printf "/%s\n" "$rel"
  done
}

cmd_grep(){
  patt="$1"; shift || true
  section="all"
  while [ $# -gt 0 ]; do
    case "$1" in
      --section) shift; section="$(lower "$1")";;
      *) say ERROR "arg desconhecido: $1"; exit 10;;
    esac; shift || true
  done
  ensure_dirs
  for base in $(ls -1 "$REG_BUILD_DIR" 2>/dev/null; ls -1 "$REG_INSTALL_DIR" 2>/dev/null) ; do
    mm=""; mn=""
    case "$section" in
      meta|all)
        for m in "$REG_BUILD_DIR/$base/build.meta" "$REG_INSTALL_DIR/$base/install.meta"; do
          [ -f "$m" ] || continue
          if grep -Hn -- "$patt" "$m" 2>/dev/null; then :; fi
        done
        ;;
    esac
    case "$section" in
      manifest|all)
        for m in "$REG_BUILD_DIR/$base/build.manifest" "$REG_INSTALL_DIR/$base/install.manifest"; do
          [ -f "$m" ] || continue
          if grep -Hn -- "$patt" "$m" 2>/dev/null; then :; fi
        done
        ;;
    esac
    case "$section" in
      depends|all)
        m="$REG_BUILD_DIR/$base/depends.resolved"
        [ -f "$m" ] && grep -Hn -- "$patt" "$m" 2>/dev/null || true
        ;;
    esac
  done
}
# =========================
# 6) Verificação / diff / audit
# =========================
recalc_hash(){
  f="$1"
  [ -f "$f" ] && sha256_file "$f" 2>/dev/null || echo "-"
}

cmd_verify(){
  name="$1"; ver="$2"; which="${3:-install}"
  base="$name-$ver"
  case "$which" in
    install) mani="$REG_INSTALL_DIR/$base/install.manifest" ;;
    build)   mani="$REG_BUILD_DIR/$base/build.manifest" ;;
    *) say ERROR "tipo inválido: $which"; exit 10;;
  esac
  [ -f "$mani" ] || { say ERROR "manifest não encontrado: $mani"; exit 20; }
  say STEP "Verificando $which $base"
  bad=0
  while IFS="$(printf '\t')" read -r rel hash rest || [ -n "$rel" ]; do
    [ -n "$rel" ] || continue
    f="/$rel"
    if [ ! -e "$f" ] && [ "$which" = "install" ]; then
      say WARN "FALTANDO: /$rel"; bad=1; continue
    fi
    if [ -f "$f" ] && [ "$hash" != "-" ]; then
      h2="$(recalc_hash "$f")"
      [ "$h2" = "$hash" ] || { say WARN "ALTERADO: /$rel"; bad=1; }
    fi
  done <"$mani"
  [ $bad -eq 0 ] && { say OK; } || { say ERROR "desvios detectados"; exit 21; }
}

cmd_diff(){
  name="$1"; a="$2"; b="$3"; which="${4:-install}"
  case "$which" in
    install) A="$REG_INSTALL_DIR/${name}-${a}/install.manifest"; B="$REG_INSTALL_DIR/${name}-${b}/install.manifest";;
    build)   A="$REG_BUILD_DIR/${name}-${a}/build.manifest";    B="$REG_BUILD_DIR/${name}-${b}/build.manifest";;
  esac
  [ -f "$A" ] && [ -f "$B" ] || { say ERROR "manifests ausentes"; exit 20; }
  awk -F'\t' '{print $1}' "$A" | sort >"/tmp/.A.$$"
  awk -F'\t' '{print $1}' "$B" | sort >"/tmp/.B.$$"
  say STEP "Diff $which $name: $a → $b"
  echo "REMOVIDOS:"
  comm -23 "/tmp/.A.$$" "/tmp/.B.$$" | sed 's/^/  - \//'
  echo "ADICIONADOS:"
  comm -13 "/tmp/.A.$$" "/tmp/.B.$$" | sed 's/^/  + \//'
  rm -f "/tmp/.A.$$" "/tmp/.B.$$" 2>/dev/null || true
  say OK
}

cmd_audit(){
  [ $STRICT -eq 1 ] && say INFO "modo estrito habilitado"
  inc=0
  say STEP "Audit: integridade básica"
  # build/install meta & manifest pareados
  for base in $(ls -1 "$REG_INSTALL_DIR" 2>/dev/null); do
    [ -f "$REG_INSTALL_DIR/$base/install.manifest" ] || { say WARN "manifest faltando em install: $base"; inc=1; }
    [ -f "$REG_INSTALL_DIR/$base/install.meta" ]     || { say WARN "meta faltando em install: $base"; inc=1; }
  done
  for base in $(ls -1 "$REG_BUILD_DIR" 2>/div/null 2>/dev/null || true); do
    [ -f "$REG_BUILD_DIR/$base/build.manifest" ] || { say WARN "manifest faltando em build: $base"; inc=1; }
    [ -f "$REG_BUILD_DIR/$base/build.meta" ]     || { say WARN "meta faltando em build: $base"; inc=1; }
  done
  # repo index vs arquivos
  sums="$REPO_DIR/sha256sums.txt"
  if [ -f "$sums" ]; then
    awk '{print $2}' "$sums" 2>/dev/null | while read -r f; do
      [ -f "$REPO_DIR/$f" ] || { say WARN "no repo: listado em sha256sums.txt mas não existe: $f"; inc=1; }
    done
  fi
  [ $inc -eq 0 ] && say OK || { say WARN "audit encontrou problemas"; [ $STRICT -eq 1 ] && exit 22; }
}

# =========================
# 7) Consistência & links
# =========================
cmd_check_links(){
  say STEP "Checando correspondência build ↔ install"
  for inst in $(ls -1 "$REG_INSTALL_DIR" 2>/dev/null | sort); do
    nm="$(pkg_name "$inst")"; vr="$(pkg_ver "$inst")"
    bpath="$REG_BUILD_DIR/$inst"
    if [ ! -d "$bpath" ]; then
      say WARN "instalado sem build correspondente: $inst"
    fi
  done
  say OK
}

cmd_link(){
  name="$1"; ver="$2"; from="${3:-}"
  instdir="$REG_INSTALL_DIR/${name}-${ver}"
  [ -d "$instdir" ] || { say ERROR "install não encontrado: $instdir"; exit 20; }
  if [ -n "$from" ]; then
    builddir="$REG_BUILD_DIR/${name}-${from}"
  else
    builddir="$REG_BUILD_DIR/${name}-${ver}"
  fi
  [ -d "$builddir" ] || { say ERROR "build não encontrado: $builddir"; exit 20; }
  meta="$instdir/install.meta"
  [ -f "$meta" ] || touch "$meta"
  if grep -q "^BUILD_REF=" "$meta" 2>/dev/null; then
    sed -i "s|^BUILD_REF=.*$|BUILD_REF=$builddir|" "$meta" 2>/dev/null || die "falha edit meta"
  else
    printf "BUILD_REF=%s\n" "$builddir" >>"$meta" 2>/dev/null || die "falha escrever meta"
  fi
  say INFO "vinculado: $meta → $builddir"
}

# =========================
# 8) Limpeza / GC / órfãos / purge
# =========================
cmd_prune(){
  say STEP "Prune: limpando work/destdir órfãos"
  c=0
  for d in "$BUILD_DIR"/* 2>/dev/null; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    dest="$d/destdir"; work="$d/work"
    # mantém pkg/ sempre
    if [ -d "$work" ]; then safe_rm_rf "$work" && c=$((c+1)); fi
    if [ -d "$dest" ]; then
      # remove destdir se existir build.manifest correspondente (já empacotado)
      [ -f "$REG_BUILD_DIR/$base/build.manifest" ] && safe_rm_rf "$dest" && c=$((c+1)) || true
    fi
  done
  say INFO "removidos: $c"
  say OK
}

cmd_gc(){
  aggressive="${1:-0}"
  say STEP "GC: limpando cache não referenciado"
  kept=0; removed=0
  for d in "$CACHE_DIR"/* 2>/dev/null; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    # preserva se houver manifest.fetch ou referência recente
    mf="$CACHE_DIR/$base/manifest.fetch"
    if [ -f "$mf" ]; then kept=$((kept+1)); continue; fi
    # agressivo remove tudo que não tem build/install correspondente
    if [ "$aggressive" = "1" ]; then
      safe_rm_rf "$d" && removed=$((removed+1)) || true
    else
      kept=$((kept+1))
    fi
  done
  say INFO "kept=$kept removed=$removed"
  say OK
}

cmd_orphans(){
  say STEP "Detectando órfãos"
  # 1) installs sem arquivos no /
  for inst in $(ls -1 "$REG_INSTALL_DIR" 2>/dev/null); do
    mani="$REG_INSTALL_DIR/$inst/install.manifest"
    [ -f "$mani" ] || { say WARN "sem manifest: $inst"; continue; }
    miss=0
    awk -F'\t' '{print $1}' "$mani" | while read -r rel; do f="/$rel"; [ -e "$f" ] || miss=1; done
    [ $miss -eq 1 ] && say WARN "instalação com entradas ausentes: $inst"
  done
  # 2) pacotes no repo não indexados
  sums="$REPO_DIR/sha256sums.txt"
  if [ -f "$sums" ]; then
    for f in "$REPO_DIR"/*.tar.* "$REPO_DIR"/*.deb "$REPO_DIR"/*.rpm 2>/dev/null; do
      [ -e "$f" ] || continue
      bn="$(basename "$f")"
      grep -q " $bn\$" "$sums" 2>/dev/null || say WARN "pacote não indexado: $bn"
    done
  else
    say WARN "sha256sums.txt ausente no repo"
  fi
  say OK
}

cmd_purge(){
  name="$1"; ver="$2"; do_inst="$3"; do_build="$4"; do_cache="$5"; do_repo="$6"
  [ $YES -eq 1 ] || { say ERROR "purge exige --yes"; exit 10; }
  say STEP "Purge $name ${ver:-*}"
  pat="$name-${ver:-}"
  if [ "$do_inst" = "1" ]; then
    for d in "$REG_INSTALL_DIR"/$pat* 2>/dev/null; do [ -e "$d" ] && safe_rm_rf "$d"; done
  fi
  if [ "$do_build" = "1" ]; then
    for d in "$REG_BUILD_DIR"/$pat* 2>/dev/null; do [ -e "$d" ] && safe_rm_rf "$d"; done
    for d in "$BUILD_DIR"/$pat* 2>/dev/null; do [ -e "$d" ] && safe_rm_rf "$d"; done
  fi
  if [ "$do_cache" = "1" ]; then
    for d in "$CACHE_DIR"/$pat* 2>/dev/null; do [ -e "$d" ] && safe_rm_rf "$d"; done
  fi
  if [ "$do_repo" = "1" ]; then
    sums="$REPO_DIR/sha256sums.txt"
    for f in "$REPO_DIR"/$pat*.tar.* "$REPO_DIR"/$pat*.deb "$REPO_DIR"/$pat*.rpm 2>/dev/null; do
      [ -e "$f" ] || continue
      bn="$(basename "$f")"
      rm -f -- "$f" 2>/dev/null || true
      [ -f "$sums" ] && grep -v " $bn\$" "$sums" >"$sums.tmp" 2>/dev/null && mv "$sums.tmp" "$sums" 2>/dev/null || true
    done
  fi
  say OK
}
# =========================
# 9) Repositório (delegando ao adm-pack.sh quando possível)
# =========================
cmd_repo_index(){
  dir="${1:-$REPO_DIR}"
  if [ -x "$BIN_DIR/adm-pack.sh" ]; then
    "$BIN_DIR/adm-pack.sh" repo index --dir "$dir" || exit $?
  else
    say WARN "adm-pack.sh não encontrado — index simples"
    idx="$dir/index.json"; sums="$dir/sha256sums.txt"
    : >"$idx"; : >"$sums" || { say ERROR "falha ao criar índices"; exit 20; }
    printf "[\n" >"$idx"; first=1
    for f in "$dir"/*.tar.* "$dir"/*.deb "$dir"/*.rpm 2>/dev/null; do
      [ -e "$f" ] || continue
      bn="$(basename "$f")"; sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"; sh="$(sha256_file "$f")"
      echo "$sh  $bn" >>"$sums"
      [ $first -eq 1 ] || printf ",\n" >>"$idx"; first=0
      printf "  {\"file\":\"%s\",\"size\":%s,\"sha256\":\"%s\",\"timestamp\":\"%s\"}" "$bn" "$sz" "$sh" "$(_ts)" >>"$idx"
    done
    printf "\n]\n" >>"$idx"
  fi
  say OK
}

cmd_repo_verify(){
  dir="${1:-$REPO_DIR}"
  if [ -x "$BIN_DIR/adm-pack.sh" ]; then
    "$BIN_DIR/adm-pack.sh" repo verify --dir "$dir" || exit $?
  else
    say WARN "adm-pack.sh não encontrado — verificação simples"
    sums="$dir/sha256sums.txt"
    [ -f "$sums" ] || { say ERROR "sha256sums.txt ausente"; exit 20; }
    ok=1
    while read -r h f; do
      [ -f "$dir/$f" ] || { say ERROR "ausente no dir: $f"; ok=0; continue; }
      hl="$(sha256_file "$dir/$f")"
      [ "$hl" = "$h" ] || { say ERROR "hash divergente: $f"; ok=0; }
    done <"$sums"
    [ $ok -eq 1 ] && say OK || { say ERROR "repo inválido"; exit 22; }
  fi
}

cmd_repo_find(){
  name="$1"; ver="${2:-}"
  found=0
  for f in "$REPO_DIR"/*.tar.* "$REPO_DIR"/*.deb "$REPO_DIR"/*.rpm 2>/dev/null; do
    [ -e "$f" ] || continue
    bn="$(basename "$f")"
    echo "$bn" | grep -Eq "^${name}[-_]?${ver:-}" || continue
    echo "$bn"; found=1
  done
  [ $found -eq 1 ] || say WARN "nenhum pacote encontrado para $name $ver"
}

# =========================
# 10) Export / Import / Snapshot
# =========================
cmd_export(){
  name="$1"; ver="$2"; outdir="$3"
  base="$name-${ver:-*}"
  mkdir -p "$outdir" || { say ERROR "não foi possível criar $outdir"; exit 20; }
  tmp="$(mktemp -d 2>/dev/null || echo "/tmp/adm-exp-$$")"
  mkdir -p "$tmp/registry" "$tmp/repo" "$tmp/logs" || true
  # copia registros
  for p in "$REG_BUILD_DIR"/$base "$REG_INSTALL_DIR"/$base 2>/dev/null; do
    [ -e "$p" ] && cp -a "$p" "$tmp/registry/" 2>/dev/null || true
  done
  # pacotes do repo com nome
  for f in "$REPO_DIR"/$name*.tar.* "$REPO_DIR"/$name*.deb "$REPO_DIR"/$name*.rpm 2>/dev/null; do
    [ -e "$f" ] && cp -a "$f" "$tmp/repo/" 2>/dev/null || true
  done
  # logs opcionais
  cp -a "$LOG_DIR" "$tmp/logs/" 2>/dev/null || true
  out="$outdir/${name}-${ver:-bundle}-registry.tar.zst"
  command -v zstd >/dev/null 2>&1 && (cd "$tmp" && tar cf - . | zstd -q -T0 -o "$out") || (cd "$tmp" && tar cJf "$out".xz .)
  safe_rm_rf "$tmp" || true
  say INFO "export gerado: $out"
}

cmd_import(){
  bundle="$1"; rewrite="${2:-0}"; keep="${3:-0}"
  [ -f "$bundle" ] || { say ERROR "bundle ausente: $bundle"; exit 20; }
  tmp="$(mktemp -d 2>/dev/null || echo "/tmp/adm-imp-$$")"
  case "$bundle" in
    *.zst)  zstd -dc "$bundle" | (cd "$tmp" && tar xf -) || { safe_rm_rf "$tmp"; exit 20; };;
    *.xz)   xz -dc "$bundle" | (cd "$tmp" && tar xf -) || { safe_rm_rf "$tmp"; exit 20; };;
    *.tar)  (cd "$tmp" && tar xf "$bundle") || { safe_rm_rf "$tmp"; exit 20; };;
    *) say ERROR "formato de bundle não suportado"; safe_rm_rf "$tmp"; exit 10;;
  esac
  # merge cuidadoso
  for sub in registry repo; do
    [ -d "$tmp/$sub" ] || continue
    (cd "$tmp/$sub" && tar cf - .) | (cd "$ADM_ROOT/$sub" && tar xpf -) || true
  done
  safe_rm_rf "$tmp" || true
  say OK
}

cmd_snapshot(){
  with_pkgs="$1"; outfile="$2"
  tmp="$(mktemp -d 2>/dev/null || echo "/tmp/adm-snap-$$")"
  mkdir -p "$tmp/registry" "$tmp/repo" || true
  (cd "$ADM_ROOT/registry" && tar cf - .) | (cd "$tmp/registry" && tar xf -) || true
  cp -a "$REPO_DIR/index.json" "$REPO_DIR/sha256sums.txt" "$tmp/repo/" 2>/dev/null || true
  [ "$with_pkgs" = "1" ] && (cd "$REPO_DIR" && tar cf - *.tar.* *.deb *.rpm 2>/dev/null | (cd "$tmp/repo" && tar xf -)) || true
  command -v zstd >/dev/null 2>&1 && (cd "$tmp" && tar cf - . | zstd -q -T0 -o "$outfile") || (cd "$tmp" && tar cJf "$outfile".xz .)
  safe_rm_rf "$tmp" || true
  say INFO "snapshot: $outfile"
}

# =========================
# 11) Perfis & Estágios
# =========================
cmd_profiles_show(){
  act="$PROFILES_DIR/active"
  echo "Perfis disponíveis:"
  ls -1 "$PROFILES_DIR"/*.env 2>/dev/null | sed 's|.*/||;s|\.env$||' || true
  printf "Ativo: "
  [ -f "$act" ] && cat "$act" || echo "(desconhecido)"
}

cmd_stage_show(){
  for s in 0 1 2; do
    root="$ADM_ROOT/stage$s/root"
    [ -d "$root" ] || continue
    sz="$(du -sh "$root" 2>/dev/null | awk '{print $1}')"
    echo "stage$s: $root (size=$sz)"
  done
}

cmd_stage_audit(){
  for s in 0 1 2; do
    root="$ADM_ROOT/stage$s/root"
    [ -d "$root" ] || { say WARN "stage$s ausente"; continue; }
    for d in dev proc sys tmp; do
      [ -d "$root/$d" ] || say WARN "stage$s: $d ausente"
    done
  done
  say OK
}

# =========================
# 12) Manifest / Meta utils
# =========================
cmd_manifest_cat(){
  m="$1"; [ -f "$m" ] || { say ERROR "manifest ausente: $m"; exit 20; }
  nl -ba "$m"
}

cmd_manifest_to_json(){
  m="$1"; [ -f "$m" ] || { say ERROR "manifest ausente: $m"; exit 20; }
  printf "[\n"; first=1
  while IFS="$(printf '\t')" read -r rel h rest || [ -n "$rel" ]; do
    [ -n "$rel" ] || continue
    [ $first -eq 1 ] || printf ",\n"
    first=0
    printf "  {\"path\":\"/%s\",\"sha256\":\"%s\"}" "$rel" "$h"
  done <"$m"
  printf "\n]\n"
}

cmd_meta_get(){
  meta="$1"; key="$2"
  [ -f "$meta" ] || { say ERROR "meta ausente: $meta"; exit 20; }
  awk -F'=' -v k="$key" '$1==k{print $2}' "$meta" | head -n1
}

cmd_meta_set(){
  meta="$1"; kv="$2"
  [ -f "$meta" ] || touch "$meta"
  key="$(printf "%s" "$kv" | awk -F'=' '{print $1}')"
  val="$(printf "%s" "$kv" | cut -d'=' -f2-)"
  jnl="$meta.journal"
  printf "%s %s %s=%s\n" "$(_ts)" "$(id -un 2>/dev/null || echo root)" "$key" "$val" >>"$jnl" 2>/dev/null || true
  if grep -q "^${key}=" "$meta" 2>/dev/null; then
    sed -i "s|^${key}=.*$|${key}=${val}|" "$meta" 2>/dev/null || die "falha atualizar meta"
  else
    printf "%s=%s\n" "$key" "$val" >>"$meta" 2>/dev/null || die "falha gravar meta"
  fi
  say OK
}

# =========================
# 13) Main dispatcher
# =========================
main(){
  _color_setup
  ensure_dirs
  cmd="${1:-}"; shift || true
  case "$cmd" in
    ls)       cmd_ls "${1:-all}" "$@";;
    info)     [ $# -ge 1 ] || { usage; exit 10; }; n="$1"; shift; cmd_info "$n" "$@";;
    files)    [ $# -ge 1 ] || { usage; exit 10; }; n="$1"; shift; cmd_files "$n" "$@";;
    grep)     [ $# -ge 1 ] || { usage; exit 10; }; cmd_grep "$@";;

    verify)   [ $# -ge 3 ] || { usage; exit 10; }; cmd_verify "$1" "$2" "${3:-install}";;
    diff)     [ $# -ge 4 ] || { usage; exit 10; }; cmd_diff "$1" "$2" "$3" "${4:-install}";;
    audit)    rem="$(parse_common_flags "$@")"; set -- $rem; cmd_audit;;
    check-links) cmd_check_links;;
    link)     [ $# -ge 2 ] || { usage; exit 10; }; cmd_link "$1" "$2" "${3:-}";;

    prune)    cmd_prune;;
    gc)       [ "${1:-}" = "--aggressive" ] && cmd_gc 1 || cmd_gc 0;;
    orphans)  cmd_orphans;;
    purge)    # purge <name> [--version VER] [--include-install] [--include-build] [--include-cache] [--include-repo] --yes
              name="${1:-}"; [ -n "$name" ] || { usage; exit 10; }; shift || true
              ver=""; di=0; db=0; dc=0; dr=0
              while [ $# -gt 0 ]; do
                case "$1" in
                  --version) shift; ver="$1";;
                  --include-install) di=1;;
                  --include-build) db=1;;
                  --include-cache) dc=1;;
                  --include-repo) dr=1;;
                  --yes) YES=1;;
                  *) say ERROR "arg desconhecido: $1"; exit 10;;
                esac; shift || true
              done
              cmd_purge "$name" "$ver" "$di" "$db" "$dc" "$dr";;

    repo)     sub="${1:-}"; shift || true
              case "$sub" in
                index) cmd_repo_index "${1:-$REPO_DIR}";;
                verify) cmd_repo_verify "${1:-$REPO_DIR}";;
                find)   [ $# -ge 1 ] || { usage; exit 10; }; cmd_repo_find "$1" "${2:-}";;
                *) say ERROR "repo subcomando inválido"; usage; exit 10;;
              esac;;

    export)   [ $# -ge 3 ] || { usage; exit 10; }; cmd_export "$1" "${2:-}" "$3";;
    import)   # import --file BUNDLE [--rewrite-paths] [--keep-existing]
              [ "${1:-}" = "--file" ] || { usage; exit 10; }
              bundle="$2"; shift 2 || true
              rw=0; kp=0
              while [ $# -gt 0 ]; do
                case "$1" in --rewrite-paths) rw=1;; --keep-existing) kp=1;; *) :;; esac; shift || true
              done
              cmd_import "$bundle" "$rw" "$kp";;
    snapshot) # snapshot [--with-packages] --out FILE
              with=0; out=""
              while [ $# -gt 0 ]; do
                case "$1" in --with-packages) with=1;; --out) shift; out="$1";; *) :;; esac; shift || true
              done
              [ -n "$out" ] || { say ERROR "use --out FILE"; exit 10; }
              cmd_snapshot "$with" "$out";;

    profiles) [ "${1:-}" = "show" ] || { usage; exit 10; }; cmd_profiles_show;;
    stage)    sub="${1:-show}"; shift || true
              case "$sub" in
                show) cmd_stage_show;;
                audit) cmd_stage_audit;;
                *) say ERROR "stage subcomando inválido"; exit 10;;
              esac;;

    manifest) sub="${1:-}"; shift || true
              case "$sub" in
                cat) [ $# -ge 1 ] || { usage; exit 10; }; cmd_manifest_cat "$1";;
                to-json) [ $# -ge 1 ] || { usage; exit 10; }; cmd_manifest_to_json "$1";;
                *) say ERROR "manifest subcomando inválido"; exit 10;;
              esac;;
    meta)     sub="${1:-}"; shift || true
              case "$sub" in
                get) [ $# -ge 2 ] || { usage; exit 10; }; cmd_meta_get "$1" "$2";;
                set) [ $# -ge 2 ] || { usage; exit 10; }; cmd_meta_set "$1" "$2";;
                *) say ERROR "meta subcomando inválido"; exit 10;;
              esac;;

    -h|--help|help|"") usage; exit 0;;
    *) say ERROR "subcomando desconhecido: $cmd"; usage; exit 10;;
  esac
}

main "$@"
