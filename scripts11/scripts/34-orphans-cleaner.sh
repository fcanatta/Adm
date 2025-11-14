#!/usr/bin/env bash
# 34-orphans-cleaner.sh
# Limpador de órfãos do ADM.
#
# Usa o DB criado por 33-install-remove.sh:
#   ADM_DB_ROOT/installs/<root_id>/packages/<cat>/<nome>/<versao>/{manifest,files.list}
#
# Integra com:
#   - 10-repo-metafile.sh (adm_meta_load, adm_meta_get_var)
#   - 32-resolver-deps.sh (adm_deps_parse_token) se disponível
#   - 33-install-remove.sh (adm_pkg_remove_version) para remoção segura
#   - 01-log-ui.sh para logs bonitos (com fallback)
#
# Descobre:
#   - Pacotes órfãos (sem nenhum outro pacote dependendo deles - run_deps/opt_deps)
#   - Versões obsoletas (stale): pacotes com múltiplas versões instaladas
#   - Dependências ausentes (metafile cita but não existe/instalada)
#
# CLI:
#   34-orphans-cleaner.sh scan [root]
#   34-orphans-cleaner.sh list [root]
#   34-orphans-cleaner.sh remove-orphans [root] [--force]
#   34-orphans-cleaner.sh remove-stale   [root] [--force]
#   34-orphans-cleaner.sh help
#
# Env opcional:
#   ADM_DB_ROOT               (default: /usr/src/adm/db)
#   ADM_REPO                  (default: /usr/src/adm/repo)
#   ADM_ORPHANS_PROTECTED     (lista separada por espaço: "cat/pkg" ou "pkg" a proteger)
#
# Nenhum erro silencioso: qualquer estado inconsistente gera mensagem clara.

# ----------------------------------------------------------------------
# Requisitos e modo seguro
# ----------------------------------------------------------------------

if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERRO: 34-orphans-cleaner.sh requer bash." >&2
    exit 1
fi

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "ERRO: 34-orphans-cleaner.sh requer bash >= 4." >&2
    exit 1
fi

set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------
# Ambiente, logging e integrações
# ----------------------------------------------------------------------

ADM_ROOT_DEFAULT="/usr/src/adm"
ADM_ROOT="${ADM_ROOT:-$ADM_ROOT_DEFAULT}"

ADM_DB_ROOT="${ADM_DB_ROOT:-$ADM_ROOT/db}"
ADM_REPO="${ADM_REPO:-$ADM_ROOT/repo}"

# Logging: usa 01-log-ui.sh se disponível; senão, fallback simples.
if ! declare -F adm_info >/dev/null 2>&1; then
    adm_log_ts() { date +"%Y-%m-%d %H:%M:%S"; }
    adm_info()   { printf '[%s] [INFO] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_warn()   { printf '[%s] [WARN] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_error()  { printf '[%s] [ERRO] %s\n'  "$(adm_log_ts)" "$*" >&2; }
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

# Sanitizadores básicos (compatíveis com 10-repo-metafile / 33-install-remove)
if ! declare -F adm_repo_sanitize_name >/dev/null 2>&1; then
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
fi

if ! declare -F adm_repo_sanitize_category >/dev/null 2>&1; then
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
fi

# Metafile API é essencial para saber deps
if ! declare -F adm_meta_load >/dev/null 2>&1 || \
   ! declare -F adm_meta_get_var >/dev/null 2>&1; then
    adm_die "Funções de metafile (adm_meta_load/adm_meta_get_var) não disponíveis. Carregue 10-repo-metafile.sh."
fi

# Para remover pacotes, usamos adm_pkg_remove_version, se disponível
ADM_ORPHANS_CAN_REMOVE=0
if declare -F adm_pkg_remove_version >/dev/null 2>&1; then
    ADM_ORPHANS_CAN_REMOVE=1
fi

# Para parse de token (apenas 'pkg' ou 'cat/pkg'), usamos resolver se existir
ADM_HAS_DEPS_TOKEN_PARSE=0
if declare -F adm_deps_parse_token >/dev/null 2>&1; then
    ADM_HAS_DEPS_TOKEN_PARSE=1
fi

# ----------------------------------------------------------------------
# Helpers de root / DB
# ----------------------------------------------------------------------

adm_orphans_root_normalize() {
    local root="${1:-/}"
    [ -z "$root" ] && root="/"
    root="$(printf '%s' "$root" | sed 's://*:/:g')"
    printf '%s\n' "$root"
}

adm_orphans_root_id() {
    local root
    root="$(adm_orphans_root_normalize "${1:-/}")"

    if [ "$root" = "/" ]; then
        printf '%s\n' "host"
        return 0
    fi

    local id
    id="$(printf '%s' "$root" | sed 's:[^A-Za-z0-9._-]:_:g')"
    [ -z "$id" ] && id="root"
    printf '%s\n' "$id"
}

adm_orphans_db_root_for() {
    local root="${1:-/}"
    local root_id
    root_id="$(adm_orphans_root_id "$root")"
    printf '%s/installs/%s' "$ADM_DB_ROOT" "$root_id"
}

adm_orphans_db_packages_root() {
    local root="${1:-/}"
    local dbroot
    dbroot="$(adm_orphans_db_root_for "$root")"
    printf '%s/packages' "$dbroot"
}

# ----------------------------------------------------------------------
# Parse de token de pacote e de dependência
# ----------------------------------------------------------------------

adm_orphans_parse_pkg_token() {
    # token: "cat/pkg" ou "pkg"; retorna "categoria nome"
    local token_raw="${1:-}"
    local token
    token="${token_raw#"${token_raw%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"

    if [ -z "$token" ]; then
        adm_die "adm_orphans_parse_pkg_token chamado com token vazio."
    fi

    if [[ "$token" == */* ]]; then
        local category_part="${token%%/*}"
        local name_part="${token#*/}"
        local c n
        c="$(adm_repo_sanitize_category "$category_part")"
        n="$(adm_repo_sanitize_name "$name_part")"
        printf '%s %s\n' "$c" "$n"
    else
        # Sem categoria -> tentamos resolver via adm_deps_parse_token se existir,
        # senão buscamos no ADM_REPO manualmente.
        if [ "$ADM_HAS_DEPS_TOKEN_PARSE" -eq 1 ]; then
            local out
            if out="$(adm_deps_parse_token "$token" 2>/dev/null)"; then
                printf '%s\n' "$out"
            else
                # Não encontramos no resolver -> tratamos como "externo"
                return 1
            fi
        else
            local name
            name="$(adm_repo_sanitize_name "$token")"
            local matches=() cat_dir pkg_dir cat pkg

            if [ ! -d "$ADM_REPO" ]; then
                adm_warn "ADM_REPO não existe ($ADM_REPO); não é possível resolver '$token'."
                return 1
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
                return 1
            elif [ "$count" -gt 1 ]; then
                adm_warn "Pacote '$name' é ambíguo (múltiplas categorias) ao tentar resolver dependência; ignorando este token."
                return 1
            fi

            printf '%s\n' "${matches[0]}"
        fi
    fi
}

adm_orphans_parse_dep_list_to_pairs() {
    # Converte string "dep1,dep2,cat/pkg" em linhas "cat nome".
    #
    # Diferença importante: NÃO morre se dependência não puder ser resolvida;
    # apenas dá warning e ignora (trata como dep externa/nativa).
    local list="${1:-}"

    [ -z "$list" ] && return 0

    local IFS=','
    local token
    for token in $list; do
        token="${token#"${token%%[![:space:]]*}"}"
        token="${token%"${token##*[![:space:]]}"}"
        [ -z "$token" ] && continue

        local out
        if out="$(adm_orphans_parse_pkg_token "$token" 2>/dev/null)"; then
            printf '%s\n' "$out"
        else
            adm_warn "Dependência '$token' não pôde ser resolvida (provavelmente externo/sistema); ignorando para órfãos."
            # Não falha, apenas ignora este dep.
        fi
    done
}

# ----------------------------------------------------------------------
# Estruturas internas
# ----------------------------------------------------------------------
# Chave principal: "cat name ver"

declare -Ag ADM_ORPH_PKG_CAT       # key -> categoria
declare -Ag ADM_ORPH_PKG_NAME      # key -> nome
declare -Ag ADM_ORPH_PKG_VER       # key -> versao
declare -Ag ADM_ORPH_PKG_DEP_TOK   # key -> string "cat name;cat name;..."
declare -Ag ADM_ORPH_REVDEP_COUNT  # key -> número de dependentes
declare -Ag ADM_ORPH_PKG_PROTECTED # "cat name" -> 1 (protegido)

declare -Ag ADM_ORPH_VERSIONS_BY_PKG # "cat name" -> "ver1 ver2 ..."
declare -Ag ADM_ORPH_MAX_VERSION_BY_PKG # "cat name" -> versao mais nova (sort -V)

declare -Ag ADM_ORPH_MISSING_DEPS  # "cat name" (dep) -> contador de pacotes que referem

ADM_ORPH_SCANNED_ROOT=""

adm_orphans_key() {
    local c="${1:-}" n="${2:-}" v="${3:-}"
    printf '%s %s %s' "$c" "$n" "$v"
}

adm_orphans_pkg_id() {
    local c="${1:-}" n="${2:-}"
    printf '%s %s' "$c" "$n"
}

# ----------------------------------------------------------------------
# Carregar proteção (pacotes que nunca serão considerados órfãos)
# ----------------------------------------------------------------------

adm_orphans_load_protected() {
    # ADM_ORPHANS_PROTECTED="sys/bash sys/coreutils gcc ..."
    local prot="${ADM_ORPHANS_PROTECTED:-}"

    [ -z "$prot" ] && return 0

    local token
    for token in $prot; do
        local out
        if out="$(adm_orphans_parse_pkg_token "$token" 2>/dev/null)"; then
            local c n
            c="${out%% *}"
            n="${out#* }"
            local id
            id="$(adm_orphans_pkg_id "$c" "$n")"
            ADM_ORPH_PKG_PROTECTED["$id"]=1
        else
            adm_warn "Token protegido '$token' não pôde ser resolvido; ignorando."
        fi
    done
}

# ----------------------------------------------------------------------
# Leitura do DB de instalação
# ----------------------------------------------------------------------

adm_orphans_load_db_for_root() {
    local root="${1:-/}"
    root="$(adm_orphans_root_normalize "$root")"
    ADM_ORPH_SCANNED_ROOT="$root"

    local pkgs_root
    pkgs_root="$(adm_orphans_db_packages_root "$root")"

    if [ ! -d "$pkgs_root" ]; then
        adm_warn "Nenhum DB de pacotes encontrado para root=$root em $pkgs_root."
        return 0
    fi

    adm_stage "SCAN-DB root=$root (pkgs_root=$pkgs_root)"

    local cat_dir pkg_dir ver_dir cat pkg ver key
    for cat_dir in "$pkgs_root"/*; do
        [ -d "$cat_dir" ] || continue
        cat="$(basename "$cat_dir")"
        for pkg_dir in "$cat_dir"/*; do
            [ -d "$pkg_dir" ] || continue
            pkg="$(basename "$pkg_dir")"
            for ver_dir in "$pkg_dir"/*; do
                [ -d "$ver_dir" ] || continue
                ver="$(basename "$ver_dir")"

                key="$(adm_orphans_key "$cat" "$pkg" "$ver")"
                ADM_ORPH_PKG_CAT["$key"]="$cat"
                ADM_ORPH_PKG_NAME["$key"]="$pkg"
                ADM_ORPH_PKG_VER["$key"]="$ver"
                ADM_ORPH_REVDEP_COUNT["$key"]=0
            done
        done
    done
}

adm_orphans_has_pkgs() {
    [ "${#ADM_ORPH_PKG_CAT[@]}" -gt 0 ]
}

# ----------------------------------------------------------------------
# Construir mapa de versões por pacote (cat+name)
# ----------------------------------------------------------------------

adm_orphans_build_version_maps() {
    local key c n v id
    for key in "${!ADM_ORPH_PKG_CAT[@]}"; do
        c="${ADM_ORPH_PKG_CAT[$key]}"
        n="${ADM_ORPH_PKG_NAME[$key]}"
        v="${ADM_ORPH_PKG_VER[$key]}"
        id="$(adm_orphans_pkg_id "$c" "$n")"

        local current="${ADM_ORPH_VERSIONS_BY_PKG[$id]:-}"
        if [ -z "$current" ]; then
            ADM_ORPH_VERSIONS_BY_PKG["$id"]="$v"
        else
            ADM_ORPH_VERSIONS_BY_PKG["$id"]="$current $v"
        fi
    done

    # Determinar versão máxima (mais nova) por pacote (sort -V)
    local pkg_id versions max
    for pkg_id in "${!ADM_ORPH_VERSIONS_BY_PKG[@]}"; do
        versions="${ADM_ORPH_VERSIONS_BY_PKG[$pkg_id]}"
        max="$(printf '%s\n' $versions | sort -V | tail -n1)"
        ADM_ORPH_MAX_VERSION_BY_PKG["$pkg_id"]="$max"
    done
}

# ----------------------------------------------------------------------
# Carregar dependências a partir dos metafiles
# ----------------------------------------------------------------------

adm_orphans_load_pkg_deps() {
    local root="${1:-/}"
    root="$(adm_orphans_root_normalize "$root")"

    adm_stage "LOAD-DEPS (metafiles) para root=$root"

    local key c n v pkg_id
    for key in "${!ADM_ORPH_PKG_CAT[@]}"; do
        c="${ADM_ORPH_PKG_CAT[$key]}"
        n="${ADM_ORPH_PKG_NAME[$key]}"
        v="${ADM_ORPH_PKG_VER[$key]}" # pode não ser usado aqui, mas mantemos

        # Carregar metafile
        adm_meta_load "$c" "$n"
        local run_deps build_deps opt_deps
        run_deps="$(adm_meta_get_var "run_deps")"
        build_deps="$(adm_meta_get_var "build_deps")"
        opt_deps="$(adm_meta_get_var "opt_deps")"

        # Para órfãos em runtime, nos interessam principalmente run_deps+opt_deps.
        # (build_deps não influenciam se um pacote continua necessário em runtime,
        #  mas ainda podem ser usados para análises futuras; ignoramos por ora aqui.)
        local all_runtime_deps
        if [ -n "$run_deps" ] || [ -n "$opt_deps" ]; then
            all_runtime_deps="$run_deps,$opt_deps"
        else
            all_runtime_deps=""
        fi

        # Converte deps em pares "cat nome"
        local dep_list_pairs=""
        if [ -n "$all_runtime_deps" ]; then
            dep_list_pairs="$(adm_orphans_parse_dep_list_to_pairs "$all_runtime_deps")"
        fi

        # Guardar forma normalizada: "cat name;cat name;..."
        local dep_pairs_str=""
        if [ -n "$dep_list_pairs" ]; then
            local line
            while IFS= read -r line || [ -n "$line" ]; do
                [ -z "$line" ] && continue
                dep_pairs_str+="${line};"
            done <<< "$dep_list_pairs"
        fi

        ADM_ORPH_PKG_DEP_TOK["$key"]="$dep_pairs_str"
    done
}

# ----------------------------------------------------------------------
# Construir grafo reverso de dependências
# ----------------------------------------------------------------------

adm_orphans_build_reverse_deps() {
    adm_stage "BUILD-REVERSE-DEPS"

    local key deps dep c_dep n_dep ver_list pkg_id dep_id dep_key

    for key in "${!ADM_ORPH_PKG_CAT[@]}"; do
        deps="${ADM_ORPH_PKG_DEP_TOK[$key]:-}"
        [ -z "$deps" ] && continue

        # deps: "cat name;cat name;..."
        while [ -n "$deps" ]; do
            dep="${deps%%;*}"
            deps="${deps#*;}"
            [ -z "$dep" ] && continue

            c_dep="${dep%% *}"
            n_dep="${dep#* }"

            dep_id="$(adm_orphans_pkg_id "$c_dep" "$n_dep")"
            ver_list="${ADM_ORPH_VERSIONS_BY_PKG[$dep_id]:-}"

            if [ -z "$ver_list" ]; then
                # Dependência citada, mas nenhuma versão instalada
                # Marcamos como "missing dep" para relatório
                ADM_ORPH_MISSING_DEPS["$dep_id"]=$(( ${ADM_ORPH_MISSING_DEPS[$dep_id]:-0} + 1 ))
                continue
            fi

            # Para cada versão instalada dessa dependência, aumentamos contador de dependentes
            local v
            for v in $ver_list; do
                dep_key="$(adm_orphans_key "$c_dep" "$n_dep" "$v")"
                ADM_ORPH_REVDEP_COUNT["$dep_key"]=$(( ${ADM_ORPH_REVDEP_COUNT[$dep_key]:-0} + 1 ))
            done
        done
    done
}

# ----------------------------------------------------------------------
# Descobrir órfãos e versões obsoletas
# ----------------------------------------------------------------------

adm_orphans_classify() {
    local root="${1:-/}"
    root="$(adm_orphans_root_normalize "$root")"

    adm_stage "CLASSIFY-ORPHANS root=$root"

    local key c n v id count maxver

    echo "=== Pacotes instalados em root=$root ===" >&2
    local total=0
    for key in "${!ADM_ORPH_PKG_CAT[@]}"; do
        total=$((total+1))
    done
    adm_info "Total de entradas (cat/nome/versao) no DB: $total"
}

adm_orphans_list_candidates() {
    # Gera três listas:
    #   1) leaf_orphans: cat name ver (sem dependentes)
    #   2) stale_versions: cat name ver (versões não-máximas)
    #   3) missing_deps: cat name (sem versao)
    local key c n v id count maxver

    echo "### ORPHANS-LEAF"    # marcador de seção
    for key in "${!ADM_ORPH_PKG_CAT[@]}"; do
        c="${ADM_ORPH_PKG_CAT[$key]}"
        n="${ADM_ORPH_PKG_NAME[$key]}"
        v="${ADM_ORPH_PKG_VER[$key]}"
        id="$(adm_orphans_pkg_id "$c" "$n")"
        count="${ADM_ORPH_REVDEP_COUNT[$key]:-0}"
        if [ "$count" -eq 0 ]; then
            # checar se protegido
            if [ "${ADM_ORPH_PKG_PROTECTED[$id]:-0}" -eq 1 ]; then
                continue
            fi
            printf '%s %s %s\n' "$c" "$n" "$v"
        fi
    done

    echo "### STALE-VERSIONS"
    local pkg_id versions max
    for pkg_id in "${!ADM_ORPH_VERSIONS_BY_PKG[@]}"; do
        versions="${ADM_ORPH_VERSIONS_BY_PKG[$pkg_id]}"
        max="${ADM_ORPH_MAX_VERSION_BY_PKG[$pkg_id]}"
        for v in $versions; do
            [ "$v" = "$max" ] && continue
            # pacote tem versão obsoleta
            c="${pkg_id%% *}"
            n="${pkg_id#* }"
            printf '%s %s %s\n' "$c" "$n" "$v"
        done
    done

    echo "### MISSING-DEPS"
    local dep_id
    for dep_id in "${!ADM_ORPH_MISSING_DEPS[@]}"; do
        c="${dep_id%% *}"
        n="${dep_id#* }"
        printf '%s %s %s\n' "$c" "$n" "${ADM_ORPH_MISSING_DEPS[$dep_id]}"
    done
}

# ----------------------------------------------------------------------
# Relatórios
# ----------------------------------------------------------------------

adm_orphans_report_scan() {
    local root="${1:-/}"
    root="$(adm_orphans_root_normalize "$root")"

    adm_stage "SCAN-ORPHANS root=$root"

    adm_orphans_load_db_for_root "$root"
    if ! adm_orphans_has_pkgs; then
        adm_info "Nenhum pacote instalado encontrado para root=$root."
        return 0
    fi

    adm_orphans_load_protected
    adm_orphans_build_version_maps
    adm_orphans_load_pkg_deps "$root"
    adm_orphans_build_reverse_deps

    # Produz relatório humano
    local out
    out="$(adm_orphans_list_candidates)"

    local section
    section="$(printf '%s\n' "$out" | sed -n '1p')"
    if [ "$section" != "### ORPHANS-LEAF" ]; then
        adm_die "Erro interno: formato inesperado em adm_orphans_list_candidates"
    fi

    echo "===== RELATÓRIO DE ÓRFÃOS (leaf) para root=$root ====="
    printf '%s\n' "$out" | awk '
        BEGIN {
            sec = "";
        }
        /^### / {
            sec = $2;
            print "";
            if (sec == "ORPHANS-LEAF") {
                print ">> Pacotes órfãos (sem dependentes, não protegidos):";
                print "categoria nome versao";
            } else if (sec == "STALE-VERSIONS") {
                print ">> Versões obsoletas (pacotes com múltiplas versões; estas NÃO são as mais novas):";
                print "categoria nome versao";
            } else if (sec == "MISSING-DEPS") {
                print ">> Dependências citadas mas NÃO instaladas (count = quantos pacotes citam):";
                print "categoria nome count";
            }
            next;
        }
        NF {
            print $0;
        }
    '
}

adm_orphans_report_list() {
    local root="${1:-/}"
    root="$(adm_orphans_root_normalize "$root")"

    adm_stage "LIST-ORPHANS root=$root"

    adm_orphans_load_db_for_root "$root"
    if ! adm_orphans_has_pkgs; then
        adm_info "Nenhum pacote instalado encontrado para root=$root."
        return 0
    fi

    adm_orphans_load_protected
    adm_orphans_build_version_maps
    adm_orphans_load_pkg_deps "$root"
    adm_orphans_build_reverse_deps

    local out
    out="$(adm_orphans_list_candidates)"

    echo "== Orphans (leaf) =="
    printf '%s\n' "$out" | awk '
        /^### ORPHANS-LEAF/ { sec=1; next }
        /^###/              { sec=0; next }
        sec==1 && NF { print $0 }
    '

    echo
    echo "== Stale versions =="
    printf '%s\n' "$out" | awk '
        /^### STALE-VERSIONS/ { sec=1; next }
        /^###/                { sec=0; next }
        sec==1 && NF { print $0 }
    '
}

# ----------------------------------------------------------------------
# Remoções (órfãos e stale)
# ----------------------------------------------------------------------

adm_orphans_remove_list() {
    local root="${1:-/}" target_section="${2:-ORPHANS-LEAF}" force="${3:-0}"

    root="$(adm_orphans_root_normalize "$root")"

    adm_stage "REMOVE-$target_section root=$root (force=$force)"

    if [ "$ADM_ORPHANS_CAN_REMOVE" -ne 1 ]; then
        adm_die "adm_pkg_remove_version não está disponível; carregue 33-install-remove.sh antes de remover pacotes."
    fi

    adm_orphans_load_db_for_root "$root"
    if ! adm_orphans_has_pkgs; then
        adm_info "Nenhum pacote instalado encontrado para root=$root."
        return 0
    fi

    adm_orphans_load_protected
    adm_orphans_build_version_maps
    adm_orphans_load_pkg_deps "$root"
    adm_orphans_build_reverse_deps

    local out
    out="$(adm_orphans_list_candidates)"

    local section_name="ORPHANS-LEAF"
    [ "$target_section" = "STALE-VERSIONS" ] && section_name="STALE-VERSIONS"

    local list
    list="$(printf '%s\n' "$out" | awk -v s="$section_name" '
        $0=="### " s { next }
        $0=="### " s" " { next }
    ' )'  # não serve; vamos filtrar direito

    # Re-filtrar direito: extrair só a seção desejada
    list="$(printf '%s\n' "$out" | awk -v s="### "s -v s2="### " '
        BEGIN { sec=0 }
        $0==s { sec=1; next }
        /^### / { if ($0!=s) sec=0; next }
        sec==1 && NF { print $0 }
    ')"

    if [ -z "$list" ]; then
        adm_info "Nenhum candidato a remoção encontrado para seção $target_section em root=$root."
        return 0
    fi

    adm_info "Candidatos a remoção ($target_section) em root=$root:"
    printf '%s\n' "$list"

    if [ "$force" -ne 1 ]; then
        adm_warn "Remoção NÃO executada (falta --force)."
        return 0
    fi

    adm_warn "Removendo pacotes ($target_section) em root=$root (force=1)."

    local line c n v
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        c="${line%% *}"
        n="${line#* }"
        v="${n##* }"
        n="${n% *}"

        adm_info "Removendo $c/$n-$v (root=$root)"
        adm_pkg_remove_version "$c" "$n" "$v" "$root"
    done <<< "$list"
}

# ----------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------

adm_orphans_usage() {
    cat <<EOF
Uso: $(basename "$0") <comando> [args...]

Comandos:
  scan [root]
      - Relatório completo de órfãos, versões obsoletas e deps ausentes.

  list [root]
      - Listagem resumida de órfãos e versões obsoletas.

  remove-orphans [root] [--force]
      - Remove pacotes órfãos (leaf: sem dependentes, não protegidos).
      - Sem --force, apenas mostra os candidatos.

  remove-stale [root] [--force]
      - Remove versões obsoletas (todas as versões não-máximas de cada pacote).
      - Sem --force, apenas mostra os candidatos.

  help
      - Mostra esta ajuda.

Exemplos:
  $(basename "$0") scan /
  $(basename "$0") list /usr/src/adm/rootfs-stage1
  $(basename "$0") remove-orphans / --force
  $(basename "$0") remove-stale /usr/src/adm/rootfs-stage2 --force

Env:
  ADM_DB_ROOT=/usr/src/adm/db
  ADM_REPO=/usr/src/adm/repo
  ADM_ORPHANS_PROTECTED="sys/bash sys/coreutils gcc ..."
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cmd="${1:-help}"
    case "$cmd" in
        scan)
            if [ "$#" -gt 2 ]; then
                adm_error "Uso: $0 scan [root]"
                exit 1
            fi
            root="${2:-/}"
            adm_orphans_report_scan "$root"
            ;;
        list)
            if [ "$#" -gt 2 ]; then
                adm_error "Uso: $0 list [root]"
                exit 1
            fi
            root="${2:-/}"
            adm_orphans_report_list "$root"
            ;;
        remove-orphans)
            if [ "$#" -gt 3 ]; then
                adm_error "Uso: $0 remove-orphans [root] [--force]"
                exit 1
            fi
            root="${2:-/}"
            force=0
            if [ "${3:-}" = "--force" ]; then
                force=1
            fi
            adm_orphans_remove_list "$root" "ORPHANS-LEAF" "$force"
            ;;
        remove-stale)
            if [ "$#" -gt 3 ]; then
                adm_error "Uso: $0 remove-stale [root] [--force]"
                exit 1
            fi
            root="${2:-/}"
            force=0
            if [ "${3:-}" = "--force" ]; then
                force=1
            fi
            adm_orphans_remove_list "$root" "STALE-VERSIONS" "$force"
            ;;
        help|-h|--help)
            adm_orphans_usage
            ;;
        *)
            adm_error "Comando desconhecido: $cmd"
            adm_orphans_usage
            exit 1
            ;;
    esac
fi
