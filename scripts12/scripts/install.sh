#!/usr/bin/env bash

ADM_ROOT="/usr/src/adm"
ADM_SCRIPTS="$ADM_ROOT/scripts"
ADM_REPO="$ADM_ROOT/repo"
ADM_PKG_CACHE="$ADM_ROOT/packages"
ADM_BACKUP="$ADM_ROOT/backup"
ADM_BUILD="$ADM_ROOT/build"

INSTALL_NO_DEPS=0
INSTALL_BIN=0
INSTALL_TARGET=""
INSTALL_FILE=""
UI_OK=1

# ----------------------------------------------------
# carregar módulos
# ----------------------------------------------------
for f in ui.sh db.sh metafile.sh source.sh build_core.sh package.sh profile.sh; do
    if [ -r "$ADM_SCRIPTS/$f" ]; then
        . "$ADM_SCRIPTS/$f"
    fi
done

# ----------------------------------------------------
# LOGS
# ----------------------------------------------------
log_info(){ [ $UI_OK -eq 1 ] && adm_ui_log_info "$@" || echo "[INFO] $@"; }
log_warn(){ [ $UI_OK -eq 1 ] && adm_ui_log_warn "$@" || echo "[WARN] $@"; }
log_error(){ [ $UI_OK -eq 1 ] && adm_ui_log_error "$@" || echo "[ERROR] $@"; }
die(){ log_error "$@"; exit 1; }

trim(){ local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf "%s" "$s"; }

timestamp(){ date +"%Y%m%d-%H%M%S"; }

# ----------------------------------------------------
# BACKUP modo C (local + global)
# ----------------------------------------------------
backup_local(){
    local file="$1"
    [ -f "$file" ] || return 0
    cp -a "$file" "${file}.adm-bak-$(timestamp)"
}

backup_global(){
    local pkg="$1"
    local file="$2"
    [ -f "$file" ] || return 0
    local rel="${file#/}"
    local dst="$ADM_BACKUP/$pkg/$(timestamp)/$rel"
    mkdir -p "$(dirname "$dst")"
    cp -a "$file" "$dst"
}

backup_conflict(){
    local pkg="$1"
    local file="$2"
    backup_local "$file"
    backup_global "$pkg" "$file"
}

# ----------------------------------------------------
# hooks
# ----------------------------------------------------
find_repo_dir(){
    local name="$1"
    find "$ADM_REPO" -type f -path "*/$name/metafile" -printf '%h\n' 2>/dev/null | head -n1
}

run_hooks_pre(){
    local name="$1"
    local d
    d=$(find_repo_dir "$name")
    [ -z "$d" ] && return 0
    [ -x "$d/hooks/pre_install" ] && "$d/hooks/pre_install" "$name" || true
}

run_hooks_post(){
    local name="$1"
    local d
    d=$(find_repo_dir "$name")
    [ -z "$d" ] && return 0
    [ -x "$d/hooks/post_install" ] && "$d/hooks/post_install" "$name" || true
}

# ----------------------------------------------------
# validação de metafile
# ----------------------------------------------------
validate_meta(){
    [ -z "$MF_NAME" ] && die "metafile: MF_NAME vazio"
    [ -z "$MF_VERSION" ] && die "metafile: MF_VERSION vazio"
    [ -z "$MF_SOURCES" ] && die "metafile: MF_SOURCES vazio"
    return 0
}

# ----------------------------------------------------
# resolução de tipo de arquivo
# ----------------------------------------------------
file_type(){
    case "$1" in
        *.pkg) echo "adm" ;;
        *.deb) echo "deb" ;;
        *.rpm) echo "rpm" ;;
        *) echo "unknown" ;;
    esac
}

# ----------------------------------------------------
# remoção de versões antigas (single-version)
# ----------------------------------------------------
remove_old_versions(){
    local name="$1"
    adm_db_init
    local line
    while read -r line; do
        [ -z "$line" ] && continue
        local pkg
        pkg=$(echo "$line" | awk '{print $1}')
        adm_db_unregister "$pkg"
    done <<< "$(adm_db_list_installed | grep "^$name ")"
}

# ----------------------------------------------------
# instalação de arquivo de pacote
# ----------------------------------------------------
install_pkg_file_secure(){
    local file="$1"
    local tmp
    tmp=$(mktemp -d)
    _pkg_tar_extract_to_dir "$file" "$tmp" || die "Falha ao extrair $file"

    _pkg_read_manifest_file "$tmp" || die
    local name="$PKG_MAN_NAME"

    local list="$tmp/CONTROL/files"
    [ -f "$list" ] || die "Lista de arquivos ausente em pkg"

    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        local dst="/$rel"
        if [ -e "$dst" ]; then
            backup_conflict "$name" "$dst"
        fi
    done < "$list"

    (cd "$tmp" && tar -cf - . --exclude=CONTROL) | tar -C / -xf - || die "Falha ao instalar arquivos"

    local files_db=""
    while IFS= read -r rel; do
        files_db="${files_db}/$rel"$'\n'
    done < "$list"

    adm_db_init
    adm_db_register_install \
        "$PKG_MAN_NAME" "$PKG_MAN_VERSION" "$PKG_MAN_CATEGORY" \
        "$PKG_MAN_LIBC" "$PKG_MAN_INIT" "$PKG_MAN_PROFILE" "$PKG_MAN_TARGET" \
        "$PKG_MAN_REASON" "$PKG_MAN_RUN_DEPS" "$PKG_MAN_BUILD_DEPS" "$PKG_MAN_OPT_DEPS" \
        "$files_db"

    rm -rf "$tmp"
}

# ----------------------------------------------------
# resolver dependência binária
# ----------------------------------------------------
bin_pkg_available(){
    local dep="$1"
    find "$ADM_PKG_CACHE/$dep" -type f -name "$dep-*.pkg" 2>/dev/null | head -n1
}

resolve_bin_dep(){
    local dep="$1"
    local f
    f=$(bin_pkg_available "$dep")
    [ -z "$f" ] && return 1
    install_pkg_file_secure "$f"
    return 0
}

# ----------------------------------------------------
# fallback fonte
# ----------------------------------------------------
resolve_dep_source(){
    local dep="$1"
    load_metafile "$dep" || die "metafile não encontrado para $dep"
    validate_meta

    adm_profile_apply_current

    adm_source_prepare_from_meta || die
    local dest="$ADM_BUILD/${dep}-${MF_VERSION}/dest"
    rm -rf "$dest"
    mkdir -p "$dest"

    adm_build_core_from_meta "$dest" || die

    ADM_PKG_BUILD_ONLY=1 adm_pkg_from_destdir "$dest" > /tmp/dep.pkg || die
    install_pkg_file_secure "$(cat /tmp/dep.pkg)"
}

# ----------------------------------------------------
# resolução total de dependências
# ----------------------------------------------------
resolve_all_deps(){
    local deps="$MF_RUN_DEPS $MF_BUILD_DEPS"
    [ $INSTALL_NO_DEPS -eq 1 ] && return 0

    for d in $deps; do
        resolve_bin_dep "$d" || resolve_dep_source "$d"
    done
}

# ----------------------------------------------------
# instalação binária com fallback fonte
# ----------------------------------------------------
install_bin_fallback(){
    local name="$1"
    local f
    f=$(bin_pkg_available "$name") || return 1
    [ -z "$f" ] && return 1

    local tmp
    tmp=$(mktemp -d)
    _pkg_tar_extract_to_dir "$f" "$tmp" || die
    _pkg_read_manifest_file "$tmp" || die

    for d in $PKG_MAN_RUN_DEPS; do
        resolve_bin_dep "$d" || resolve_dep_source "$d"
    done

    install_pkg_file_secure "$f"
    rm -rf "$tmp"
    return 0
}

# ----------------------------------------------------
# fetch + extract + build + package + install
# ----------------------------------------------------
install_source(){
    local name="$1"

    load_metafile "$name" || die "Metafile não encontrado"
    validate_meta
    adm_profile_apply_current

    resolve_all_deps

    adm_source_prepare_from_meta || die

    local dest="$ADM_BUILD/${name}-${MF_VERSION}/dest"
    rm -rf "$dest"
    mkdir -p "$dest"

    adm_build_core_from_meta "$dest" || die
    ADM_PKG_BUILD_ONLY=1 adm_pkg_from_destdir "$dest" > /tmp/src.pkg || die

    install_pkg_file_secure "$(cat /tmp/src.pkg)"
}
# ----------------------------------------------------
# instalar arquivo explicitamente
# ----------------------------------------------------
install_from_file(){
    local f="$1"
    local t
    t=$(file_type "$f")
    case "$t" in
        adm) install_pkg_file_secure "$f" ;;
        deb) adm_pkg_repack_deb "$f" ;;
        rpm) adm_pkg_repack_rpm "$f" ;;
        *) die "Tipo de arquivo não suportado: $f" ;;
    esac
}

# ----------------------------------------------------
# fluxo principal
# ----------------------------------------------------
install_main(){
    local name="$1"

    run_hooks_pre "$name"
    remove_old_versions "$name"

    if [ $INSTALL_BIN -eq 1 ]; then
        install_bin_fallback "$name" || install_source "$name"
        run_hooks_post "$name"
        return 0
    fi

    install_source "$name"
    run_hooks_post "$name"
}

# ----------------------------------------------------
# CLI
# ----------------------------------------------------
help(){
cat <<EOF
Uso:
  adm install <pacote> [--no-deps]
  adm install-bin <pacote> [--no-deps]
  adm install <arquivo.pkg|.deb|.rpm>
EOF
}

CMD="$1"
shift || true

case "$CMD" in
    install)
        for a in "$@"; do
            case "$a" in
                --no-deps) INSTALL_NO_DEPS=1 ;;
                *) INSTALL_TARGET="$a" ;;
            esac
        done
        [ -z "$INSTALL_TARGET" ] && help && exit 1
        if [ -f "$INSTALL_TARGET" ]; then
            install_from_file "$INSTALL_TARGET"
        else
            install_main "$INSTALL_TARGET"
        fi
        ;;
    install-bin)
        INSTALL_BIN=1
        for a in "$@"; do
            case "$a" in
                --no-deps) INSTALL_NO_DEPS=1 ;;
                *) INSTALL_TARGET="$a" ;;
            esac
        done
        [ -z "$INSTALL_TARGET" ] && help && exit 1
        install_main "$INSTALL_TARGET"
        ;;
    *)
        help
        exit 1
        ;;
esac
