#!/usr/bin/env bash
set -euo pipefail

#=============================================
#  lfs-pkg  -  gerenciador simples de builds
#=============================================

LFS="${LFS:-/mnt/lfs}"
LFS_PACKAGES_DIR="${LFS_PACKAGES_DIR:-$LFS/packages}"
LFS_PKG_DB_DIR="${LFS_PKG_DB_DIR:-$LFS/var/pkgdb}"
BUILD_ORDER_FILE="${BUILD_ORDER_FILE:-$LFS_PACKAGES_DIR/build-order.txt}"

# Cores para saída na tela
COLOR_INFO="\033[1;34m"
COLOR_WARN="\033[1;33m"
COLOR_ERROR="\033[1;31m"
COLOR_OK="\033[1;32m"
COLOR_RESET="\033[0m"

# Cria diretórios básicos de banco de dados
mkdir -p "$LFS_PKG_DB_DIR"/{installed,logs}

#---------------------------------------------
# Logging
#---------------------------------------------

log_info() {
    echo -e "${COLOR_INFO}[INFO] $*${COLOR_RESET}"
}

log_warn() {
    echo -e "${COLOR_WARN}[WARN] $*${COLOR_RESET}"
}

log_error() {
    echo -e "${COLOR_ERROR}[ERRO] $*${COLOR_RESET}" >&2
}

log_ok() {
    echo -e "${COLOR_OK}[OK] $*${COLOR_RESET}"
}

die() {
    log_error "$*"
    exit 1
}

#---------------------------------------------
# Helpers gerais
#---------------------------------------------

ensure_not_root() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        die "não execute este comando como root (use o usuário de build)."
    fi
}

ensure_dirs() {
    mkdir -p "$LFS_PACKAGES_DIR" || true
    mkdir -p "$LFS_PKG_DB_DIR/installed" "$LFS_PKG_DB_DIR/logs"
}

# key = categoria:pacote
pkg_key() {
    local category="$1" name="$2"
    echo "${category}:${name}"
}

pkg_db_dir() {
    local key="$1"
    echo "$LFS_PKG_DB_DIR/installed/$key"
}

pkg_manifest() {
    local key="$1"
    echo "$(pkg_db_dir "$key")/manifest"
}

pkg_meta() {
    local key="$1"
    echo "$(pkg_db_dir "$key")/meta"
}

pkg_logfile() {
    local key="$1" action="$2"
    echo "$LFS_PKG_DB_DIR/logs/${key}.${action}.log"
}

pkg_script_path() {
    local category="$1" name="$2"
    echo "$LFS_PACKAGES_DIR/$category/$name/$name.sh"
}

pkg_hooks_prefix() {
    local category="$1" name="$2"
    echo "$LFS_PACKAGES_DIR/$category/$name/$name"
}

is_installed() {
    local key="$1"
    [[ -f "$(pkg_manifest "$key")" ]]
}

#---------------------------------------------
# Snapshot de FS para gerar manifesto
#---------------------------------------------

snapshot_fs() {
    local outfile="$1"
    find "$LFS" -xdev \
        -path "$LFS_PKG_DB_DIR" -prune -o \
        -print | sort > "$outfile"
}

calc_manifest() {
    local before="$1" after="$2" out="$3"
    comm -13 "$before" "$after" > "$out"
}

#---------------------------------------------
# Metadados do script de pacote
#---------------------------------------------

load_pkg_metadata_from_script() {
    local script="$1"

    PKG_NAME=""
    PKG_VERSION=""
    PKG_CATEGORY=""
    PKG_DEPS=()

    # shellcheck source=/dev/null
    . "$script"

    [[ -n "${PKG_NAME:-}" ]] || die "PKG_NAME não definido em $script"
    [[ -n "${PKG_CATEGORY:-}" ]] || die "PKG_CATEGORY não definido em $script"
}

write_meta_file() {
    local key="$1" name="$2" category="$3" version="$4" deps="$5"
    local meta_file
    meta_file="$(pkg_meta "$key")"
    mkdir -p "$(dirname "$meta_file")"
    {
        echo "NAME=$name"
        echo "CATEGORY=$category"
        echo "VERSION=$version"
        echo "DEPS=$deps"
        echo "INSTALL_TIME=$(date +'%F %T')"
    } > "$meta_file"
}

read_meta_field() {
    local key="$1" field="$2"
    local meta_file
    meta_file="$(pkg_meta "$key")"
    [[ -f "$meta_file" ]] || return 1
    # shellcheck disable=SC1090
    . "$meta_file"
    eval "echo \${$field:-}"
}

#---------------------------------------------
# Localizar script pelo nome (para deps)
#---------------------------------------------

find_script_by_name() {
    local name="$1"
    local hits
    hits=$(find "$LFS_PACKAGES_DIR" -maxdepth 3 -type f -name "$name.sh")
    local count
    count=$(echo "$hits" | sed '/^$/d' | wc -l)
    if [[ "$count" -eq 0 ]]; then
        return 1
    elif [[ "$count" -gt 1 ]]; then
        echo "$hits"
        return 2
    else
        echo "$hits"
        return 0
    fi
}

#---------------------------------------------
# Hooks
#---------------------------------------------

run_hook_if_exists() {
    local hook="$1" key="$2" category="$3" name="$4"
    if [[ -x "$hook" ]]; then
        log_info "Rodando hook $hook para $key"
        "$hook" "$category" "$name" "$key" || die "Hook $hook falhou para $key"
    fi
}

#---------------------------------------------
# INSTALL (com deps, manifest, hooks, log)
#---------------------------------------------

install_pkg() {
    ensure_not_root
    ensure_dirs

    local category="$1" name="$2"
    local key
    key=$(pkg_key "$category" "$name")

    if is_installed "$key"; then
        log_warn "Pacote $key já instalado; pulando."
        return 0
    fi

    local script
    script="$(pkg_script_path "$category" "$name")"
    [[ -f "$script" ]] || die "Script de pacote não encontrado: $script"

    load_pkg_metadata_from_script "$script"

    if [[ "$PKG_NAME" != "$name" ]]; then
        die "PKG_NAME=$PKG_NAME no script, mas nome esperado é $name"
    fi

    # --- Checar se scripts de dependência existem
    local dep
    for dep in "${PKG_DEPS[@]:-}"; do
        if [[ -z "$dep" ]]; then
            continue
        fi
        if ! find_script_by_name "$dep" >/dev/null 2>&1; then
            die "Dependência $dep do pacote $key não encontrada em $LFS_PACKAGES_DIR"
        fi
    done

    # --- Resolver e instalar dependências recursivamente
    for dep in "${PKG_DEPS[@]:-}"; do
        [[ -z "$dep" ]] && continue
        local dep_script
        dep_script=$(find_script_by_name "$dep" || true)
        if [[ -z "$dep_script" ]]; then
            die "Dependência $dep não encontrada para $key"
        fi
        local dep_cat dep_name
        dep_cat=$(basename "$(dirname "$dep_script")")
        dep_name=$(basename "$dep_script" .sh)
        local dep_key
        dep_key=$(pkg_key "$dep_cat" "$dep_name")
        if ! is_installed "$dep_key"; then
            log_info "Instalando dependência $dep_key requerida por $key"
            install_pkg "$dep_cat" "$dep_name"
        fi
    done

    # Hooks específicos do pacote
    local hooks_prefix
    hooks_prefix="$(pkg_hooks_prefix "$category" "$name")"
    local pre_install_hook="${hooks_prefix}.pre_install"
    local post_install_hook="${hooks_prefix}.post_install"

    local log_file
    log_file="$(pkg_logfile "$key" install)"

    log_info "==> Instalando pacote $key (versão ${PKG_VERSION:-desconhecida})"
    log_info "Log: $log_file"

    mkdir -p "$(dirname "$log_file")"

    run_hook_if_exists "$pre_install_hook" "$key" "$category" "$name"

    # Snapshot antes da instalação
    local before after manifest_file
    before="$(mktemp)"
    after="$(mktemp)"
    manifest_file="$(pkg_manifest "$key")"
    mkdir -p "$(dirname "$manifest_file")"

    snapshot_fs "$before"

    {
        log_info "Executando função pkg_build do script $script ..."
        # shellcheck source=/dev/null
        . "$script"
        if ! type pkg_build >/dev/null 2>&1; then
            die "Função pkg_build não definida em $script"
        fi
        pkg_build
        log_ok "Build de $key concluído."
    } > >(tee -a "$log_file") 2>&1

    # Snapshot depois e geração do manifesto
    snapshot_fs "$after"
    calc_manifest "$before" "$after" "$manifest_file"
    rm -f "$before" "$after"

    write_meta_file "$key" "$name" "$category" "${PKG_VERSION:-}" "${PKG_DEPS[*]:-}"

    # Registrar último pacote instalado com sucesso
    echo "$(pkg_key "$category" "$name")" > "$LFS_PKG_DB_DIR/last_success"

    run_hook_if_exists "$post_install_hook" "$key" "$category" "$name"

    log_ok "Pacote $key instalado com sucesso."
}

#---------------------------------------------
# UNINSTALL (via manifesto) + hooks
#---------------------------------------------

uninstall_pkg() {
    ensure_not_root
    ensure_dirs

    local name="$1" category="${2:-}"
    local key

    if [[ -n "$category" ]]; then
        key=$(pkg_key "$category" "$name")
        if ! is_installed "$key"; then
            die "Pacote $key não está instalado."
        fi
    else
        # Descobrir categoria pelo meta
        local metas
        metas=$(grep -Rl "^NAME=$name\$" "$LFS_PKG_DB_DIR/installed" 2>/dev/null || true)
        local count
        count=$(echo "$metas" | sed '/^$/d' | wc -l)
        if [[ "$count" -eq 0 ]]; then
            die "Pacote $name não encontrado na base de instalados."
        elif [[ "$count" -gt 1 ]]; then
            echo "Múltiplos pacotes com NAME=$name encontrados:"
            echo "$metas"
            die "Especifique também a categoria."
        else
            local meta_file
            meta_file="$metas"
            local base
            base=$(basename "$(dirname "$meta_file")")
            key="$base"
        fi
    fi

    local manifest
    manifest="$(pkg_manifest "$key")"
    [[ -f "$manifest" ]] || die "Manifesto não encontrado para $key: $manifest"

    local name_field category_field
    name_field=$(read_meta_field "$key" NAME)
    category_field=$(read_meta_field "$key" CATEGORY)

    if [[ -z "$category" ]]; then
        category="$category_field"
    fi

    local hooks_prefix
    hooks_prefix="$(pkg_hooks_prefix "$category" "$name_field")"
    local pre_uninstall_hook="${hooks_prefix}.pre_uninstall"
    local post_uninstall_hook="${hooks_prefix}.post_uninstall"

    local log_file
    log_file="$(pkg_logfile "$key" uninstall)"
    mkdir -p "$(dirname "$log_file")"

    log_info "==> Desinstalando pacote $key"
    log_info "Log: $log_file"

    run_hook_if_exists "$pre_uninstall_hook" "$key" "$category" "$name_field"

    {
        # Remove arquivos/diretórios listados no manifesto (de trás pra frente)
        tac "$manifest" | while read -r path; do
            if [[ -f "$path" || -L "$path" ]]; then
                rm -f "$path" && log_info "Removido arquivo $path"
            elif [[ -d "$path" ]]; then
                rmdir "$path" 2>/dev/null && log_info "Removido diretório vazio $path" || true
            fi
        done

        rm -f "$manifest"
        rm -f "$(pkg_meta "$key")"
        rmdir "$(pkg_db_dir "$key")" 2>/dev/null || true

        log_ok "Pacote $key desinstalado."
    } > >(tee -a "$log_file") 2>&1

    run_hook_if_exists "$post_uninstall_hook" "$key" "$category" "$name_field"
}

#---------------------------------------------
# Listar pacotes instalados
#---------------------------------------------

list_installed() {
    ensure_dirs
    echo "Pacotes instalados em $LFS_PKG_DB_DIR/installed:"
    find "$LFS_PKG_DB_DIR/installed" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | while read -r key; do
        local name category version
        name=$(read_meta_field "$key" NAME)
        category=$(read_meta_field "$key" CATEGORY)
        version=$(read_meta_field "$key" VERSION)
        printf '  - %s (cat=%s, ver=%s)\n' "$name" "$category" "$version"
    done
}

#---------------------------------------------
# Encontrar e remover órfãos
#---------------------------------------------

find_orphans() {
    ensure_dirs
    local all_keys
    all_keys=$(find "$LFS_PKG_DB_DIR/installed" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' || true)
    local key
    for key in $all_keys; do
        local name
        name=$(read_meta_field "$key" NAME)
        local others deps
        local needed=0
        for others in $all_keys; do
            [[ "$others" == "$key" ]] && continue
            deps=$(read_meta_field "$others" DEPS)
            if echo " $deps " | grep -q " $name "; then
                needed=1
                break
            fi
        done
        if [[ "$needed" -eq 0 ]]; then
            echo "$key"
        fi
    done
}

uninstall_orphans() {
    local orphans
    orphans=$(find_orphans)
    if [[ -z "$orphans" ]]; then
        log_info "Nenhum órfão encontrado."
        return 0
    fi

    log_warn "Os seguintes pacotes parecem órfãos (ninguém depende deles):"
    echo "$orphans" | sed 's/^/  - /'
    read -r -p "Remover todos? [y/N] " ans
    case "$ans" in
        y|Y)
            local key
            for key in $orphans; do
                local name category
                name=$(read_meta_field "$key" NAME)
                category=$(read_meta_field "$key" CATEGORY)
                uninstall_pkg "$name" "$category"
            done
            ;;
        *)
            log_info "Abortado pelo usuário."
            ;;
    esac
}

#---------------------------------------------
# Retomar a partir do último sucesso
# (usa build-order.txt: linha no formato categoria:pacote)
#---------------------------------------------

resume_from_last_success() {
    ensure_dirs
    if [[ ! -f "$LFS_PKG_DB_DIR/last_success" ]]; then
        die "Arquivo last_success não encontrado; ainda não há builds bem-sucedidos registrados."
    fi

    [[ -f "$BUILD_ORDER_FILE" ]] || die "Arquivo de ordem de build não encontrado: $BUILD_ORDER_FILE"

    local last key_list
    last=$(cat "$LFS_PKG_DB_DIR/last_success")
    key_list=$(grep -Ev '^\s*$|^\s*#' "$BUILD_ORDER_FILE" || true)

    if ! echo "$key_list" | grep -qx "$last"; then
        die "Pacote last_success ($last) não está no arquivo de ordem de build."
    fi

    local start_install=0
    local line
    while read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        if [[ "$start_install" -eq 0 ]]; then
            if [[ "$line" == "$last" ]]; then
                start_install=1
                continue    # começa no próximo
            else
                continue
            fi
        fi
        local category name
        category="${line%%:*}"
        name="${line##*:}"
        install_pkg "$category" "$name"
    done <<< "$key_list"
}

#---------------------------------------------
# CLI
#---------------------------------------------

usage() {
    cat <<EOF
Uso: $0 <comando> [args]

Comandos:
  install <categoria> <pacote>   Instala um pacote (resolve dependências)
  uninstall <pacote> [categoria] Desinstala um pacote via manifesto
  uninstall-orphans              Remove pacotes órfãos (sem dependentes)
  list                           Lista pacotes instalados
  resume                         Retoma build a partir do último sucesso (usa build-order.txt)
  help                           Mostra esta ajuda

Estrutura esperada de scripts:
  \$LFS/packages/<categoria>/<pacote>/<pacote>.sh

Dentro de <pacote>.sh:
  PKG_NAME=nome
  PKG_VERSION=versão
  PKG_CATEGORY=categoria
  PKG_DEPS=(dep1 dep2 ...)

  pkg_build() {
      # aqui compila e instala o pacote (configure/make/make install, etc.)
  }

Hooks opcionais por pacote (executáveis, no mesmo diretório):
  <pacote>.pre_install
  <pacote>.post_install
  <pacote>.pre_uninstall
  <pacote>.post_uninstall

Arquivo de ordem de build (opcional, para 'resume'):
  $BUILD_ORDER_FILE
  Formato por linha: categoria:pacote
EOF
}

main() {
    local cmd="${1:-}"
    if [[ -z "$cmd" ]]; then
        usage
        exit 1
    fi
    shift || true

    case "$cmd" in
        install)
            [[ $# -eq 2 ]] || die "Uso: $0 install <categoria> <pacote>"
            install_pkg "$1" "$2"
            ;;
        uninstall)
            [[ $# -ge 1 ]] || die "Uso: $0 uninstall <pacote> [categoria]"
            uninstall_pkg "$1" "${2:-}"
            ;;
        uninstall-orphans)
            uninstall_orphans
            ;;
        list)
            list_installed
            ;;
        resume)
            resume_from_last_success
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            die "Comando inválido: $cmd"
            ;;
    esac
}

main "$@"
