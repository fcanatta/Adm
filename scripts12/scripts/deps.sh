#!/usr/bin/env bash
# deps.sh – Resolução de dependências para o ADM
#
# Responsabilidades:
#   - Ler dependências (run_deps, build_deps, opt_deps) dos metafiles
#   - Descobrir e carregar transitivamente todos os pacotes necessários
#   - Detectar ciclos de dependência e reportar caminho do ciclo
#   - Calcular ordem de build (deps antes dos dependentes)
#   - Integrar opcionalmente com db.sh para saber o que já está instalado
#   - Nunca ter erro silencioso: sempre retorna código != 0 em caso de problema
#
# Saídas principais (globais):
#   ADM_DEPS_ORDER        → array com todos os pacotes em ordem de build
#   ADM_DEPS_TO_BUILD     → array com pacotes que NÃO estão instalados
#   ADM_DEPS_MISSING      → array com pacotes para os quais não há metafile
#
# Uso típico:
#   . /usr/src/adm/scripts/ui.sh        # opcional
#   . /usr/src/adm/scripts/metafile.sh  # se não carregar aqui
#   . /usr/src/adm/scripts/deps.sh
#
#   adm_deps_init || adm_ui_die "Falha ao inicializar deps"
#   adm_deps_resolve_pkgs bash coreutils || adm_ui_die "Erro nas dependências"
#   printf '%s\n' "${ADM_DEPS_ORDER[@]}"
#
# Este script NÃO usa set -e.

ADM_DEPS_REPO="${ADM_DEPS_REPO:-/usr/src/adm/repo}"

# Integração opcional com ui.sh e db.sh
_DEPS_HAVE_UI=0
_DEPS_HAVE_DB=0

if declare -F adm_ui_log_info >/dev/null 2>&1; then
    _DEPS_HAVE_UI=1
fi

if declare -F adm_db_is_installed >/dev/null 2>&1; then
    _DEPS_HAVE_DB=1
fi

_deps_log() {
    local lvl="$1"; shift || true
    local msg="$*"
    if [ "$_DEPS_HAVE_UI" -eq 1 ]; then
        case "$lvl" in
            INFO)  adm_ui_log_info  "$msg" ;;
            WARN)  adm_ui_log_warn  "$msg" ;;
            ERROR) adm_ui_log_error "$msg" ;;
            DEBUG) adm_ui_log_info  "[DEBUG] $msg" ;;
            *)     adm_ui_log_info  "$msg" ;;
        esac
    else
        printf 'deps[%s]: %s\n' "$lvl" "$msg" >&2
    fi
}

_deps_fail() {
    _deps_log ERROR "$*"
    return 1
}

_deps_trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# -----------------------------
# Estado global / caches
# -----------------------------
ADM_DEPS_ORDER=()        # ordem final
ADM_DEPS_TO_BUILD=()     # subset de ORDER que não estão instalados
ADM_DEPS_MISSING=()      # pacotes sem metafile

# Bash 4+ necessário
declare -Ag _DEPS_METAFILE      # pkg -> caminho do metafile
declare -Ag _DEPS_CATEGORY      # pkg -> categoria
declare -Ag _DEPS_VERSION       # pkg -> versão
declare -Ag _DEPS_RUN           # pkg -> "dep1 dep2 ..."
declare -Ag _DEPS_BUILD         # pkg -> "depA depB ..."
declare -Ag _DEPS_OPT           # pkg -> "depX depY ..."
declare -Ag _DEPS_ADJ           # pkg -> "dep1 dep2 ..." (grafo total)

declare -Ag _DEPS_STATE         # pkg -> 0 (nunca), 1 (visitando), 2 (finalizado)

_DEPS_INIT_DONE=0

# -----------------------------
# Garantir que metafile.sh foi carregado
# -----------------------------
_deps_ensure_metafile() {
    if declare -F adm_meta_load >/dev/null 2>&1; then
        return 0
    fi

    # Tentativa de carregar metafile.sh automaticamente
    local mf_script="/usr/src/adm/scripts/metafile.sh"
    if [ -r "$mf_script" ]; then
        # shellcheck source=/usr/src/adm/scripts/metafile.sh
        . "$mf_script" || _deps_fail "Falha ao carregar $mf_script"
        return $?
    fi

    _deps_fail "adm_meta_load não encontrado e metafile.sh não está acessível em $mf_script"
}

# -----------------------------
# Inicialização geral de deps
# -----------------------------
adm_deps_init() {
    if [ "$_DEPS_INIT_DONE" -eq 1 ]; then
        return 0
    fi

    if [ ! -d "$ADM_DEPS_REPO" ]; then
        _deps_log WARN "Diretório de repo não existe: $ADM_DEPS_REPO (continuando mesmo assim)"
    fi

    _deps_ensure_metafile || return 1

    # limpa estado global
    ADM_DEPS_ORDER=()
    ADM_DEPS_TO_BUILD=()
    ADM_DEPS_MISSING=()
    _DEPS_METAFILE=()
    _DEPS_CATEGORY=()
    _DEPS_VERSION=()
    _DEPS_RUN=()
    _DEPS_BUILD=()
    _DEPS_OPT=()
    _DEPS_ADJ=()
    _DEPS_STATE=()

    _DEPS_INIT_DONE=1
    _deps_log INFO "deps.sh inicializado (repo=$ADM_DEPS_REPO)"
    return 0
}

# -----------------------------
# Integração opcional com DB
# -----------------------------
_deps_is_installed() {
    # Retorna 0 se o pacote estiver instalado (via db.sh), 1 caso contrário.
    local pkg="$1"
    if [ "$_DEPS_HAVE_DB" -eq 1 ]; then
        adm_db_is_installed "$pkg"
        return $?
    fi
    # Sem DB, assume não instalado
    return 1
}

# -----------------------------
# Encontrar metafile de pacote
# -----------------------------
_deps_find_metafile() {
    # Uso:
    #   _deps_find_metafile pkg
    # Saída: imprime caminho do metafile ou vazio
    local ident="$1"
    local cat="" pkg=""

    if [ -z "$ident" ]; then
        return 1
    fi

    # Suporte a "categoria/pacote"
    if [[ "$ident" == */* ]]; then
        cat="${ident%%/*}"
        pkg="${ident##*/}"
    else
        pkg="$ident"
    fi

    # Se categoria foi especificada
    if [ -n "$cat" ]; then
        local path="$ADM_DEPS_REPO/$cat/$pkg/metafile"
        [ -f "$path" ] && { printf '%s\n' "$path"; return 0; }
        return 1
    fi

    # Caso contrário, procurar em todas categorias
    local found=()
    local p
    shopt -s nullglob
    for p in "$ADM_DEPS_REPO"/*/"$pkg"/metafile; do
        found+=("$p")
    done
    shopt -u nullglob

    case "${#found[@]}" in
        0)
            return 1
            ;;
        1)
            printf '%s\n' "${found[0]}"
            return 0
            ;;
        *)
            _deps_log WARN "Múltiplos metafiles encontrados para pacote '$pkg'; usando o primeiro: ${found[0]}"
            printf '%s\n' "${found[0]}"
            return 0
            ;;
    esac
}

# -----------------------------
# Carregar um pacote (metafile → cache)
# -----------------------------
_adm_deps_load_pkg() {
    # carrega informações de um pacote se ainda não estiver no cache
    local ident="$1"
    local pkg

    if [ -z "$ident" ]; then
        _deps_fail "_adm_deps_load_pkg: nome de pacote vazio"
        return 1
    fi

    # normalizar para apenas o nome do pacote (sem categoria)
    if [[ "$ident" == */* ]]; then
        pkg="${ident##*/}"
    else
        pkg="$ident"
    fi

    # já carregado?
    if [ -n "${_DEPS_METAFILE[$pkg]:-}" ]; then
        return 0
    fi

    local mf
    mf="$(_deps_find_metafile "$ident")" || {
        _deps_log ERROR "Metafile não encontrado para pacote '$ident'"
        ADM_DEPS_MISSING+=("$pkg")
        return 1
    }

    if ! adm_meta_load "$mf"; then
        _deps_log ERROR "Falha ao carregar metafile para pacote '$pkg' ($mf)"
        return 1
    fi

    if [ -z "$MF_NAME" ]; then
        _deps_log ERROR "Metafile '$mf' não definiu campo 'name'"
        return 1
    fi

    # Preencher caches
    _DEPS_METAFILE["$MF_NAME"]="$mf"
    _DEPS_CATEGORY["$MF_NAME"]="$MF_CATEGORY"
    _DEPS_VERSION["$MF_NAME"]="$MF_VERSION"

    # Dependências como strings (espaço separado)
    _DEPS_RUN["$MF_NAME"]="$(_deps_trim "$MF_RUN_DEPS")"
    _DEPS_BUILD["$MF_NAME"]="$(_deps_trim "$MF_BUILD_DEPS")"
    _DEPS_OPT["$MF_NAME"]="$(_deps_trim "$MF_OPT_DEPS")"

    _deps_log DEBUG "Carregado pacote '$MF_NAME' (versão=$MF_VERSION, cat=$MF_CATEGORY)"

    return 0
}
# -----------------------------
# Construir grafo de dependências para um pacote
# -----------------------------
_adm_deps_build_adj_for_pkg() {
    # Uso interno: assume que o pacote já foi carregado com _adm_deps_load_pkg
    local pkg="$1"
    local incl_opt="$2"   # 0 ou 1

    local run="${_DEPS_RUN[$pkg]:-}"
    local build="${_DEPS_BUILD[$pkg]:-}"
    local opt="${_DEPS_OPT[$pkg]:-}"

    local deps=""
    [ -n "$run" ]   && deps="$deps $run"
    [ -n "$build" ] && deps="$deps $build"
    if [ "$incl_opt" -eq 1 ] && [ -n "$opt" ]; then
        deps="$deps $opt"
    fi

    # normalizar
    deps="$(_deps_trim "$deps")"

    _DEPS_ADJ["$pkg"]="$deps"

    # garantir que todos os deps estejam carregados
    local d
    for d in $deps; do
        # evitar loops de recarga
        if [ -z "${_DEPS_METAFILE[$d]:-}" ]; then
            _adm_deps_load_pkg "$d" || {
                _deps_log ERROR "Falha ao carregar dependência '$d' requerida por '$pkg'"
                # registra como missing, mas continua para detectar mais erros
                continue
            }
            _adm_deps_build_adj_for_pkg "$d" "$incl_opt"
        fi
    done
}

# -----------------------------
# DFS para topological sort e detecção de ciclos
# -----------------------------
_ADM_DEPS_STACK=()

_adm_deps_stack_push() {
    _ADM_DEPS_STACK+=("$1")
}

_adm_deps_stack_pop() {
    local n="${#_ADM_DEPS_STACK[@]}"
    if [ "$n" -gt 0 ]; then
        unset "_ADM_DEPS_STACK[$((n-1))]"
        _ADM_DEPS_STACK=("${_ADM_DEPS_STACK[@]}")
    fi
}

_adm_deps_stack_path() {
    printf '%s' "${_ADM_DEPS_STACK[0]}"
    local i
    for (( i=1; i<${#_ADM_DEPS_STACK[@]}; i++ )); do
        printf ' -> %s' "${_ADM_DEPS_STACK[$i]}"
    done
}

_adm_deps_dfs_visit() {
    local pkg="$1"
    local incl_opt="$2"

    local st="${_DEPS_STATE[$pkg]:-0}"

    if [ "$st" -eq 1 ]; then
        # ciclo detectado
        _ADM_DEPS_STACK+=("$pkg")
        _deps_log ERROR "Ciclo de dependências detectado: $(_adm_deps_stack_path)"
        return 1
    elif [ "$st" -eq 2 ]; then
        # já finalizado
        return 0
    fi

    _DEPS_STATE["$pkg"]=1
    _adm_deps_stack_push "$pkg"

    local deps="${_DEPS_ADJ[$pkg]:-}"
    local d
    for d in $deps; do
        # ignora deps sem metafile (já logado em outro ponto)
        if [ -z "${_DEPS_METAFILE[$d]:-}" ]; then
            continue
        fi
        if ! _adm_deps_dfs_visit "$d" "$incl_opt"; then
            return 1
        fi
    done

    _DEPS_STATE["$pkg"]=2
    _adm_deps_stack_pop

    # adicionar pacote depois de todos deps (post-order)
    ADM_DEPS_ORDER+=("$pkg")
    return 0
}

# -----------------------------
# Resolver dependências para um conjunto de pacotes
# -----------------------------
adm_deps_resolve_pkgs() {
    # Uso:
    #   adm_deps_resolve_pkgs [--include-optional] pkg1 pkg2 ...
    #
    # Efeitos:
    #   - Preenche ADM_DEPS_ORDER (deps antes dos dependentes)
    #   - Preenche ADM_DEPS_TO_BUILD (apenas não instalados)
    #   - Preenche ADM_DEPS_MISSING (metafiles ausentes)
    #
    local incl_opt=0
    local roots=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --include-optional|--include-opt)
                incl_opt=1
                shift
                ;;
            *)
                roots+=("$1")
                shift
                ;;
        esac
    done

    if [ "${#roots[@]}" -eq 0 ]; then
        _deps_fail "adm_deps_resolve_pkgs: nenhum pacote informado"
        return 1
    fi

    adm_deps_init || return 1

    # Limpar resultados anteriores
    ADM_DEPS_ORDER=()
    ADM_DEPS_TO_BUILD=()
    ADM_DEPS_MISSING=()
    _DEPS_ADJ=()
    _DEPS_STATE=()
    _ADM_DEPS_STACK=()

    local r
    local rc=0

    # carregar e construir grafo a partir das raízes
    for r in "${roots[@]}"; do
        if ! _adm_deps_load_pkg "$r"; then
            _deps_log ERROR "Não foi possível carregar pacote raiz '$r'"
            rc=1
        fi
    done

    if [ "$rc" -ne 0 ]; then
        _deps_fail "Falha ao carregar um ou mais pacotes raiz"
        return 1
    fi

    for r in "${roots[@]}"; do
        local pkg="${r##*/}"
        _adm_deps_build_adj_for_pkg "$pkg" "$incl_opt"
    done

    # DFS topológico
    for r in "${roots[@]}"; do
        local pkg="${r##*/}"
        if ! _adm_deps_dfs_visit "$pkg" "$incl_opt"; then
            _deps_fail "Erro ao ordenar dependências (ciclo detectado)"
            return 1
        fi
    done

    # Remover duplicados mantendo ordem (DFS já tende a não duplicar, mas garantimos)
    local seen=()
    local unique=()
    local p
    for p in "${ADM_DEPS_ORDER[@]}"; do
        if [ -n "${seen[$p]:-}" ]; then
            continue
        fi
        seen["$p"]=1
        unique+=("$p")
    done
    ADM_DEPS_ORDER=("${unique[@]}")

    # Calcular ADM_DEPS_TO_BUILD
    ADM_DEPS_TO_BUILD=()
    for p in "${ADM_DEPS_ORDER[@]}"; do
        if ! _deps_is_installed "$p"; then
            ADM_DEPS_TO_BUILD+=("$p")
        fi
    done

    if [ "${#ADM_DEPS_MISSING[@]}" -gt 0 ]; then
        _deps_log ERROR "Pacotes sem metafile: ${ADM_DEPS_MISSING[*]}"
        return 1
    fi

    _deps_log INFO "Resolução de dependências concluída. Total=${#ADM_DEPS_ORDER[@]} para build; Novos=${#ADM_DEPS_TO_BUILD[@]}"

    return 0
}

# -----------------------------
# Funções auxiliares públicas
# -----------------------------
adm_deps_get_metafile() {
    # Imprime caminho do metafile de um pacote
    local pkg="${1##*/}"
    local mf="${_DEPS_METAFILE[$pkg]:-}"
    if [ -z "$mf" ]; then
        _deps_fail "adm_deps_get_metafile: pacote '$pkg' não conhecido (chame adm_deps_resolve_pkgs antes)"
        return 1
    fi
    printf '%s\n' "$mf"
}

adm_deps_get_run_deps() {
    local pkg="${1##*/}"
    printf '%s\n' "${_DEPS_RUN[$pkg]:-}"
}

adm_deps_get_build_deps() {
    local pkg="${1##*/}"
    printf '%s\n' "${_DEPS_BUILD[$pkg]:-}"
}

adm_deps_get_opt_deps() {
    local pkg="${1##*/}"
    printf '%s\n' "${_DEPS_OPT[$pkg]:-}"
}

adm_deps_print_order() {
    local p
    for p in "${ADM_DEPS_ORDER[@]}"; do
        printf '%s\n' "$p"
    done
}

adm_deps_print_to_build() {
    local p
    for p in "${ADM_DEPS_TO_BUILD[@]}"; do
        printf '%s\n' "$p"
    done
}

# -----------------------------
# Modo de teste direto
# -----------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Exemplo:
    #   ./deps.sh bash coreutils
    if [ "$#" -lt 1 ]; then
        echo "Uso: $0 [--include-optional] pkg1 pkg2 ..." >&2
        exit 1
    fi

    if ! adm_deps_resolve_pkgs "$@"; then
        echo "ERRO na resolução de dependências." >&2
        exit 1
    fi

    echo "== ORDEM COMPLETA =="
    adm_deps_print_order

    echo
    echo "== A CONSTRUIR (não instalados) =="
    adm_deps_print_to_build
fi
