#!/usr/bin/env bash
# db.sh – Banco de dados de pacotes do ADM
#
# Tudo fica em /usr/src/adm/db, nada em /var.
#
# Layout:
#   /usr/src/adm/db/
#     pkg/<nome>/
#       meta      → chave=valor
#       files     → lista de arquivos instalados (1 por linha)
#
# Campos do meta:
#   name=nome
#   version=1.2.3
#   category=apps|libs|sys|dev|x11|wayland
#   libc=glibc|musl
#   init=systemd|sysv|runit
#   profile=aggressive|normal|minimal
#   target=aarch64-linux-musl|native|...
#   reason=manual|auto          (instalação direta ou dependência)
#   install_date=YYYY-MM-DD HH:MM:SS
#   run_deps=dep1 dep2 ...
#   build_deps=depA depB ...
#   opt_deps=depX depY ...
#
# Funções principais:
#   adm_db_init
#   adm_db_register_install
#   adm_db_is_installed
#   adm_db_list_files
#   adm_db_remove_record
#   adm_db_mark_manual / adm_db_mark_auto
#   adm_db_list_installed
#   adm_db_list_orphans
#
# Este script NÃO usa set -e.

ADM_DB_ROOT="${ADM_DB_ROOT:-/usr/src/adm/db}"
ADM_DB_PKG_DIR="$ADM_DB_ROOT/pkg"

_DB_HAVE_UI=0

if declare -F adm_ui_log_info >/dev/null 2>&1; then
    _DB_HAVE_UI=1
fi

_db_log() {
    local lvl="$1"; shift || true
    local msg="$*"
    if [ "$_DB_HAVE_UI" -eq 1 ]; then
        case "$lvl" in
            INFO)  adm_ui_log_info  "$msg" ;;
            WARN)  adm_ui_log_warn  "$msg" ;;
            ERROR) adm_ui_log_error "$msg" ;;
            DEBUG) adm_ui_log_info  "[DEBUG] $msg" ;;
            *)     adm_ui_log_info  "$msg" ;;
        esac
    else
        printf 'db[%s]: %s\n' "$lvl" "$msg" >&2
    fi
}

_db_fail() {
    _db_log ERROR "$*"
    return 1
}

_db_trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# -----------------------------
# Inicialização e sanity check
# -----------------------------
adm_db_init() {
    if ! mkdir -p "$ADM_DB_PKG_DIR" 2>/dev/null; then
        _db_fail "Não foi possível criar diretório de DB: $ADM_DB_PKG_DIR"
        return 1
    fi
    if [ ! -w "$ADM_DB_PKG_DIR" ]; then
        _db_fail "Diretório de DB não é gravável: $ADM_DB_PKG_DIR"
        return 1
    fi
    _db_log INFO "db.sh inicializado (root=$ADM_DB_ROOT)"
    return 0
}

# -----------------------------
# Caminhos de meta/files
# -----------------------------
_adm_db_pkg_dir() {
    local pkg="$1"
    printf '%s/%s\n' "$ADM_DB_PKG_DIR" "$pkg"
}

_adm_db_meta_file() {
    local pkg="$1"
    printf '%s/meta\n' "$(_adm_db_pkg_dir "$pkg")"
}

_adm_db_files_file() {
    local pkg="$1"
    printf '%s/files\n' "$(_adm_db_pkg_dir "$pkg")"
}

# -----------------------------
# Verificar se pacote está instalado
# -----------------------------
adm_db_is_installed() {
    local pkg="${1##*/}"

    if [ -z "$pkg" ]; then
        _db_fail "adm_db_is_installed: nome de pacote vazio"
        return 1
    fi

    local meta="$(_adm_db_meta_file "$pkg")"
    if [ -f "$meta" ]; then
        return 0
    fi
    return 1
}

# -----------------------------
# Ler meta de um pacote
# -----------------------------
# Variáveis globais de leitura (para uso interno ou externo):
DB_META_NAME=""
DB_META_VERSION=""
DB_META_CATEGORY=""
DB_META_LIBC=""
DB_META_INIT=""
DB_META_PROFILE=""
DB_META_TARGET=""
DB_META_REASON=""
DB_META_INSTALL_DATE=""
DB_META_RUN_DEPS=""
DB_META_BUILD_DEPS=""
DB_META_OPT_DEPS=""

_adm_db_reset_meta_vars() {
    DB_META_NAME=""
    DB_META_VERSION=""
    DB_META_CATEGORY=""
    DB_META_LIBC=""
    DB_META_INIT=""
    DB_META_PROFILE=""
    DB_META_TARGET=""
    DB_META_REASON=""
    DB_META_INSTALL_DATE=""
    DB_META_RUN_DEPS=""
    DB_META_BUILD_DEPS=""
    DB_META_OPT_DEPS=""
}

adm_db_read_meta() {
    # Uso:
    #   adm_db_read_meta pkg
    # Em sucesso, popula DB_META_* e retorna 0
    local pkg="${1##*/}"
    local meta="$(_adm_db_meta_file "$pkg")"

    _adm_db_reset_meta_vars

    if [ ! -f "$meta" ]; then
        _db_fail "adm_db_read_meta: meta não encontrado para pacote '$pkg'"
        return 1
    fi
    if [ ! -r "$meta" ]; then
        _db_fail "adm_db_read_meta: meta não legível: $meta"
        return 1
    fi

    local line lineno=0
    local key val

    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        line="$(_db_trim "$line")"

        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue

        case "$line" in
            *=*) ;;
            *)
                _db_fail "Linha inválida no meta ($meta:$lineno): '$line'"
                return 1
                ;;
        esac

        key="${line%%=*}"
        val="${line#*=}"
        key="$(_db_trim "$key")"
        val="$(_db_trim "$val")"

        case "$key" in
            name)         DB_META_NAME="$val" ;;
            version)      DB_META_VERSION="$val" ;;
            category)     DB_META_CATEGORY="$val" ;;
            libc)         DB_META_LIBC="$val" ;;
            init)         DB_META_INIT="$val" ;;
            profile)      DB_META_PROFILE="$val" ;;
            target)       DB_META_TARGET="$val" ;;
            reason)       DB_META_REASON="$val" ;;
            install_date) DB_META_INSTALL_DATE="$val" ;;
            run_deps)     DB_META_RUN_DEPS="$val" ;;
            build_deps)   DB_META_BUILD_DEPS="$val" ;;
            opt_deps)     DB_META_OPT_DEPS="$val" ;;
            *)
                _db_log WARN "Chave desconhecida em meta ($meta:$lineno): '$key' (ignorada)"
                ;;
        esac
    done < "$meta"

    # validações mínimas
    local ok=0
    [ -z "$DB_META_NAME" ]    && _db_log ERROR "meta '$meta' sem campo 'name'"         && ok=1
    [ -z "$DB_META_VERSION" ] && _db_log ERROR "meta '$meta' sem campo 'version'"      && ok=1
    [ -z "$DB_META_CATEGORY" ]&& _db_log ERROR "meta '$meta' sem campo 'category'"     && ok=1
    [ -z "$DB_META_REASON" ]  && _db_log ERROR "meta '$meta' sem campo 'reason'"       && ok=1

    if [ "$ok" -ne 0 ]; then
        return 1
    fi

    return 0
}

# -----------------------------
# Escrever meta de um pacote
# -----------------------------
_adm_db_write_meta() {
    # Usa DB_META_* atuais
    local pkg="$1"
    local dir="$(_adm_db_pkg_dir "$pkg")"
    local meta="$(_adm_db_meta_file "$pkg")"

    if ! mkdir -p "$dir" 2>/dev/null; then
        _db_fail "Não foi possível criar diretório de pacote no DB: $dir"
        return 1
    fi

    local tmp="${meta}.tmp.$$"

    {
        printf 'name=%s\n'         "$DB_META_NAME"
        printf 'version=%s\n'      "$DB_META_VERSION"
        printf 'category=%s\n'     "$DB_META_CATEGORY"
        printf 'libc=%s\n'         "$DB_META_LIBC"
        printf 'init=%s\n'         "$DB_META_INIT"
        printf 'profile=%s\n'      "$DB_META_PROFILE"
        printf 'target=%s\n'       "$DB_META_TARGET"
        printf 'reason=%s\n'       "$DB_META_REASON"
        printf 'install_date=%s\n' "$DB_META_INSTALL_DATE"
        printf 'run_deps=%s\n'     "$DB_META_RUN_DEPS"
        printf 'build_deps=%s\n'   "$DB_META_BUILD_DEPS"
        printf 'opt_deps=%s\n'     "$DB_META_OPT_DEPS"
    } > "$tmp" 2>/dev/null || {
        _db_fail "Falha ao escrever meta temporário: $tmp"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }

    if ! mv -f "$tmp" "$meta" 2>/dev/null; then
        _db_fail "Falha ao mover meta temporário para destino: $meta"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi

    return 0
}

# -----------------------------
# Escrever lista de arquivos
# -----------------------------
_adm_db_write_files() {
    # Uso:
    #   _adm_db_write_files pkg "arquivo1\narquivo2\n..."
    local pkg="$1"; shift || true
    local content="$*"

    local dir="$(_adm_db_pkg_dir "$pkg")"
    local files="$(_adm_db_files_file "$pkg")"

    if ! mkdir -p "$dir" 2>/dev/null; then
        _db_fail "Não foi possível criar diretório de pacote no DB: $dir"
        return 1
    fi

    local tmp="${files}.tmp.$$"

    # Sobrescreve lista de arquivos
    printf '%s\n' "$content" > "$tmp" 2>/dev/null || {
        _db_fail "Falha ao escrever files temporário: $tmp"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }

    if ! mv -f "$tmp" "$files" 2>/dev/null; then
        _db_fail "Falha ao mover files temporário para destino: $files"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi

    return 0
}
# -----------------------------
# Registrar instalação de pacote
# -----------------------------
adm_db_register_install() {
    # Uso:
    #   adm_db_register_install \
    #       nome versão categoria libc init profile target reason \
    #       "run_deps..." "build_deps..." "opt_deps..." \
    #       "lista_de_arquivos_separados_por_\n"
    #
    # Exemplo:
    #   adm_db_register_install \
    #       bash 5.2.21 apps glibc systemd normal native manual \
    #       "readline ncurses" "gcc make" "" \
    #       "/bin/bash\n/usr/share/doc/bash/..."
    #
    local name="$1"
    local version="$2"
    local category="$3"
    local libc="$4"
    local init="$5"
    local profile="$6"
    local target="$7"
    local reason="$8"
    local run_deps="$9"
    shift 9 || true
    local build_deps="$1"
    shift || true
    local opt_deps="$1"
    shift || true
    local files_list="$*"

    if [ -z "$name" ] || [ -z "$version" ] || [ -z "$category" ]; then
        _db_fail "adm_db_register_install: name, version e category são obrigatórios"
        return 1
    fi

    if [ -z "$reason" ]; then
        reason="manual"
    fi

    adm_db_init || return 1

    _adm_db_reset_meta_vars
    DB_META_NAME="$name"
    DB_META_VERSION="$version"
    DB_META_CATEGORY="$category"
    DB_META_LIBC="$libc"
    DB_META_INIT="$init"
    DB_META_PROFILE="$profile"
    DB_META_TARGET="${target:-native}"
    DB_META_REASON="$reason"
    DB_META_INSTALL_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
    DB_META_RUN_DEPS="$(_db_trim "$run_deps")"
    DB_META_BUILD_DEPS="$(_db_trim "$build_deps")"
    DB_META_OPT_DEPS="$(_db_trim "$opt_deps")"

    if ! _adm_db_write_meta "$name"; then
        _db_fail "Falha ao gravar meta no DB para '$name'"
        return 1
    fi

    if ! _adm_db_write_files "$name" "$files_list"; then
        _db_fail "Falha ao gravar lista de arquivos no DB para '$name'"
        return 1
    fi

    _db_log INFO "Registro de instalação salvo no DB: $name-$version (reason=$reason)"
    return 0
}

# -----------------------------
# Listar arquivos de um pacote
# -----------------------------
adm_db_list_files() {
    local pkg="${1##*/}"
    local files="$(_adm_db_files_file "$pkg")"

    if [ ! -f "$files" ]; then
        _db_fail "Lista de arquivos não encontrada para pacote '$pkg'"
        return 1
    fi

    cat "$files"
    return 0
}

# -----------------------------
# Remover registro de pacote (não remove arquivos do sistema)
# -----------------------------
adm_db_remove_record() {
    local pkg="${1##*/}"
    local dir="$(_adm_db_pkg_dir "$pkg")"

    if ! adm_db_is_installed "$pkg"; then
        _db_fail "adm_db_remove_record: pacote '$pkg' não está registrado"
        return 1
    fi

    if ! rm -rf "$dir" 2>/dev/null; then
        _db_fail "Falha ao remover diretório de DB para '$pkg': $dir"
        return 1
    fi

    _db_log INFO "Registro de DB removido para pacote '$pkg'"
    return 0
}

# -----------------------------
# Marcar pacote como manual/auto
# -----------------------------
_adm_db_set_reason() {
    local pkg="${1##*/}"
    local new_reason="$1"

    local meta="$(_adm_db_meta_file "$pkg")"
    if ! adm_db_read_meta "$pkg"; then
        return 1
    fi

    DB_META_REASON="$new_reason"
    if ! _adm_db_write_meta "$pkg"; then
        _db_fail "Falha ao atualizar reason para '$pkg'"
        return 1
    fi
    _db_log INFO "Pacote '$pkg' marcado como '$new_reason'"
    return 0
}

adm_db_mark_manual() {
    local pkg="$1"
    _adm_db_set_reason "$pkg" "manual"
}

adm_db_mark_auto() {
    local pkg="$1"
    _adm_db_set_reason "$pkg" "auto"
}

# -----------------------------
# Listar todos os pacotes instalados
# -----------------------------
adm_db_list_installed() {
    adm_db_init || return 1

    local d pkg
    shopt -s nullglob
    for d in "$ADM_DB_PKG_DIR"/*; do
        [ -d "$d" ] || continue
        pkg="${d##*/}"
        printf '%s\n' "$pkg"
    done
    shopt -u nullglob
    return 0
}

# -----------------------------
# Construir mapa de dependentes (reverse deps)
# -----------------------------
_adm_db_build_reverse_deps() {
    # Usa adm_db_read_meta em todos os pacotes e constrói:
    #   _DB_REVERSE[dep] = "pkg1 pkg2 ..."
    declare -gA _DB_REVERSE
    _DB_REVERSE=()

    local d pkg
    shopt -s nullglob
    for d in "$ADM_DB_PKG_DIR"/*; do
        [ -d "$d" ] || continue
        pkg="${d##*/}"
        if ! adm_db_read_meta "$pkg"; then
            _db_log ERROR "Ignorando pacote '$pkg' por meta inválido"
            continue
        fi

        local deps_all=""
        [ -n "$DB_META_RUN_DEPS" ]   && deps_all="$deps_all $DB_META_RUN_DEPS"
        [ -n "$DB_META_BUILD_DEPS" ] && deps_all="$deps_all $DB_META_BUILD_DEPS"
        [ -n "$DB_META_OPT_DEPS" ]   && deps_all="$deps_all $DB_META_OPT_DEPS"

        deps_all="$(_db_trim "$deps_all")"
        local dep
        for dep in $deps_all; do
            # adiciona pkg em _DB_REVERSE[dep]
            if [ -z "${_DB_REVERSE[$dep]:-}" ]; then
                _DB_REVERSE["$dep"]="$pkg"
            else
                _DB_REVERSE["$dep"]="${_DB_REVERSE[$dep]} $pkg"
            fi
        done
    done
    shopt -u nullglob

    return 0
}

# -----------------------------
# Listar órfãos (auto + sem dependentes)
# -----------------------------
adm_db_list_orphans() {
    adm_db_init || return 1
    _adm_db_build_reverse_deps || return 1

    local d pkg
    local orphans=()

    shopt -s nullglob
    for d in "$ADM_DB_PKG_DIR"/*; do
        [ -d "$d" ] || continue
        pkg="${d##*/}"

        if ! adm_db_read_meta "$pkg"; then
            _db_log ERROR "Ignorando pacote '$pkg' ao calcular órfãos (meta inválido)"
            continue
        fi

        # só consideramos auto
        if [ "$DB_META_REASON" != "auto" ]; then
            continue
        fi

        # tem alguém que dependa dele?
        if [ -n "${_DB_REVERSE[$pkg]:-}" ]; then
            continue
        fi

        orphans+=("$pkg")
    done
    shopt -u nullglob

    local o
    for o in "${orphans[@]}"; do
        printf '%s\n' "$o"
    done

    _db_log INFO "Encontrados ${#orphans[@]} órfãos (reason=auto, sem dependentes)"
    return 0
}

# -----------------------------
# Debug / inspeção
# -----------------------------
adm_db_debug_dump_pkg() {
    local pkg="$1"
    if ! adm_db_read_meta "$pkg"; then
        return 1
    fi

    echo "== META para '$pkg' =="
    printf 'name=%s\n'         "$DB_META_NAME"
    printf 'version=%s\n'      "$DB_META_VERSION"
    printf 'category=%s\n'     "$DB_META_CATEGORY"
    printf 'libc=%s\n'         "$DB_META_LIBC"
    printf 'init=%s\n'         "$DB_META_INIT"
    printf 'profile=%s\n'      "$DB_META_PROFILE"
    printf 'target=%s\n'       "$DB_META_TARGET"
    printf 'reason=%s\n'       "$DB_META_REASON"
    printf 'install_date=%s\n' "$DB_META_INSTALL_DATE"
    printf 'run_deps=%s\n'     "$DB_META_RUN_DEPS"
    printf 'build_deps=%s\n'   "$DB_META_BUILD_DEPS"
    printf 'opt_deps=%s\n'     "$DB_META_OPT_DEPS"

    echo
    echo "== FILES =="
    adm_db_list_files "$pkg" || return 1
}

# -----------------------------
# Modo de teste direto
# -----------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Teste simples:
    #   ./db.sh test               → mostra ajuda
    #   ./db.sh list               → lista instalados
    #   ./db.sh debug bash         → dump de um pacote
    #   ./db.sh orphans            → lista órfãos
    cmd="${1:-help}"
    shift || true

    case "$cmd" in
        help)
            cat << 'EOF'
Uso:
  db.sh list
  db.sh debug <pkg>
  db.sh orphans
EOF
            ;;
        list)
            adm_db_list_installed
            ;;
        debug)
            if [ -z "$1" ]; then
                echo "Uso: db.sh debug <pkg>" >&2
                exit 1
            fi
            adm_db_debug_dump_pkg "$1" || exit 1
            ;;
        orphans)
            adm_db_list_orphans || exit 1
            ;;
        *)
            echo "Comando desconhecido: $cmd" >&2
            exit 1
            ;;
    esac
fi
