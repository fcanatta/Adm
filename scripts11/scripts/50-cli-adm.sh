#!/usr/bin/env bash
# 50-cli-adm.sh (PARTE 1)
# Interface de Linha de Comando principal do ADM.
#
# Objetivos:
#   - Ser a "face" unificada de todos os scripts:
#       00-env-profiles.sh
#       01-log-ui.sh
#       10-repo-metafile.sh
#       12-hooks-patches.sh
#       13-binary-cache.sh
#       20-toolchain-stage1.sh
#       22-rootfs-stage2.sh
#       30-source-manager.sh
#       31-build-engine.sh
#       32-resolver-deps.sh
#       33-install-remove.sh
#       34-orphans-cleaner.sh
#       40-update-manager.sh
#       41-upgrade.sh
#
#   - Comandos de alto nível: install, remove, build, toolchain, update, upgrade, orphans, info, etc.
#   - Menu TUI simples quando chamado sem argumentos.
#   - Nenhum erro silencioso: tudo tem mensagem clara.

# ----------------------------------------------------------------------
# Segurança básica
# ----------------------------------------------------------------------

if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERRO: 50-cli-adm.sh requer bash." >&2
    exit 1
fi

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "ERRO: 50-cli-adm.sh requer bash >= 4." >&2
    exit 1
fi

set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------
# Ambiente padrão
# ----------------------------------------------------------------------

ADM_CLI_NAME="ADM"
ADM_CLI_VERSION="1.0"
ADM_CLI_TAGLINE="ADM tools construction"

ADM_ROOT_DEFAULT="/usr/src/adm"
ADM_ROOT="${ADM_ROOT:-$ADM_ROOT_DEFAULT}"

ADM_SCRIPTS="${ADM_SCRIPTS:-$ADM_ROOT/scripts}"
ADM_REPO="${ADM_REPO:-$ADM_ROOT/repo}"
ADM_UPDATE_ROOT="${ADM_UPDATE_ROOT:-$ADM_ROOT/update}"
ADM_DB_ROOT="${ADM_DB_ROOT:-$ADM_ROOT/db}"

# ----------------------------------------------------------------------
# Logging (integra com 01-log-ui.sh se existir)
# ----------------------------------------------------------------------

if ! declare -F adm_info >/dev/null 2>&1; then
    adm_cli_ts() { date +"%Y-%m-%d %H:%M:%S"; }
    adm_info()   { printf '[%s] [INFO] %s\n'  "$(adm_cli_ts)" "$*" >&2; }
    adm_warn()   { printf '[%s] [WARN] %s\n'  "$(adm_cli_ts)" "$*" >&2; }
    adm_error()  { printf '[%s] [ERRO] %s\n'  "$(adm_cli_ts)" "$*" >&2; }
    adm_die()    { adm_error "$*"; exit 1; }
fi

if ! declare -F adm_stage >/dev/null 2>&1; then
    adm_stage() { adm_info "===== STAGE: $* ====="; }
fi

if ! declare -F adm_ensure_dir >/dev/null 2>&1; then
    adm_ensure_dir() {
        local d="${1:-}"
        if [ -z "$d" ]; then
            adm_die "adm_ensure_dir chamado com caminho vazio"
        fi
        if [ -d "$d" ]; then
            return 0
        fi
        if ! mkdir -p "$d"; then
            adm_die "Falha ao criar diretório: $d"
        fi
    }
fi

# ----------------------------------------------------------------------
# Sanitizadores básicos (coerentes com scripts anteriores)
# ----------------------------------------------------------------------

adm_cli_trim() {
    local s="${1:-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

adm_repo_sanitize_name() {
    local n="${1:-}"
    if [ -z "$n" ]; then
        adm_die "Nome vazio não é permitido"
    fi
    if [[ ! "$n" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        adm_die "Nome inválido '$n'. Use apenas [A-Za-z0-9._+-]."
    fi
    printf '%s' "$n"
}

adm_repo_sanitize_category() {
    local c="${1:-}"
    if [ -z "$c" ]; then
        adm_die "Categoria vazia não é permitida"
    fi
    if [[ ! "$c" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        adm_die "Categoria inválida '$c'. Use apenas [A-Za-z0-9._+-]."
    fi
    printf '%s' "$c"
}

adm_cli_root_normalize() {
    local root="${1:-/}"
    [ -z "$root" ] && root="/"
    root="$(printf '%s' "$root" | sed 's://*:/:g')"
    printf '%s\n' "$root"
}

adm_cli_require_root_if_needed() {
    local root
    root="$(adm_cli_root_normalize "${1:-/}")"
    if [ "$root" = "/" ] && [ "$(id -u)" -ne 0 ]; then
        adm_die "Operação com root='/' requer privilégios de root."
    fi
}

# ----------------------------------------------------------------------
# Localização de scripts auxiliares
# ----------------------------------------------------------------------

adm_cli_find_script() {
    local name="${1:-}"
    [ -z "$name" ] && adm_die "adm_cli_find_script requer nome de script"
    local path="$ADM_SCRIPTS/$name"
    if [ ! -x "$path" ]; then
        adm_error "Script requerido não encontrado ou não executável: $path"
        return 1
    fi
    printf '%s\n' "$path"
}

# ----------------------------------------------------------------------
# Logo / Header / UI
# ----------------------------------------------------------------------

adm_cli_logo() {
    # Bem-vindo com um pouco de estilo, mas sem exagero
    cat <<EOF
   ___    ____  __  __
  / _ |  / __ \/ / / /   $ADM_CLI_NAME CLI v$ADM_CLI_VERSION
 / __ | / /_/ / /_/ /    $ADM_CLI_TAGLINE
/_/ |_| \____/\____/     root: $ADM_ROOT

EOF
}

adm_cli_header_info() {
    # Mostra info resumida do ambiente no topo
    cat <<EOF
[ADM ENV]
  ADM_ROOT        = $ADM_ROOT
  ADM_SCRIPTS     = $ADM_SCRIPTS
  ADM_REPO        = $ADM_REPO
  ADM_UPDATE_ROOT = $ADM_UPDATE_ROOT
  ADM_DB_ROOT     = $ADM_DB_ROOT

EOF
}

# ----------------------------------------------------------------------
# Detecção de disponibilidade de recursos
# ----------------------------------------------------------------------

ADM_CLI_HAS_DEPS=0
if declare -F adm_deps_resolve_for_pkg >/dev/null 2>&1 && \
   declare -F adm_deps_parse_token >/dev/null 2>&1; then
    ADM_CLI_HAS_DEPS=1
fi

adm_cli_check_optional() {
    local name="$1" script="$2"
    if [ -x "$script" ]; then
        printf '  [✔] %s -> %s\n' "$name" "$script"
    else
        printf '  [ ] %s (não encontrado: %s)\n' "$name" "$script"
    fi
}

adm_cli_diag() {
    adm_stage "DIAGNÓSTICO RÁPIDO"

    echo "Scripts principais:"
    adm_cli_check_optional "33-install-remove" "$ADM_SCRIPTS/33-install-remove.sh"
    adm_cli_check_optional "34-orphans-cleaner" "$ADM_SCRIPTS/34-orphans-cleaner.sh"
    adm_cli_check_optional "40-update-manager" "$ADM_SCRIPTS/40-update-manager.sh"
    adm_cli_check_optional "41-upgrade" "$ADM_SCRIPTS/41-upgrade.sh"
    adm_cli_check_optional "20-toolchain-stage1" "$ADM_SCRIPTS/20-toolchain-stage1.sh"
    adm_cli_check_optional "22-rootfs-stage2" "$ADM_SCRIPTS/22-rootfs-stage2.sh"
    adm_cli_check_optional "30-source-manager" "$ADM_SCRIPTS/30-source-manager.sh"
    adm_cli_check_optional "31-build-engine" "$ADM_SCRIPTS/31-build-engine.sh"
    adm_cli_check_optional "32-resolver-deps" "$ADM_SCRIPTS/32-resolver-deps.sh"

    echo
    echo "Estado de dependências (resolver-deps):"
    if [ "$ADM_CLI_HAS_DEPS" -eq 1 ]; then
        echo "  [✔] Resolver de dependências disponível."
    else
        echo "  [ ] Resolver de dependências NÃO disponível (32-resolver-deps.sh não carregado)."
    fi
}

# ----------------------------------------------------------------------
# Parsing de token (cat/pkg ou pkg)
# ----------------------------------------------------------------------

adm_cli_parse_token() {
    local token_raw="${1:-}"
    local token
    token="$(adm_cli_trim "$token_raw")"
    if [ -z "$token" ]; then
        adm_die "Token vazio não é permitido."
    fi

    if [[ "$token" == */* ]]; then
        local c="${token%%/*}"
        local n="${token#*/}"
        c="$(adm_repo_sanitize_category "$c")"
        n="$(adm_repo_sanitize_name "$n")"
        printf '%s %s\n' "$c" "$n"
        return 0
    fi

    # Sem categoria: procurar no repo
    local name
    name="$(adm_repo_sanitize_name "$token")"
    local matches=() cat_dir pkg_dir cat pkg

    if [ ! -d "$ADM_REPO" ]; then
        adm_die "ADM_REPO não existe: $ADM_REPO (não é possível resolver token '$token')."
    fi

    for cat_dir in "$ADM_REPO"/*; do
        [ -d "$cat_dir" ] || continue
        cat="$(basename "$cat_dir")"
        for pkg_dir in "$cat_dir"/*; do
            [ -d "$pkg_dir" ] || continue
            pkg="$(basename "$pkg_dir")"
            if [ "$pkg" = "$name" ] && [ -f "$pkg_dir/metafile" ]; then
                matches+=("$cat $pkg")
            fi
        done
    done

    local count="${#matches[@]}"
    if [ "$count" -eq 0 ]; then
        adm_die "Pacote '$name' não encontrado em nenhuma categoria do repo."
    elif [ "$count" -gt 1 ]; then
        adm_error "Pacote '$name' é ambíguo; múltiplas categorias:"
        local m
        for m in "${matches[@]}"; do
            adm_error "  - $m"
        done
        adm_die "Use 'categoria/nome' para esse pacote."
    fi

    printf '%s\n' "${matches[0]}"
}

# ----------------------------------------------------------------------
# Menu TUI simples (modo interativo quando sem argumentos)
# ----------------------------------------------------------------------

adm_cli_menu_show() {
    adm_cli_logo
    adm_cli_header_info

    cat <<'EOF'
[ MENU PRINCIPAL ADM ]

  1) Instalar programa (adm install)
  2) Remover programa (adm remove)
  3) Verificar updates (adm check-updates)
  4) Aplicar upgrades (adm upgrade)
  5) Gerenciar órfãos (adm orphans)
  6) Toolchain & Rootfs (stage1/stage2)
  7) Info e diagnóstico (adm info)
  8) Sair

Escolha uma opção (1-8): 
EOF
}

adm_cli_menu_loop() {
    while true; do
        adm_cli_menu_show
        read -r -p "> " opt || { echo; return 0; }
        case "$opt" in
            1)
                read -r -p "Digite o programa (token, ex: sys/bash ou bash): " token || true
                token="$(adm_cli_trim "$token")"
                [ -z "$token" ] && continue
                "./$(basename "$0")" install "$token"
                ;;
            2)
                read -r -p "Digite o programa (token, ex: sys/bash ou bash): " token || true
                token="$(adm_cli_trim "$token")"
                [ -z "$token" ] && continue
                "./$(basename "$0")" remove "$token"
                ;;
            3)
                "./$(basename "$0")" check-updates
                ;;
            4)
                "./$(basename "$0")" upgrade-all
                ;;
            5)
                "./$(basename "$0")" orphans
                ;;
            6)
                echo
                echo "  a) stage1 toolchain (20-toolchain-stage1)"
                echo "  b) stage2 rootfs    (22-rootfs-stage2)"
                echo "  c) voltar"
                read -r -p "Escolha (a/b/c): " sub || true
                case "$sub" in
                    a) "./$(basename "$0")" toolchain stage1 ;;
                    b) "./$(basename "$0")" toolchain stage2 ;;
                    *) : ;;
                esac
                ;;
            7)
                "./$(basename "$0")" info
                ;;
            8)
                echo "Saindo..."
                return 0
                ;;
            *)
                echo "Opção inválida."
                ;;
        esac
        echo
        read -r -p "Pressione ENTER para continuar..." _ || true
        clear || true
    done
}

# ----------------------------------------------------------------------
# HELP geral
# ----------------------------------------------------------------------

adm_cli_usage() {
    cat <<EOF
Uso: $(basename "$0") <comando> [args...]

Comandos principais:
  install <token> [root]
      - Instala um programa e dependências.
        token: "cat/pkg" ou apenas "pkg".
        root:  diretório alvo (padrão: /).

  remove <token> [root]
      - Remove um programa (todas as versões instaladas em root).

  build <token> [modo]
      - Compila um programa sem instalar (se 31-build-engine.sh estiver disponível).
        modo: build (padrão), run, all, etc.

  toolchain stage1
  toolchain stage2
      - Aciona scripts de construção de toolchain/ rootfs.

  check-updates [token]
      - Sem argumentos: verifica updates para todos os pacotes (40-update-manager.sh world-check).
      - Com token: verifica updates apenas para o pacote indicado.

  update-meta <token> [--deep]
      - Gera metafile de update para o pacote (40-update-manager.sh update-meta-token).

  upgrade <token> [root] [--no-install] [--deep]
      - Aplica update (metafile gerado) e faz upgrade do pacote (41-upgrade.sh upgrade-token).

  upgrade-all [root] [--no-install] [--deep]
      - Aplica todos os upgrades disponíveis (41-upgrade.sh world).

  orphans [--list|--scan|--remove|--remove-stale] [root] [--force]
      - Integra com 34-orphans-cleaner.sh.

  info
      - Mostra informações do ambiente e diagnóstico rápido.

  help
      - Mostra esta ajuda.

Sem argumentos:
  Exibe logo e entra em modo de menu interativo TUI simples.

EOF
}
# 50-cli-adm.sh (PARTE 2)
# Continuação do script — cole IMEDIATAMENTE após a Parte 1 no mesmo arquivo.

# ----------------------------------------------------------------------
# Wrappers de alto nível para scripts auxiliares
# ----------------------------------------------------------------------

# 33-install-remove.sh
adm_cli_install_token() {
    local token="${1:-}" root="${2:-/}"
    [ -z "$token" ] && adm_die "install requer token (ex: sys/bash ou bash)."

    root="$(adm_cli_root_normalize "$root")"
    adm_cli_require_root_if_needed "$root"

    local script
    script="$(adm_cli_find_script "33-install-remove.sh")" || adm_die "Instalar requer 33-install-remove.sh."

    adm_stage "CLI INSTALL token=$token root=$root"
    "$script" install-token "$token" "build" "$root"
}

adm_cli_remove_token() {
    local token="${1:-}" root="${2:-/}"
    [ -z "$token" ] && adm_die "remove requer token (ex: sys/bash ou bash)."

    root="$(adm_cli_root_normalize "$root")"
    adm_cli_require_root_if_needed "$root"

    local script
    script="$(adm_cli_find_script "33-install-remove.sh")" || adm_die "Remover requer 33-install-remove.sh."

    adm_stage "CLI REMOVE token=$token root=$root"
    "$script" remove-token "$token" "$root"
}

# 31-build-engine.sh (opcional)
adm_cli_build_token() {
    local token="${1:-}" mode="${2:-build}"
    [ -z "$token" ] && adm_die "build requer token (ex: sys/bash ou bash)."

    local script
    script="$(adm_cli_find_script "31-build-engine.sh")" || adm_die "Build requer 31-build-engine.sh."

    adm_stage "CLI BUILD token=$token mode=$mode"

    # Supondo que 31-build-engine.sh tenha um comando build-token;
    # se não tiver, esta chamada falhará com mensagem clara.
    "$script" build-token "$token" "$mode"
}

# Toolchain / Rootfs
adm_cli_toolchain_stage1() {
    local script
    script="$(adm_cli_find_script "20-toolchain-stage1.sh")" || adm_die "Toolchain stage1 requer 20-toolchain-stage1.sh."
    adm_stage "CLI TOOLCHAIN STAGE1"
    "$script"
}

adm_cli_toolchain_stage2() {
    local script
    script="$(adm_cli_find_script "22-rootfs-stage2.sh")" || adm_die "Rootfs stage2 requer 22-rootfs-stage2.sh."
    adm_stage "CLI ROOTFS STAGE2"
    "$script"
}

# 40-update-manager.sh
adm_cli_check_updates_world() {
    local script
    script="$(adm_cli_find_script "40-update-manager.sh")" || adm_die "check-updates requer 40-update-manager.sh."
    adm_stage "CLI CHECK-UPDATES (world)"
    "$script" world-check
}

adm_cli_check_updates_token() {
    local token="${1:-}"
    [ -z "$token" ] && adm_die "check-updates token requer token."

    local script
    script="$(adm_cli_find_script "40-update-manager.sh")" || adm_die "check-updates requer 40-update-manager.sh."

    adm_stage "CLI CHECK-UPDATES token=$token"
    "$script" check-token "$token"
}

adm_cli_update_meta_token() {
    local token="${1:-}" deep="${2:-0}"
    [ -z "$token" ] && adm_die "update-meta requer token."

    local script
    script="$(adm_cli_find_script "40-update-manager.sh")" || adm_die "update-meta requer 40-update-manager.sh."

    local args=( "update-meta-token" "$token" )
    if [ "$deep" -eq 1 ]; then
        args+=( "--deep" )
    fi

    adm_stage "CLI UPDATE-META token=$token deep=$deep"
    "$script" "${args[@]}"
}

# 41-upgrade.sh
adm_cli_upgrade_token() {
    local token="${1:-}" root="${2:-/}" no_install="${3:-0}" deep="${4:-0}"

    [ -z "$token" ] && adm_die "upgrade requer token."

    root="$(adm_cli_root_normalize "$root")"
    adm_cli_require_root_if_needed "$root"

    local script
    script="$(adm_cli_find_script "41-upgrade.sh")" || adm_die "upgrade requer 41-upgrade.sh."

    local args=( "upgrade-token" "$token" "$root" )
    if [ "$no_install" -eq 1 ]; then
        args+=( "--no-install" )
    fi
    if [ "$deep" -eq 1 ]; then
        args+=( "--deep" )
    fi

    adm_stage "CLI UPGRADE token=$token root=$root no_install=$no_install deep=$deep"
    "$script" "${args[@]}"
}

adm_cli_upgrade_all() {
    local root="${1:-/}" no_install="${2:-0}" deep="${3:-0}"

    root="$(adm_cli_root_normalize "$root")"
    adm_cli_require_root_if_needed "$root"

    local script
    script="$(adm_cli_find_script "41-upgrade.sh")" || adm_die "upgrade-all requer 41-upgrade.sh."

    local args=( "world" "$root" )
    if [ "$no_install" -eq 1 ]; then
        args+=( "--no-install" )
    fi
    if [ "$deep" -eq 1 ]; then
        args+=( "--deep" )
    fi

    adm_stage "CLI UPGRADE-ALL root=$root no_install=$no_install deep=$deep"
    "$script" "${args[@]}"
}

# 34-orphans-cleaner.sh
adm_cli_orphans() {
    local mode="${1:-list}" root="${2:-/}" force="${3:-0}"

    local script
    script="$(adm_cli_find_script "34-orphans-cleaner.sh")" || adm_die "orphans requer 34-orphans-cleaner.sh."

    root="$(adm_cli_root_normalize "$root")"
    adm_cli_require_root_if_needed "$root"

    adm_stage "CLI ORPHANS mode=$mode root=$root force=$force"

    case "$mode" in
        list)
            "$script" list "$root"
            ;;
        scan)
            "$script" scan "$root"
            ;;
        remove)
            if [ "$force" -eq 1 ]; then
                "$script" remove-orphans "$root" --force
            else
                "$script" remove-orphans "$root"
            fi
            ;;
        remove-stale)
            if [ "$force" -eq 1 ]; then
                "$script" remove-stale "$root" --force
            else
                "$script" remove-stale "$root"
            fi
            ;;
        *)
            adm_die "Modo inválido para orphans: $mode"
            ;;
    esac
}

# ----------------------------------------------------------------------
# INFO / STATUS
# ----------------------------------------------------------------------

adm_cli_info() {
    adm_cli_logo
    adm_cli_header_info
    adm_cli_diag

    echo
    echo "[ NOTAS ]"
    echo "  - use '$(basename "$0") help' para detalhes dos comandos;"
    echo "  - use '$(basename "$0")' sem argumentos para modo de menu interativo."
}

# ----------------------------------------------------------------------
# MAIN CLI
# ----------------------------------------------------------------------

adm_cli_main() {
    if [ "$#" -eq 0 ]; then
        # Modo menu interativo
        adm_cli_menu_loop
        return 0
    fi

    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        help|-h|--help)
            adm_cli_logo
            adm_cli_usage
            ;;
        info)
            adm_cli_info
            ;;
        install)
            if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
                adm_die "Uso: $(basename "$0") install <token> [root]"
            fi
            local token="$1" root="${2:-/}"
            adm_cli_install_token "$token" "$root"
            ;;
        remove)
            if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
                adm_die "Uso: $(basename "$0") remove <token> [root]"
            fi
            local token="$1" root="${2:-/}"
            adm_cli_remove_token "$token" "$root"
            ;;
        build)
            if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
                adm_die "Uso: $(basename "$0") build <token> [modo]"
            fi
            local token="$1" mode="${2:-build}"
            adm_cli_build_token "$token" "$mode"
            ;;
        toolchain)
            sub="${1:-}"
            case "$sub" in
                stage1)
                    adm_cli_toolchain_stage1
                    ;;
                stage2)
                    adm_cli_toolchain_stage2
                    ;;
                *)
                    adm_die "Uso: $(basename "$0") toolchain <stage1|stage2>"
                    ;;
            esac
            ;;
        check-updates)
            if [ "$#" -eq 0 ]; then
                adm_cli_check_updates_world
            elif [ "$#" -eq 1 ]; then
                adm_cli_check_updates_token "$1"
            else
                adm_die "Uso: $(basename "$0") check-updates [token]"
            fi
            ;;
        update-meta)
            # update-meta <token> [--deep]
            if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
                adm_die "Uso: $(basename "$0") update-meta <token> [--deep]"
            fi
            local token="$1" deep=0
            if [ "${2:-}" = "--deep" ]; then
                deep=1
            fi
            adm_cli_update_meta_token "$token" "$deep"
            ;;
        upgrade)
            # upgrade <token> [root] [--no-install] [--deep]
            if [ "$#" -lt 1 ]; then
                adm_die "Uso: $(basename "$0") upgrade <token> [root] [--no-install] [--deep]"
            fi
            local token="$1"
            shift
            local root="/"
            local no_install=0
            local deep=0

            # Primeiro argumento extra pode ser root (se não começar com -)
            if [ "${1:-}" != "" ] && [ "${1#-}" != "$1" ]; then
                : # é opção
            elif [ "${1:-}" != "" ]; then
                root="$1"
                shift
            fi

            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --no-install) no_install=1 ;;
                    --deep)       deep=1 ;;
                    *)
                        adm_die "Opção desconhecida em upgrade: $1"
                        ;;
                esac
                shift
            done

            adm_cli_upgrade_token "$token" "$root" "$no_install" "$deep"
            ;;
        upgrade-all)
            # upgrade-all [root] [--no-install] [--deep]
            local root="/"
            local no_install=0
            local deep=0

            # root opcional
            if [ "${1:-}" != "" ] && [ "${1#-}" != "$1" ]; then
                : # é opção
            elif [ "${1:-}" != "" ]; then
                root="$1"
                shift
            fi

            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --no-install) no_install=1 ;;
                    --deep)       deep=1 ;;
                    *)
                        adm_die "Opção desconhecida em upgrade-all: $1"
                        ;;
                esac
                shift
            done

            adm_cli_upgrade_all "$root" "$no_install" "$deep"
            ;;
        orphans)
            # orphans [--list|--scan|--remove|--remove-stale] [root] [--force]
            local mode="list"
            local root="/"
            local force=0

            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --list)         mode="list" ;;
                    --scan)         mode="scan" ;;
                    --remove)       mode="remove" ;;
                    --remove-stale) mode="remove-stale" ;;
                    --force)        force=1 ;;
                    *)
                        if [ "$root" = "/" ]; then
                            root="$1"
                        else
                            adm_die "Argumento desconhecido para orphans: $1"
                        fi
                        ;;
                esac
                shift
            done

            adm_cli_orphans "$mode" "$root" "$force"
            ;;
        *)
            adm_error "Comando desconhecido: $cmd"
            adm_cli_usage
            exit 1
            ;;
    esac
}

# Executar main se chamado diretamente
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    adm_cli_main "$@"
fi
