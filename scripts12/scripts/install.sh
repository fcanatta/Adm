#!/usr/bin/env bash

ADM_ROOT="/usr/src/adm"
ADM_SCRIPTS="$ADM_ROOT/scripts"
ADM_REPO="$ADM_ROOT/repo"
ADM_PKG_CACHE="$ADM_ROOT/packages"
ADM_BACKUP="$ADM_ROOT/backup"
ADM_BUILD="$ADM_ROOT/build"

INSTALL_NO_DEPS=0
INSTALL_BIN=0
INSTALL_FILE=""
INSTALL_NAME=""
UI_OK=1

if [ -r "$ADM_SCRIPTS/ui.sh" ]; then
    . "$ADM_SCRIPTS/ui.sh"
else
    UI_OK=0
fi
if [ -r "$ADM_SCRIPTS/db.sh" ]; then
    . "$ADM_SCRIPTS/db.sh"
fi
if [ -r "$ADM_SCRIPTS/metafile.sh" ]; then
    . "$ADM_SCRIPTS/metafile.sh"
fi
if [ -r "$ADM_SCRIPTS/source.sh" ]; then
    . "$ADM_SCRIPTS/source.sh"
fi
if [ -r "$ADM_SCRIPTS/build_core.sh" ]; then
    . "$ADM_SCRIPTS/build_core.sh"
fi
if [ -r "$ADM_SCRIPTS/package.sh" ]; then
    . "$ADM_SCRIPTS/package.sh"
fi

log_info(){ [ $UI_OK -eq 1 ] && adm_ui_log_info "$@" || echo "[INFO] $@"; }
log_warn(){ [ $UI_OK -eq 1 ] && adm_ui_log_warn "$@" || echo "[WARN] $@"; }
log_error(){ [ $UI_OK -eq 1 ] && adm_ui_log_error "$@" || echo "[ERROR] $@"; }

die(){ log_error "$@"; exit 1; }

trim(){ local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

backup_local(){
    local file="$1"
    local ts; ts=$(date +"%Y%m%d-%H%M%S")
    [ -f "$file" ] || return 0
    cp -a "$file" "${file}.adm-bak-$ts"
}

backup_global(){
    local pkg="$1"
    local file="$2"
    local ts; ts=$(date +"%Y%m%d-%H%M%S")
    local dst="$ADM_BACKUP/$pkg/$ts"
    mkdir -p "$dst"
    if [ -f "$file" ]; then
        local rel="${file#/}"
        mkdir -p "$dst/$(dirname "$rel")"
        cp -a "$file" "$dst/$rel"
    fi
}

install_backup(){
    local pkg="$1"
    local file="$2"
    backup_local "$file"
    backup_global "$pkg" "$file"
}

detect_pkg_file_type(){
    local f="$1"
    case "$f" in
        *.pkg) echo "adm" ;;
        *.deb) echo "deb" ;;
        *.rpm) echo "rpm" ;;
        *) echo "unknown" ;;
    esac
}

load_metafile_for(){
    local name="$1"
    local meta
    meta=$(find "$ADM_REPO" -type f -path "*/$name/metafile" 2>/dev/null | head -n1)
    [ -z "$meta" ] && return 1
    adm_meta_load "$meta"
}

run_hooks_pre(){
    local name="$1"
    local cat dir
    dir=$(dirname "$(find "$ADM_REPO" -type f -path "*/$name/metafile" | head -n1)")
    [ -z "$dir" ] && return 0
    if [ -x "$dir/hooks/pre_install" ]; then
        "$dir/hooks/pre_install" "$name" || die "Falha no pre_install hook"
    fi
}

run_hooks_post(){
    local name="$1"
    local cat dir
    dir=$(dirname "$(find "$ADM_REPO" -type f -path "*/$name/metafile" | head -n1)")
    [ -z "$dir" ] && return 0
    if [ -x "$dir/hooks/post_install" ]; then
        "$dir/hooks/post_install" "$name" || die "Falha no post_install hook"
    fi
}

install_pkg_file(){
    local f="$1"
    adm_pkg_install_file "$f"
}

remove_old_versions(){
    local name="$1"
    adm_db_init
    local list
    list=$(adm_db_list_installed | grep "^$name " || true)
    while read -r line; do
        [ -z "$line" ] && continue
        local old
        old=$(echo "$line" | awk '{print $1}')
        adm_db_unregister "$old"
    done <<< "$list"
}

resolve_bin_dep(){
    local dep="$1"
    local path="$ADM_PKG_CACHE/$dep"
    local file
    file=$(find "$path" -type f -name "$dep-*.pkg" 2>/dev/null | head -n1)
    if [ -n "$file" ]; then
        install_pkg_file "$file"
        return 0
    fi
    return 1
}

resolve_dep_source(){
    local dep="$1"
    load_metafile_for "$dep" || die "Metafile não encontrado p/ dep $dep"
    local dest
    dest="$ADM_BUILD/${dep}.dest"
    rm -rf "$dest"
    mkdir -p "$dest"
    adm_src_fetch "$MF_SOURCES" "$MF_SHA256SUMS" "$MF_MD5SUMS" || die
    adm_src_extract || die
    adm_build_core "$dep" "$dest" || die
    ADM_PKG_BUILD_ONLY=1 adm_pkg_from_destdir "$dest" > /tmp/pkg.out || die
    local pkgfile
    pkgfile=$(cat /tmp/pkg.out)
    install_pkg_file "$pkgfile"
}

resolve_all_deps_full(){
    local name="$1"
    [ "$INSTALL_NO_DEPS" -eq 1 ] && return 0
    local deps="$MF_RUN_DEPS $MF_BUILD_DEPS"
    for d in $deps; do
        resolve_bin_dep "$d" || resolve_dep_source "$d"
    done
}

is_bin_pkg_available(){
    local name="$1"
    local p="$ADM_PKG_CACHE/$name"
    find "$p" -type f -name "$name-*.pkg" | head -n1
}

install_bin_fallback(){
    local name="$1"
    local f
    f=$(is_bin_pkg_available "$name")
    [ -z "$f" ] && return 1
    local stage scrapfile
    stage=$(mktemp -d)
    scrapfile="$stage/tmp.pkg"
    cp "$f" "$scrapfile"
    local m
    m=$(mktemp -d)
    _pkg_tar_extract_to_dir "$scrapfile" "$m" || die
    _pkg_read_manifest_file "$m"
    local all="${PKG_MAN_RUN_DEPS}"
    for d in $all; do
        resolve_bin_dep "$d" || resolve_dep_source "$d"
    done
    install_pkg_file "$scrapfile"
    rm -rf "$stage" "$m"
    return 0
}

install_source_full(){
    local name="$1"
    load_metafile_for "$name" || die "metafile de $name não encontrado"
    resolve_all_deps_full "$name"
    local dest
    dest="$ADM_BUILD/${name}.dest"
    rm -rf "$dest"
    mkdir -p "$dest"
    adm_src_fetch "$MF_SOURCES" "$MF_SHA256SUMS" "$MF_MD5SUMS" || die
    adm_src_extract || die
    adm_build_core "$name" "$dest" || die
    ADM_PKG_BUILD_ONLY=1 adm_pkg_from_destdir "$dest" > /tmp/pkgsrc.out || die
    local pkgfile
    pkgfile=$(cat /tmp/pkgsrc.out)
    install_pkg_file "$pkgfile"
}
install_file_auto(){
    local file="$1"
    local t
    t=$(detect_pkg_file_type "$file")
    case "$t" in
        adm) install_pkg_file "$file" ;;
        deb) adm_pkg_repack_deb "$file" ;;
        rpm) adm_pkg_repack_rpm "$file" ;;
        *) die "Arquivo desconhecido: $file" ;;
    esac
}

install_main(){
    local name="$1"
    run_hooks_pre "$name"
    remove_old_versions "$name"
    if [ "$INSTALL_BIN" -eq 1 ]; then
        install_bin_fallback "$name" && {
            run_hooks_post "$name"
            return 0
        }
        install_source_full "$name"
        run_hooks_post "$name"
        return 0
    fi

    install_source_full "$name"
    run_hooks_post "$name"
}

install_from_pkg_or_source(){
    local arg="$1"
    if [ -f "$arg" ]; then
        install_file_auto "$arg"
        exit 0
    fi
    INSTALL_NAME="$arg"
    install_main "$INSTALL_NAME"
}

print_help(){
cat <<EOF
Usage:
  adm install <pkg> [--no-deps]
  adm install-bin <pkg> [--no-deps]
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
                *) INSTALL_FILE="$a" ;;
            esac
        done
        [ -z "$INSTALL_FILE" ] && print_help && exit 1
        install_from_pkg_or_source "$INSTALL_FILE"
        ;;
    install-bin)
        INSTALL_BIN=1
        for a in "$@"; do
            case "$a" in
                --no-deps) INSTALL_NO_DEPS=1 ;;
                *) INSTALL_FILE="$a" ;;
            esac
        done
        [ -z "$INSTALL_FILE" ] && print_help && exit 1
        install_from_pkg_or_source "$INSTALL_FILE"
        ;;
    *)
        print_help
        exit 1
        ;;
esac
