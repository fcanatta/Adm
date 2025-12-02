#!/usr/bin/env bash
# adm.sh - simples gerenciador de builds e pacotes
# Estrutura:
#   /mnt/adm/
#     adm.sh
#     packages/<categoria>/<programa>/
#       programa.sh            # script de build
#       programa.deps          # dependências (uma por linha, formato categoria/programa)
#       programa.pre_install   # hook opcional
#       programa.post_install  # hook opcional
#       programa.pre_uninstall # hook opcional
#       programa.post_uninstall# hook opcional
#     cache/src
#     cache/packages
#     logs
#     db/installed
#     db/pkgs/*.meta
#     db/files/*.list

set -euo pipefail

#--------------------------------------
# Diretórios base
#--------------------------------------
ADM_ROOT="${ADM_ROOT:-/mnt/adm}"

PKG_BASE="$ADM_ROOT/packages"
CACHE_SRC="$ADM_ROOT/cache/src"
CACHE_PKG="$ADM_ROOT/cache/packages"
LOG_DIR="$ADM_ROOT/logs"
BUILD_ROOT="$ADM_ROOT/build"

DB_DIR="$ADM_ROOT/db"
DB_INSTALLED="$DB_DIR/installed"
DB_PKG_META="$DB_DIR/pkgs"
DB_PKG_FILES="$DB_DIR/files"

mkdir -p "$PKG_BASE" "$CACHE_SRC" "$CACHE_PKG" "$LOG_DIR" \
         "$BUILD_ROOT" "$DB_DIR" "$DB_PKG_META" "$DB_PKG_FILES"

#--------------------------------------
# Cores e logging
#--------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_INFO=$'\033[1;34m'
  C_WARN=$'\033[1;33m'
  C_ERR=$'\033[1;31m'
  C_OK=$'\033[1;32m'
else
  C_RESET=""; C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""
fi

LOG_FILE="$LOG_DIR/adm.log"

log_init() {
  local tag="$1"
  local ts
  ts="$(date +'%Y%m%d-%H%M%S')"
  LOG_FILE="$LOG_DIR/${tag}-${ts}.log"
  : > "$LOG_FILE"
}

_log() {
  local level="$1" color="$2"; shift 2
  local msg="$*"
  local ts
  ts="$(date +'%Y-%m-%d %H:%M:%S')"

  >&2 printf "%b[%s][%s] %s%b\n" "$color" "$ts" "$level" "$msg" "$C_RESET"
  printf "[%s][%s] %s\n" "$ts" "$level" "$msg" >> "$LOG_FILE"
}

log_info()  { _log INFO  "$C_INFO" "$*"; }
log_warn()  { _log WARN  "$C_WARN" "$*"; }
log_error() { _log ERROR "$C_ERR"  "$*"; }
log_ok()    { _log OK    "$C_OK"   "$*"; }

#--------------------------------------
# Libc / profile
#--------------------------------------
DEFAULT_LIBC="unknown"
PROFILE="${PROFILE:-}"

detect_libc() {
  if getconf GNU_LIBC_VERSION &>/dev/null; then
    DEFAULT_LIBC="glibc"
  elif ldd --version 2>&1 | grep -qi musl; then
    DEFAULT_LIBC="musl"
  elif command -v musl-gcc &>/dev/null; then
    DEFAULT_LIBC="musl"
  else
    DEFAULT_LIBC="unknown"
  fi
}

set_profile() {
  local requested="${1:-}"

  if [[ -n "$requested" ]]; then
    PROFILE="$requested"
  elif [[ -z "${PROFILE:-}" ]]; then
    PROFILE="$DEFAULT_LIBC"
  fi

  case "$PROFILE" in
    glibc)
      log_info "Usando profile de libc: glibc"
      ;;
    musl)
      log_info "Usando profile de libc: musl"
      if command -v musl-gcc &>/dev/null; then
        export CC="${CC:-musl-gcc}"
      else
        log_warn "musl-gcc não encontrado; ajuste CC/CFLAGS manualmente se necessário."
      fi
      ;;
    *)
      log_warn "Profile de libc desconhecido: '$PROFILE'. Sem ajustes especiais."
      ;;
  esac

  export PROFILE
}

#--------------------------------------
# Helpers para identificação de pacote
#--------------------------------------
PKG_CAT=""
PKG_NAME=""
PKG_ID=""          # categoria/programa
PKG_KEY=""         # categoria_programa (para arquivos em db)
PKG_META_DIR=""    # /mnt/adm/packages/categoria/programa

set_pkg_vars() {
  PKG_CAT="$1"
  PKG_NAME="$2"
  PKG_ID="${PKG_CAT}/${PKG_NAME}"
  PKG_KEY="${PKG_CAT}_${PKG_NAME}"
  PKG_META_DIR="$PKG_BASE/$PKG_CAT/$PKG_NAME"

  if [[ ! -d "$PKG_META_DIR" ]]; then
    log_error "Diretório do pacote não encontrado: $PKG_META_DIR"
    exit 1
  fi
}

#--------------------------------------
# Registro em banco simples
#--------------------------------------
register_event() {
  local action="$1" status="$2" version="$3"
  local ts
  ts="$(date +'%Y-%m-%d %H:%M:%S')"
  mkdir -p "$(dirname "$DB_INSTALLED")"
  echo "${ts}|${action}|${PKG_ID}|${version}|${PROFILE}|${status}" >> "$DB_INSTALLED"
}

#--------------------------------------
# Carregar script de build do pacote
#--------------------------------------
PKG_VERSION=""
SRC_URL=""
SRC_MD5=""
PKG_BUILD_FUNC="pkg_build"

load_pkg_script() {
  local script="$PKG_META_DIR/${PKG_NAME}.sh"
  if [[ ! -f "$script" ]]; then
    log_error "Script de build do pacote não encontrado: $script"
    exit 1
  fi

  # Limpa variáveis globais relacionadas ao pacote
  PKG_VERSION=""
  SRC_URL=""
  SRC_MD5=""
  if declare -F "$PKG_BUILD_FUNC" &>/dev/null; then
    unset -f "$PKG_BUILD_FUNC"
  fi

  # shellcheck source=/dev/null
  source "$script"

  : "${PKG_VERSION:?PKG_VERSION não definido em $script}"
  : "${SRC_URL:?SRC_URL não definido em $script}"

  if ! declare -F "$PKG_BUILD_FUNC" &>/dev/null; then
    log_error "Função $PKG_BUILD_FUNC() não definida em $script"
    exit 1
  fi
}

#--------------------------------------
# Dependências (arquivo .deps)
# formato: categoria/programa (uma por linha, # = comentário)
#--------------------------------------
declare -A BUILT_IN_SESSION
declare -A INSTALLED_IN_SESSION
declare -A UNINSTALLED_IN_SESSION

read_deps() {
  local deps_file="$PKG_META_DIR/${PKG_NAME}.deps"
  [[ ! -f "$deps_file" ]] && return 0

  local deps=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs || true)"
    [[ -z "$line" ]] && continue
    deps+=("$line")
  done < "$deps_file"

  printf '%s\n' "${deps[@]:-}"
}

#--------------------------------------
# Download + cache de source + extração
#--------------------------------------
prepare_source() {
  mkdir -p "$CACHE_SRC" "$BUILD_ROOT"

  local src_file="${SRC_URL##*/}"
  local src_cache="$CACHE_SRC/$src_file"

  if [[ ! -f "$src_cache" ]]; then
    log_info "Baixando source para cache: $SRC_URL"
    if command -v curl &>/dev/null; then
      if ! curl -L -o "$src_cache" "$SRC_URL"; then
        log_error "Falha no download com curl."
        exit 1
      fi
    elif command -v wget &>/dev/null; then
      if ! wget -O "$src_cache" "$SRC_URL"; then
        log_error "Falha no download com wget."
        exit 1
      fi
    else
      log_error "Nem curl nem wget disponíveis."
      exit 1
    fi
  else
    log_info "Usando source do cache: $src_cache"
  fi

  if [[ -n "${SRC_MD5:-}" ]]; then
    log_info "Verificando md5sum..."
    echo "${SRC_MD5}  ${src_cache}" | md5sum -c -
    log_ok "md5sum OK"
  else
    log_warn "SRC_MD5 não definido; sem verificação de integridade."
  fi

  local build_dir="$BUILD_ROOT/${PKG_CAT}/${PKG_NAME}"
  rm -rf "$build_dir"
  mkdir -p "$build_dir"

  log_info "Extraindo source em $build_dir..."
  if ! tar xf "$src_cache" -C "$build_dir"; then
    log_error "Falha ao extrair $src_cache"
    exit 1
  fi

  local top_dir
  top_dir="$(tar tf "$src_cache" | head -n1 | cut -d/ -f1)"

  if [[ -d "$build_dir/$top_dir" ]]; then
    export SRC_DIR="$build_dir/$top_dir"
  else
    export SRC_DIR="$build_dir"
  fi

  export DESTDIR="$build_dir/pkgroot"
  mkdir -p "$DESTDIR"

  log_info "SRC_DIR=$SRC_DIR"
  log_info "DESTDIR=$DESTDIR"
}

#--------------------------------------
# Empacotar resultado do build
#--------------------------------------
package_result() {
  mkdir -p "$CACHE_PKG"

  local profile_tag="${PROFILE:-$DEFAULT_LIBC}"
  [[ -z "$profile_tag" ]] && profile_tag="unknownlibc"

  local out_name="${PKG_CAT}-${PKG_NAME}-${PKG_VERSION}-${profile_tag}.tar.xz"
  local out_path="$CACHE_PKG/$out_name"

  log_info "Gerando pacote: $out_path"
  (
    cd "$DESTDIR"
    if ! tar cJf "$out_path" . ; then
      log_error "Falha ao criar pacote $out_path"
      exit 1
    fi
  )
  log_ok "Pacote gerado: $out_path"

  echo "$out_path"
}

#--------------------------------------
# Hooks
#--------------------------------------
run_hook_if_exists() {
  local hook_path="$1"
  local when="$2" # string para log: pre_install, post_install, etc.

  if [[ -f "$hook_path" ]]; then
    log_info "Executando hook $when: $hook_path"
    if ! bash "$hook_path"; then
      log_error "Hook $when falhou: $hook_path"
      exit 1
    fi
  else
    log_info "Hook $when não encontrado (ok): $hook_path"
  fi
}

#--------------------------------------
# Instalar pacote (tarball) no sistema
# - resolve dependências
# - executa hooks
# - registra arquivos
#--------------------------------------
is_pkg_installed() {
  [[ -f "$DB_PKG_META/${PKG_KEY}.meta" ]]
}

get_pkg_tarball_path() {
  local profile_tag="${PROFILE:-$DEFAULT_LIBC}"
  [[ -z "$profile_tag" ]] && profile_tag="unknownlibc"
  echo "$CACHE_PKG/${PKG_CAT}-${PKG_NAME}-${PKG_VERSION}-${profile_tag}.tar.xz"
}

install_pkg_files() {
  local tarball="$1"

  if [[ ! -f "$tarball" ]]; then
    log_error "Tarball não encontrado: $tarball"
    exit 1
  fi

  log_info "Instalando pacote no sistema a partir de: $tarball"

  # Lista de arquivos instalados
  local list_file="$DB_PKG_FILES/${PKG_KEY}.list"
  : > "$list_file"

  # Primeiro, registra quais arquivos serão criados:
  tar tf "$tarball" | while IFS= read -r path; do
    path="$(echo "$path" | sed 's#^\.\/##')"
    [[ -z "$path" ]] && continue
    echo "/$path" >> "$list_file"
  done

  # Agora extrai de fato:
  if ! tar -C / -xpf "$tarball"; then
    log_error "Falha ao extrair pacote em /"
    exit 1
  fi

  log_ok "Arquivos instalados; lista registrada em $list_file"
}

write_pkg_meta() {
  local deps_str="$1"
  local meta_file="$DB_PKG_META/${PKG_KEY}.meta"

  {
    echo "NAME=$PKG_NAME"
    echo "CATEGORY=$PKG_CAT"
    echo "ID=$PKG_ID"
    echo "VERSION=$PKG_VERSION"
    echo "PROFILE=${PROFILE:-$DEFAULT_LIBC}"
    echo "DEPS=$deps_str"
  } > "$meta_file"

  log_ok "Metadados gravados em $meta_file"
}

install_pkg_recursive() {
  # Evitar loops
  if [[ -n "${INSTALLED_IN_SESSION[$PKG_ID]:-}" ]]; then
    log_info "Pacote $PKG_ID já tratado para instalação nesta sessão."
    return 0
  fi

  # Resolve dependências primeiro
  local deps=()
  mapfile -t deps < <(read_deps || true)

  for dep in "${deps[@]}"; do
    local dep_cat="${dep%%/*}"
    local dep_name="${dep##*/}"

    log_info "Resolvendo dependência: $dep -> $dep_cat/$dep_name"
    (
      # escopo próprio
      set_pkg_vars "$dep_cat" "$dep_name"
      load_pkg_script
      build_pkg_if_needed
      install_pkg_recursive
    )
  done

  # Volta ao pacote atual (escopo externo)
  set_pkg_vars "$PKG_CAT" "$PKG_NAME"
  load_pkg_script

  if is_pkg_installed; then
    log_info "Pacote $PKG_ID já instalado. Pulando instalação."
    INSTALLED_IN_SESSION["$PKG_ID"]=1
    return 0
  fi

  # Garante tarball
  build_pkg_if_needed
  local tarball
  tarball="$(get_pkg_tarball_path)"

  # Hooks de pre-install
  run_hook_if_exists "$PKG_META_DIR/${PKG_NAME}.pre_install" "pre_install"

  # Instala arquivos
  install_pkg_files "$tarball"

  # Hooks de post-install
  run_hook_if_exists "$PKG_META_DIR/${PKG_NAME}.post_install" "post_install"

  # grava metadados e registro
  local deps_str="${deps[*]:-}"
  write_pkg_meta "$deps_str"
  register_event "install" "OK" "$PKG_VERSION"

  INSTALLED_IN_SESSION["$PKG_ID"]=1
  log_ok "Instalação de $PKG_ID concluída."
}

#--------------------------------------
# Build
#--------------------------------------
build_pkg_only() {
  local build_tag="build-${PKG_CAT}_${PKG_NAME}"
  log_init "$build_tag"

  detect_libc
  set_profile "${PROFILE:-}"

  load_pkg_script
  log_info "Iniciando build de $PKG_ID (versão $PKG_VERSION, profile $PROFILE)"

  prepare_source

  export NUMJOBS="${NUMJOBS:-$(nproc 2>/dev/null || echo 1)}"
  log_info "Chamando função $PKG_BUILD_FUNC()..."
  (
    cd "$SRC_DIR"
    "$PKG_BUILD_FUNC"
  )

  package_result >/dev/null
  register_event "build" "OK" "$PKG_VERSION"
  BUILT_IN_SESSION["$PKG_ID"]=1
  log_ok "Build de $PKG_ID concluído."
}

build_pkg_if_needed() {
  detect_libc
  set_profile "${PROFILE:-}"

  local tarball
  tarball="$(get_pkg_tarball_path)"

  if [[ -f "$tarball" ]]; then
    log_info "Tarball já existe: $tarball (não rebuildando)"
  else
    build_pkg_only
  fi
}

#--------------------------------------
# Uninstall
# - remove dependentes primeiro (reverse deps)
# - executa hooks pre/post_uninstall
#--------------------------------------
find_reverse_deps() {
  local target_id="$PKG_ID"
  local f
  for f in "$DB_PKG_META"/*.meta; do
    [[ ! -f "$f" ]] && continue
    # shellcheck disable=SC1090
    source "$f"
    local deps_str="${DEPS:-}"
    for d in $deps_str; do
      if [[ "$d" == "$target_id" ]]; then
        echo "${CATEGORY}/${NAME}"
      fi
    done
  done
}

uninstall_pkg_recursive() {
  if [[ -n "${UNINSTALLED_IN_SESSION[$PKG_ID]:-}" ]]; then
    log_info "Pacote $PKG_ID já tratado para remoção nesta sessão."
    return 0
  fi

  if ! is_pkg_installed; then
    log_warn "Pacote $PKG_ID não está registrado como instalado. Nada a fazer."
    UNINSTALLED_IN_SESSION["$PKG_ID"]=1
    return 0
  fi

  # Descobre dependentes e remove primeiro
  log_info "Verificando dependentes de $PKG_ID..."
  local rev
  mapfile -t rev < <(find_reverse_deps || true)

  for r in "${rev[@]}"; do
    local r_cat="${r%%/*}"
    local r_name="${r##*/}"
    log_info "Removendo dependente: $r"
    (
      set_pkg_vars "$r_cat" "$r_name"
      uninstall_pkg_recursive
    )
  done

  # Recarrega meta do pacote alvo para obter versão
  local meta_file="$DB_PKG_META/${PKG_KEY}.meta"
  # shellcheck disable=SC1090
  source "$meta_file"

  # Hook pre_uninstall
  run_hook_if_exists "$PKG_META_DIR/${PKG_NAME}.pre_uninstall" "pre_uninstall"

  # Remove arquivos listados
  local list_file="$DB_PKG_FILES/${PKG_KEY}.list"
  if [[ ! -f "$list_file" ]]; then
    log_warn "Lista de arquivos não encontrada para $PKG_ID: $list_file"
  else
    log_info "Removendo arquivos listados em $list_file"
    while IFS= read -r p || [[ -n "$p" ]]; do
      [[ -z "$p" ]] && continue
      if [[ -d "$p" && ! -L "$p" ]]; then
        if ! rmdir "$p" 2>/dev/null; then
          log_info "Mantendo diretório (provavelmente não vazio): $p"
        fi
      else
        if [[ -e "$p" || -L "$p" ]]; then
          if ! rm -f "$p"; then
            log_warn "Falha ao remover arquivo: $p"
          fi
        fi
      fi
    done < "$list_file"
    rm -f "$list_file"
  fi

  # Hook post_uninstall
  run_hook_if_exists "$PKG_META_DIR/${PKG_NAME}.post_uninstall" "post_uninstall"

  # Remove metadados
  rm -f "$meta_file"

  register_event "uninstall" "OK" "${VERSION:-unknown}"
  UNINSTALLED_IN_SESSION["$PKG_ID"]=1
  log_ok "Remoção de $PKG_ID concluída."
}

#--------------------------------------
# Comandos de Git (update/sync)
#--------------------------------------
git_sync() {
  local repo="${1:-$ADM_ROOT}"

  if [[ ! -d "$repo/.git" ]]; then
    log_error "Diretório $repo não é um repositório Git."
    exit 1
  fi

  log_info "Sincronizando repositório Git em $repo"
  (
    cd "$repo"
    git status --short || true

    if ! git pull --rebase; then
      log_warn "git pull --rebase falhou."
    fi

    if ! git push; then
      log_warn "git push falhou (talvez sem remote configurado ou conflitos)."
    fi
  )
  log_ok "Sync Git finalizado (verifique logs acima para detalhes)."
}

#--------------------------------------
# Listagem / info
#--------------------------------------
list_packages() {
  echo "Pacotes disponíveis em $PKG_BASE:"
  find "$PKG_BASE" -mindepth 2 -maxdepth 2 -type d | sed "s#^$PKG_BASE/##" | sort
}

show_registry() {
  if [[ -f "$DB_INSTALLED" ]]; then
    cat "$DB_INSTALLED"
  else
    echo "Nenhum registro ainda."
  fi
}

show_pkg_info() {
  local meta_file="$DB_PKG_META/${PKG_KEY}.meta"
  if [[ ! -f "$meta_file" ]]; then
    echo "Pacote $PKG_ID não está instalado ou não possui metadados."
    return 1
  fi
  cat "$meta_file"
}

usage() {
  cat <<EOF
Uso: $0 <comando> [args]

Comandos principais:
  build <categoria> <programa> [profile]      Apenas compila e gera tarball em cache
  install <categoria> <programa> [profile]    Resolve deps, build se precisar e instala com hooks
  uninstall <categoria> <programa>            Remove pacotes dependentes e depois o alvo

Outros comandos:
  list                                        Lista todos os pacotes disponíveis
  info <categoria> <programa>                 Mostra metadados do pacote instalado
  registry                                    Mostra histórico de build/install/uninstall
  git-sync [caminho_repo]                     Executa git pull/push no repositório (default: $ADM_ROOT)

Exemplos:
  $0 build dev binutils
  $0 install dev binutils musl
  $0 uninstall dev binutils
  $0 git-sync /mnt/adm
EOF
}

#--------------------------------------
# Dispatch
#--------------------------------------
cmd="${1:-}"

case "$cmd" in
  build)
    [[ $# -lt 3 ]] && { usage; exit 1; }
    cat="$2"; prog="$3"; prof="${4:-}"
    set_pkg_vars "$cat" "$prog"
    [[ -n "$prof" ]] && PROFILE="$prof"
    log_init "build-${cat}_${prog}"
    build_pkg_only
    ;;
  install)
    [[ $# -lt 3 ]] && { usage; exit 1; }
    cat="$2"; prog="$3"; prof="${4:-}"
    set_pkg_vars "$cat" "$prog"
    [[ -n "$prof" ]] && PROFILE="$prof"
    log_init "install-${cat}_${prog}"
    detect_libc
    set_profile "$PROFILE"
    install_pkg_recursive
    ;;
  uninstall)
    [[ $# -lt 3 ]] && { usage; exit 1; }
    cat="$2"; prog="$3"
    set_pkg_vars "$cat" "$prog"
    log_init "uninstall-${cat}_${prog}"
    detect_libc
    set_profile "${PROFILE:-}"
    uninstall_pkg_recursive
    ;;
  list)
    log_init "list"
    list_packages
    ;;
  registry)
    log_init "registry"
    show_registry
    ;;
  info)
    [[ $# -lt 3 ]] && { usage; exit 1; }
    cat="$2"; prog="$3"
    set_pkg_vars "$cat" "$prog"
    log_init "info-${cat}_${prog}"
    show_pkg_info
    ;;
  git-sync)
    log_init "git-sync"
    git_sync "${2:-$ADM_ROOT}"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    echo "Comando desconhecido: $cmd"
    usage
    exit 1
    ;;
esac
