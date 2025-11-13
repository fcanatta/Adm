#!/usr/bin/env bash
# lib/adm/pkg.sh
#
# Subsistema de PACOTES do ADM
#
# Responsabilidades:
#   - Instalar pacotes (construindo via build.sh e instalando em / ou em um root custom)
#   - Registrar instalação em packages.db
#   - Desinstalar pacotes usando manifest de arquivos
#   - Autoremove de órfãos usando deps.sh
#   - Listar / inspecionar pacotes instalados
#   - Nenhum erro silencioso: todos os problemas são logados claramente
#
# Formato de packages.db (tab-separated):
#   name<TAB>category<TAB>version<TAB>profile<TAB>libc<TAB>install_reason<TAB>run_deps<TAB>status
#
# Campos:
#   name            ex: util-linux
#   category        ex: base
#   version         ex: 2.41.1
#   profile         ex: normal
#   libc            ex: glibc | musl | unknown
#   install_reason  explicit | auto
#   run_deps        CSV (dep1,dep2,...)
#   status          installed | removed
#
# Manifest de arquivos:
#   - Guardado em: $ADM_STATE_DIR/manifests/<category>/<name>.list
#   - Cada linha: caminho relativo à raiz do sistema, sem "/" inicial
#     Exemplo: "usr/bin/gcc"
###############################################################################
# Proteção contra múltiplos loads
###############################################################################
if [ -n "${ADM_PKG_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
ADM_PKG_LOADED=1
###############################################################################
# Dependências: log + core + repo + build + deps
###############################################################################
# -------- LOG ---------------------------------------------------------
if ! command -v adm_log_pkg >/dev/null 2>&1; then
    # Fallback mínimo se log.sh ainda não foi carregado
    adm_log()        { printf '%s\n' "$*" >&2; }
    adm_log_info()   { adm_log "[INFO]   $*"; }
    adm_log_warn()   { adm_log "[WARN]   $*"; }
    adm_log_error()  { adm_log "[ERROR]  $*"; }
    adm_log_debug()  { :; }
    adm_log_pkg()    { adm_log "[PKG]    $*"; }
fi

# -------- CORE (paths, root, helpers) --------------------------------
if command -v adm_core_init_paths >/dev/null 2>&1; then
    adm_core_init_paths
fi

if ! command -v adm_require_root >/dev/null 2>&1; then
    adm_require_root() {
        if [ "$(id -u 2>/dev/null)" != "0" ]; then
            adm_log_error "Este comando requer privilégios de root."
            return 1
        fi
        return 0
    }
fi

if ! command -v adm_mkdir_p >/dev/null 2>&1; then
    adm_mkdir_p() {
        if [ $# -ne 1 ]; then
            adm_log_error "adm_mkdir_p requer 1 argumento: DIRETÓRIO"
            return 1
        fi
        mkdir -p -- "$1" 2>/dev/null || {
            adm_log_error "Falha ao criar diretório: %s" "$1"
            return 1
        }
    }
fi

if ! command -v adm_rm_rf_safe >/dev/null 2>&1; then
    adm_rm_rf_safe() {
        if [ $# -ne 1 ]; then
            adm_log_error "adm_rm_rf_safe requer 1 argumento: CAMINHO"
            return 1
        fi
        rm -rf -- "$1" 2>/dev/null || {
            adm_log_warn "Falha ao remover recursivamente: %s" "$1"
            return 1
        }
    }
fi

# -------- REPO --------------------------------------------------------
if ! command -v adm_repo_load_metafile >/dev/null 2>&1; then
    adm_log_error "repo.sh não carregado; adm_repo_load_metafile ausente. pkg.sh ficará limitado."
fi

if ! command -v adm_repo_parse_deps >/dev/null 2>&1; then
    adm_log_warn "adm_repo_parse_deps ausente; usando parser CSV simples."
    adm_repo_parse_deps() {
        printf '%s\n' "$1" | tr ',' '\n'
    }
fi

if ! command -v adm_repo_hooks_dir >/dev/null 2>&1; then
    adm_repo_hooks_dir() { return 1; }
fi

# -------- BUILD -------------------------------------------------------
if ! command -v adm_build_package >/dev/null 2>&1; then
    adm_log_error "build.sh não carregado; adm_build_package ausente. adm_pkg_install não poderá construir pacotes."
fi

# -------- DEPS (para órfãos) -----------------------------------------
if ! command -v adm_deps_list_orphans >/dev/null 2>&1; then
    adm_log_warn "deps.sh não carregado; autoremove de órfãos não estará disponível."
    adm_deps_list_orphans() { :; }
fi

# -------- PATHS GLOBAIS -----------------------------------------------
: "${ADM_ROOT:=${ADM_ROOT:-/usr/src/adm}}"
: "${ADM_STATE_DIR:=${ADM_STATE_DIR:-$ADM_ROOT/state}}"
: "${ADM_DESTDIR_DIR:=${ADM_DESTDIR_DIR:-$ADM_ROOT/destdir}}"
: "${ADM_LOG_DIR:=${ADM_LOG_DIR:-$ADM_ROOT/logs}}"

: "${ADM_DEPS_DB_PATH:=${ADM_DEPS_DB_PATH:-$ADM_STATE_DIR/packages.db}}"
: "${ADM_MANIFEST_DIR:=${ADM_MANIFEST_DIR:-$ADM_STATE_DIR/manifests}}"
: "${ADM_INSTALL_ROOT:=${ADM_INSTALL_ROOT:-/}}"  # raiz onde o pacote é instalado

adm_mkdir_p "$ADM_STATE_DIR"   || adm_log_error "Falha ao criar ADM_STATE_DIR: %s" "$ADM_STATE_DIR"
adm_mkdir_p "$ADM_MANIFEST_DIR"|| adm_log_error "Falha ao criar ADM_MANIFEST_DIR: %s" "$ADM_MANIFEST_DIR"
adm_mkdir_p "$ADM_LOG_DIR"     || adm_log_error "Falha ao criar ADM_LOG_DIR: %s" "$ADM_LOG_DIR"

###############################################################################
# Helpers internos
###############################################################################

adm_pkg__trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

adm_pkg__pkg_key() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_pkg__pkg_key requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi
    printf '%s/%s\n' "$1" "$2"
}

adm_pkg__validate_identifier() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_pkg__validate_identifier requer 1 argumento."
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

adm_pkg__manifest_path() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_pkg__manifest_path requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi
    local category="$1" pkg="$2"
    printf '%s/%s/%s.list\n' "$ADM_MANIFEST_DIR" "$category" "$pkg"
}

###############################################################################
# packages.db – leitura / gravação
###############################################################################

adm_pkg_db_init() {
    if [ ! -f "$ADM_DEPS_DB_PATH" ]; then
        adm_log_debug "Criando packages.db em: %s" "$ADM_DEPS_DB_PATH"
        adm_mkdir_p "$(dirname "$ADM_DEPS_DB_PATH")" || return 1
        : >"$ADM_DEPS_DB_PATH" 2>/dev/null || {
            adm_log_error "Não foi possível criar packages.db: %s" "$ADM_DEPS_DB_PATH"
            return 1
        }
    fi
    return 0
}

# Lê DB inteiro para stdout (apenas linhas não vazias e não comentadas)
adm_pkg_db_read_all() {
    adm_pkg_db_init || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in
            \#*) continue ;;
        esac
        printf '%s\n' "$line"
    done <"$ADM_DEPS_DB_PATH"
}

# Reescreve DB com um conjunto de linhas (espera input em stdin)
adm_pkg_db_write_from_stdin() {
    adm_pkg_db_init || return 1
    local tmp
    tmp="$(mktemp -t adm-pkg-db-XXXXXX 2>/dev/null || echo '')"
    if [ -z "$tmp" ]; then
        adm_log_error "Falha ao criar arquivo temporário para atualizar packages.db."
        return 1
    fi

    cat >"$tmp" 2>/dev/null || {
        adm_log_error "Falha ao escrever no arquivo temporário (%s)." "$tmp"
        rm -f "$tmp" 2>/dev/null || :
        return 1
    }

    if ! mv "$tmp" "$ADM_DEPS_DB_PATH" 2>/dev/null; then
        adm_log_error "Falha ao substituir packages.db por %s." "$tmp"
        rm -f "$tmp" 2>/dev/null || :
        return 1
    fi

    return 0
}

# Registra instalação (substitui qualquer linha existente para name+category)
adm_pkg_db_register_install() {
    # args: NAME CATEGORY VERSION PROFILE LIBC REASON RUN_DEPS
    if [ $# -ne 7 ]; then
        adm_log_error "adm_pkg_db_register_install requer 7 argumentos."
        return 1
    fi
    local name="$1" category="$2" version="$3" profile="$4" libc="$5" reason="$6" run_deps="$7"
    local key="$category/$name"

    adm_pkg_db_init || return 1

    local line
    local out=""
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in
            \#*) out="${out}${line}"$'\n'; continue ;;
        esac

        IFS=$'\t' read -r d_name d_cat _rest <<<"$line"
        if [ "$d_name" = "$name" ] && [ "$d_cat" = "$category" ]; then
            # pula linha antiga (vai ser substituída)
            continue
        fi
        out="${out}${line}"$'\n'
    done <"$ADM_DEPS_DB_PATH"

    # Adiciona nova linha
    local status="installed"
    local newline
    newline="${name}\t${category}\t${version}\t${profile}\t${libc}\t${reason}\t${run_deps}\t${status}"
    out="${out}${newline}"$'\n'

    printf '%s' "$out" | adm_pkg_db_write_from_stdin || return 1
    adm_log_pkg "Registrado pacote instalado em packages.db: %s (versão=%s, profile=%s, libc=%s, reason=%s)" \
        "$key" "$version" "$profile" "$libc" "$reason"
    return 0
}

# Marca pacote como removido (status=removed). Mantém histórico simples.
adm_pkg_db_mark_removed() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_pkg_db_mark_removed requer 2 argumentos: NAME CATEGORY"
        return 1
    fi
    local name="$1" category="$2"
    local key="$category/$name"

    adm_pkg_db_init || return 1

    local line out="" found=0
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in
            \#*) out="${out}${line}"$'\n'; continue ;;
        esac
        IFS=$'\t' read -r d_name d_cat d_ver d_prof d_libc d_reason d_run_deps d_status <<<"$line"
        if [ "$d_name" = "$name" ] && [ "$d_cat" = "$category" ]; then
            # sobrescreve status para removed
            out="${out}${d_name}\t${d_cat}\t${d_ver}\t${d_prof}\t${d_libc}\t${d_reason}\t${d_run_deps}\tremoved"$'\n'
            found=1
        else
            out="${out}${line}"$'\n'
        fi
    done <"$ADM_DEPS_DB_PATH"

    if [ $found -eq 0 ]; then
        adm_log_warn "adm_pkg_db_mark_removed: pacote %s não estava registrado em packages.db." "$key"
        # Ainda assim, adiciona uma entrada de removed para histórico.
        out="${out}${name}\t${category}\t\t\t\tremoved\t\tremoved"$'\n'
    fi

    printf '%s' "$out" | adm_pkg_db_write_from_stdin || return 1
    adm_log_pkg "Marcado como removido em packages.db: %s" "$key"
    return 0
}

# Lista pacotes instalados (helper para CLI)
adm_pkg_list_installed() {
    adm_pkg_db_init || return 1
    local line name category version profile libc reason run_deps status
    printf "name\tcategory\tversion\tprofile\tlibc\treason\tstatus\n"
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in
            \#*) continue ;;
        esac
        IFS=$'\t' read -r name category version profile libc reason run_deps status <<<"$line"
        [ -z "$name" ] && continue
        [ -z "$status" ] && status="installed"
        [ "$status" != "installed" ] && continue
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$name" "$category" "$version" "$profile" "$libc" "$reason" "$status"
    done <"$ADM_DEPS_DB_PATH"
}

###############################################################################
# Manifest de arquivos (instalação / remoção)
###############################################################################

# Gera manifest a partir de um DESTDIR (lista de arquivos/links)
adm_pkg__generate_manifest_from_destdir() {
    if [ $# -ne 3 ]; then
        adm_log_error "adm_pkg__generate_manifest_from_destdir requer 3 argumentos: CATEGORIA PACOTE DESTDIR"
        return 1
    fi
    local category="$1" pkg="$2" destdir="$3"

    if [ ! -d "$destdir" ]; then
        adm_log_error "DESTDIR não existe para gerar manifest: %s" "$destdir"
        return 1
    fi

    local manifest
    manifest="$(adm_pkg__manifest_path "$category" "$pkg")" || return 1

    adm_mkdir_p "$(dirname "$manifest")" || return 1

    # Lista tudo (arquivos, dirs, links) como caminhos relativos, sem "./"
    # Usamos 'find' com -printf para ser robusto; se não suportar -printf, fallback para tar.
    if find "$destdir" -mindepth 1 -printf '%P\n' >/dev/null 2>&1; then
        if ! find "$destdir" -mindepth 1 -printf '%P\n' 2>/dev/null | sort >"$manifest"; then
            adm_log_error "Falha ao gerar manifest para %s/%s" "$category" "$pkg"
            return 1
        fi
    else
        # Fallback com tar
        ( cd "$destdir" && tar cf - . ) 2>/dev/null | tar tf - 2>/dev/null | sed 's@^\./@@' | sort >"$manifest" || {
            adm_log_error "Falha ao gerar manifest (fallback tar) para %s/%s" "$category" "$pkg"
            return 1
        }
    fi

    adm_log_pkg "Manifest gerado para %s/%s em: %s" "$category" "$pkg" "$manifest"
    return 0
}

# Copia DESTDIR para raiz de instalação preservando permissão/symlink
adm_pkg__install_destdir_into_root() {
    if [ $# -ne 3 ]; then
        adm_log_error "adm_pkg__install_destdir_into_root requer 3 argumentos: CATEGORIA PACOTE DESTDIR"
        return 1
    fi
    local category="$1" pkg="$2" destdir="$3"

    if [ ! -d "$destdir" ]; then
        adm_log_error "DESTDIR não existe para instalação: %s" "$destdir"
        return 1
    fi
    if [ ! -d "$ADM_INSTALL_ROOT" ]; then
        adm_log_error "ADM_INSTALL_ROOT não existe: %s" "$ADM_INSTALL_ROOT"
        return 1
    fi

    if ! adm_require_root; then
        return 1
    fi

    adm_log_pkg "Instalando %s/%s em raiz: %s" "$category" "$pkg" "$ADM_INSTALL_ROOT"

    # Copia via tar para preservar tudo (similar a 'make install DESTDIR=destdir')
    (
        cd "$destdir" || exit 1
        tar cf - . 2>/dev/null
    ) | (
        cd "$ADM_INSTALL_ROOT" || exit 1
        tar xpf - 2>/dev/null
    )

    local rc=$?
    if [ $rc -ne 0 ]; then
        adm_log_error "Falha ao instalar %s/%s em %s (rc=%d)" "$category" "$pkg" "$ADM_INSTALL_ROOT" "$rc"
        return $rc
    fi

    adm_log_pkg "Instalação de %s/%s concluída em %s" "$category" "$pkg" "$ADM_INSTALL_ROOT"
    return 0
}

# Remove arquivos listados no manifest
adm_pkg__remove_files_from_manifest() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_pkg__remove_files_from_manifest requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi
    local category="$1" pkg="$2"
    local manifest
    manifest="$(adm_pkg__manifest_path "$category" "$pkg")" || return 1

    if [ ! -f "$manifest" ]; then
        adm_log_warn "Manifest não encontrado para %s/%s: %s (remoção best-effort)" "$category" "$pkg" "$manifest"
        return 0
    fi

    if ! adm_require_root; then
        return 1
    fi

    adm_log_pkg "Removendo arquivos de %s/%s conforme manifest: %s" "$category" "$pkg" "$manifest"

    # 1) Remove arquivos (não diretórios)
    local rel full
    local -a dir_candidates=()
    while IFS= read -r rel || [ -n "$rel" ]; do
        rel="$(adm_pkg__trim "$rel")"
        [ -z "$rel" ] && continue

        # Ignora "." que às vezes aparece em tar
        [ "$rel" = "." ] && continue

        full="$ADM_INSTALL_ROOT/$rel"

        # Coleta diretório pai para limpeza posterior
        dir_candidates+=("$(dirname "$rel")")

        if [ -L "$full" ] || [ -f "$full" ]; then
            rm -f -- "$full" 2>/dev/null || adm_log_warn "Falha ao remover arquivo/symlink: %s" "$full"
        fi
    done <"$manifest"

    # 2) Tenta remover diretórios vazios (ordem do mais profundo para o mais raso)
    if [ "${#dir_candidates[@]}" -gt 0 ]; then
        # Remove duplicados e ordena por comprimento decrescente
        printf '%s\n' "${dir_candidates[@]}" | awk '!seen[$0]++' | \
        awk '{ print length, $0 }' | sort -rn | cut -d" " -f2- | while IFS= read -r d || [ -n "$d" ]; do
            [ -z "$d" ] && continue
            [ "$d" = "." ] && continue
            full="$ADM_INSTALL_ROOT/$d"
            if [ -d "$full" ]; then
                rmdir -- "$full" 2>/dev/null || adm_log_debug "Diretório não vazio ou não removido: %s" "$full"
            fi
        done
    fi

    # Não apagamos manifest automaticamente; pode ser útil para debugging.
    return 0
}

###############################################################################
# Instalação de pacotes
###############################################################################

# Instala um único pacote (sem resolver dependências)
# Uso: adm_pkg_install_single categoria pacote [reason]
# reason: explicit (default) | auto
adm_pkg_install_single() {
    if [ $# -lt 2 ] || [ $# -gt 3 ]; then
        adm_log_error "adm_pkg_install_single requer 2 ou 3 argumentos: CATEGORIA PACOTE [REASON]"
        return 1
    fi
    local category="$1" pkg="$2"
    local reason="${3:-explicit}"

    adm_pkg__validate_identifier "$category" || return 1
    adm_pkg__validate_identifier "$pkg"      || return 1

    local key; key="$(adm_pkg__pkg_key "$category" "$pkg")" || return 1

    if ! adm_require_root; then
        return 1
    fi

    adm_log_pkg "=== INSTALAÇÃO DE %s (reason=%s) ===" "$key" "$reason"

    # 1) Build (cria DESTDIR)
    if ! command -v adm_build_package >/dev/null 2>&1; then
        adm_log_error "adm_build_package não disponível; não é possível construir %s." "$key"
        return 1
    fi

    if ! adm_build_package "$category" "$pkg"; then
        adm_log_error "Build falhou para %s; instalação abortada." "$key"
        return 1
    fi

    # 2) Carrega metafile (de novo, para pegar infos)
    if ! adm_repo_load_metafile "$category" "$pkg" "ADM_META_"; then
        adm_log_error "Falha ao carregar metafile após build para %s." "$key"
        return 1
    fi

    # 3) Calcula DESTDIR do pacote
    local destdir="$ADM_DESTDIR_DIR/$category/$pkg"
    if [ ! -d "$destdir" ]; then
        adm_log_error "DESTDIR esperado não encontrado após build: %s" "$destdir"
        return 1
    fi

    # 4) Gera manifest
    adm_pkg__generate_manifest_from_destdir "$category" "$pkg" "$destdir" || return 1

    # 5) Instala arquivos em ADM_INSTALL_ROOT
    adm_pkg__install_destdir_into_root "$category" "$pkg" "$destdir" || return 1

    # 6) Registra em packages.db
    local version profile libc run_deps
    version="${ADM_META_version:-}"
    profile="${ADM_PROFILE_NAME:-default}"
    libc="${ADM_LIBC:-unknown}"

    # run_deps do metafile (pode ser vazio)
    run_deps="${ADM_META_run_deps:-}"

    adm_pkg_db_register_install "$pkg" "$category" "$version" "$profile" "$libc" "$reason" "$run_deps" || return 1

    adm_log_pkg "=== INSTALAÇÃO COMPLETA: %s ===" "$key"
    return 0
}

# Instala pacote + dependências (run_deps + build_deps como auto)
# Uso:
#   adm_pkg_install_with_deps categoria pacote
adm_pkg_install_with_deps() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_pkg_install_with_deps requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi
    local category="$1" pkg="$2"
    local key; key="$(adm_pkg__pkg_key "$category" "$pkg")" || return 1

    if ! command -v adm_deps_resolve_for_install >/dev/null 2>&1; then
        adm_log_warn "adm_deps_resolve_for_install ausente; instalando apenas %s sem deps." "$key"
        return adm_pkg_install_single "$category" "$pkg" "explicit"
    fi

    # Resolução inclui o pacote raiz por último.
    local spec="$key"
    local line dep_cat dep_pkg
    local -a order=()

    if ! while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        order+=("$line")
    done <<EOF
$(adm_deps_resolve_for_install "$spec" 0)
EOF
    then
        adm_log_error "Falha na resolução de dependências para %s." "$key"
        return 1
    fi

    if [ "${#order[@]}" -eq 0 ]; then
        adm_log_warn "Resolução de dependências retornou vazio para %s; instalando apenas o pacote alvo." "$key"
        return adm_pkg_install_single "$category" "$pkg" "explicit"
    fi

    adm_log_pkg "Ordem de instalação calculada para %s: %s" "$key" "${order[*]}"

    local last="${order[-1]}"

    # Instala todos, marcando o pacote raiz como explicit e os demais como auto
    local entry reason
    for entry in "${order[@]}"; do
        dep_cat="${entry%%/*}"
        dep_pkg="${entry##*/}"

        if [ "$entry" = "$last" ]; then
            reason="explicit"
        else
            reason="auto"
        fi

        adm_pkg_install_single "$dep_cat" "$dep_pkg" "$reason" || return 1
    done

    return 0
}

###############################################################################
# Desinstalação de pacotes
###############################################################################

# Desinstala um único pacote (não mexe em deps/órfãos)
adm_pkg_uninstall_single() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_pkg_uninstall_single requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi
    local category="$1" pkg="$2"
    local key; key="$(adm_pkg__pkg_key "$category" "$pkg")" || return 1

    if ! adm_require_root; then
        return 1
    fi

    adm_log_pkg "=== DESINSTALAÇÃO DE %s ===" "$key"

    # Hook de uninstall (repo/<category>/<pkg>/hooks/pre_uninstall)
    if command -v adm_repo_hooks_dir >/dev/null 2>&1; then
        local hooks_dir hook
        hooks_dir="$(adm_repo_hooks_dir "$category" "$pkg" 2>/dev/null)" || hooks_dir=""
        hook="$hooks_dir/pre_uninstall"
        if [ -x "$hook" ]; then
            adm_log_pkg "Executando hook pre_uninstall para %s" "$key"
            ( cd "$ADM_INSTALL_ROOT" && "$hook" ) || adm_log_warn "Hook pre_uninstall retornou erro para %s (continuando)." "$key"
        fi
    fi

    # Remove arquivos
    adm_pkg__remove_files_from_manifest "$category" "$pkg" || adm_log_warn "Problemas ao remover arquivos de %s." "$key"

    # Marca no packages.db
    adm_pkg_db_mark_removed "$pkg" "$category" || adm_log_warn "Não foi possível marcar %s como removido no DB." "$key"

    # Hook pós-uninstall
    if command -v adm_repo_hooks_dir >/dev/null 2>&1; then
        local hooks_dir2 hook2
        hooks_dir2="$(adm_repo_hooks_dir "$category" "$pkg" 2>/dev/null)" || hooks_dir2=""
        hook2="$hooks_dir2/post_uninstall"
        if [ -x "$hook2" ]; then
            adm_log_pkg "Executando hook post_uninstall para %s" "$key"
            ( cd "$ADM_INSTALL_ROOT" && "$hook2" ) || adm_log_warn "Hook post_uninstall retornou erro para %s (continuando)." "$key"
        fi
    fi

    adm_log_pkg "=== DESINSTALAÇÃO COMPLETA: %s ===" "$key"
    return 0
}

# Autoremove de órfãos (usa deps.sh -> adm_deps_list_orphans)
adm_pkg_autoremove_orphans() {
    if ! command -v adm_deps_list_orphans >/dev/null 2>&1; then
        adm_log_error "adm_deps_list_orphans não disponível; não é possível fazer autoremove."
        return 1
    fi

    adm_log_pkg "Procurando pacotes órfãos para autoremove..."

    local orphan
    local -a orphans=()

    while IFS= read -r orphan || [ -n "$orphan" ]; do
        [ -z "$orphan" ] && continue
        orphans+=("$orphan")
    done <<EOF
$(adm_deps_list_orphans)
EOF

    if [ "${#orphans[@]}" -eq 0 ]; then
        adm_log_pkg "Nenhum órfão encontrado."
        return 0
    fi

    adm_log_pkg "Órfãos detectados: %s" "${orphans[*]}"

    local entry category pkg
    for entry in "${orphans[@]}"; do
        category="${entry%%/*}"
        pkg="${entry##*/}"
        adm_pkg_uninstall_single "$category" "$pkg" || adm_log_warn "Falha ao remover órfão %s (continuando)." "$entry"
    done

    return 0
}

###############################################################################
# marcam pacotes como explicit/auto (sem instalar/desinstalar)
###############################################################################

adm_pkg_mark_reason() {
    if [ $# -ne 3 ]; then
        adm_log_error "adm_pkg_mark_reason requer 3 argumentos: CATEGORIA PACOTE REASON"
        return 1
    fi
    local category="$1" pkg="$2" reason="$3"

    case "$reason" in
        explicit|auto) ;;
        *)
            adm_log_error "REASON inválido em adm_pkg_mark_reason: %s (use explicit|auto)" "$reason"
            return 1
            ;;
    esac

    adm_pkg_db_init || return 1

    local line out="" found=0
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in
            \#*) out="${out}${line}"$'\n'; continue ;;
        esac
        IFS=$'\t' read -r d_name d_cat d_ver d_prof d_libc d_reason d_run_deps d_status <<<"$line"
        if [ "$d_name" = "$pkg" ] && [ "$d_cat" = "$category" ]; then
            out="${out}${d_name}\t${d_cat}\t${d_ver}\t${d_prof}\t${d_libc}\t${reason}\t${d_run_deps}\t${d_status}"$'\n'
            found=1
        else
            out="${out}${line}"$'\n'
        fi
    done <"$ADM_DEPS_DB_PATH"

    if [ $found -eq 0 ]; then
        adm_log_error "Não foi possível encontrar %s/%s em packages.db para remarcação." "$category" "$pkg"
        return 1
    fi

    printf '%s' "$out" | adm_pkg_db_write_from_stdin || return 1
    adm_log_pkg "Pacote %s/%s remarcado como '%s'." "$category" "$pkg" "$reason"
    return 0
}

###############################################################################
# Info simples
###############################################################################

adm_pkg_info() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_pkg_info requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi
    local category="$1" pkg="$2"

    adm_pkg_db_init || return 1

    local line name cat version profile libc reason run_deps status found=0
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in
            \#*) continue ;;
        esac
        IFS=$'\t' read -r name cat version profile libc reason run_deps status <<<"$line"
        [ -z "$name" ] && continue
        if [ "$name" = "$pkg" ] && [ "$cat" = "$category" ]; then
            found=1
            [ -z "$status" ] && status="installed"
            printf "name=%s\ncategory=%s\nversion=%s\nprofile=%s\nlibc=%s\nreason=%s\nrun_deps=%s\nstatus=%s\n" \
                "$name" "$cat" "$version" "$profile" "$libc" "$reason" "$run_deps" "$status"
        fi
    done <"$ADM_DEPS_DB_PATH"

    if [ $found -eq 0 ]; then
        adm_log_error "Pacote %s/%s não encontrado em packages.db." "$category" "$pkg"
        return 1
    fi
    return 0
}

###############################################################################
# Inicialização
###############################################################################

adm_pkg_init() {
    adm_pkg_db_init || adm_log_error "Falha ao inicializar packages.db."
    adm_log_debug "Subsistema de pacotes (pkg.sh) carregado. DB: %s" "$ADM_DEPS_DB_PATH"
}

adm_pkg_init
