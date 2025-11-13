#!/usr/bin/env bash
# install-adm.sh
# Instalador inteligente do ADM a partir do repo GitHub (scripts10/scripts-lib)

set -u

###############################################################################
# CONFIG BÁSICA
###############################################################################

ADM_REPO_URL="${ADM_REPO_URL:-https://github.com/fcanatta/Adm.git}"
ADM_ROOT_DEFAULT="/usr/src/adm"
ADM_ROOT="${ADM_ROOT:-$ADM_ROOT_DEFAULT}"
ADM_LIBDIR="${ADM_LIBDIR:-$ADM_ROOT/lib/adm}"
ADM_WORKDIR="${ADM_WORKDIR:-/tmp/adm-install}"
ADM_BRANCH="${ADM_BRANCH:-main}"

ADM_INSTALL_FORCE="${ADM_INSTALL_FORCE:-0}"   # 1 = sobrescreve sem perguntar
ADM_INSTALL_DRYRUN="${ADM_INSTALL_DRYRUN:-0}" # 1 = só mostra o que faria

###############################################################################
# CORES
###############################################################################

if [ -t 1 ]; then
    COL_RESET=$'\033[0m'
    COL_BOLD=$'\033[1m'
    COL_DIM=$'\033[2m'
    COL_RED=$'\033[31m'
    COL_GREEN=$'\033[32m'
    COL_YELLOW=$'\033[33m'
    COL_BLUE=$'\033[34m'
    COL_MAGENTA=$'\033[35m'
    COL_CYAN=$'\033[36m'
else
    COL_RESET=""
    COL_BOLD=""
    COL_DIM=""
    COL_RED=""
    COL_GREEN=""
    COL_YELLOW=""
    COL_BLUE=""
    COL_MAGENTA=""
    COL_CYAN=""
fi

log()        { printf '%b\n' "$*" >&2; }
log_info()   { log "${COL_BLUE}[INFO]${COL_RESET}  $*"; }
log_warn()   { log "${COL_YELLOW}[WARN]${COL_RESET}  $*"; }
log_error()  { log "${COL_RED}[ERROR]${COL_RESET} $*"; }
log_ok()     { log "${COL_GREEN}[OK]${COL_RESET}    $*"; }
log_debug()  { log "${COL_DIM}[DEBUG] $*${COL_RESET}"; }
log_cmd()    { log "${COL_CYAN}[CMD]${COL_RESET}   $*"; }

###############################################################################
# HELP
###############################################################################

usage() {
    cat <<EOF
Uso: $0 [opções]

Opções:
  --root DIR          Define ADM_ROOT (default: $ADM_ROOT_DEFAULT)
  --force             Sobrescreve arquivos sem perguntar (backup .bak)
  --dry-run           Apenas mostra o que faria, não altera nada
  --no-color          Desativa cores
  -h, --help          Mostra esta ajuda

Variáveis:
  ADM_REPO_URL        URL do repo (default: $ADM_REPO_URL)
  ADM_BRANCH          Branch (default: $ADM_BRANCH)
  ADM_WORKDIR         Diretório temporário do clone (default: $ADM_WORKDIR)
EOF
}

###############################################################################
# PARSE ARG
###############################################################################

while [ $# -gt 0 ]; do
    case "$1" in
        --root)
            [ $# -ge 2 ] || { log_error "--root precisa de argumento"; exit 1; }
            ADM_ROOT="$2"; shift
            ;;
        --force)
            ADM_INSTALL_FORCE=1
            ;;
        --dry-run)
            ADM_INSTALL_DRYRUN=1
            ;;
        --no-color)
            COL_RESET=""; COL_BOLD=""; COL_DIM=""
            COL_RED=""; COL_GREEN=""; COL_YELLOW=""
            COL_BLUE=""; COL_MAGENTA=""; COL_CYAN=""
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Opção desconhecida: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

ADM_LIBDIR="$ADM_ROOT/lib/adm"

###############################################################################
# CHECKS INICIAIS
###############################################################################

if [ "$(id -u 2>/dev/null)" != "0" ]; then
    log_error "Precisa ser root (sudo) para instalar em /usr e /usr/src."
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    log_error "'git' não encontrado no PATH. Instale git primeiro."
    exit 1
fi

log_info "Instalando ADM em: ${ADM_ROOT}"
log_info "Libs em:           ${ADM_LIBDIR}"
log_info "Repo URL:          ${ADM_REPO_URL}"
log_info "Branch:            ${ADM_BRANCH}"
[ "$ADM_INSTALL_DRYRUN" -eq 1 ] && log_warn "MODO DRY-RUN ATIVADO (nenhuma alteração será feita)."

###############################################################################
# FUNÇÕES AUXILIARES
###############################################################################

mkdir_p() {
    local d="$1"
    if [ "$ADM_INSTALL_DRYRUN" -eq 1 ]; then
        log_cmd "[DRY-RUN] mkdir -p \"$d\""
        return 0
    fi
    mkdir -p -- "$d" 2>/dev/null || {
        log_error "Falha ao criar diretório: %s" "$d"
        return 1
    }
}

copy_file_smart() {
    # args: SRC DEST MODE
    local src="$1" dest="$2" mode="$3"

    if [ ! -f "$src" ]; then
        log_error "Arquivo fonte não encontrado: %s" "$src"
        return 1
    fi

    if [ -e "$dest" ] && [ "$ADM_INSTALL_FORCE" -ne 1 ]; then
        # backup se já existe e não está em force
        local backup="${dest}.bak"
        if [ "$ADM_INSTALL_DRYRUN" -eq 1 ]; then
            log_cmd "[DRY-RUN] backup \"$dest\" → \"$backup\""
        else
            cp -f "$dest" "$backup" 2>/dev/null || {
                log_error "Falha ao criar backup: %s" "$backup"
                return 1
            }
            log_info "Backup criado: %s" "$backup"
        fi
    fi

    if [ "$ADM_INSTALL_DRYRUN" -eq 1 ]; then
        log_cmd "[DRY-RUN] cp \"$src\" \"$dest\""
        log_cmd "[DRY-RUN] chmod $mode \"$dest\""
        return 0
    fi

    cp -f "$src" "$dest" 2>/dev/null || {
        log_error "Falha ao copiar %s → %s" "$src" "$dest"
        return 1
    }
    chmod "$mode" "$dest" 2>/dev/null || {
        log_error "Falha ao aplicar chmod %s em %s" "$mode" "$dest"
        return 1
    }
    log_ok "Instalado: %s" "$dest"
}

create_file_if_missing() {
    # args: PATH CONTENT
    local path="$1"
    shift
    local content="$*"

    if [ -e "$path" ]; then
        log_debug "Arquivo de config já existe, mantendo: %s" "$path"
        return 0
    fi

    local dir
    dir="$(dirname "$path")"

    if [ "$ADM_INSTALL_DRYRUN" -eq 1 ]; then
        log_cmd "[DRY-RUN] mkdir -p \"$dir\""
        log_cmd "[DRY-RUN] criar config: $path"
        return 0
    fi

    mkdir -p "$dir" 2>/dev/null || {
        log_error "Falha ao criar diretório de config: %s" "$dir"
        return 1
    }

    printf '%s\n' "$content" >"$path" 2>/dev/null || {
        log_error "Falha ao criar arquivo de config: %s" "$path"
        return 1
    }

    log_ok "Config criado: %s" "$path"
}

###############################################################################
# CLONE / UPDATE DO REPO
###############################################################################

clone_or_update_repo() {
    mkdir_p "$ADM_WORKDIR" || return 1

    if [ -d "$ADM_WORKDIR/Adm/.git" ]; then
        log_info "Repositório já clonado em %s, atualizando..." "$ADM_WORKDIR/Adm"
        if [ "$ADM_INSTALL_DRYRUN" -eq 1 ]; then
            log_cmd "[DRY-RUN] cd \"$ADM_WORKDIR/Adm\" && git fetch --all --prune && git checkout \"$ADM_BRANCH\" && git pull --ff-only"
            return 0
        fi
        (
            cd "$ADM_WORKDIR/Adm" || exit 1
            git fetch --all --prune || exit 1
            git checkout "$ADM_BRANCH" || exit 1
            git pull --ff-only || exit 1
        ) || {
            log_error "Falha ao atualizar repositório em %s" "$ADM_WORKDIR/Adm"
            return 1
        }
    else
        if [ "$ADM_INSTALL_DRYRUN" -eq 1 ]; then
            log_cmd "[DRY-RUN] git clone \"$ADM_REPO_URL\" \"$ADM_WORKDIR/Adm\" --branch \"$ADM_BRANCH\" --depth 1"
            return 0
        fi
        log_info "Clonando repositório para %s..." "$ADM_WORKDIR/Adm"
        git clone "$ADM_REPO_URL" "$ADM_WORKDIR/Adm" --branch "$ADM_BRANCH" --depth 1 2>/dev/null || {
            log_error "Falha ao clonar %s em %s" "$ADM_REPO_URL" "$ADM_WORKDIR/Adm"
            return 1
        }
    fi

    return 0
}

###############################################################################
# INSTALAÇÃO DOS SCRIPTS
###############################################################################

install_scripts() {
    local src_dir="$ADM_WORKDIR/Adm/scripts10/scripts-lib"

    if [ ! -d "$src_dir" ]; then
        log_error "Diretório de scripts não encontrado no repo: %s" "$src_dir"
        log_error "Verifique se a árvore scripts10/scripts-lib existe."
        return 1
    fi

    mkdir_p "$ADM_ROOT"   || return 1
    mkdir_p "$ADM_LIBDIR" || return 1

    # destinos padrão extras
    mkdir_p "$ADM_ROOT/repo"              || return 1
    mkdir_p "$ADM_ROOT/state/manifests"   || return 1
    mkdir_p "$ADM_ROOT/cache/sources"     || return 1
    mkdir_p "$ADM_ROOT/cache/build"       || return 1
    mkdir_p "$ADM_ROOT/destdir"           || return 1
    mkdir_p "$ADM_ROOT/logs"              || return 1
    mkdir_p "$ADM_ROOT/tmp"               || return 1
    mkdir_p "$ADM_ROOT/cross-tools"       || return 1
    mkdir_p "$ADM_ROOT/rootfs/stage2"     || return 1
    mkdir_p "$ADM_ROOT/stages.d"          || return 1
    mkdir_p "$ADM_ROOT/updates"           || return 1
    mkdir_p "$ADM_ROOT/mkinit/hooks.d"    || return 1

    # instalador genérico:
    #  - se o script chama "adm" → /usr/bin/adm
    #  - caso contrário → $ADM_LIBDIR/<nome>
    #  - todos com modo 0755 (bibliotecas poderão ser sourced ou executadas)
    local s base dest
    for s in "$src_dir"/*.sh "$src_dir"/adm; do
        [ -e "$s" ] || continue
        base="$(basename "$s")"

        case "$base" in
            adm|adm.sh)
                dest="/usr/bin/adm"
                ;;
            *)
                dest="$ADM_LIBDIR/$base"
                ;;
        esac

        copy_file_smart "$s" "$dest" "0755" || return 1
    done

    return 0
}

###############################################################################
# CRIAR ARQUIVOS DE CONFIGURAÇÃO BÁSICOS
###############################################################################

create_configs() {
    # /etc/adm.conf
    create_file_if_missing "/etc/adm.conf" \
"ADM_ROOT=\"$ADM_ROOT\"
ADM_LOG_LEVEL=\"info\"
ADM_PROFILE_DEFAULT=\"normal\"
"

    # Config básica de profiles (se o sistema usar isso)
    create_file_if_missing "$ADM_ROOT/profiles.d/default.conf" \
"# Profiles básicos do ADM
# aggressive|normal|minimal
PROFILE_DEFAULT=normal
"

    # Placeholders de stages.d
    create_file_if_missing "$ADM_ROOT/stages.d/README" \
"Coloque aqui arquivos *.list definindo os pacotes de cada stage:
  cross.list
  temp.list
  stage2.list
  base.list
"

    # Placeholder de mkinit hooks
    create_file_if_missing "$ADM_ROOT/mkinit/hooks.d/README" \
"Hooks para mkinitramfs:
  Qualquer script executável aqui será chamado com:
    BUILD_DIR=... KVER=... ROOTFS=...
"

    return 0
}

###############################################################################
# DETECÇÃO DE INSTALAÇÃO EXISTENTE
###############################################################################

check_existing() {
    local exists=0

    [ -x "/usr/bin/adm" ] && exists=1
    [ -d "$ADM_LIBDIR" ] && [ "$(ls -A "$ADM_LIBDIR" 2>/dev/null | wc -l)" -gt 0 ] && exists=1

    if [ "$exists" -eq 1 ] && [ "$ADM_INSTALL_FORCE" -ne 1 ]; then
        log_warn "Parece que o ADM já está instalado."
        log_warn "Arquivos existentes serão preservados com backup .bak se sobrescritos."
        log_warn "Use ADM_INSTALL_FORCE=1 ou --force para sobrescrever sem avisar."
    fi

    return 0
}

###############################################################################
# MAIN
###############################################################################

main() {
    log_info "=== Instalador ADM ==="

    check_existing || exit 1
    clone_or_update_repo || exit 1
    install_scripts      || exit 1
    create_configs       || exit 1

    if [ "$ADM_INSTALL_DRYRUN" -eq 1 ]; then
        log_ok "DRY-RUN concluído: nenhuma alteração foi feita."
    else
        log_ok "Instalação do ADM concluída com sucesso."
        if [ -x /usr/bin/adm ]; then
            log_info "Teste rápido: execute 'adm help' ou apenas 'adm' para ver a logo."
        fi
    fi
}

main
