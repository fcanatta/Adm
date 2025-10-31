#!/usr/bin/env bash
#=============================================================
# package.sh — Empacotador do ADM Build System
#-------------------------------------------------------------
# - Gera manifest (lista + sha256) dos arquivos instalados
# - Gera pkginfo (metadados)
# - Compacta em .pkg.tar.zst (ou .tar.xz fallback)
# - Assina (opcional) com GPG se PKG_SIGN_KEY estiver configurado
# - Registra pacote no status DB
#
# Uso:
#   bash package.sh /usr/src/adm/repo/<grupo>/<pkg>
#   bash package.sh --test
#=============================================================

set -o pipefail
[[ -n "${ADM_PACKAGE_SH_LOADED}" ]] && return
ADM_PACKAGE_SH_LOADED=1

#-------------------------------------------------------------
# Security / env
#-------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" && ! -f "/usr/src/adm/scripts/env.sh" ]]; then
    echo "❌ Este script deve ser executado dentro do ambiente ADM."
    exit 1
fi

#-------------------------------------------------------------
# Dependencies (assume these scripts exist; abort if missing)
#-------------------------------------------------------------
source /usr/src/adm/scripts/env.sh
source /usr/src/adm/scripts/log.sh
source /usr/src/adm/scripts/utils.sh
source /usr/src/adm/scripts/ui.sh
source /usr/src/adm/scripts/hooks.sh

#-------------------------------------------------------------
# Configuration and defaults
#-------------------------------------------------------------
PKG_LOG_DIR="${ADM_LOG_DIR}/package"
PACKAGES_DIR="${ADM_ROOT}/packages"
STATUS_DB="${ADM_STATUS_DB:-/var/lib/adm/status.db}"
TMP_DIR="${ADM_TMP_DIR:-/usr/src/adm/tmp}"

ensure_dir "$PKG_LOG_DIR"
ensure_dir "$PACKAGES_DIR"
ensure_dir "$TMP_DIR"
ensure_dir "$(dirname "$STATUS_DB")"

# compression preferences
HAS_ZSTD=0
if check_command zstd >/dev/null 2>&1; then
    HAS_ZSTD=1
fi
HAS_TAR=0
if check_command tar >/dev/null 2>&1; then
    HAS_TAR=1
fi

#-------------------------------------------------------------
# Helper: load package metadata (from build.pkg)
#-------------------------------------------------------------
load_package_metadata() {
    local pkg_dir="$1"
    local build_file="${pkg_dir}/build.pkg"

    if [[ ! -f "$build_file" ]]; then
        log_error "build.pkg não encontrado em: ${pkg_dir}"
        return 1
    fi

    # shellcheck disable=SC1090
    source "$build_file"

    # Ensure minimal fields
    : "${PKG_NAME:?PKG_NAME requerido no build.pkg}"
    : "${PKG_VERSION:?PKG_VERSION requerido no build.pkg}"
    : "${PKG_GROUP:=core}"       # default group
    : "${PKG_DESCRIPTION:=}"
    : "${PKG_LICENSE:=}"
    : "${PKG_MAINTAINER:=}"
    # PKG_DEPENDS may be empty array
    return 0
}

#-------------------------------------------------------------
# Helper: path helpers
#-------------------------------------------------------------
install_tree() { echo "${ADM_ROOT}/install/${PKG_NAME}"; }
package_basename() { echo "${PKG_NAME}-${PKG_VERSION}"; }
package_prefix_dir() { echo "${PACKAGES_DIR}/${PKG_GROUP}"; }
package_path() { echo "$(package_prefix_dir)/$(package_basename).pkg.tar.${HAS_ZSTD:+zst}${HAS_ZSTD:-xz}"; }

#-------------------------------------------------------------
# Generate manifest: list files relative to prefix, with sha256 and size
# Output: manifest file path
#-------------------------------------------------------------
generate_manifest() {
    local inst_dir="$1"
    local out_manifest="$2"

    : > "$out_manifest"
    pushd "$inst_dir" >/dev/null || return 1

    # find all regular files and symlinks; preserve order
    while IFS= read -r -d $'\0' file; do
        rel="${file#./}"
        if [[ -h "$rel" ]]; then
            # symlink: store link target
            target=$(readlink "$rel")
            printf "L %s -> %s\n" "$rel" "$target" >>"$out_manifest"
        elif [[ -f "$rel" ]]; then
            # regular file: sha256 and size
            sha=$(sha256sum "$rel" | awk '{print $1}')
            sz=$(stat -c%s "$rel")
            printf "F %s %s %s\n" "$rel" "$sha" "$sz" >>"$out_manifest"
        fi
    done < <(find . -mindepth 1 -print0 | sort -z)

    popd >/dev/null
    log_info "Manifest gerado: ${out_manifest}"
    return 0
}

#-------------------------------------------------------------
# Create pkginfo file
#-------------------------------------------------------------
create_pkginfo() {
    local out_pkginfo="$1"
    local pkg_size_bytes="$2"
    local pkg_sha="$3"
    local builddate
    builddate=$(date '+%Y-%m-%d %H:%M:%S')

    {
        echo "pkgname = ${PKG_NAME}"
        echo "pkgver = ${PKG_VERSION}"
        echo "pkgdesc = ${PKG_DESCRIPTION}"
        echo "group = ${PKG_GROUP}"
        echo "url = ${PKG_URL:-}"
        echo "license = ${PKG_LICENSE}"
        echo "maintainer = ${PKG_MAINTAINER}"
        echo "builddate = ${builddate}"
        echo "size = ${pkg_size_bytes}"
        if [[ -n "${PKG_DEPENDS[*]:-}" ]]; then
            echo -n "depends ="
            for d in "${PKG_DEPENDS[@]}"; do
                echo -n " ${d}"
            done
            echo
        fi
        echo "sha256 = ${pkg_sha}"
    } > "$out_pkginfo"

    log_info "pkginfo criado: ${out_pkginfo}"
}

#-------------------------------------------------------------
# Compress package into .pkg.tar.zst or .pkg.tar.xz
#-------------------------------------------------------------
compress_package() {
    local src_dir="$1"   # directory whose contents will be packaged
    local out_path="$2"  # final package path

    ensure_dir "$(dirname "$out_path")"

    if [[ $HAS_ZSTD -eq 1 && $HAS_TAR -eq 1 ]]; then
        ui_draw_progress "${PKG_NAME}" "package" 10 0
        # use tar with zstd (portable with tar -I if available)
        if tar --version | grep -qi "GNU tar"; then
            # prefer -I "zstd -T0 -19" if available
            if check_command zstd >/dev/null 2>&1; then
                tar -C "$src_dir" -cf - . | zstd -T0 -19 -o "$out_path"
            else
                # fallback to tar with --zstd if tar was compiled with zstd support
                tar --zstd -C "$src_dir" -cf "$out_path" .
            fi
        else
            # generic fallback: create tar then compress with zstd
            local tmp_tar="${TMP_DIR}/$(package_basename).tar"
            tar -C "$src_dir" -cf "$tmp_tar" .
            zstd -T0 -19 -o "$out_path" "$tmp_tar"
            rm -f "$tmp_tar"
        fi
        ui_draw_progress "${PKG_NAME}" "package" 90 0
        return $?
    fi

    # fallback to xz (if zstd not available)
    if check_command xz >/dev/null 2>&1 && [[ $HAS_TAR -eq 1 ]]; then
        ui_draw_progress "${PKG_NAME}" "package" 10 0
        tar -C "$src_dir" -cJf "$out_path" .
        ui_draw_progress "${PKG_NAME}" "package" 90 0
        return $?
    fi

    log_error "Nenhum compressor suportado encontrado (zstd ou xz). Instale zstd ou xz."
    return 1
}

#-------------------------------------------------------------
# Sign package with GPG if PKG_SIGN_KEY is defined in env.sh
#-------------------------------------------------------------
sign_package() {
    local pkg_path="$1"
    if [[ -n "${PKG_SIGN_KEY:-}" ]]; then
        check_command gpg || { log_warn "gpg não disponível; pulando assinatura"; return 2; }
        log_info "Assinando pacote com a chave ${PKG_SIGN_KEY}"
        # detached ASCII or binary? produce detached binary signature
        if gpg --batch --yes --default-key "${PKG_SIGN_KEY}" -o "${pkg_path}.sig" --detach-sign "${pkg_path}"; then
            log_success "Assinatura gerada: ${pkg_path}.sig"
            return 0
        else
            log_warn "Falha ao assinar ${pkg_path}"
            return 1
        fi
    fi
    return 0
}

#-------------------------------------------------------------
# Register package in status DB
#-------------------------------------------------------------
register_package() {
    local pkg_path="$1"
    local pkg_sha="$2"
    local pkg_size="$3"
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    ensure_dir "$(dirname "$STATUS_DB")"

    # format: pkgname|version|group|date|sha256|size|path
    printf "%s|%s|%s|%s|%s|%s|%s\n" "${PKG_NAME}" "${PKG_VERSION}" "${PKG_GROUP}" "${now}" "${pkg_sha}" "${pkg_size}" "${pkg_path}" >> "${STATUS_DB}"
    log_info "Pacote registrado em ${STATUS_DB}"
}

#-------------------------------------------------------------
# Main packaging pipeline
#-------------------------------------------------------------
package_main() {
    local pkg_dir="$1"
    local log_file="${PKG_LOG_DIR}/${PKG_NAME}.log"
    : > "$log_file"

    # hooks pre-package
    call_hook "pre-package" "$pkg_dir"

    local inst_dir
    inst_dir=$(install_tree)
    if [[ ! -d "$inst_dir" ]]; then
        log_error "Diretório de instalação não encontrado: ${inst_dir}"
        return 1
    fi

    local pkg_prefix
    pkg_prefix="$(package_prefix_dir)"
    ensure_dir "$pkg_prefix"

    local work_tmp="${TMP_DIR}/package-${PKG_NAME}-${PKG_VERSION}"
    rm -rf "$work_tmp"
    mkdir -p "$work_tmp/root"

    # copy install tree into staging area preserving attributes
    log_info "Copiando arquivos para staging..."
    rsync -a --delete "${inst_dir}/" "${work_tmp}/root/" >>"$log_file" 2>&1 || { log_error "Falha ao copiar install tree"; return 1; }

    # generate manifest
    local manifest_path="${pkg_prefix}/$(package_basename).manifest"
    generate_manifest "${work_tmp}/root" "$manifest_path"

    # create pkginfo
    local pkginfo_path="${pkg_prefix}/$(package_basename).pkginfo"

    # create package file (tar.zst or tar.xz)
    local pkg_out="${pkg_prefix}/$(package_basename).pkg.tar"
    if [[ $HAS_ZSTD -eq 1 ]]; then
        pkg_out="${pkg_out}.zst"
    else
        pkg_out="${pkg_out}.xz"
    fi

    ui_draw_header "${PKG_NAME}-${PKG_VERSION}" "package"
    ui_draw_progress "${PKG_NAME}" "package" 5 0
    log_info "Compactando pacote em ${pkg_out} ..."
    if ! compress_package "${work_tmp}/root" "${pkg_out}"; then
        log_error "Falha na compressão do pacote"
        rm -rf "$work_tmp"
        return 1
    fi

    # compute package checksum & size
    local pkg_sha
    pkg_sha=$(sha256sum "${pkg_out}" | awk '{print $1}')
    local pkg_size
    pkg_size=$(stat -c%s "${pkg_out}")

    # finalize pkginfo (size in bytes)
    create_pkginfo "$pkginfo_path" "$pkg_size" "$pkg_sha"

    # copy manifest and pkginfo alongside package (already created in pkg_prefix)
    cp -a "${manifest_path}" "${pkg_prefix}/" || true
    cp -a "${pkginfo_path}" "${pkg_prefix}/" || true

    # sign package optionally
    sign_package "${pkg_out}"

    # register package
    register_package "${pkg_out}" "${pkg_sha}" "${pkg_size}"

    # hooks post-package
    call_hook "post-package" "$pkg_dir"

    # cleanup
    rm -rf "$work_tmp"

    log_success "Pacote criado: ${pkg_out}"
    echo "${pkg_out}"
    return 0
}

#-------------------------------------------------------------
# CLI and entrypoint
#-------------------------------------------------------------
_show_help() {
    cat <<EOF
package.sh - empacotador ADM

Uso:
  package.sh <pkg_dir>      # empacota o conteúdo de install/<pkg>
  package.sh --test         # empacota /usr/src/adm/repo/core/zlib (exemplo)
  package.sh --help
EOF
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "$1" in
        --test)
            # test using sample package repo/core/zlib
            pkg_dir="/usr/src/adm/repo/core/zlib"
            log_init
            if load_package_metadata "$pkg_dir"; then
                package_main "$pkg_dir"
            fi
            log_close
            ;;
        --help|-h)
            _show_help
            ;;
        *)
            if [[ -z "$1" ]]; then
                _show_help
                exit 2
            fi
            pkg_dir="$1"
            log_init
            if load_package_metadata "$pkg_dir"; then
                package_main "$pkg_dir"
            fi
            log_close
            ;;
    esac
fi
