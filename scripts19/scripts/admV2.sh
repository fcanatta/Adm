#!/usr/bin/env bash
# adm - gerenciador de builds e pacotes simples
#
# Layout esperado:
#   /mnt/adm/
#     adm
#     packages/<categoria>/<programa>/
#       programa.sh
#       programa.deps
#       programa.pre_install
#       programa.post_install
#       programa.pre_uninstall
#       programa.post_uninstall
#     cache/src
#     cache/packages
#     logs
#     db/installed
#     db/pkgs/*.meta
#     db/files/*.list
#  Usando o fixperms
# rebuild de um pacote qualquer
# ADM_FIXPERMS_VERBOSE=1 ./adm build categoria/pacote
# ou instalar (que internamente vai buildar se precisar)
# ADM_FIXPERMS_VERBOSE=1 ./adm install categoria/pacote
# Desativar temporariamente 
# ADM_DISABLE_FIXPERMS=1 ./adm build categoria/pacote
# Instalação simulada
# ADM_DRYRUN=1 ./adm install cross/file-pass1
# Uninstall simulada
# ADM_DRYRUN=1 ./adm uninstall cross/file-pass1

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

# --- [INÍCIO] Integração com módulo adm-fixperms --------------------

adm_load_fixperms() {
  # Carrega o módulo só uma vez
  if [[ -n "${ADM_FIXPERMS_LOADED:-}" ]]; then
    return 0
  fi

  local mod="${ADM_FIXPERMS_MODULE:-$ADM_ROOT/scripts/adm-fixperms.sh}"

  if [[ -f "$mod" ]]; then
    # shellcheck source=/mnt/adm/scripts/adm-fixperms.sh
    . "$mod"
    ADM_FIXPERMS_LOADED=1
    log_info "Módulo adm-fixperms carregado: $mod"
  else
    ADM_FIXPERMS_LOADED=0
    log_warn "Módulo de permissões não encontrado: $mod (defina ADM_DISABLE_FIXPERMS=1 se não quiser ver este aviso)"
  fi
}

adm_fixperms_wrapper() {
  local destdir="$1"

  # Se ADM_DISABLE_FIXPERMS=1, nem tenta.
  if [[ "${ADM_DISABLE_FIXPERMS:-0}" = "1" ]]; then
    log_info "fixperms desativado (ADM_DISABLE_FIXPERMS=1)"
    return 0
  fi

  if [[ -z "$destdir" || ! -d "$destdir" ]]; then
    log_warn "DESTDIR inválido para fixperms: '$destdir'"
    return 1
  fi

  adm_load_fixperms
  if [[ "${ADM_FIXPERMS_LOADED:-0}" != "1" ]]; then
    log_warn "Módulo adm-fixperms não carregado; pulando normalização de permissões."
    return 0
  fi

  log_info "Normalizando permissões em DESTDIR com adm-fixperms..."
  # Permite controlar verbosidade pelo ambiente
  ADM_FIXPERMS_VERBOSE="${ADM_FIXPERMS_VERBOSE:-0}" adm_fixperms "$destdir"
}

# --- [FIM] Integração com módulo adm-fixperms -----------------------

is_dry_run() {
  [[ "${ADM_DRYRUN:-0}" = "1" ]]
}

#--------------------------------------
# Libc / profile
#--------------------------------------
DEFAULT_LIBC="unknown"
PROFILE="${PROFILE:-}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"
DEFAULT_LIBC_DETECTED=""

detect_libc() {
  # Detecta apenas uma vez por execução
  if [[ -n "${DEFAULT_LIBC_DETECTED:-}" ]]; then
    return 0
  fi

  if getconf GNU_LIBC_VERSION &>/dev/null; then
    DEFAULT_LIBC="glibc"
  elif ldd --version 2>&1 | grep -qi musl; then
    DEFAULT_LIBC="musl"
  elif command -v musl-gcc &>/dev/null; then
    DEFAULT_LIBC="musl"
  else
    DEFAULT_LIBC="unknown"
  fi

  DEFAULT_LIBC_DETECTED=1
  log_info "Libc detectada: $DEFAULT_LIBC"
}

set_profile() {
  local requested="${1:-}"

  if [[ -n "$requested" ]]; then
    PROFILE="$requested"
  elif [[ -z "${PROFILE:-}" ]]; then
    detect_libc
    PROFILE="$DEFAULT_LIBC"
  fi

  case "$PROFILE" in
    glibc)
      log_info "Usando profile de libc: glibc"
      ;;
    musl)
      log_info "Usando profile de libc: musl"
      # Só seta CC se não estiver definido
      if [[ -z "${CC:-}" ]] && command -v musl-gcc &>/dev/null; then
        export CC="musl-gcc"
        log_info "Definindo CC=musl-gcc para profile musl"
      fi
      ;;
    *)
      detect_libc
      log_warn "Profile de libc desconhecido: '$PROFILE' (libc detectada: $DEFAULT_LIBC)"
      ;;
  esac

  export PROFILE
}

#--------------------------------------
# Identidade do pacote (globais)
#--------------------------------------
PKG_CAT=""
PKG_NAME=""
PKG_ID=""      # categoria/programa
PKG_KEY=""     # categoria_programa
PKG_META_DIR=""

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

# Resolve só pelo nome do programa (sem categoria):
resolve_pkg_by_name() {
  local name="$1"
  local -a matches=()
  local p

  # Layout esperado:
  #   packages/<categoria>/<programa>/<programa>.sh
  # Ou seja, profundidade 3 a partir de $PKG_BASE
  while IFS= read -r p; do
    matches+=("$p")
  done < <(
    find "$PKG_BASE" -mindepth 3 -maxdepth 3 -type f -name "${name}.sh" 2>/dev/null || true
  )

  local count="${#matches[@]}"
  if (( count == 0 )); then
    log_error "Pacote '${name}' não encontrado em $PKG_BASE"
    exit 1
  elif (( count > 1 )); then
    log_error "Nome de pacote '${name}' é ambíguo. Encontrados:"
    local m cat prog
    for m in "${matches[@]}"; do
      # .../packages/cat/name/name.sh
      cat="$(basename "$(dirname "$m")")"
      prog="$(basename "$m" .sh)"
      printf "  %s/%s\n" "$cat" "$prog"
    done
    exit 1
  fi

  local full="${matches[0]}"
  local cat prog
  cat="$(basename "$(dirname "$full")")"
  prog="$(basename "$full" .sh)"
  set_pkg_vars "$cat" "$prog"
}

#--------------------------------------
# Registro de eventos
#--------------------------------------
register_event() {
  local action="$1" status="$2" version="$3"
  local ts
  ts="$(date +'%Y-%m-%d %H:%M:%S')"

  if is_dry_run; then
    log_info "[dry-run] Registraria evento: ${ts}|${action}|${PKG_ID}|${version}|${PROFILE}|${status}"
    return 0
  fi

  mkdir -p "$(dirname "$DB_INSTALLED")"
  echo "${ts}|${action}|${PKG_ID}|${version}|${PROFILE}|${status}" >> "$DB_INSTALLED"
}
#--------------------------------------
# Script e variáveis do pacote
#--------------------------------------
PKG_VERSION=""
SRC_URL=""
SRC_MD5=""
PKG_BUILD_FUNC="pkg_build"

load_pkg_script() {
  local script="$PKG_META_DIR/${PKG_NAME}.sh"
  if [[ ! -f "$script" ]]; then
    log_error "Script de build não encontrado: $script"
    exit 1
  fi

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
# Dependências
#--------------------------------------
declare -A BUILT_IN_SESSION
declare -A INSTALLED_IN_SESSION
declare -A UNINSTALLED_IN_SESSION

read_deps() {
  local deps_file="$PKG_META_DIR/${PKG_NAME}.deps"
  [[ ! -f "$deps_file" ]] && return 0

  local deps=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Remove comentários
    line="${line%%#*}"
    # Trim
    line="$(echo "$line" | xargs || true)"
    [[ -z "$line" ]] && continue
    deps+=("$line")
  done < "$deps_file"

  printf '%s\n' "${deps[@]:-}"
}

# Converte DEPS / DEPS_STR de um .meta em um array
# Uso:
#   local arr=()
#   meta_deps_to_array arr
#   for d in "${arr[@]}"; do ...; done
meta_deps_to_array() {
  local __name="$1"
  local -n __out="$__name"

  __out=()

  # Caso novo/antigo: DEPS como array bash
  if declare -p DEPS &>/dev/null 2>&1; then
    if [[ "$(declare -p DEPS 2>/dev/null)" == "declare -a DEPS="* ]]; then
      __out+=("${DEPS[@]}")
    fi
  fi

  # DEPS_STR (formato string, espaço-separado)
  if [[ ${#__out[@]} -eq 0 && -n "${DEPS_STR:-}" ]]; then
    read -r -a __out <<< "$DEPS_STR"
  fi

  # Fallback: DEPS como string simples
  if [[ ${#__out[@]} -eq 0 && -n "${DEPS:-}" ]]; then
    read -r -a __out <<< "$DEPS"
  fi
}

#--------------------------------------
# Download + cache + extração
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

  # Proteção extra contra rm -rf perigoso
  if [[ -z "$build_dir" || -z "$BUILD_ROOT" ]]; then
    log_error "build_dir/BUILD_ROOT vazios; abortando por segurança."
    exit 1
  fi

  case "$build_dir" in
    "$BUILD_ROOT"/*) ;;
    *)
      log_error "build_dir '$build_dir' não está dentro de BUILD_ROOT '$BUILD_ROOT'; abortando rm -rf por segurança."
      exit 1
      ;;
  esac

  rm -rf -- "$build_dir"
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
# Empacotar resultado
#--------------------------------------
get_profile_tag() {
  local p="${PROFILE:-$DEFAULT_LIBC}"
  [[ -z "$p" ]] && p="unknownlibc"
  echo "$p"
}

get_pkg_tarball_path() {
  local profile_tag
  profile_tag="$(get_profile_tag)"
  echo "$CACHE_PKG/${PKG_CAT}-${PKG_NAME}-${PKG_VERSION}-${profile_tag}.tar.xz"
}

package_result() {
  mkdir -p "$CACHE_PKG"
  local out_path
  out_path="$(get_pkg_tarball_path)"

  # Normaliza permissões do DESTDIR antes de empacotar
  if [[ -n "${DESTDIR:-}" && -d "$DESTDIR" ]]; then
    adm_fixperms_wrapper "$DESTDIR" || \
      log_warn "Falha ao normalizar permissões em $DESTDIR (continuando mesmo assim)"
  else
    log_warn "DESTDIR não definido ou inexistente ao gerar pacote; pulando fixperms."
  fi

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
  local when="$2"

  if [[ ! -f "$hook_path" ]]; then
    log_info "Hook $when não encontrado (ok): $hook_path"
    return 0
  fi

  if is_dry_run; then
    log_info "[dry-run] Ignorando execução de hook $when: $hook_path"
    return 0
  fi

  log_info "Executando hook $when: $hook_path"
  if ! bash "$hook_path"; then
    log_error "Hook $when falhou: $hook_path"
    exit 1
  fi
}

#--------------------------------------
# Instalação
#--------------------------------------
is_pkg_installed() {
  [[ -f "$DB_PKG_META/${PKG_KEY}.meta" ]]
}

installed_mark() {
  if [[ -f "$DB_PKG_META/${PKG_KEY}.meta" ]]; then
    echo "[ ✔️]"
  else
    echo "[   ]"
  fi
}

install_pkg_files() {
  local tarball="$1"
  local list_file="$DB_PKG_FILES/${PKG_KEY}.list"

  mkdir -p "$DB_PKG_FILES"

  if is_dry_run; then
    log_info "[dry-run] Geraria lista de arquivos em $list_file a partir de $tarball"
    log_info "[dry-run] Extrairia $tarball em /"
    return 0
  fi

  log_info "Registrando arquivos de $tarball em $list_file"
  tar tf "$tarball" | sed 's|^|/|' > "$list_file"

  log_info "Extraindo $tarball em /"
  tar -C / -xpf "$tarball"
}

write_pkg_meta() {
  local deps_str="$1"
  local meta_file="$DB_PKG_META/${PKG_KEY}.meta"

  mkdir -p "$DB_PKG_META"

  {
    echo "NAME=\"$PKG_NAME\""
    echo "CATEGORY=\"$PKG_CAT\""
    echo "ID=\"$PKG_ID\""
    echo "VERSION=\"$PKG_VERSION\""
    echo "PROFILE=\"${PROFILE:-unknown}\""
    # Compatibilidade: array + string
    echo "DEPS_STR=\"$deps_str\""
    echo "DEPS=( $deps_str )"
  } > "$meta_file"

  log_info "Metadados gravados em $meta_file"
}

#--------------------------------------
# Build
#--------------------------------------
build_pkg_only() {
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

  load_pkg_script
  local tarball
  tarball="$(get_pkg_tarball_path)"

  if [[ "$FORCE_REBUILD" = "1" ]]; then
    log_info "FORCE_REBUILD ativo; rebuildando $PKG_ID"
    rm -f "$tarball"
    build_pkg_only
  elif [[ -f "$tarball" ]]; then
    log_info "Tarball já existe: $tarball (não rebuildando)"
  else
    build_pkg_only
  fi
}

#--------------------------------------
# Instalação recursiva com deps
#--------------------------------------
install_pkg_recursive() {
  # Estado: "" (não visitado), "visiting" (em processamento), "done" (finalizado)
  local state="${INSTALLED_IN_SESSION[$PKG_ID]:-}"

  if [[ "$state" == "visiting" ]]; then
    log_error "Dependência cíclica detectada envolvendo $PKG_ID"
    exit 1
  elif [[ "$state" == "done" ]]; then
    log_info "Pacote $PKG_ID já tratado para instalação nesta sessão."
    return 0
  fi

  INSTALLED_IN_SESSION["$PKG_ID"]="visiting"

  # Carrega script do pacote atual
  load_pkg_script

  # Dependências declaradas no .deps (categoria/programa)
  local deps=()
  mapfile -t deps < <(read_deps || true)

  local dep
  for dep in "${deps[@]}"; do
    [[ -z "$dep" ]] && continue

    local dep_cat="${dep%%/*}"
    local dep_name="${dep##*/}"

    log_info "Resolvendo dependência $dep_cat/$dep_name para $PKG_ID..."

    # Salva contexto do pacote atual
    local saved_cat="$PKG_CAT" saved_name="$PKG_NAME" saved_id="$PKG_ID" saved_key="$PKG_KEY" saved_meta="$PKG_META_DIR"

    set_pkg_vars "$dep_cat" "$dep_name"
    install_pkg_recursive

    # Restaura contexto
    PKG_CAT="$saved_cat"
    PKG_NAME="$saved_name"
    PKG_ID="$saved_id"
    PKG_KEY="$saved_key"
    PKG_META_DIR="$saved_meta"
  done

  # Garante que o pacote esteja construído
  build_pkg_if_needed
  local tarball
  tarball="$(get_pkg_tarball_path)"

  # Se já estiver instalado e não estamos forçando, não reinstala
  if is_pkg_installed && [[ "${FORCE_REBUILD:-0}" != "1" ]]; then
    log_info "Pacote $PKG_ID já instalado. Use FORCE_REBUILD=1 para forçar rebuild/reinstalação."
    INSTALLED_IN_SESSION["$PKG_ID"]="done"
    return 0
  fi

  # Hooks e instalação
  run_hook_if_exists "$PKG_META_DIR/${PKG_NAME}.pre_install" "pre_install"
  install_pkg_files "$tarball"
  run_hook_if_exists "$PKG_META_DIR/${PKG_NAME}.post_install" "post_install"

  local deps_str="${deps[*]:-}"
  if is_dry_run; then
    log_info "[dry-run] Não escreveria metadados de instalação (meta) para $PKG_ID"
  else
    write_pkg_meta "$deps_str"
  fi
  register_event "install" "OK" "$PKG_VERSION"

  INSTALLED_IN_SESSION["$PKG_ID"]="done"
  log_ok "Instalação de $PKG_ID concluída."
}

#--------------------------------------
# Uninstall (com dependentes)
#--------------------------------------
find_reverse_deps() {
  local target="$PKG_ID"
  local f

  [[ ! -d "$DB_PKG_META" ]] && return 0

  for f in "$DB_PKG_META"/*.meta; do
    [[ ! -f "$f" ]] && continue

    local NAME="" CATEGORY="" ID="" VERSION="" PROFILE="" DEPS=() DEPS_STR=""
    # shellcheck disable=SC1090
    source "$f"

    local deps=()
    meta_deps_to_array deps

    local d
    for d in "${deps[@]}"; do
      if [[ "$d" == "$target" ]]; then
        printf '%s/%s\n' "$CATEGORY" "$NAME"
        break
      fi
    done
  done
}

uninstall_pkg_recursive() {
  # Estado: "" (não visitado), "visiting" (em processamento), "done" (finalizado)
  local state="${UNINSTALLED_IN_SESSION[$PKG_ID]:-}"

  if [[ "$state" == "visiting" ]]; then
    log_error "Dependência reversa cíclica detectada envolvendo $PKG_ID"
    exit 1
  elif [[ "$state" == "done" ]]; then
    log_info "Pacote $PKG_ID já tratado para remoção nesta sessão."
    return 0
  fi

  if ! is_pkg_installed; then
    log_warn "Pacote $PKG_ID não está registrado como instalado. Nada a fazer."
    UNINSTALLED_IN_SESSION["$PKG_ID"]="done"
    return 0
  fi

  UNINSTALLED_IN_SESSION["$PKG_ID"]="visiting"

  log_info "Verificando dependentes de $PKG_ID..."
  local rev=()
  mapfile -t rev < <(find_reverse_deps || true)

  local r
  for r in "${rev[@]}"; do
    [[ -z "$r" ]] && continue

    local r_cat="${r%%/*}"
    local r_name="${r##*/}"

    log_info "Removendo dependente: $r"

    # Salva contexto
    local saved_cat="$PKG_CAT" saved_name="$PKG_NAME" saved_id="$PKG_ID" saved_key="$PKG_KEY" saved_meta="$PKG_META_DIR"

    set_pkg_vars "$r_cat" "$r_name"
    uninstall_pkg_recursive

    # Restaura contexto
    PKG_CAT="$saved_cat"
    PKG_NAME="$saved_name"
    PKG_ID="$saved_id"
    PKG_KEY="$saved_key"
    PKG_META_DIR="$saved_meta"
  done

  local meta_file="$DB_PKG_META/${PKG_KEY}.meta"
  if [[ ! -f "$meta_file" ]]; then
    log_warn "Metadados ausentes para $PKG_ID, removendo somente lista de arquivos se existir."
  else
    # shellcheck disable=SC1090
    source "$meta_file"
  fi

  run_hook_if_exists "$PKG_META_DIR/${PKG_NAME}.pre_uninstall" "pre_uninstall"

  local list_file="$DB_PKG_FILES/${PKG_KEY}.list"
  if [[ -f "$list_file" ]]; then
    if is_dry_run; then
      log_info "[dry-run] Removeria arquivos listados em $list_file"
      while IFS= read -r p || [[ -n "$p" ]]; do
        [[ -z "$p" ]] && continue
        log_info "[dry-run]   $p"
      done < "$list_file"
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
  else
    log_warn "Lista de arquivos não encontrada para $PKG_ID."
  fi

  run_hook_if_exists "$PKG_META_DIR/${PKG_NAME}.post_uninstall" "post_uninstall"

  local event_version="${VERSION:-${PKG_VERSION:-unknown}}"

  if is_dry_run; then
    log_info "[dry-run] Não removeria meta de instalação: $meta_file"
  else
    rm -f "$meta_file"
  fi

  register_event "uninstall" "OK" "$event_version"

  UNINSTALLED_IN_SESSION["$PKG_ID"]="done"
  log_ok "Remoção de $PKG_ID concluída."
}

#--------------------------------------
# Git sync
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
      log_warn "git push falhou (sem remote ou conflitos)."
    fi
  )
  log_ok "Sync Git finalizado."
}

#--------------------------------------
# Listagem e info
#--------------------------------------
list_packages() {
  echo "Pacotes disponíveis em $PKG_BASE:"
  # Diretórios de pacote: packages/<categoria>/<programa>/
  find "$PKG_BASE" -mindepth 2 -maxdepth 2 -type d 2>/dev/null \
    | sort \
    | while read -r d; do
        local cat prog
        cat="$(basename "$(dirname "$d")")"
        prog="$(basename "$d")"
        set_pkg_vars "$cat" "$prog"
        printf "%-20s (%s) %s\n" "$prog" "$cat" "$(installed_mark)"
      done
}

show_registry() {
  if [[ -f "$DB_INSTALLED" ]]; then
    cat "$DB_INSTALLED"
  else
    echo "Nenhum registro ainda."
  fi
}

show_pkg_info() {
  echo "Informações do pacote $PKG_ID"

  # Info vinda do script de build
  if load_pkg_script 2>/dev/null; then
    echo "Script:"
    printf "  Nome: %s\n" "$PKG_NAME"
    printf "  Categoria: %s\n" "$PKG_CAT"
    printf "  Versão declarada: %s\n" "$PKG_VERSION"
    printf "  URL: %s\n" "$SRC_URL"

    local deps_decl=()
    mapfile -t deps_decl < <(read_deps || true)
    if ((${#deps_decl[@]})); then
      printf "  Dependências declaradas (.deps): %s\n" "${deps_decl[*]}"
    else
      printf "  Dependências declaradas (.deps): (nenhuma)\n"
    fi
  else
    echo "Script de build não pôde ser carregado."
  fi

  echo

  # Info vinda do meta de instalação
  local meta_file="$DB_PKG_META/${PKG_KEY}.meta"
  if [[ ! -f "$meta_file" ]]; then
    echo "Pacote ainda não instalado (meta não encontrado: $meta_file)"
    return 0
  fi

  local NAME="" CATEGORY="" ID="" VERSION="" PROFILE="" DEPS=() DEPS_STR=""
  # shellcheck disable=SC1090
  source "$meta_file"

  echo "Meta de instalação:"
  printf "  Nome: %s\n" "$NAME"
  printf "  Categoria: %s\n" "$CATEGORY"
  printf "  ID: %s\n" "$ID"
  printf "  Versão instalada: %s\n" "$VERSION"
  printf "  Profile: %s\n" "$PROFILE"

  local deps_meta=()
  meta_deps_to_array deps_meta
  if ((${#deps_meta[@]})); then
    printf "  Dependências (meta): %s\n" "${deps_meta[*]}"
  else
    printf "  Dependências (meta): (nenhuma)\n"
  fi
}

list_installed() {
  echo "Pacotes instalados:"
  if [[ ! -d "$DB_PKG_META" ]]; then
    echo "  (nenhum pacote instalado)"
    return 0
  fi

  local f
  for f in "$DB_PKG_META"/*.meta; do
    [[ ! -f "$f" ]] && continue

    local NAME="" CATEGORY="" ID="" VERSION="" PROFILE="" DEPS=() DEPS_STR=""
    # shellcheck disable=SC1090
    source "$f"

    local deps_meta=()
    meta_deps_to_array deps_meta

    printf "Programa: %s [ ✔️]\n" "$NAME"
    printf "  Categoria: %s\n" "$CATEGORY"
    printf "  ID: %s\n" "$ID"
    printf "  Versão: %s\n" "$VERSION"
    printf "  Profile: %s\n" "$PROFILE"
    if ((${#deps_meta[@]})); then
      printf "  Dependências: %s\n" "${deps_meta[*]}"
    else
      printf "  Dependências: (nenhuma)\n"
    fi
    echo
  done
}

search_packages() {
  local pattern="$1"
  echo "Busca por: $pattern"
  find "$PKG_BASE" -mindepth 2 -maxdepth 2 -type d 2>/dev/null \
    | sort \
    | while read -r d; do
        local cat prog
        cat="$(basename "$(dirname "$d")")"
        prog="$(basename "$d")"
        if [[ "$prog" == *"$pattern"* || "$cat" == *"$pattern"* ]]; then
          set_pkg_vars "$cat" "$prog"
          printf "%-20s (%s) %s\n" "$prog" "$cat" "$(installed_mark)"
        fi
      done
}

#--------------------------------------
# Rebuild (programa ou sistema)
#--------------------------------------
rebuild_program() {
  FORCE_REBUILD=1
  detect_libc
  set_profile "${PROFILE:-}"
  install_pkg_recursive
}

rebuild_system() {
  FORCE_REBUILD=1
  detect_libc
  set_profile "${PROFILE:-}"

  if [[ ! -d "$DB_PKG_META" ]]; then
    echo "Nenhum pacote instalado para rebuild."
    return 0
  fi

  # Limpa cache de sessão
  INSTALLED_IN_SESSION=()
  BUILT_IN_SESSION=()

  local f
  for f in "$DB_PKG_META"/*.meta; do
    [[ ! -f "$f" ]] && continue
    local NAME="" CATEGORY=""
    # shellcheck disable=SC1090
    source "$f"
    log_info "Rebuild de ${CATEGORY}/${NAME}"
    set_pkg_vars "$CATEGORY" "$NAME"
    install_pkg_recursive
  done
}

#--------------------------------------
# Usage
#--------------------------------------
usage() {
  cat <<EOF
Uso: $0 <comando> [args]

Comandos principais:
  build <programa>                 Compila e gera tarball em cache
  install <programa> [profile]     Resolve deps, build se precisar e instala (com hooks)
  uninstall <programa>             Remove dependentes e depois o programa

Rebuild:
  rebuild <programa>               Reconstrói (build + reinstall) o programa e deps
  rebuild-system                   Reconstrói todo o sistema instalado com deps organizadas

Consulta:
  list                             Lista todos os programas disponíveis (com [ ✔️] se instalados)
  search <padrão>                  Procura programa pelo nome/categoria, mostra [ ✔️] se instalado
  info <programa>                  Mostra informações do programa + estado [ ✔️] se instalado
  installed                        Lista todos os programas instalados com todas as informações
  registry                         Mostra histórico de build/install/uninstall

Git:
  git-sync [caminho_repo]          Executa git pull/push no repositório (default: $ADM_ROOT)

Exemplos:
  $0 build binutils
  $0 install binutils musl
  $0 uninstall binutils
  $0 rebuild binutils
  $0 rebuild-system
  $0 search bin
  $0 info binutils
  $0 installed
EOF
}

#--------------------------------------
# Dispatch
#--------------------------------------
cmd="${1:-}"

case "$cmd" in
  build)
    [[ $# -lt 2 ]] && { usage; exit 1; }
    prog="$2"
    log_init "build-${prog}"
    resolve_pkg_by_name "$prog"
    build_pkg_only
    ;;
  install)
    [[ $# -lt 2 ]] && { usage; exit 1; }
    prog="$2"; prof="${3:-}"
    log_init "install-${prog}"
    resolve_pkg_by_name "$prog"
    [[ -n "$prof" ]] && PROFILE="$prof"
    INSTALLED_IN_SESSION=()
    install_pkg_recursive
    ;;
  uninstall)
    [[ $# -lt 2 ]] && { usage; exit 1; }
    prog="$2"
    log_init "uninstall-${prog}"
    resolve_pkg_by_name "$prog"
    UNINSTALLED_IN_SESSION=()
    detect_libc
    set_profile "${PROFILE:-}"
    uninstall_pkg_recursive
    ;;
  rebuild)
    [[ $# -lt 2 ]] && { usage; exit 1; }
    prog="$2"
    log_init "rebuild-${prog}"
    resolve_pkg_by_name "$prog"
    INSTALLED_IN_SESSION=()
    rebuild_program
    ;;
  rebuild-system)
    log_init "rebuild-system"
    rebuild_system
    ;;
  list)
    log_init "list"
    list_packages
    ;;
  search)
    [[ $# -lt 2 ]] && { usage; exit 1; }
    pattern="$2"
    log_init "search-${pattern}"
    search_packages "$pattern"
    ;;
  info)
    [[ $# -lt 2 ]] && { usage; exit 1; }
    prog="$2"
    log_init "info-${prog}"
    resolve_pkg_by_name "$prog"
    show_pkg_info
    ;;
  installed)
    log_init "installed"
    list_installed
    ;;
  registry)
    log_init "registry"
    show_registry
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
