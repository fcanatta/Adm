#!/usr/bin/env bash
# adm - mini gerenciador de pacotes / build system

set -euo pipefail

### CONFIGURAÇÃO GERAL #########################################################

ADM_REPO_URL="${ADM_REPO_URL:-https://github.com/fcanatta/Adm.git}"
ADM_REPO_DIR="${ADM_REPO_DIR:-/usr/src/adm}"
PKG_BASE_DIR="${ADM_REPO_DIR}/packages"

CACHE_SRC="${CACHE_SRC:-/var/cache/adm/sources}"
CACHE_PKG="${CACHE_PKG:-/var/cache/adm/packages}"

DB_DIR="${DB_DIR:-/var/lib/adm/db}"
PROFILES_DIR="${PROFILES_DIR:-/etc/adm/profiles}"

LOG_DIR="${LOG_DIR:-/var/log/adm}"
LOG_FILE="${LOG_DIR}/adm.log"

mkdir -p "$CACHE_SRC" "$CACHE_PKG" "$DB_DIR" "$LOG_DIR"

### CORES E LOG ###############################################################

if [ -t 1 ]; then
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    BLUE=$'\033[34m'
    MAGENTA=$'\033[35m'
    CYAN=$'\033[36m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; BOLD=""; RESET=""
fi

timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

log_append_file() {
    local level="$1"; shift
    printf "[%s] %s: %s\n" "$(timestamp)" "$level" "$*" >> "$LOG_FILE"
}

log_info() {
    log_append_file "INFO" "$@"
    printf "%s[INFO]%s %s\n" "$BLUE" "$RESET" "$*"
}

log_warn() {
    log_append_file "WARN" "$@"
    printf "%s[WARN]%s %s\n" "$YELLOW" "$RESET" "$*" >&2
}

log_error() {
    log_append_file "ERROR" "$@"
    printf "%s[ERRO]%s %s\n" "$RED" "$RESET" "$*" >&2
}

log_success() {
    log_append_file "OK" "$@"
    printf "%s[ OK ]%s %s\n" "$GREEN" "$RESET" "$*"
}

die() {
    log_error "$*"
    exit 1
}

# Escapa um valor para ser seguro em arquivos .meta/.buildinfo (código shell)
sh_quote() {
  # Usa printf %q (bash) para gerar uma representação segura
  local q
  printf -v q '%q' "$1"
  printf '%s' "$q"
}

### UTILITÁRIOS ###############################################################

usage() {
    cat <<EOF
${BOLD}Uso:${RESET} adm <comando> [args]

Comandos principais:
  ${BOLD}build${RESET}    <programa|categoria/programa>   - compila e gera tar.zst (glibc/musl detectado)
  ${BOLD}install${RESET}  <programa|categoria/programa>   - instala no rootfs correspondente
  ${BOLD}uninstall${RESET} <programa|categoria/programa>  - remove com checagem de dependências reversas
  ${BOLD}search${RESET}   <padrão>                       - procura pacotes, mostra [ ✔️ ] se instalado
  ${BOLD}info${RESET}     <programa|categoria/programa>  - mostra informações do pacote + [ ✔️ ] se instalado
  ${BOLD}list${RESET}                                    - lista pacotes instalados
  ${BOLD}update-repo${RESET}                             - sincroniza /usr/src/adm com o git

Variáveis úteis:
  ADM_LIBC=glibc|musl     (força libc em vez de autodetectar)

Diretórios:
  Repo de pacotes: ${PKG_BASE_DIR}
  Cache sources:   ${CACHE_SRC}
  Cache pkgs:      ${CACHE_PKG}
  Banco de dados:  ${DB_DIR}
  Logs:            ${LOG_FILE}
EOF
}

check_requirements() {
  local missing=()

  # Ferramentas realmente essenciais para o fluxo principal
  for cmd in git find tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  # Compressor: precisa de pelo menos um
  if ! command -v zstd >/dev/null 2>&1 && ! command -v xz >/dev/null 2>&1; then
    missing+=("zstd/xz")
  fi

  if ((${#missing[@]} > 0)); then
    log_error "Dependências externas ausentes: ${missing[*]}"
    die "Instale os comandos acima e tente novamente."
  fi
}

ensure_repo() {
    if [ -d "$ADM_REPO_DIR/.git" ]; then
        # Já é um repositório git, nada a fazer
        return 0
    fi

    # Se o diretório existe mas não é git, evita sobrescrever coisas silenciosamente
    if [ -d "$ADM_REPO_DIR" ] && [ "$(ls -A "$ADM_REPO_DIR" 2>/dev/null | wc -l)" -ne 0 ]; then
        log_error "ADM_REPO_DIR existe mas não é um repositório git: $ADM_REPO_DIR"
        log_error "Por segurança, não vou clonar por cima de um diretório não vazio."
        log_error "Ajuste ADM_REPO_DIR ou inicialize o repositório git manualmente."
        die "Repositório ADM inválido em $ADM_REPO_DIR"
    fi

    log_info "Clonando repositório em $ADM_REPO_DIR..."
    mkdir -p "$(dirname "$ADM_REPO_DIR")"
    git clone "$ADM_REPO_URL" "$ADM_REPO_DIR" || die "Falha ao clonar repositório."
}

detect_libc() {
    local arg_libc="${1:-}"
    local libc=""

    if [ -n "$arg_libc" ]; then
        libc="$arg_libc"
    elif [ -n "${ADM_LIBC:-}" ]; then
        libc="$ADM_LIBC"
    elif command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
        libc="musl"
    else
        libc="glibc"
    fi

    case "$libc" in
        glibc|musl)
            echo "$libc"
            ;;
        *)
            die "libc inválida ou desconhecida: '$libc' (esperado: glibc ou musl)"
            ;;
    esac
}

rootfs_for_libc() {
    case "$1" in
        glibc) echo "/opt/systems/glibc-rootfs" ;;
        musl)  echo "/opt/systems/musl-rootfs" ;;
        *) die "libc desconhecida: $1" ;;
    esac
}

pkg_dir() {
    local cat="$1" pkg="$2"
    echo "${PKG_BASE_DIR}/${cat}/${pkg}"
}

meta_path() {
    local cat="$1" pkg="$2" libc="$3"
    echo "${DB_DIR}/${cat}__${pkg}__${libc}.meta"
}

files_path() {
    local cat="$1" pkg="$2" libc="$3"
    echo "${DB_DIR}/${cat}__${pkg}__${libc}.files"
}

buildinfo_path() {
    local cat="$1" pkg="$2" libc="$3"
    echo "${CACHE_PKG}/${cat}__${pkg}__${libc}.buildinfo"
}

load_profile() {
    local libc="$1"
    local profile="${PROFILES_DIR}/${libc}.profile"
    if [ -f "$profile" ]; then
        # Carrega com proteção: se der erro de sintaxe, não mata o adm todo
        if ! . "$profile"; then
            log_error "Falha ao carregar profile $profile (erro de shell). Continuando sem profile."
        fi
    else
        log_warn "Profile $profile não encontrado. Continuando sem profile específico."
    fi
}

read_deps_file() {
    local depfile="$1"
    [ -f "$depfile" ] || return 0
    grep -Ev '^\s*($|#)' "$depfile" || true
}

pkg_is_installed_any_libc() {
    local cat="$1" pkg="$2"
    local meta
    for meta in "${DB_DIR}/${cat}__${pkg}__"*.meta; do
        [ -f "$meta" ] && return 0
    done
    return 1
}

find_reverse_deps() {
    local target="$1" libc="$2"
    local meta
    for meta in "$DB_DIR"/*.meta; do
        [ -e "$meta" ] || continue
        unset PKG_ID PKG_DEPS PKG_LIBC
        # Carrega o meta com proteção contra sintaxe inválida
        if ! . "$meta"; then
            log_warn "Falha ao ler meta $meta (arquivo inválido?), ignorando para reverse deps."
            continue
        fi
        [ "${PKG_LIBC:-}" = "$libc" ] || continue
        for d in ${PKG_DEPS:-}; do
            if [ "$d" = "$target" ]; then
                echo "${PKG_ID:-unknown}"
            fi
        done
    done
}

run_hook() {
    # $1 = phase (pre_install / post_install / pre_uninstall / post_uninstall)
    # $2 = caminho do hook (arquivo único)
    # $3 = rootfs
    # $4 = cat
    # $5 = pkg
    # $6 = libc
    # $7 = version
    local phase="$1" hook="$2" rootfs="$3" cat="$4" pkg="$5" libc="$6" version="$7"

    # Se não existir, não faz nada (hook opcional)
    if [ -z "$hook" ] || [ ! -e "$hook" ]; then
        return 0
    fi

    # Se existir mas não for executável, avisa e não roda
    if [ ! -x "$hook" ]; then
        log_warn "Hook ${phase} encontrado mas não executável: $hook (ignorando)"
        return 0
    fi

    log_info "Executando hook ${phase}: ${hook}"

    # Executa hook com ambiente definido e reporta erros claramente
    set +e
    ROOTFS="$rootfs" \
    ADM_CATEGORY="$cat" \
    ADM_PKG_NAME="$pkg" \
    ADM_LIBC="$libc" \
    ADM_PKG_VERSION="$version" \
    sh "$hook"
    local status=$?
    set -e

    if [ $status -ne 0 ]; then
        log_error "Hook ${phase} ($hook) falhou com status $status"
        exit $status
    fi
}

resolve_build_deps() {
  local libc="$1" cat="$2" pkg="$3"
  local depfile dep current resolved dcat dpkg _ dep_id

  depfile="$(pkg_dir "$cat" "$pkg")/pkg.deps"
  current="${cat}/${pkg}"

  # Atualiza "pilha" de dependências para detecção de ciclos
  if [[ " ${ADM_DEP_STACK:-} " != *" ${current} "* ]]; then
    ADM_DEP_STACK="${ADM_DEP_STACK:+$ADM_DEP_STACK }${current}"
    export ADM_DEP_STACK
  fi

  # Lê arquivo de dependências (se existir)
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue

    resolved="$(resolve_pkg_single "$dep")" || die "Dependência '$dep' não encontrada para ${current}"
    dcat="${resolved%%|*}"
    _="${resolved#*|}"; dpkg="${_%|*}"
    dep_id="${dcat}/${dpkg}"

    log_info "(build) Dependência: '$dep' -> '${dep_id}'"

    # Verifica ciclo de dependência
    if [[ " ${ADM_DEP_STACK:-} " == *" ${dep_id} "* ]]; then
      die "Dependência cíclica detectada: ${dep_id} (stack: ${ADM_DEP_STACK})"
    fi

    # Evita processar o mesmo pacote várias vezes na mesma resolução
    if [[ " ${ADM_DEP_SEEN_BUILD:-} " == *" ${dep_id} "* ]]; then
      log_info "(build) Dependência '${dep_id}' já processada nesta resolução, pulando."
      continue
    fi
    ADM_DEP_SEEN_BUILD="${ADM_DEP_SEEN_BUILD:+$ADM_DEP_SEEN_BUILD }${dep_id}"
    export ADM_DEP_SEEN_BUILD

    # Faz build da dependência (que também será instalada depois em cmd_install)
    cmd_build "${dep_id}" "$libc"
    cmd_install "${dep_id}" "$libc"
  done < <(read_deps_file "$depfile")
}

resolve_install_deps() {
  local libc="$1" cat="$2" pkg="$3"
  local depfile dep current resolved dcat dpkg _ dep_id meta filesdb

  depfile="$(pkg_dir "$cat" "$pkg")/pkg.deps"
  current="${cat}/${pkg}"

  if [[ " ${ADM_DEP_STACK:-} " != *" ${current} "* ]]; then
    ADM_DEP_STACK="${ADM_DEP_STACK:+$ADM_DEP_STACK }${current}"
    export ADM_DEP_STACK
  fi

  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue

    resolved="$(resolve_pkg_single "$dep")" || die "Dependência '$dep' não encontrada para ${current}"
    dcat="${resolved%%|*}"
    _="${resolved#*|}"; dpkg="${_%|*}"
    dep_id="${dcat}/${dpkg}"

    log_info "(install) Dependência: '$dep' -> '${dep_id}'"

    if [[ " ${ADM_DEP_STACK:-} " == *" ${dep_id} "* ]]; then
      die "Dependência cíclica detectada na instalação: ${dep_id} (stack: ${ADM_DEP_STACK})"
    fi

    # Evita processamento repetido da mesma dependência
    if [[ " ${ADM_DEP_SEEN_INSTALL:-} " == *" ${dep_id} "* ]]; then
      log_info "(install) Dependência '${dep_id}' já processada nesta resolução, pulando."
      continue
    fi
    ADM_DEP_SEEN_INSTALL="${ADM_DEP_SEEN_INSTALL:+$ADM_DEP_SEEN_INSTALL }${dep_id}"
    export ADM_DEP_SEEN_INSTALL

    # Se já está instalada para essa libc, não precisa chamar cmd_install
    meta="$(meta_path "$dcat" "$dpkg" "$libc")"
    filesdb="$(files_path "$dcat" "$dpkg" "$libc")"
    if [[ -f "$meta" && -f "$filesdb" ]]; then
      log_info "(install) Dependência '${dep_id}' já instalada para libc '$libc', pulando."
      continue
    fi

    cmd_install "${dep_id}" "$libc"
  done < <(read_deps_file "$depfile")
}

### RESOLUÇÃO DE PACOTE (NOME -> CATEGORIA/PROGRAMA) ###########################
# Retorna EXACTAMENTE uma linha: "categoria|programa|diretorio"
resolve_pkg_single() {
    local name="$1"

    [ -d "$PKG_BASE_DIR" ] || die "Diretório de pacotes não encontrado: $PKG_BASE_DIR"

    # Se vier como categoria/programa
    if [[ "$name" == */* ]]; then
        local cat="${name%/*}"
        local pkg="${name##*/}"
        local dir="${PKG_BASE_DIR}/${cat}/${pkg}"
        [ -d "$dir" ] || die "Pacote '$name' não encontrado em $PKG_BASE_DIR"
        echo "${cat}|${pkg}|${dir}"
        return 0
    fi

    # Caso contrário, procurar por nome em todas categorias
    local matches=()
    while IFS= read -r -d '' dir; do
        local pkg
        pkg="$(basename "$dir")"
        local cat
        cat="$(basename "$(dirname "$dir")")"
        [ "$pkg" = "$name" ] || continue
        if [ -x "${dir}/${pkg}.sh" ]; then
            matches+=("${cat}|${pkg}|${dir}")
        fi
    done < <(find "$PKG_BASE_DIR" -mindepth 2 -maxdepth 2 -type d -print0)

    local count="${#matches[@]}"

    if [ "$count" -eq 0 ]; then
        die "Pacote '$name' não encontrado em $PKG_BASE_DIR"
    elif [ "$count" -gt 1 ]; then
        log_error "Mais de um pacote com nome '$name' encontrado:"
        local m
        for m in "${matches[@]}"; do
            IFS='|' read -r cat pkg dir <<< "$m"
            printf "  - %s/%s (%s)\n" "$cat" "$pkg" "$dir" >&2
        done
        die "Use 'categoria/nome' para desambiguar (ex: utils/${name})."
    fi

    echo "${matches[0]}"
}

adm_finalize_build() {
  local libc="$1" cat="$2" pkg="$3"
  local buildinfo build_root destdir tarball version

  buildinfo="$(buildinfo_path "$cat" "$pkg" "$libc")"
  build_root="${ADM_BUILD_ROOT:-/tmp/adm-build-${cat}-${pkg}-${libc}}"
  destdir="${ADM_DESTDIR:-${build_root}/destdir}"

  if [[ ! -d "$destdir" ]]; then
    die "DESTDIR '$destdir' não existe. Certifique-se de que o script de build instalou arquivos em ADM_DESTDIR."
  fi

  log_info "Finalizando build de ${cat}/${pkg} para ${libc} em '${destdir}'"

  # Strip em binários ELF, se possível
  if command -v strip >/dev/null 2>&1 && command -v file >/dev/null 2>&1; then
    log_info "Aplicando strip em binários ELF..."
    while IFS= read -r f; do
      if file "$f" 2>/dev/null | grep -qi 'elf'; then
        strip --strip-unneeded "$f" || log_warn "Falha no strip de '$f' (ignorando)."
      fi
    done < <(find "$destdir" -type f -perm -u+x 2>/dev/null || true)
  else
    log_warn "Comandos 'strip' ou 'file' não encontrados. Pulando strip de binários."
  fi

  mkdir -p "$CACHE_PKG"

  if command -v zstd >/dev/null 2>&1; then
    tarball="${CACHE_PKG}/${cat}__${pkg}__${libc}.tar.zst"
    tar -C "$destdir" -I "zstd -19 --long=31" -cf "$tarball" . || die "Falha ao criar tarball com zstd."
  else
    tarball="${CACHE_PKG}/${cat}__${pkg}__${libc}.tar.xz"
    log_warn "zstd não encontrado, usando xz para o tarball."
    tar -C "$destdir" -Jcf "$tarball" . || die "Falha ao criar tarball com xz."
  fi

  version="${ADM_PKG_VERSION:-${PKG_VERSION:-unknown}}"

  {
    printf 'PKG_ID=%s\n'       "$(sh_quote "${cat}/${pkg}")"
    printf 'PKG_NAME=%s\n'     "$(sh_quote "${pkg}")"
    printf 'PKG_CATEGORY=%s\n' "$(sh_quote "${cat}")"
    printf 'PKG_VERSION=%s\n'  "$(sh_quote "${version}")"
    printf 'PKG_LIBC=%s\n'     "$(sh_quote "${libc}")"
    printf 'PKG_TARBALL=%s\n'  "$(sh_quote "${tarball}")"
  } > "$buildinfo"

  log_success "Pacote empacotado em: ${tarball}"
  log_info "Buildinfo registrado em: ${buildinfo}"
}

### COMANDOS ###################################################################

cmd_update_repo() {
    ensure_repo
    log_info "Atualizando repositório em $ADM_REPO_DIR..."
    (cd "$ADM_REPO_DIR" && git pull --ff-only) || die "Falha ao atualizar repositório."
    log_success "Repositório atualizado."
}

cmd_build() {
  local name="$1"
  local libc
  libc="$(detect_libc "${2:-}")"

  local rootfs
  rootfs="$(rootfs_for_libc "$libc")"

  ensure_repo

  local resolved cat pkg pdir build_script
  resolved="$(resolve_pkg_single "$name")"
  cat="${resolved%%|*}"
  resolved="${resolved#*|}"; pkg="${resolved%%|*}"
  pdir="${resolved##*|}"

  build_script="${pdir}/${pkg}.sh"
  if [[ ! -x "$build_script" ]]; then
    die "Script de build não encontrado ou não executável: ${build_script}"
  fi

  log_info "Iniciando build de ${cat}/${pkg} para libc '${libc}'"

  load_profile "$libc"
  resolve_build_deps "$libc" "$cat" "$pkg"

  # build_root único por processo, para evitar conflitos em builds paralelos
  local build_root="/tmp/adm-build-${cat}-${pkg}-${libc}.$$"
  local destdir="${build_root}/destdir"

  rm -rf "$build_root"
  mkdir -p "$build_root" "$destdir" "$CACHE_SRC" "$CACHE_PKG"

  export ADM_CATEGORY="$cat"
  export ADM_PKG_NAME="$pkg"
  export ADM_LIBC="$libc"
  export ADM_ROOTFS="$rootfs"
  export ADM_CACHE_SRC="$CACHE_SRC"
  export ADM_CACHE_PKG="$CACHE_PKG"
  export ADM_BUILDINFO
  ADM_BUILDINFO="$(buildinfo_path "$cat" "$pkg" "$libc")"
  export ADM_BUILD_ROOT="$build_root"
  export ADM_DESTDIR="$destdir"

  bash "$build_script" build "$libc"

  adm_finalize_build "$libc" "$cat" "$pkg"

  log_success "Build concluído de ${cat}/${pkg} para '${libc}'"
}

cmd_install() {
  local name="$1"
  local libc
  libc="$(detect_libc "${2:-}")"

  local rootfs
  rootfs="$(rootfs_for_libc "$libc")"

  ensure_repo
  mkdir -p "$rootfs"

  local resolved cat pkg pdir
  resolved="$(resolve_pkg_single "$name")"
  cat="${resolved%%|*}"
  resolved="${resolved#*|}"; pkg="${resolved%%|*}"
  pdir="${resolved##*|}"

  local meta filesdb buildinfo
  meta="$(meta_path "$cat" "$pkg" "$libc")"
  filesdb="$(files_path "$cat" "$pkg" "$libc")"
  buildinfo="$(buildinfo_path "$cat" "$pkg" "$libc")"

  # Se já está instalado para esta libc, não faz nada
  if [[ -f "$meta" && -f "$filesdb" ]]; then
    log_info "Pacote ${cat}/${pkg} já está instalado para libc '${libc}'. Nenhuma ação necessária."
    return 0
  fi

  # Se não há buildinfo ainda, faz build primeiro
  if [[ ! -f "$buildinfo" ]]; then
    log_warn "Buildinfo não encontrado para ${cat}/${pkg} (${libc}). Rodando build..."
    cmd_build "${cat}/${pkg}" "$libc"
  fi

  # Carrega buildinfo
  # shellcheck disable=SC1090
  . "$buildinfo"

  if [[ -z "${PKG_TARBALL:-}" ]]; then
    die "PKG_TARBALL não definido em buildinfo: ${buildinfo}"
  fi
  if [[ ! -f "$PKG_TARBALL" ]]; then
    die "Tarball de pacote não encontrado: ${PKG_TARBALL}"
  fi

  resolve_install_deps "$libc" "$cat" "$pkg"

  local pre_hook="${pdir}/${pkg}.pre_install"
  local post_hook="${pdir}/${pkg}.post_install"

  run_hook "pre_install" "$pre_hook" "$rootfs" "$cat" "$pkg" "$libc" "${PKG_VERSION:-unknown}"

  log_info "Instalando tarball '${PKG_TARBALL}' em '${rootfs}'"

  local filelist
  filelist="$(mktemp)"
  tar -tf "$PKG_TARBALL" > "$filelist"

  tar -C "$rootfs" -xf "$PKG_TARBALL"

  mv "$filelist" "$filesdb"

  {
    printf 'PKG_ID=%s\n'       "$(sh_quote "${cat}/${pkg}")"
    printf 'PKG_NAME=%s\n'     "$(sh_quote "${pkg}")"
    printf 'PKG_CATEGORY=%s\n' "$(sh_quote "${cat}")"
    printf 'PKG_VERSION=%s\n'  "$(sh_quote "${PKG_VERSION:-unknown}")"
    printf 'PKG_LIBC=%s\n'     "$(sh_quote "${libc}")"
    printf 'PKG_TARBALL=%s\n'  "$(sh_quote "${PKG_TARBALL}")"

    # Dependências deste pacote (não recursivas)
    local deps_line
    deps_line="$(read_deps_file "${pdir}/${pkg}.deps" | tr '\n' ' ' || true)"
    printf 'PKG_DEPS=%s\n' "$(sh_quote "${deps_line}")"
  } > "$meta"

  run_hook "post_install" "$post_hook" "$rootfs" "$cat" "$pkg" "$libc" "${PKG_VERSION:-unknown}"

  log_success "Instalação concluída de ${cat}/${pkg} para '${libc}'"
}

cmd_uninstall() {
  local name="$1"
  local libc
  libc="$(detect_libc "${2:-}")"

  local rootfs
  rootfs="$(rootfs_for_libc "$libc")"

  local resolved cat pkg pdir
  resolved="$(resolve_pkg_single "$name")"
  cat="${resolved%%|*}"
  resolved="${resolved#*|}"; pkg="${resolved%%|*}"
  pdir="${resolved##*|}"

  local meta filesdb
  meta="$(meta_path "$cat" "$pkg" "$libc")"
  filesdb="$(files_path "$cat" "$pkg" "$libc")"

  if [[ ! -f "$meta" || ! -f "$filesdb" ]]; then
    die "Pacote ${cat}/${pkg} (${libc}) não parece estar instalado (faltam arquivos em ${DB_DIR})."
  fi

  # Carrega metadata de forma segura
  if ! . "$meta"; then
    log_error "Arquivo de metadata inválido ou corrompido: ${meta}"
    die "Não foi possível carregar metadata para ${cat}/${pkg} (${libc})."
  fi

  local target="${cat}/${pkg}"
  local rdeps
  rdeps="$(find_reverse_deps "$target" "$libc" || true)"

  if [[ -n "$rdeps" ]]; then
    log_error "Não é possível remover ${target} (${libc}). Outros pacotes dependem dele:"
    printf '%s\n' "$rdeps"
    die "Remoção abortada devido a dependências reversas."
  fi

  local pre_hook="${pdir}/${pkg}.pre_uninstall"
  local post_hook="${pdir}/${pkg}.post_uninstall"

  run_hook "pre_uninstall" "$pre_hook" "$rootfs" "$cat" "$pkg" "$libc" "${PKG_VERSION:-unknown}"

  log_info "Removendo arquivos de ${target} (${libc})"

  # Remove arquivos listados, com verificação básica de segurança de caminho
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue

    case "$path" in
      /*)
        log_warn "Caminho absoluto inválido em '${filesdb}': '${path}'. Ignorando."
        continue
        ;;
      *'..'*)
        log_warn "Caminho inseguro (contém '..') em '${filesdb}': '${path}'. Ignorando."
        continue
        ;;
    esac

    rm -f "${rootfs}/${path}" || log_warn "Falha ao remover arquivo '${rootfs}/${path}'"
  done < "$filesdb"

  # Tenta remover diretórios vazios (em ordem reversa)
  sort -r "$filesdb" 2>/dev/null | while IFS= read -r path; do
    [[ -z "$path" ]] && continue

    case "$path" in
      /*|*'..'*)
        # já avisamos acima quando necessário
        continue
        ;;
    esac

    local dir
    dir="$(dirname "$path")"
    rmdir --ignore-fail-on-non-empty "${rootfs}/${dir}" 2>/dev/null || true
  done

  rm -f "$meta" "$filesdb"

  run_hook "post_uninstall" "$post_hook" "$rootfs" "$cat" "$pkg" "$libc" "${PKG_VERSION:-unknown}"

  log_success "Remoção concluída de ${target} (${libc})"
}

cmd_list() {
    printf "%-5s %-30s %-15s %-10s %-20s\n" "OK" "PACOTE" "VERSÃO" "LIBC" "CATEG."
    printf "%-5s %-30s %-15s %-10s %-20s\n" "-----" "------------------------------" "---------------" "----------" "--------------------"

    local meta
    for meta in "$DB_DIR"/*.meta; do
        [ -e "$meta" ] || continue

        unset PKG_ID PKG_NAME PKG_CATEGORY PKG_VERSION PKG_LIBC

        # Carrega .meta com proteção: se falhar, avisa e pula
        if ! . "$meta"; then
            log_warn "Falha ao carregar meta $meta (arquivo inválido?), ignorando na listagem."
            continue
        fi

        local id="${PKG_ID:-unknown}"
        local name="${PKG_NAME:-unknown}"
        local cat="${PKG_CATEGORY:-unknown}"
        local ver="${PKG_VERSION:-unknown}"
        local libc="${PKG_LIBC:-unknown}"

        printf "%-5s %-30s %-15s %-10s %-20s\n" "[✔]" "$id" "$ver" "$libc" "$cat"
    done
}

cmd_search() {
    local pattern="$1"
    ensure_repo
    [ -d "$PKG_BASE_DIR" ] || die "Diretório de pacotes não encontrado: $PKG_BASE_DIR"

    local found=0
    while IFS= read -r -d '' dir; do
        local pkg cat
        pkg="$(basename "$dir")"
        cat="$(basename "$(dirname "$dir")")"

        # case-insensitive match
        if [[ "${pkg,,}" == *"${pattern,,}"* ]]; then
            found=1
            local mark="[    ]"
            if pkg_is_installed_any_libc "$cat" "$pkg"; then
                mark="[ ✔️ ]"
            fi
            printf "%s %s/%s\n" "$mark" "$cat" "$pkg"
        fi
    done < <(find "$PKG_BASE_DIR" -mindepth 2 -maxdepth 2 -type d -print0)

    if [ "$found" -eq 0 ]; then
        log_warn "Nenhum pacote encontrado que corresponda a '$pattern'."
    fi
}

cmd_info() {
    local name="$1"

    ensure_repo

    if [ ! -d "$PKG_BASE_DIR" ]; then
        die "Diretório de pacotes não encontrado: $PKG_BASE_DIR"
    fi

    local matches=()

    if [[ "$name" == */* ]]; then
        local cat="${name%/*}"
        local pkg="${name##*/}"
        local dir="${PKG_BASE_DIR}/${cat}/${pkg}"
        if [ ! -d "$dir" ]; then
            die "Pacote '${name}' não encontrado."
        fi
        matches+=("${cat}|${pkg}|${dir}")
    else
        local dir cat pkg
        while IFS= read -r -d '' dir; do
            pkg="$(basename "$dir")"
            cat="$(basename "$(dirname "$dir")")"
            if [ "$pkg" = "$name" ]; then
                matches+=("${cat}|${pkg}|${dir}")
            fi
        done < <(find "$PKG_BASE_DIR" -mindepth 2 -maxdepth 2 -type d -print0)
    fi

    if [ "${#matches[@]}" -eq 0 ]; then
        die "Pacote '${name}' não encontrado."
    fi

    local entry cat pkg dir
    for entry in "${matches[@]}"; do
        IFS='|' read -r cat pkg dir <<< "$entry"

        local installed mark
        if pkg_is_installed_any_libc "$cat" "$pkg"; then
            installed="sim"
            mark="[ ✔️ ]"
        else
            installed="não"
            mark="[    ]"
        fi

        printf "%s%s/%s%s\n" "$mark " "$cat" "$pkg" "$RESET"
        printf "  Diretório: %s\n" "$dir"

        local any_meta=0
        local meta
        for meta in "${DB_DIR}/${cat}__${pkg}__"*.meta; do
            [ -f "$meta" ] || continue
            any_meta=1

            unset PKG_LIBC PKG_VERSION PKG_TARBALL

            # Carrega .meta com proteção
            if ! . "$meta"; then
                log_warn "Falha ao carregar meta $meta (arquivo inválido?), ignorando nesta saída."
                continue
            fi

            printf "  - libc:      %s\n" "${PKG_LIBC:-unknown}"
            printf "    versão:    %s\n" "${PKG_VERSION:-unknown}"
            printf "    tarball:   %s\n" "${PKG_TARBALL:-unknown}"
        done

        if [ "$any_meta" -eq 0 ]; then
            printf "  Instaldo?:   %s\n" "$installed"
        fi

        printf "  Script:     %s/%s.sh\n" "$dir" "$pkg"
        echo
    done
}

### MAIN #######################################################################

main() {
    local cmd="${1:-}"
    case "$cmd" in
        build)
            [ $# -ge 2 ] || { usage; exit 1; }
            check_requirements
            cmd_build "$2" "${3:-}"
            ;;
        install)
            [ $# -ge 2 ] || { usage; exit 1; }
            check_requirements
            cmd_install "$2" "${3:-}"
            ;;
        uninstall)
            [ $# -ge 2 ] || { usage; exit 1; }
            check_requirements
            cmd_uninstall "$2" "${3:-}"
            ;;
        list)
            cmd_list
            ;;
        search)
            [ $# -ge 2 ] || { usage; exit 1; }
            cmd_search "$2"
            ;;
        info)
            [ $# -ge 2 ] || { usage; exit 1; }
            cmd_info "$2"
            ;;
        update-repo)
            check_requirements
            cmd_update_repo
            ;;
        ""|-h|--help|help)
            usage
            ;;
        *)
            log_error "Comando inválido: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
