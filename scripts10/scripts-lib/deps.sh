#!/usr/bin/env bash
# lib/adm/deps.sh
#
# Resolução de dependências do ADM:
#   - Leitura de deps (run_deps, build_deps, opt_deps) dos metafiles
#   - Resolução de especificações de pacote (categoria/pkg ou só pkg)
#   - Ordenação topológica de dependências para instalação (deps antes do alvo)
#   - Detecção de ciclos de dependência
#   - Suporte a autodetecção de órfãos com base em packages.db
#
# Objetivo: zero erros silenciosos – qualquer problema relevante gera log claro.
#===============================================================================
# Proteção contra múltiplos loads
#===============================================================================
if [ -n "${ADM_DEPS_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
ADM_DEPS_LOADED=1
#===============================================================================
# Dependências: log + core + repo
#===============================================================================
if ! command -v adm_log_info >/dev/null 2>&1; then
    # Fallback mínimo se log.sh ainda não foi carregado
    adm_log()       { printf '%s\n' "$*" >&2; }
    adm_log_info()  { adm_log "[INFO]  $*"; }
    adm_log_warn()  { adm_log "[WARN]  $*"; }
    adm_log_error() { adm_log "[ERROR] $*"; }
    adm_log_debug() { :; }
fi

if ! command -v adm_core_init_paths >/dev/null 2>&1; then
    adm_log_error "deps.sh requer core.sh (função adm_core_init_paths não encontrada)."
else
    adm_core_init_paths
fi

if ! command -v adm_repo_load_metafile >/dev/null 2>&1; then
    adm_log_error "deps.sh requer repo.sh (função adm_repo_load_metafile não encontrada)."
fi

if ! command -v adm_repo_parse_deps >/dev/null 2>&1; then
    adm_log_error "deps.sh requer repo.sh (função adm_repo_parse_deps não encontrada)."
fi

: "${ADM_REPO_DIR:=${ADM_ROOT:-/usr/src/adm}/repo}"
: "${ADM_STATE_DIR:=${ADM_ROOT:-/usr/src/adm}/state}"
: "${ADM_DEPS_DB_PATH:=${ADM_STATE_DIR}/packages.db}"
#===============================================================================
# Helpers internos
#===============================================================================
# Valida um identificador simples de pacote/categoria
adm_deps__validate_identifier() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_deps__validate_identifier requer 1 argumento."
        return 1
    fi
    local s="$1"
    if [ -z "$s" ]; then
        adm_log_error "Identificador não pode ser vazio."
        return 1
    fi
    case "$s" in
        *[!A-Za-z0-9._-]*)
            adm_log_error "Identificador inválido: '%s' (permitido: letras, números, ., -, _)" "$s"
            return 1
            ;;
    esac
    return 0
}

# Normaliza "categoria/pkg" (já separados) para uma chave "categoria/pkg"
adm_deps__key() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_deps__key requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi
    local category="$1" pkg="$2"
    printf '%s/%s\n' "$category" "$pkg"
}
#===============================================================================
# Resolução de especificações de pacote
#===============================================================================
#
# Especificações aceitas:
#   - "categoria/pkg"
#   - "pkg"  (sem categoria → tenta localizar em todas as categorias)
#
# Saída: "categoria pkg" em stdout, se sucesso.
adm_deps_resolve_spec() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_deps_resolve_spec requer 1 argumento: SPEC"
        return 1
    fi

    local spec="$1"
    local category pkg

    if [ -z "$spec" ]; then
        adm_log_error "adm_deps_resolve_spec: SPEC vazio."
        return 1
    fi

    case "$spec" in
        */*)
            category="${spec%%/*}"
            pkg="${spec##*/}"

            adm_deps__validate_identifier "$category" || return 1
            adm_deps__validate_identifier "$pkg"      || return 1

            # Checa se diretório existe
            if [ ! -d "$ADM_REPO_DIR/$category/$pkg" ]; then
                adm_log_error "Pacote '%s' não encontrado em categoria '%s' (%s)." "$pkg" "$category" "$ADM_REPO_DIR/$category/$pkg"
                return 1
            fi

            printf '%s %s\n' "$category" "$pkg"
            return 0
            ;;
        *)
            # Só nome de pacote: procurar em todas as categorias
            pkg="$spec"
            adm_deps__validate_identifier "$pkg" || return 1

            if ! command -v adm_repo_list_categories >/dev/null 2>&1; then
                adm_log_error "adm_repo_list_categories não disponível; não é possível resolver SPEC '%s' sem categoria." "$spec"
                return 1
            fi

            local cat matches=0 found_cat=""
            while IFS= read -r cat || [ -n "$cat" ]; do
                [ -z "$cat" ] && continue
                if [ -d "$ADM_REPO_DIR/$cat/$pkg" ]; then
                    matches=$((matches + 1))
                    found_cat="$cat"
                fi
            done <<EOF
$(adm_repo_list_categories 2>/dev/null)
EOF

            if [ "$matches" -eq 0 ]; then
                adm_log_error "Pacote '%s' não encontrado em nenhuma categoria do repositório." "$pkg"
                return 1
            fi
            if [ "$matches" -gt 1 ]; then
                adm_log_error "Pacote '%s' encontrado em múltiplas categorias; use 'categoria/%s' (categorias: %s)." \
                    "$pkg" "$pkg" "$(find "$ADM_REPO_DIR" -mindepth 2 -maxdepth 2 -type d -name "$pkg" 2>/dev/null | sed "s|$ADM_REPO_DIR/||" | sed 's|/'$pkg'$||' | tr '\n' ' ')"
                return 1
            fi

            printf '%s %s\n' "$found_cat" "$pkg"
            return 0
            ;;
    esac
}
#===============================================================================
# Carregar deps de um pacote (run/build/opt) a partir do metafile
#===============================================================================
# Uso: adm_deps_get_pkg_deps CATEGORIA PACOTE
# Saída em stdout, com formato:
#   RUN dep1
#   RUN dep2
#   BUILD depA
#   OPT depX
adm_deps_get_pkg_deps() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_deps_get_pkg_deps requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi

    local category="$1" pkg="$2"
    local prefix="ADM_META_"

    if ! adm_repo_load_metafile "$category" "$pkg" "$prefix"; then
        adm_log_error "Não foi possível carregar metafile para %s/%s." "$category" "$pkg"
        return 1
    fi

    # shellcheck disable=SC2016
    eval 'local run="${'"${prefix}"'run_deps}"'
    eval 'local build="${'"${prefix}"'build_deps}"'
    eval 'local opt="${'"${prefix}"'opt_deps}"'

    local dep
    # RUN
    if [ -n "$run" ]; then
        while IFS= read -r dep || [ -n "$dep" ]; do
            [ -z "$dep" ] && continue
            printf 'RUN %s\n' "$dep"
        done <<EOF
$(adm_repo_parse_deps "$run")
EOF
    fi

    # BUILD
    if [ -n "$build" ]; then
        while IFS= read -r dep || [ -n "$dep" ]; do
            [ -z "$dep" ] && continue
            printf 'BUILD %s\n' "$dep"
        done <<EOF
$(adm_repo_parse_deps "$build")
EOF
    fi

    # OPT
    if [ -n "$opt" ]; then
        while IFS= read -r dep || [ -n "$dep" ]; do
            [ -z "$dep" ] && continue
            printf 'OPT %s\n' "$dep"
        done <<EOF
$(adm_repo_parse_deps "$opt")
EOF
    fi

    return 0
}
#===============================================================================
# Resolução recursiva e ordenação topológica
#===============================================================================
# Implementação via DFS com detecção de ciclos.
#
# Interface principal para instalação:
#
#   adm_deps_resolve_for_install SPEC [include_opt_deps]
#
# SPEC pode ser:
#   - "categoria/pkg"
#   - "pkg" (sem categoria; será resolvido)
#
# include_opt_deps:
#   0 (padrão) - ignora opt_deps
#   1          - inclui opt_deps na resolução
#
# Saída:
#   Uma lista de "categoria/pkg" em ordem topológica, com o pacote raiz por último.
#   Exemplo:
#     sys/gcc
#     libs/zlib
#     base/util-linux   # raiz
# Arrays globais (associativos) para a DFS
# shellcheck disable=SC2034
declare -gA ADM_DEPS_TEMP_MARK
declare -gA ADM_DEPS_PERM_MARK
declare -gA ADM_DEPS_ROLE        # RUN/BUILD/OPT/ROOT (informativo)
declare -ga ADM_DEPS_ORDER

# Limpa estado interno da DFS
adm_deps__reset_state() {
    ADM_DEPS_TEMP_MARK=()
    ADM_DEPS_PERM_MARK=()
    ADM_DEPS_ROLE=()
    ADM_DEPS_ORDER=()
}

# Marca papel de um nó (root/run/build/opt)
adm_deps__set_role() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_deps__set_role requer 2 argumentos: KEY ROLE"
        return 1
    fi
    local key="$1" role="$2"

    # Se já tem um papel mais forte, não sobrescrever por um mais fraco (ROOT > BUILD > RUN > OPT)
    local current="${ADM_DEPS_ROLE[$key]:-}"

    case "$role" in
        ROOT)
            ADM_DEPS_ROLE["$key"]="ROOT"
            ;;
        BUILD)
            case "$current" in
                ROOT) ;; # mantém ROOT
                *) ADM_DEPS_ROLE["$key"]="BUILD" ;;
            esac
            ;;
        RUN)
            case "$current" in
                ROOT|BUILD) ;; # mantém mais forte
                *) ADM_DEPS_ROLE["$key"]="RUN" ;;
            esac
            ;;
        OPT)
            # Não sobrescreve nada, é sempre o mais fraco
            if [ -z "$current" ]; then
                ADM_DEPS_ROLE["$key"]="OPT"
            fi
            ;;
        *)
            adm_log_warn "adm_deps__set_role: role desconhecido '%s' para '%s'." "$role" "$key"
            ;;
    esac

    return 0
}

# DFS recursivo
#   arg1: categoria
#   arg2: pacote
#   arg3: include_opt_deps (0/1)
adm_deps__dfs_visit() {
    if [ $# -ne 3 ]; then
        adm_log_error "adm_deps__dfs_visit requer 3 argumentos: CATEGORIA PACOTE INCLUDE_OPT"
        return 1
    fi

    local category="$1" pkg="$2" include_opt="$3"
    local key
    key="$(adm_deps__key "$category" "$pkg")" || return 1

    # Se já permanentemente marcado, não faz nada
    if [ "${ADM_DEPS_PERM_MARK[$key]:-0}" -eq 1 ]; then
        return 0
    fi

    # Detecção de ciclo
    if [ "${ADM_DEPS_TEMP_MARK[$key]:-0}" -eq 1 ]; then
        adm_log_error "Ciclo de dependências detectado envolvendo '%s'." "$key"
        return 1
    fi

    ADM_DEPS_TEMP_MARK["$key"]=1
    adm_log_debug "DFS visit: %s" "$key"

    # Carrega deps do pacote
    local deps_line kind dep_spec dep_cat dep_pkg
    while IFS= read -r deps_line || [ -n "$deps_line" ]; do
        [ -z "$deps_line" ] && continue

        kind="${deps_line%% *}"
        dep_spec="${deps_line#* }"

        # OPT pode ser ignorado se include_opt=0
        if [ "$kind" = "OPT" ] && [ "$include_opt" -ne 1 ]; then
            continue
        fi

        # Resolve spec do dep
        if ! read -r dep_cat dep_pkg <<<"$(adm_deps_resolve_spec "$dep_spec" 2>/dev/null)"; then
            adm_log_error "Falha ao resolver dependência '%s' requerida por '%s'." "$dep_spec" "$key"
            return 1
        fi

        local dep_key
        dep_key="$(adm_deps__key "$dep_cat" "$dep_pkg")" || return 1

        # Define papel do dep
        case "$kind" in
            BUILD) adm_deps__set_role "$dep_key" "BUILD" ;;
            RUN)   adm_deps__set_role "$dep_key" "RUN" ;;
            OPT)   adm_deps__set_role "$dep_key" "OPT" ;;
        esac

        # Visita recursivamente
        if ! adm_deps__dfs_visit "$dep_cat" "$dep_pkg" "$include_opt"; then
            return 1
        fi
    done <<EOF
$(adm_deps_get_pkg_deps "$category" "$pkg")
EOF

    ADM_DEPS_TEMP_MARK["$key"]=0
    ADM_DEPS_PERM_MARK["$key"]=1

    # Adiciona ao final da ordem (dep ~> pkg; DFS garante que deps venham antes)
    ADM_DEPS_ORDER+=("$key")

    return 0
}

# Função principal para resolução de deps para instalação
# Uso:
#   adm_deps_resolve_for_install SPEC [include_opt_deps]
#
# Saída:
#   Linhas com "categoria/pkg" em ordem; o pacote raiz é o último da lista.
adm_deps_resolve_for_install() {
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then
        adm_log_error "adm_deps_resolve_for_install requer 1 ou 2 argumentos: SPEC [INCLUDE_OPT]"
        return 1
    fi

    local spec="$1"
    local include_opt="${2:-0}"

    case "$include_opt" in
        0|1) ;;
        *)
            adm_log_error "Segundo argumento de adm_deps_resolve_for_install deve ser 0 ou 1 (include_opt_deps)."
            return 1
            ;;
    esac

    local root_cat root_pkg root_key
    if ! read -r root_cat root_pkg <<<"$(adm_deps_resolve_spec "$spec" 2>/dev/null)"; then
        adm_log_error "Não foi possível resolver SPEC raiz '%s'." "$spec"
        return 1
    fi

    root_key="$(adm_deps__key "$root_cat" "$root_pkg")" || return 1

    adm_deps__reset_state
    adm_deps__set_role "$root_key" "ROOT"

    adm_log_info "Resolvendo dependências para instalação: %s (%s/%s)" "$spec" "$root_cat" "$root_pkg"

    if ! adm_deps__dfs_visit "$root_cat" "$root_pkg" "$include_opt"; then
        adm_log_error "Falha na resolução recursiva de deps para '%s'." "$spec"
        return 1
    fi

    local key
    for key in "${ADM_DEPS_ORDER[@]}"; do
        printf '%s\n' "$key"
    done

    return 0
}

#===============================================================================
# Leitura de packages.db e órfãos
#===============================================================================
#
# Suposição de formato de packages.db (tab-separated):
#   name<TAB>category<TAB>version<TAB>profile<TAB>libc<TAB>install_reason<TAB>run_deps<TAB>status
#
# Campos:
#   name            ex: util-linux
#   category        ex: base
#   version         ex: 2.41.1
#   profile         ex: normal
#   libc            ex: glibc/musl
#   install_reason  explicit | auto
#   run_deps        lista separada por vírgula ("zlib,libxcrypt")
#   status          installed | removed (opcional; default = installed)
#
# O arquivo é mantido principalmente por pkg.sh; aqui nós só lemos/analisamos.

# Lista pacotes instalados (name category reason status), um por linha
adm_deps_list_installed() {
    if [ ! -f "$ADM_DEPS_DB_PATH" ]; then
        adm_log_warn "packages.db não encontrado (nenhum pacote registrado ainda): %s" "$ADM_DEPS_DB_PATH"
        return 0
    fi

    local line name category version profile libc reason run_deps status
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in
            \#*) continue ;;
        esac

        # Quebra em até 8 campos (o resto unido no último)
        IFS=$'\t' read -r name category version profile libc reason run_deps status <<<"$line"

        # Campos mínimos
        if [ -z "$name" ] || [ -z "$category" ]; then
            adm_log_warn "Linha inválida em packages.db (faltando name ou category): %s" "$line"
            continue
        fi

        [ -z "$status" ] && status="installed"

        if [ "$status" != "installed" ]; then
            continue
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$category" "$version" "$profile" "$libc" "$reason" "$run_deps" "$status"
    done <"$ADM_DEPS_DB_PATH"

    return 0
}

# Procura pacotes que têm "target_name" como dependência (run_deps).
# Args:
#   1: target_name (nome do pacote, sem categoria)
# Saída:
#   Linhas "category/pkg"
adm_deps_find_reverse_deps() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_deps_find_reverse_deps requer 1 argumento: NOME_ALVO"
        return 1
    fi
    local target="$1"
    if [ -z "$target" ]; then
        adm_log_error "adm_deps_find_reverse_deps: nome alvo não pode ser vazio."
        return 1
    fi

    local name category version profile libc reason run_deps status
    local dep pkg_base

    while IFS=$'\t' read -r name category version profile libc reason run_deps status || [ -n "$name" ]; do
        [ -z "$name" ] && continue

        # Só consideramos instalados
        [ -z "$status" ] && status="installed"
        [ "$status" != "installed" ] && continue

        if [ -z "$run_deps" ]; then
            continue
        fi

        # Quebra lista de deps e procura target
        while IFS= read -r dep || [ -n "$dep" ]; do
            [ -z "$dep" ] && continue

            # depende do formato armazenado; aceitamos:
            #   - "pkg"
            #   - "categoria/pkg"
            case "$dep" in
                */*)
                    pkg_base="${dep##*/}"
                    ;;
                *)
                    pkg_base="$dep"
                    ;;
            esac

            if [ "$pkg_base" = "$target" ]; then
                printf '%s/%s\n' "$category" "$name"
                break
            fi
        done <<EOF
$(adm_repo_parse_deps "$run_deps")
EOF
    done <<EOF
$(adm_deps_list_installed)
EOF

    return 0
}

# Lista pacotes órfãos (candidatos a autoremove).
#
# Critérios:
#   - status=installed
#   - install_reason=auto
#   - nenhum outro pacote instalado depende dele via run_deps
#   - categoria diferente de "base" (base nunca é considerada órfã)
#
# Saída:
#   Linhas "category/pkg"
adm_deps_list_orphans() {
    if [ ! -f "$ADM_DEPS_DB_PATH" ]; then
        adm_log_warn "packages.db não encontrado; nenhum órfão a listar."
        return 0
    fi

    local line name category version profile libc reason run_deps status
    local dependant_count

    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in
            \#*) continue ;;
        esac

        IFS=$'\t' read -r name category version profile libc reason run_deps status <<<"$line"

        [ -z "$name" ] && continue
        [ -z "$status" ] && status="installed"
        [ "$status" != "installed" ] && continue

        # Mantemos pacotes explicitamente instalados
        if [ "$reason" != "auto" ]; then
            continue
        fi

        # Nunca considerar categoria "base" como órfã
        if [ "$category" = "base" ]; then
            adm_log_debug "Pacote base não será considerado órfão: %s/%s" "$category" "$name"
            continue
        fi

        # Verifica se alguém depende deste pacote
        dependant_count=0
        while IFS= read -r _depender || [ -n "$_depender" ]; do
            [ -z "$_depender" ] && continue
            dependant_count=$((dependant_count + 1))
        done <<EOF
$(adm_deps_find_reverse_deps "$name")
EOF

        if [ "$dependant_count" -eq 0 ]; then
            printf '%s/%s\n' "$category" "$name"
        fi
    done <"$ADM_DEPS_DB_PATH"

    return 0
}

#===============================================================================
# Inicialização
#===============================================================================

adm_deps_init() {
    # Nada muito pesado aqui; apenas loga se packages.db não existe.
    if [ ! -f "$ADM_DEPS_DB_PATH" ]; then
        adm_log_debug "packages.db ainda não existe: %s" "$ADM_DEPS_DB_PATH"
    fi
}

adm_deps_init
