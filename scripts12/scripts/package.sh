#!/usr/bin/env bash
# package.sh – Sistema de pacotes binários EXTREMO do ADM
#
# Formato de pacote ADM:
#   <name>-<version>-<release>-<arch>.pkg
#
# Interno (.pkg é tar.zst):
#   CONTROL/manifest    -> metadados (similar ao db.sh meta)
#   CONTROL/files       -> lista de arquivos (relativos, sem / inicial)
#   usr/..., etc        -> árvore de arquivos do sistema (sem / inicial)
#
# Diretório de pacotes:
#   /usr/src/adm/packages/<name>/<name>-<version>-<release>-<arch>.pkg
#
# Funções principais:
#   adm_pkg_from_destdir      -> empacota DESTDIR de um build ADM em .pkg, registra e (opcional) só gera ou já instala
#   adm_pkg_install_file      -> instala .pkg em / com registro no db
#   adm_pkg_repack_deb        -> reempacota .deb em .pkg + registra + instala
#   adm_pkg_repack_rpm        -> reempacota .rpm em .pkg + registra + instala
#
# Este script NÃO usa set -e.

ADM_ROOT="/usr/src/adm"
ADM_PKG_ROOT="$ADM_ROOT/packages"

# release padrão para pacotes criados a partir de DESTDIR
ADM_PKG_DEFAULT_RELEASE="${ADM_PKG_DEFAULT_RELEASE:-1}"

# se 1, adm_pkg_from_destdir só gera o pacote, não instala
ADM_PKG_BUILD_ONLY="${ADM_PKG_BUILD_ONLY:-0}"

_PKG_HAVE_UI=0
_PKG_HAVE_DB=0

if declare -F adm_ui_log_info >/dev/null 2>&1; then
    _PKG_HAVE_UI=1
fi

if declare -F adm_db_init >/dev/null 2>&1; then
    _PKG_HAVE_DB=1
fi

_pkg_log() {
    local lvl="$1"; shift || true
    local msg="$*"
    if [ "$_PKG_HAVE_UI" -eq 1 ]; then
        case "$lvl" in
            INFO)  adm_ui_log_info  "$msg" ;;
            WARN)  adm_ui_log_warn  "$msg" ;;
            ERROR) adm_ui_log_error "$msg" ;;
            DEBUG) adm_ui_log_info  "[DEBUG] $msg" ;;
            *)     adm_ui_log_info  "$msg" ;;
        esac
    else
        printf 'package[%s]: %s\n' "$lvl" "$msg" >&2
    fi
}

_pkg_fail() {
    _pkg_log ERROR "$*"
    return 1
}

_pkg_trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# --------------------------------
# Garantir db.sh e metafile.sh
# --------------------------------
_pkg_ensure_db() {
    if [ "$_PKG_HAVE_DB" -eq 1 ]; then
        return 0
    fi
    local f="$ADM_ROOT/scripts/db.sh"
    if [ -r "$f" ]; then
        # shellcheck source=/usr/src/adm/scripts/db.sh
        . "$f" || _pkg_fail "Falha ao carregar $f"
        _PKG_HAVE_DB=1
        return $?
    fi
    _pkg_fail "db.sh não encontrado em $f"
}

_pkg_ensure_metafile() {
    if declare -F adm_meta_load >/dev/null 2>&1; then
        return 0
    fi
    local f="$ADM_ROOT/scripts/metafile.sh"
    if [ -r "$f" ]; then
        # shellcheck source=/usr/src/adm/scripts/metafile.sh
        . "$f" || _pkg_fail "Falha ao carregar $f"
        return $?
    fi
    _pkg_fail "metafile.sh não encontrado em $f"
}

# --------------------------------
# Checar ferramentas: tar/zstd e reempacotadores
# --------------------------------
_pkg_have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

_pkg_check_tar_zstd() {
    if ! _pkg_have_cmd tar; then
        _pkg_fail "tar não encontrado; necessário para criar/extrair .pkg"
        return 1
    fi
    if ! _pkg_have_cmd zstd; then
        _pkg_fail "zstd não encontrado; necessário para criar/extrair .pkg (tar.zst)"
        return 1
    fi
    return 0
}

# --------------------------------
# Helpers de tar.zst
# --------------------------------
_pkg_tar_create_zst() {
    # Uso:
    #   _pkg_tar_create_zst OUTFILE STAGE_DIR DESTDIR
    #
    # Cria OUTFILE com:
    #   CONTROL/* (a partir de STAGE_DIR)
    #   árvore do DESTDIR (.)
    local outfile="$1"
    local stage="$2"
    local destdir="$3"

    _pkg_check_tar_zstd || return 1

    if [ ! -d "$stage/CONTROL" ]; then
        _pkg_fail "_pkg_tar_create_zst: diretório CONTROL ausente em $stage"
        return 1
    fi

    if [ ! -d "$destdir" ]; then
        _pkg_fail "_pkg_tar_create_zst: destdir não existe: $destdir"
        return 1
    fi

    local tmp="${outfile}.tmp.$$"

    # Tar com múltiplos -C: CONTROL e arquivos de destdir (.)
    (
        cd "$stage" && tar -cf - CONTROL
        cd "$destdir" && tar -rf - .
    ) 2>/dev/null | zstd -q -19 -o "$tmp" || {
        _pkg_fail "Falha ao criar tar.zst temporário em $tmp"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }

    if ! mv -f "$tmp" "$outfile" 2>/dev/null; then
        _pkg_fail "Não foi possível mover pacote temporário para $outfile"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    return 0
}

_pkg_tar_extract_to_dir() {
    # Uso:
    #   _pkg_tar_extract_to_dir PKG_FILE DEST_DIR
    local pkg="$1"
    local dest="$2"

    _pkg_check_tar_zstd || return 1

    if [ ! -f "$pkg" ]; then
        _pkg_fail "_pkg_tar_extract_to_dir: arquivo .pkg não encontrado: $pkg"
        return 1
    fi

    if ! mkdir -p "$dest" 2>/dev/null; then
        _pkg_fail "Não foi possível criar diretório de extração: $dest"
        return 1
    fi

    if ! zstd -d -q -c "$pkg" | tar -C "$dest" -xf - 2>/dev/null; then
        _pkg_fail "Falha ao extrair pacote $pkg para $dest"
        return 1
    fi

    return 0
}

# --------------------------------
# Nome do arquivo de pacote
# --------------------------------
_pkg_arch_normalize() {
    local arch="$1"
    case "$arch" in
        amd64)  echo "x86_64" ;;
        x86_64) echo "x86_64" ;;
        i386)   echo "i686" ;;
        arm64)  echo "aarch64" ;;
        aarch64)echo "aarch64" ;;
        *)      echo "$arch" ;;
    esac
}

_pkg_detect_arch() {
    # Melhor esforço: se não passar arch, usamos uname -m
    local a
    a="$(uname -m 2>/dev/null || echo unknown)"
    _pkg_arch_normalize "$a"
}

_pkg_package_filename() {
    # Uso:
    #   _pkg_package_filename name version release arch
    local name="$1"
    local version="$2"
    local release="$3"
    local arch="$4"
    printf '%s-%s-%s-%s.pkg\n' "$name" "$version" "$release" "$arch"
}

_pkg_package_path() {
    # Uso:
    #   _pkg_package_path name version release arch
    local name="$1"
    local version="$2"
    local release="$3"
    local arch="$4"

    local file; file="$(_pkg_package_filename "$name" "$version" "$release" "$arch")"
    printf '%s/%s/%s\n' "$ADM_PKG_ROOT" "$name" "$file"
}

# --------------------------------
# Gerar CONTROL/files a partir de DESTDIR
# --------------------------------
_pkg_generate_files_list() {
    # Uso:
    #   _pkg_generate_files_list DESTDIR OUTPUT_FILE
    # Gera lista de arquivos relativos (sem / inicial) em OUTPUT_FILE
    local destdir="$1"
    local outfile="$2"

    if [ ! -d "$destdir" ]; then
        _pkg_fail "_pkg_generate_files_list: DESTDIR não existe: $destdir"
        return 1
    fi

    local tmp="${outfile}.tmp.$$"

    (
        cd "$destdir" || exit 1
        # arquivos e links, ignorando dirs
        find . -mindepth 1 -type f -o -type l | sed 's|^\./||'
    ) > "$tmp" 2>/dev/null || {
        _pkg_fail "Falha ao gerar lista de arquivos temporária em $tmp"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }

    if ! mv -f "$tmp" "$outfile" 2>/dev/null; then
        _pkg_fail "Falha ao mover lista de arquivos para $outfile"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi

    return 0
}

# --------------------------------
# Gerar CONTROL/manifest a partir de metafile + parâmetros
# --------------------------------
_pkg_generate_manifest_from_meta() {
    # Uso:
    #   _pkg_generate_manifest_from_meta RELEASE ARCH DESTFILE
    #
    # Requer:
    #   MF_NAME, MF_VERSION, MF_CATEGORY, MF_RUN_DEPS, MF_BUILD_DEPS, MF_OPT_DEPS
    #
    local release="$1"
    local arch="$2"
    local dest="$3"

    _pkg_ensure_metafile || return 1

    if [ -z "${MF_NAME:-}" ] || [ -z "${MF_VERSION:-}" ]; then
        _pkg_fail "_pkg_generate_manifest_from_meta: MF_NAME/MF_VERSION vazios; metafile não carregado?"
        return 1
    fi

    local libc="${ADM_BUILD_LIBC:-glibc}"
    local init="${ADM_BUILD_INIT:-sysv}"
    local profile="${ADM_BUILD_PROFILE:-normal}"
    local target="${ADM_CURRENT_TARGET:-native}"
    local reason="manual"

    local run_deps="$(_pkg_trim "${MF_RUN_DEPS:-}")"
    local build_deps="$(_pkg_trim "${MF_BUILD_DEPS:-}")"
    local opt_deps="$(_pkg_trim "${MF_OPT_DEPS:-}")"
    local category="$(_pkg_trim "${MF_CATEGORY:-apps}")"

    local tmp="${dest}.tmp.$$"

    {
        printf 'name=%s\n'         "$MF_NAME"
        printf 'version=%s\n'      "$MF_VERSION"
        printf 'release=%s\n'      "$release"
        printf 'arch=%s\n'         "$arch"
        printf 'category=%s\n'     "$category"
        printf 'libc=%s\n'         "$libc"
        printf 'init=%s\n'         "$init"
        printf 'profile=%s\n'      "$profile"
        printf 'target=%s\n'       "$target"
        printf 'reason=%s\n'       "$reason"
        printf 'install_date=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'run_deps=%s\n'     "$run_deps"
        printf 'build_deps=%s\n'   "$build_deps"
        printf 'opt_deps=%s\n'     "$opt_deps"
        printf 'source_origin=%s\n' "adm-build"
    } > "$tmp" 2>/dev/null || {
        _pkg_fail "Falha ao escrever manifest temporário em $tmp"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }

    if ! mv -f "$tmp" "$dest" 2>/dev/null; then
        _pkg_fail "Falha ao mover manifest para $dest"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi

    return 0
}

# --------------------------------
# Ler CONTROL/manifest de um pacote extraído
# --------------------------------
PKG_MAN_NAME=""
PKG_MAN_VERSION=""
PKG_MAN_RELEASE=""
PKG_MAN_ARCH=""
PKG_MAN_CATEGORY=""
PKG_MAN_LIBC=""
PKG_MAN_INIT=""
PKG_MAN_PROFILE=""
PKG_MAN_TARGET=""
PKG_MAN_REASON=""
PKG_MAN_INSTALL_DATE=""
PKG_MAN_RUN_DEPS=""
PKG_MAN_BUILD_DEPS=""
PKG_MAN_OPT_DEPS=""
PKG_MAN_SOURCE_ORIGIN=""

_pkg_reset_manifest_vars() {
    PKG_MAN_NAME=""
    PKG_MAN_VERSION=""
    PKG_MAN_RELEASE=""
    PKG_MAN_ARCH=""
    PKG_MAN_CATEGORY=""
    PKG_MAN_LIBC=""
    PKG_MAN_INIT=""
    PKG_MAN_PROFILE=""
    PKG_MAN_TARGET=""
    PKG_MAN_REASON=""
    PKG_MAN_INSTALL_DATE=""
    PKG_MAN_RUN_DEPS=""
    PKG_MAN_BUILD_DEPS=""
    PKG_MAN_OPT_DEPS=""
    PKG_MAN_SOURCE_ORIGIN=""
}

_pkg_read_manifest_file() {
    # Uso:
    #   _pkg_read_manifest_file DIR
    # onde DIR contém CONTROL/manifest
    local dir="$1"
    local man="$dir/CONTROL/manifest"

    _pkg_reset_manifest_vars

    if [ ! -f "$man" ]; then
        _pkg_fail "Manifest não encontrado em $man"
        return 1
    fi

    if [ ! -r "$man" ]; then
        _pkg_fail "Manifest não legível: $man"
        return 1
    fi

    local line lineno=0 key val
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        line="$(_pkg_trim "$line")"
        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue
        case "$line" in
            *=*) ;;
            *) _pkg_fail "Linha inválida em manifest ($man:$lineno): '$line'"; return 1 ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        key="$(_pkg_trim "$key")"
        val="$(_pkg_trim "$val")"
        case "$key" in
            name)          PKG_MAN_NAME="$val" ;;
            version)       PKG_MAN_VERSION="$val" ;;
            release)       PKG_MAN_RELEASE="$val" ;;
            arch)          PKG_MAN_ARCH="$val" ;;
            category)      PKG_MAN_CATEGORY="$val" ;;
            libc)          PKG_MAN_LIBC="$val" ;;
            init)          PKG_MAN_INIT="$val" ;;
            profile)       PKG_MAN_PROFILE="$val" ;;
            target)        PKG_MAN_TARGET="$val" ;;
            reason)        PKG_MAN_REASON="$val" ;;
            install_date)  PKG_MAN_INSTALL_DATE="$val" ;;
            run_deps)      PKG_MAN_RUN_DEPS="$val" ;;
            build_deps)    PKG_MAN_BUILD_DEPS="$val" ;;
            opt_deps)      PKG_MAN_OPT_DEPS="$val" ;;
            source_origin) PKG_MAN_SOURCE_ORIGIN="$val" ;;
            *)
                _pkg_log WARN "Chave desconhecida em manifest ($key) ignorada"
                ;;
        esac
    done < "$man"

    [ -z "$PKG_MAN_NAME" ]    && _pkg_fail "Manifest sem 'name'"    && return 1
    [ -z "$PKG_MAN_VERSION" ] && _pkg_fail "Manifest sem 'version'" && return 1
    [ -z "$PKG_MAN_RELEASE" ] && _pkg_log WARN "Manifest sem 'release'; assumindo 1" && PKG_MAN_RELEASE="1"
    [ -z "$PKG_MAN_ARCH" ]    && _pkg_log WARN "Manifest sem 'arch'; será preenchido a partir do sistema"

    return 0
}

# --------------------------------
# Empacotar DESTDIR em .pkg (sem instalar)
# --------------------------------
_pkg_create_pkg_from_destdir() {
    # Uso interno:
    #   _pkg_create_pkg_from_destdir DESTDIR RELEASE ARCH OUTFILE
    local destdir="$1"
    local release="$2"
    local arch="$3"
    local outfile="$4"

    _pkg_ensure_metafile || return 1

    if [ ! -d "$destdir" ]; then
        _pkg_fail "_pkg_create_pkg_from_destdir: destdir não existe: $destdir"
        return 1
    fi

    if [ -z "${MF_NAME:-}" ] || [ -z "${MF_VERSION:-}" ]; then
        _pkg_fail "_pkg_create_pkg_from_destdir: MF_NAME/MF_VERSION vazios; metafile não carregado"
        return 1
    fi

    mkdir -p "$ADM_PKG_ROOT/${MF_NAME}" 2>/dev/null || {
        _pkg_fail "Não foi possível criar diretório de pacotes: $ADM_PKG_ROOT/${MF_NAME}"
        return 1
    }

    local stage
    stage="$(mktemp -d "$ADM_ROOT/build/.pkgstage.XXXXXX" 2>/dev/null)" || {
        _pkg_fail "Não foi possível criar diretório temporário de stage"
        return 1
    }

    mkdir -p "$stage/CONTROL" 2>/dev/null || {
        _pkg_fail "Não foi possível criar $stage/CONTROL"
        rm -rf "$stage" 2>/dev/null || true
        return 1
    }

    # Gerar manifest e files
    if ! _pkg_generate_manifest_from_meta "$release" "$arch" "$stage/CONTROL/manifest"; then
        rm -rf "$stage" 2>/dev/null || true
        return 1
    fi

    if ! _pkg_generate_files_list "$destdir" "$stage/CONTROL/files"; then
        rm -rf "$stage" 2>/dev/null || true
        return 1
    fi

    # Criar tar.zst
    if ! _pkg_tar_create_zst "$outfile" "$stage" "$destdir"; then
        rm -rf "$stage" 2>/dev/null || true
        return 1
    fi

    rm -rf "$stage" 2>/dev/null || true

    _pkg_log INFO "Pacote criado: $outfile"
    return 0
}
# --------------------------------
# Instalar .pkg em / e registrar no DB
# --------------------------------
adm_pkg_install_file() {
    # Uso:
    #   adm_pkg_install_file /usr/src/adm/packages/bash/bash-5.2.21-1-x86_64.pkg
    local pkgfile="$1"

    _pkg_ensure_db || return 1
    _pkg_check_tar_zstd || return 1
    adm_db_init || return 1

    if [ -z "$pkgfile" ]; then
        _pkg_fail "adm_pkg_install_file: caminho do .pkg não informado"
        return 1
    fi

    if [ ! -f "$pkgfile" ]; then
        _pkg_fail "adm_pkg_install_file: arquivo não encontrado: $pkgfile"
        return 1
    fi

    local stage
    stage="$(mktemp -d "$ADM_ROOT/build/.pkginst.XXXXXX" 2>/dev/null)" || {
        _pkg_fail "Não foi possível criar diretório temporário para instalação"
        return 1
    }

    # Extrai TODO o pacote para stage (incluindo CONTROL)
    if ! _pkg_tar_extract_to_dir "$pkgfile" "$stage"; then
        rm -rf "$stage" 2>/dev/null || true
        return 1
    fi

    # Ler manifest
    if ! _pkg_read_manifest_file "$stage"; then
        rm -rf "$stage" 2>/dev/null || true
        return 1
    fi

    # Ajustar arch se vazio
    if [ -z "$PKG_MAN_ARCH" ]; then
        PKG_MAN_ARCH="$(_pkg_detect_arch)"
    fi

    # Ler lista de arquivos
    local files_file="$stage/CONTROL/files"
    if [ ! -f "$files_file" ]; then
        _pkg_fail "Lista de arquivos não encontrada em $files_file"
        rm -rf "$stage" 2>/dev/null || true
        return 1
    fi

    local files_rel
    files_rel="$(cat "$files_file" 2>/dev/null || true)"

    # Extrair arquivos para /
    #   - usamos tar --exclude CONTROL para não jogar metadata no root
    (
        cd "$stage" || exit 1
        tar -cf - . --exclude CONTROL 2>/dev/null
    ) | tar -C / -xf - 2>/dev/null || {
        _pkg_fail "Falha ao extrair dados do pacote para /"
        rm -rf "$stage" 2>/dev/null || true
        return 1
    }

    # Montar lista de arquivos com / inicial para o DB
    local files_db=""
    local f
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        # arquivos relativos: usr/bin/bash -> /usr/bin/bash
        files_db="${files_db}/$f"$'\n'
    done <<< "$files_rel"

    # Registrar no DB
    local name="$PKG_MAN_NAME"
    local version="$PKG_MAN_VERSION"
    local category="$PKG_MAN_CATEGORY"
    local libc="$PKG_MAN_LIBC"
    local init="$PKG_MAN_INIT"
    local profile="$PKG_MAN_PROFILE"
    local target="$PKG_MAN_TARGET"
    local reason="$PKG_MAN_REASON"
    [ -z "$reason" ] && reason="manual"

    if ! adm_db_register_install \
        "$name" "$version" "$category" "$libc" "$init" "$profile" "$target" "$reason" \
        "$PKG_MAN_RUN_DEPS" "$PKG_MAN_BUILD_DEPS" "$PKG_MAN_OPT_DEPS" \
        "$files_db"
    then
        _pkg_fail "Falha ao registrar pacote '$name' no DB"
        rm -rf "$stage" 2>/dev/null || true
        return 1
    fi

    _pkg_log INFO "Pacote instalado e registrado: $name-$version (release=$PKG_MAN_RELEASE arch=$PKG_MAN_ARCH)"
    rm -rf "$stage" 2>/dev/null || true
    return 0
}

# --------------------------------
# Empacotar DESTDIR (build ADM) em .pkg + registrar + (opcional) instalar
# --------------------------------
adm_pkg_from_destdir() {
    # Uso:
    #   adm_pkg_from_destdir DESTDIR [RELEASE] [ARCH]
    #
    # Requer que MF_* estejam carregadas (metafile do pacote).
    local destdir="$1"
    local release="${2:-$ADM_PKG_DEFAULT_RELEASE}"
    local arch="${3:-}"

    _pkg_ensure_metafile || return 1
    _pkg_ensure_db || return 1
    _pkg_check_tar_zstd || return 1
    adm_db_init || return 1

    if [ -z "$destdir" ]; then
        _pkg_fail "adm_pkg_from_destdir: DESTDIR não informado"
        return 1
    fi

    if [ ! -d "$destdir" ]; then
        _pkg_fail "adm_pkg_from_destdir: DESTDIR não existe: $destdir"
        return 1
    fi

    if [ -z "${MF_NAME:-}" ] || [ -z "${MF_VERSION:-}" ]; then
        _pkg_fail "adm_pkg_from_destdir: MF_NAME/MF_VERSION vazios; metafile não carregado"
        return 1
    fi

    [ -z "$arch" ] && arch="$(_pkg_detect_arch)"
    arch="$(_pkg_arch_normalize "$arch")"

    local out
    out="$(_pkg_package_path "$MF_NAME" "$MF_VERSION" "$release" "$arch")"

    mkdir -p "$(dirname "$out")" 2>/dev/null || {
        _pkg_fail "Não foi possível criar diretório de destino para pacote: $(dirname "$out")"
        return 1
    }

    if ! _pkg_create_pkg_from_destdir "$destdir" "$release" "$arch" "$out"; then
        return 1
    fi

    if [ "$ADM_PKG_BUILD_ONLY" = "1" ]; then
        _pkg_log INFO "Pacote criado (build-only). Não instalando: $out"
        echo "$out"
        return 0
    fi

    # Instalar imediatamente e registrar
    if ! adm_pkg_install_file "$out"; then
        _pkg_fail "Pacote criado, mas falha na instalação: $out"
        return 1
    fi

    echo "$out"
    return 0
}

# --------------------------------
# Reempacotar .deb -> .pkg + registrar + instalar
# --------------------------------
adm_pkg_repack_deb() {
    # Uso:
    #   adm_pkg_repack_deb arquivo.deb
    #
    # Requer:
    #   dpkg-deb ou ar+tar
    local deb="$1"

    _pkg_ensure_db || return 1
    _pkg_check_tar_zstd || return 1
    adm_db_init || return 1

    if [ -z "$deb" ]; then
        _pkg_fail "adm_pkg_repack_deb: caminho do .deb não informado"
        return 1
    fi

    if [ ! -f "$deb" ]; then
        _pkg_fail "adm_pkg_repack_deb: arquivo não encontrado: $deb"
        return 1
    fi

    local work
    work="$(mktemp -d "$ADM_ROOT/build/.repackdeb.XXXXXX" 2>/dev/null)" || {
        _pkg_fail "Não foi possível criar diretório temporário para reempacotar .deb"
        return 1
    fi

    local destdir="$work/dest"
    local control_dir="$work/control"
    mkdir -p "$destdir" "$control_dir" 2>/dev/null || {
        _pkg_fail "Não foi possível criar subdirs em $work"
        rm -rf "$work" 2>/dev/null || true
        return 1
    fi

    local name version arch deps

    if _pkg_have_cmd dpkg-deb; then
        # Extrair dados e controlar metadata
        if ! dpkg-deb -x "$deb" "$destdir" 2>/dev/null; then
            _pkg_fail "dpkg-deb -x falhou para $deb"
            rm -rf "$work" 2>/dev/null || true
            return 1
        fi
        if ! dpkg-deb -e "$deb" "$control_dir" 2>/dev/null; then
            _pkg_fail "dpkg-deb -e falhou para $deb"
            rm -rf "$work" 2>/dev/null || true
            return 1
        fi
        name="$(dpkg-deb -f "$deb" Package 2>/dev/null || echo unknown)"
        version="$(dpkg-deb -f "$deb" Version 2>/dev/null || echo 0)"
        arch="$(dpkg-deb -f "$deb" Architecture 2>/dev/null || echo "$(uname -m)")"
        deps="$(dpkg-deb -f "$deb" Depends 2>/dev/null || true)"
    else
        # fallback: ar + tar
        if ! _pkg_have_cmd ar; then
            _pkg_fail "Nem dpkg-deb nem ar disponíveis; não é possível reempacotar .deb"
            rm -rf "$work" 2>/dev/null || true
            return 1
        fi
        (
            cd "$work" || exit 1
            ar x "$deb"
        ) || {
            _pkg_fail "Falha ao extrair .deb via ar: $deb"
            rm -rf "$work" 2>/dev/null || true
            return 1
        }

        # procura data.tar.* e control.tar.*
        local data_tar control_tar
        data_tar="$(ls "$work"/data.tar.* 2>/dev/null | head -n1 || true)"
        control_tar="$(ls "$work"/control.tar.* 2>/dev/null | head -n1 || true)"

        if [ -z "$data_tar" ] || [ -z "$control_tar" ]; then
            _pkg_fail "Não foi possível localizar data.tar/control.tar em $deb"
            rm -rf "$work" 2>/dev/null || true
            return 1
        fi

        tar -C "$destdir" -xf "$data_tar" || {
            _pkg_fail "Falha ao extrair data.tar de $deb"
            rm -rf "$work" 2>/dev/null || true
            return 1
        }
        tar -C "$control_dir" -xf "$control_tar" || {
            _pkg_fail "Falha ao extrair control.tar de $deb"
            rm -rf "$work" 2>/dev/null || true
            return 1
        }

        # parse control file manualmente
        if [ ! -f "$control_dir/control" ]; then
            _pkg_fail "Arquivo control não encontrado no .deb"
            rm -rf "$work" 2>/dev/null || true
            return 1
        fi
        name="$(grep -i '^Package:' "$control_dir/control" | head -n1 | cut -d: -f2- | xargs || echo unknown)"
        version="$(grep -i '^Version:' "$control_dir/control" | head -n1 | cut -d: -f2- | xargs || echo 0)"
        arch="$(grep -i '^Architecture:' "$control_dir/control" | head -n1 | cut -d: -f2- | xargs || echo "$(uname -m)")"
        deps="$(grep -i '^Depends:' "$control_dir/control" | head -n1 | cut -d: -f2- | xargs || true)"
    fi

    name="$(_pkg_trim "$name")"
    version="$(_pkg_trim "$version")"
    arch="$(_pkg_arch_normalize "$(_pkg_trim "$arch")")"
    deps="$(_pkg_trim "$deps")"

    # Converter deps do formato deb (coma e versão) para lista simples de nomes
    # Exemplo: "libc6 (>= 2.34), libtinfo6" -> "libc6 libtinfo6"
    local run_deps=""
    if [ -n "$deps" ]; then
        run_deps="$(echo "$deps" | sed 's/,/\n/g' | sed 's/(.*)//' | awk '{print $1}' | tr '\n' ' ')"
        run_deps="$(_pkg_trim "$run_deps")"
    fi

    # Mandar MF_ temporários para poder reutilizar _pkg_generate_manifest_from_meta
    MF_NAME="$name"
    MF_VERSION="$version"
    MF_CATEGORY="${MF_CATEGORY:-apps}"
    MF_RUN_DEPS="$run_deps"
    MF_BUILD_DEPS=""
    MF_OPT_DEPS=""

    local release="1"
    local pkg_path
    pkg_path="$(_pkg_package_path "$name" "$version" "$release" "$arch")"

    mkdir -p "$(dirname "$pkg_path")" 2>/dev/null || {
        _pkg_fail "Não foi possível criar diretório de pacotes: $(dirname "$pkg_path")"
        rm -rf "$work" 2>/dev/null || true
        return 1
    }

    # Criar CONTROL/manifest/files manualmente (source_origin=deb)
    local stage
    stage="$(mktemp -d "$ADM_ROOT/build/.pkgstage_deb.XXXXXX" 2>/dev/null)" || {
        _pkg_fail "Não foi possível criar diretório stage para .deb"
        rm -rf "$work" 2>/dev/null || true
        return 1
    }
    mkdir -p "$stage/CONTROL" 2>/dev/null || true

    if ! _pkg_generate_files_list "$destdir" "$stage/CONTROL/files"; then
        rm -rf "$stage" "$work" 2>/dev/null || true
        return 1
    fi

    # manifest manual
    local tmp="${stage}/CONTROL/manifest.tmp.$$"
    {
        printf 'name=%s\n'         "$name"
        printf 'version=%s\n'      "$version"
        printf 'release=%s\n'      "$release"
        printf 'arch=%s\n'         "$arch"
        printf 'category=%s\n'     "apps"
        printf 'libc=%s\n'         "glibc"
        printf 'init=%s\n'         "sysv"
        printf 'profile=%s\n'      "normal"
        printf 'target=%s\n'       "native"
        printf 'reason=%s\n'       "manual"
        printf 'install_date=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'run_deps=%s\n'     "$run_deps"
        printf 'build_deps=%s\n'   ""
        printf 'opt_deps=%s\n'     ""
        printf 'source_origin=%s\n' "deb"
    } > "$tmp" 2>/dev/null || {
        _pkg_fail "Falha ao escrever manifest temporário para .deb em $tmp"
        rm -rf "$stage" "$work" 2>/dev/null || true
        return 1
    }
    mv -f "$tmp" "$stage/CONTROL/manifest" 2>/dev/null || {
        _pkg_fail "Falha ao mover manifest para $stage/CONTROL/manifest"
        rm -rf "$stage" "$work" 2>/dev/null || true
        return 1
    }

    # Criar .pkg
    if ! _pkg_tar_create_zst "$pkg_path" "$stage" "$destdir"; then
        rm -rf "$stage" "$work" 2>/dev/null || true
        return 1
    fi

    rm -rf "$stage" 2>/dev/null || true

    # Instalar e registrar
    if ! adm_pkg_install_file "$pkg_path"; then
        _pkg_fail "Pacote .pkg criado de .deb, mas falha na instalação: $pkg_path"
        rm -rf "$work" 2>/dev/null || true
        return 1
    fi

    _pkg_log INFO "Reempacotamento .deb concluído: $deb -> $pkg_path"
    rm -rf "$work" 2>/dev/null || true
    echo "$pkg_path"
    return 0
}

# --------------------------------
# Reempacotar .rpm -> .pkg + registrar + instalar
# --------------------------------
adm_pkg_repack_rpm() {
    # Uso:
    #   adm_pkg_repack_rpm arquivo.rpm
    #
    # Requer:
    #   rpm2cpio + cpio (ideal) ou rpm
    local rpm="$1"

    _pkg_ensure_db || return 1
    _pkg_check_tar_zstd || return 1
    adm_db_init || return 1

    if [ -z "$rpm" ]; then
        _pkg_fail "adm_pkg_repack_rpm: caminho do .rpm não informado"
        return 1
    fi

    if [ ! -f "$rpm" ]; then
        _pkg_fail "adm_pkg_repack_rpm: arquivo não encontrado: $rpm"
        return 1
    fi

    local work
    work="$(mktemp -d "$ADM_ROOT/build/.repackrpm.XXXXXX" 2>/dev/null)" || {
        _pkg_fail "Não foi possível criar diretório temporário para reempacotar .rpm"
        return 1
    }

    local destdir="$work/dest"
    mkdir -p "$destdir" 2>/dev/null || {
        _pkg_fail "Não foi possível criar destdir em $work"
        rm -rf "$work" 2>/dev/null || true
        return 1
    }

    local name version arch deps

    if _pkg_have_cmd rpm2cpio && _pkg_have_cmd cpio; then
        (
            cd "$destdir" || exit 1
            rpm2cpio "$rpm" | cpio -idmv 2>/dev/null
        ) || {
            _pkg_fail "Falha ao extrair .rpm com rpm2cpio/cpio: $rpm"
            rm -rf "$work" 2>/dev/null || true
            return 1
        }
    else
        _pkg_fail "rpm2cpio/cpio não disponíveis; não é possível reempacotar .rpm"
        rm -rf "$work" 2>/dev/null || true
        return 1
    fi

    if _pkg_have_cmd rpm; then
        name="$(rpm -qp --qf '%{NAME}\n' "$rpm" 2>/dev/null || echo unknown)"
        version="$(rpm -qp --qf '%{VERSION}-%{RELEASE}\n' "$rpm" 2>/dev/null || echo 0)"
        arch="$(rpm -qp --qf '%{ARCH}\n' "$rpm" 2>/dev/null || echo "$(uname -m)")"
        deps="$(rpm -qp --requires "$rpm" 2>/dev/null || true)"
    else
        name="unknown"
        version="0"
        arch="$(uname -m 2>/dev/null || echo unknown)"
        deps=""
        _pkg_log WARN "rpm não encontrado; não foi possível extrair metadados completos de $rpm"
    fi

    name="$(_pkg_trim "$name")"
    version="$(_pkg_trim "$version")"
    arch="$(_pkg_arch_normalize "$(_pkg_trim "$arch")")"

    # converte deps para nomes simples (remove versão)
    local run_deps=""
    if [ -n "$deps" ]; then
        run_deps="$(echo "$deps" | sed 's/(.*)//' | awk '{print $1}' | tr '\n' ' ')"
        run_deps="$(_pkg_trim "$run_deps")"
    fi

    MF_NAME="$name"
    MF_VERSION="$version"
    MF_CATEGORY="${MF_CATEGORY:-apps}"
    MF_RUN_DEPS="$run_deps"
    MF_BUILD_DEPS=""
    MF_OPT_DEPS=""

    local release="1"
    local pkg_path
    pkg_path="$(_pkg_package_path "$name" "$version" "$release" "$arch")"

    mkdir -p "$(dirname "$pkg_path")" 2>/dev/null || {
        _pkg_fail "Não foi possível criar diretório de pacotes: $(dirname "$pkg_path")"
        rm -rf "$work" 2>/dev/null || true
        return 1
    }

    local stage
    stage="$(mktemp -d "$ADM_ROOT/build/.pkgstage_rpm.XXXXXX" 2>/dev/null)" || {
        _pkg_fail "Não foi possível criar diretório stage para .rpm"
        rm -rf "$work" 2>/dev/null || true
        return 1
    }
    mkdir -p "$stage/CONTROL" 2>/dev/null || true

    if ! _pkg_generate_files_list "$destdir" "$stage/CONTROL/files"; then
        rm -rf "$stage" "$work" 2>/dev/null || true
        return 1
    fi

    local tmp="${stage}/CONTROL/manifest.tmp.$$"
    {
        printf 'name=%s\n'         "$name"
        printf 'version=%s\n'      "$version"
        printf 'release=%s\n'      "$release"
        printf 'arch=%s\n'         "$arch"
        printf 'category=%s\n'     "apps"
        printf 'libc=%s\n'         "glibc"
        printf 'init=%s\n'         "sysv"
        printf 'profile=%s\n'      "normal"
        printf 'target=%s\n'       "native"
        printf 'reason=%s\n'       "manual"
        printf 'install_date=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'run_deps=%s\n'     "$run_deps"
        printf 'build_deps=%s\n'   ""
        printf 'opt_deps=%s\n'     ""
        printf 'source_origin=%s\n' "rpm"
    } > "$tmp" 2>/dev/null || {
        _pkg_fail "Falha ao escrever manifest temporário para .rpm em $tmp"
        rm -rf "$stage" "$work" 2>/dev/null || true
        return 1
    }
    mv -f "$tmp" "$stage/CONTROL/manifest" 2>/dev/null || {
        _pkg_fail "Falha ao mover manifest para $stage/CONTROL/manifest"
        rm -rf "$stage" "$work" 2>/dev/null || true
        return 1
    }

    if ! _pkg_tar_create_zst "$pkg_path" "$stage" "$destdir"; then
        rm -rf "$stage" "$work" 2>/dev/null || true
        return 1
    fi

    rm -rf "$stage" 2>/dev/null || true

    if ! adm_pkg_install_file "$pkg_path"; then
        _pkg_fail "Pacote .pkg criado de .rpm, mas falha na instalação: $pkg_path"
        rm -rf "$work" 2>/dev/null || true
        return 1
    fi

    _pkg_log INFO "Reempacotamento .rpm concluído: $rpm -> $pkg_path"
    rm -rf "$work" 2>/dev/null || true
    echo "$pkg_path"
    return 0
}

# --------------------------------
# Modo CLI (teste rápido)
# --------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Exemplos:
    #   ./package.sh from-destdir /usr/src/adm/build/bash-5.2.21/dest
    #   ./package.sh install /usr/src/adm/packages/bash/bash-5.2.21-1-x86_64.pkg
    #   ./package.sh repack-deb ./bash.deb
    #   ./package.sh repack-rpm ./bash.rpm
    cmd="${1:-help}"
    shift || true

    case "$cmd" in
        help|-h|--help)
            cat << EOF
Uso: package.sh comando [args]

Comandos:
  from-destdir DESTDIR [RELEASE] [ARCH]
      Empacota DESTDIR em .pkg, registra no DB e instala. Usa MF_* do metafile.

  install PKGFILE
      Instala um pacote .pkg em / e registra no DB.

  repack-deb FILE.deb
      Reempacota um .deb em .pkg, registra e instala.

  repack-rpm FILE.rpm
      Reempacota um .rpm em .pkg, registra e instala.
EOF
            ;;
        from-destdir)
            if [ "$#" -lt 1 ]; then
                echo "Uso: package.sh from-destdir DESTDIR [RELEASE] [ARCH]" >&2
                exit 1
            fi
            adm_pkg_from_destdir "$@" || exit 1
            ;;
        install)
            if [ "$#" -ne 1 ]; then
                echo "Uso: package.sh install PKGFILE" >&2
                exit 1
            fi
            adm_pkg_install_file "$1" || exit 1
            ;;
        repack-deb)
            if [ "$#" -ne 1 ]; then
                echo "Uso: package.sh repack-deb FILE.deb" >&2
                exit 1
            fi
            adm_pkg_repack_deb "$1" || exit 1
            ;;
        repack-rpm)
            if [ "$#" -ne 1 ]; then
                echo "Uso: package.sh repack-rpm FILE.rpm" >&2
                exit 1
            fi
            adm_pkg_repack_rpm "$1" || exit 1
            ;;
        *)
            echo "Comando desconhecido: $cmd" >&2
            exit 1
            ;;
    esac
fi
