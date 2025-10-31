#!/usr/bin/env bash
# mkinitramfs.sh — ADM Initramfs builder (improved)
# - Adds: --dry-run, module detection from rootfs fstab & /proc/modules
# - Adds: --install-hook to integrate with update.sh (post-update hook)
#
# Usage examples:
#  ./mkinitramfs.sh --dry-run
#  ./mkinitramfs.sh --compress zstd --modules "nvme ahci"
#  ./mkinitramfs.sh --install-hook   # writes /usr/src/adm/hooks/post-update
#
set -o errexit
set -o nounset
set -o pipefail

[[ -n "${ADM_MKINITRAMFS_LOADED:-}" ]] && return 0
ADM_MKINITRAMFS_LOADED=1

# ---- best-effort env includes ----
if [[ -f "/usr/src/adm/scripts/env.sh" ]]; then
    source /usr/src/adm/scripts/env.sh || true
fi
source /usr/src/adm/scripts/log.sh 2>/dev/null || true
source /usr/src/adm/scripts/hooks.sh 2>/dev/null || true
source /usr/src/adm/scripts/profile.sh 2>/dev/null || true

# ---- defaults ----
BOOT_DIR="${ADM_BOOT_DIR:-/boot}"
BACKUP_DIR="${BOOT_DIR}/backup-initramfs"
WORK_BASE="${ADM_ROOT:-/usr/src/adm}/state"
WORK_ROOT="${WORK_BASE}/initramfs-tmp"
LOG_DIR="${ADM_LOG_DIR:-/usr/src/adm/logs}/mkinitramfs"
HOOK_DIR="/usr/src/adm/hooks"
MANIFEST_NAME="initramfs.manifest"
DEFAULT_COMPRESS="zstd"

mkdir -p "$BACKUP_DIR" "$WORK_ROOT" "$LOG_DIR" "$HOOK_DIR"

# ---- options ----
KERNEL=""
ROOTFS="/"
COMPRESS="$DEFAULT_COMPRESS"
EXTRA_MODULES=()
REBUILD=0
DO_BACKUP=1
UPDATE_BOOTLOADER=0
QUIET=0
DEBUG=0
KEEP_TMP=0
DRY_RUN=0
INSTALL_HOOK=0

# ---- helpers ----
_now() { date '+%Y%m%d-%H%M%S'; }
_ts()  { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

logmsg() {
    local lvl="$1"; shift
    local msg="$*"
    if declare -f log_info >/dev/null 2>&1; then
        case "$lvl" in
            INFO) log_info "$msg" ;;
            WARN) log_warn "$msg" ;;
            ERROR) log_error "$msg" ;;
            *) log_info "$msg" ;;
        esac
    else
        printf "[%s] %s\n" "$lvl" "$msg" >&2
    fi
}

die() {
    local rc=${2:-1}
    logmsg ERROR "$1"
    if declare -f call_hook >/dev/null 2>&1; then
        call_hook "on-error" "${WORK_ROOT}" || true
    fi
    exit "$rc"
}

run_hook_if_exists() {
    local hookname="$1"
    if [[ -x "${HOOK_DIR}/${hookname}" ]]; then
        logmsg INFO "Running hook ${hookname}"
        "${HOOK_DIR}/${hookname}" "$@" || logmsg WARN "Hook ${hookname} returned non-zero"
    fi
}

which_compressor() {
    local pref="$1"
    case "$pref" in
        zstd) command -v zstd >/dev/null 2>&1 && echo "zstd" && return 0 ;;
        xz)  command -v xz >/dev/null 2>&1 && echo "xz" && return 0 ;;
        lz4) command -v lz4 >/dev/null 2>&1 && echo "lz4" && return 0 ;;
        gzip) command -v gzip >/dev/null 2>&1 && echo "gzip" && return 0 ;;
    esac
    if command -v zstd >/dev/null 2>&1; then echo "zstd"
    elif command -v xz >/dev/null 2>&1; then echo "xz"
    elif command -v lz4 >/dev/null 2>&1; then echo "lz4"
    elif command -v gzip >/dev/null 2>&1; then echo "gzip"
    else echo "none"
    fi
}

safe_copy() {
    local src="$1"; local dst="$2"
    mkdir -p "$(dirname "$dst")"
    cp -a --preserve=mode,timestamps "$src" "$dst" 2>/dev/null || cp -a "$src" "$dst"
}

copy_binary_and_libs() {
    local bin="$1"; local dest_root="$2"
    [[ -e "$bin" ]] || { logmsg WARN "Binary not found: $bin"; return 0; }
    if [[ -L "$bin" ]]; then
        local target=$(readlink -f "$bin")
        mkdir -p "${dest_root}$(dirname "$bin")"
        ln -s "$(basename "$target")" "${dest_root}${bin}" 2>/dev/null || true
        safe_copy "$target" "${dest_root}${target}"
    else
        safe_copy "$bin" "${dest_root}${bin}"
    fi
    if ldd "$bin" >/dev/null 2>&1; then
        ldd "$bin" | awk '/=>/ {print $(NF-1)} /ld-linux/ {print $1}' | while read -r lib; do
            [[ -z "$lib" ]] && continue
            [[ -f "$lib" ]] || continue
            safe_copy "$lib" "${dest_root}${lib}"
            if [[ -L "$lib" ]]; then
                tgt=$(readlink -f "$lib")
                safe_copy "$tgt" "${dest_root}${tgt}"
            fi
        done
    fi
}

create_dev_nodes() {
    local dst="$1"
    mkdir -p "${dst}/dev"
    [[ -e "${dst}/dev/null" ]] || mknod -m 666 "${dst}/dev/null" c 1 3 2>/dev/null || true
    [[ -e "${dst}/dev/console" ]] || mknod -m 600 "${dst}/dev/console" c 5 1 2>/dev/null || true
    [[ -e "${dst}/dev/tty0" ]] || mknod -m 666 "${dst}/dev/tty0" c 4 0 2>/dev/null || true
}

copy_kernel_modules() {
    local kernel_ver="$1"; local dest_root="$2"; local -n modules_ref=$3
    local moddir="/lib/modules/${kernel_ver}"
    if [[ ! -d "$moddir" ]]; then
        logmsg WARN "Module dir not found: ${moddir}"
        return 0
    fi
    mkdir -p "${dest_root}${moddir}"
    if ((${#modules_ref[@]} == 0)); then
        modules_ref=(ext4 xfs btrfs vfat ntfs sd_mod ahci nvme nvme_core usb_storage)
    fi
    for m in "${modules_ref[@]}"; do
        if command -v modinfo >/dev/null 2>&1; then
            mfile=$(modinfo -F filename "$m" 2>/dev/null || true)
            if [[ -n "$mfile" && -f "$mfile" ]]; then
                safe_copy "$mfile" "${dest_root}${mfile}"
                if command -v modprobe >/dev/null 2>&1; then
                    modprobe --show-depends "$m" 2>/dev/null | awk '{print $1}' | while read -r depf; do
                        [[ -z "$depf" ]] && continue
                        [[ -f "$depf" ]] || continue
                        safe_copy "$depf" "${dest_root}${depf}"
                    done || true
                fi
            else
                logmsg WARN "module $m not found via modinfo"
            fi
        else
            logmsg WARN "modinfo not available; skipping module resolution for $m"
        fi
    done
}

# detect modules from rootfs/etc/fstab and /proc/modules
detect_modules_from_fstab_and_proc() {
    local rootfs="$1"
    local -n outmods=$2
    outmods=()

    # map common fstype -> module
    declare -A f2m=(
        [ext4]=ext4 [xfs]=xfs [btrfs]=btrfs [vfat]=vfat [ntfs]=ntfs
        [overlay]=overlay [zfs]=zfs [nfs]=nfs client [fuse]=fuse
    )

    # parse /etc/fstab in rootfs if exists
    if [[ -f "${rootfs}/etc/fstab" ]]; then
        awk '$1 !~ /^#/ {print $3}' "${rootfs}/etc/fstab" | while read -r fs; do
            [[ -z "$fs" ]] && continue
            if [[ -n "${f2m[$fs]:-}" ]]; then
                outmods+=("${f2m[$fs]}")
            fi
        done
    fi

    # parse /proc/modules for currently loaded modules
    if [[ -r /proc/modules ]]; then
        awk '{print $1}' /proc/modules | while read -r m; do
            [[ -z "$m" ]] && continue
            outmods+=("$m")
        done
    fi

    # also include user-specified extras
    for e in "${EXTRA_MODULES[@]}"; do
        outmods+=("$e")
    done

    # dedupe
    if ((${#outmods[@]})); then
        # uniq preserving order
        local seen=()
        local uniq=()
        for m in "${outmods[@]}"; do
            if [[ -z "${seen[$m]:-}" ]]; then
                uniq+=("$m")
                seen[$m]=1
            fi
        done
        outmods=("${uniq[@]}")
    fi
}

generate_init_script() {
    local dst="$1"
    cat > "${dst}/init" <<'EOF'
#!/bin/sh
PATH=/bin:/sbin
export PATH
echo "ADM initramfs: starting"
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /tmp /run
mount -t tmpfs tmpfs /run 2>/dev/null || true

if [ -f /modules.load ]; then
    while read -r m; do
        [ -n "$m" ] && /sbin/modprobe "$m" 2>/dev/null || true
    done < /modules.load
fi

rootdev=$(sed -n 's/.*root=\([^ ]*\).*/\1/p' /proc/cmdline || true)
[ -n "$rootdev" ] || rootdev="/dev/sda1"
mkdir -p /new_root
echo "Attempt mounting $rootdev ..."
if mount -o ro "$rootdev" /new_root 2>/dev/null; then
    if [ -x /new_root/sbin/init ]; then
        exec switch_root /new_root /sbin/init
    elif [ -x /new_root/bin/sh ]; then
        exec chroot /new_root /bin/sh
    else
        exec /bin/sh
    fi
else
    echo "Failed to mount root ($rootdev), dropping to shell"
    exec /bin/sh
fi
EOF
    chmod 0755 "${dst}/init"
}

write_banner() {
    local dst="$1"; local kernel="$2"; local profile="$3"
    cat > "${dst}/banner.txt" <<EOF
ADM Initramfs
Kernel: ${kernel}
Profile: ${profile}
Generated: $(_ts)
EOF
}

# manifest generation
generate_manifest() {
    local tree="$1"; local out="$2"
    : > "$out"
    (cd "$tree" && find . -type f | sort) | while read -r rel; do
        f="${tree}/${rel#./}"
        size=$(stat -c%s "$f" 2>/dev/null || echo 0)
        sha=$(sha256sum "$f" 2>/dev/null | awk '{print $1}' || echo "")
        printf "%s\t%s\t%s\n" "${rel#./}" "$size" "$sha" >> "$out"
    done
}

create_cpio_archive() {
    local tree="$1"; local out="$2"
    (cd "$tree" && find . -print0 | cpio --null -ov --format=newc > "$out")
}

compress_initramfs() {
    local src="$1"; local out="$2"; local comp="$3"
    case "$comp" in
        zstd) zstd -19 -T0 -c "$src" > "$out" ;;
        xz)  xz -T0 -c "$src" > "$out" ;;
        lz4) lz4 -c "$src" > "$out" ;;
        gzip) gzip -c "$src" > "$out" ;;
        none) cp -a "$src" "$out" ;;
        *) zstd -19 -T0 -c "$src" > "$out";;
    esac
}

install_image_to_boot() {
    local img="$1"; local kernel="$2"; local profile="$3"
    local base="initramfs-${kernel}-${profile}.img"
    local dest="${BOOT_DIR}/${base}"
    if [[ -f "$dest" && "$DO_BACKUP" -eq 1 ]]; then
        local ts=$(_now)
        mkdir -p "$BACKUP_DIR"
        cp -a "$dest" "${BACKUP_DIR}/${base}.${ts}" || true
        logmsg INFO "Backup saved to ${BACKUP_DIR}/${base}.${ts}"
    fi
    mv -f "$img" "$dest"
    logmsg INFO "Installed initramfs to ${dest}"
    echo "$dest"
}

# create hook installer
install_post_update_hook() {
    local hookpath="${HOOK_DIR}/post-update"
    cat > "$hookpath" <<'SH'
#!/usr/bin/env bash
# post-update hook to regenerate initramfs if kernel updated
# args: original_call_args forwarded by call_hook
# This simple hook will attempt to detect if a kernel update happened by reading logs or by checking
# if /boot has a new vmlinuz. As heuristic, call mkinitramfs for current running kernel.

MKINIT="/usr/src/adm/scripts/mkinitramfs.sh"
if [[ -x "$MKINIT" ]]; then
    echo "post-update: regenerating initramfs (hook)" >&2
    # attempt to detect kernel from /boot newest vmlinuz, fallback to uname -r
    ker=$(ls -1t /boot/vmlinuz-* 2>/dev/null | head -n1 || true)
    if [[ -n "$ker" ]]; then
        ker_base=$(basename "$ker" | sed 's/^vmlinuz-//')
    else
        ker_base="$(uname -r)"
    fi
    # call mkinitramfs in background (non-blocking) to avoid blocking update.sh
    "$MKINIT" --kernel "$ker_base" --quiet --no-backup >/dev/null 2>&1 &
else
    echo "mkinitramfs not found at $MKINIT" >&2
fi
SH
    chmod 0755 "$hookpath"
    logmsg INFO "Installed post-update hook at $hookpath"
}

# ---- CLI parse ----
ARGS=()
while (( "$#" )); do
    case "$1" in
        --kernel) KERNEL="$2"; shift 2;;
        --root) ROOTFS="$2"; shift 2;;
        --compress) COMPRESS="$2"; shift 2;;
        --modules) IFS=' ' read -r -a EXTRA_MODULES <<< "$2"; shift 2;;
        --rebuild) REBUILD=1; shift;;
        --no-backup) DO_BACKUP=0; shift;;
        --update-bootloader) UPDATE_BOOTLOADER=1; shift;;
        --quiet) QUIET=1; shift;;
        --debug) DEBUG=1; shift;;
        --keep-tmp) KEEP_TMP=1; shift;;
        --dry-run) DRY_RUN=1; shift;;
        --install-hook) INSTALL_HOOK=1; shift;;
        --help|-h)
            cat <<EOF
Usage: mkinitramfs.sh [options]
Options:
  --kernel <ver>       : kernel version to build for (default: uname -r)
  --root <path>        : use alternative root (default /)
  --compress <alg>     : zstd,xz,gzip,lz4,none
  --modules "m1 m2"    : include extra modules
  --rebuild            : regenerate even if image exists
  --no-backup          : don't backup previous image
  --update-bootloader  : try to update grub
  --keep-tmp           : keep temporary dir
  --dry-run            : simulate actions, do not write /boot
  --install-hook       : install post-update hook to auto-create initramfs after kernel update
EOF
            exit 0
            ;;
        *) ARGS+=("$1"); shift;;
    esac
done

# install hook if requested and exit
if [[ "$INSTALL_HOOK" -eq 1 ]]; then
    install_post_update_hook
    exit 0
fi

# determine kernel & profile
if [[ -z "$KERNEL" ]]; then
    KERNEL="$(uname -r 2>/dev/null || true)"
    [[ -n "$KERNEL" ]] || die "unable to detect kernel version"
fi

PROFILE_ACTIVE="default"
if [[ -L "${ADM_ROOT:-/usr/src/adm}/state/current.profile" ]]; then
    PROFILE_ACTIVE=$(basename "$(readlink -f "${ADM_ROOT:-/usr/src/adm}/state/current.profile")" .profile 2>/dev/null || echo "default")
fi

COMPRESS=$(which_compressor "$COMPRESS")
logmsg INFO "Compressor: $COMPRESS"
TS=$(_now)

# choose working dir (dry-run separated)
if [[ "$DRY_RUN" -eq 1 ]]; then
    WORK_DIR="${WORK_BASE}/initramfs-tmp-dryrun-${TS}"
else
    WORK_DIR="${WORK_ROOT}"
fi

MANIFEST_TMP="${WORK_DIR}/${MANIFEST_NAME}"
IMG_TMP="${WORK_DIR}/initramfs-${KERNEL}-${PROFILE_ACTIVE}.cpio"
IMG_FINAL_TMP="${WORK_DIR}/initramfs-${KERNEL}-${PROFILE_ACTIVE}.img.tmp"
LOGFILE="${LOG_DIR}/mkinitramfs-${TS}.log"

logmsg INFO "mkinitramfs starting for kernel=${KERNEL}, profile=${PROFILE_ACTIVE}, root=${ROOTFS}, dry-run=${DRY_RUN}"

run_hook_if_exists "pre-mkinitramfs"

# cleanup or create workdir
if [[ "$REBUILD" -eq 1 && -d "$WORK_DIR" ]]; then rm -rf "$WORK_DIR"; fi
mkdir -p "$WORK_DIR"
umask 022

# prepare base structure
mkdir -p "${WORK_DIR}/"{bin,sbin,etc,proc,sys,usr,lib,lib64,dev,tmp,run}

create_dev_nodes "$WORK_DIR"

# minimal binaries: busybox preferred
BINS_TO_INCLUDE=()
if command -v busybox >/dev/null 2>&1; then
    BINS_TO_INCLUDE+=("/bin/busybox")
    for app in sh mount umount switch_root chroot ls cat echo mkdir rm rmdir ln modprobe; do
        ln -sf /bin/busybox "${WORK_DIR}/bin/${app}" 2>/dev/null || true
    done
else
    for cmd in sh mount umount switch_root chroot ls cat echo mkdir rm rmdir ln modprobe; do
        p=$(command -v "$cmd" 2>/dev/null || true)
        [[ -n "$p" ]] && BINS_TO_INCLUDE+=("$p")
    done
fi

# ensure switch_root
if [[ ! -e "${WORK_DIR}/sbin/switch_root" ]]; then
    sr=$(command -v switch_root 2>/dev/null || true)
    if [[ -n "$sr" ]]; then
        copy_binary_and_libs "$sr" "$WORK_DIR"
        mkdir -p "${WORK_DIR}/sbin"
        ln -sf "$(basename "$sr")" "${WORK_DIR}/sbin/switch_root" 2>/dev/null || true
    fi
fi

for b in "${BINS_TO_INCLUDE[@]}"; do
    [[ -n "$b" && -e "$b" ]] || continue
    mkdir -p "$(dirname "${WORK_DIR}${b}")"
    safe_copy "$b" "${WORK_DIR}${b}"
    copy_binary_and_libs "$b" "$WORK_DIR"
done

[[ -f "${ROOTFS}/etc/resolv.conf" ]] && { mkdir -p "${WORK_DIR}/etc"; safe_copy "${ROOTFS}/etc/resolv.conf" "${WORK_DIR}/etc/resolv.conf"; }

# modules detection: from fstab and /proc/modules, plus extras
DETECTED_MODULES=()
detect_modules_from_fstab_and_proc "$ROOTFS" DETECTED_MODULES
if ((${#DETECTED_MODULES[@]})); then
    logmsg INFO "Detected modules from fstab/proc/modules: ${DETECTED_MODULES[*]}"
fi

# merge with EXTRA_MODULES
for m in "${EXTRA_MODULES[@]}"; do DETECTED_MODULES+=("$m"); done
# dedupe
if ((${#DETECTED_MODULES[@]})); then
    declare -A seen; uniq=()
    for m in "${DETECTED_MODULES[@]}"; do
        [[ -z "${seen[$m]:-}" ]] && { uniq+=("$m"); seen[$m]=1; }
    done
    DETECTED_MODULES=("${uniq[@]}")
fi

# copy modules transactionally (or simulate in dry-run)
if [[ "$DRY_RUN" -eq 1 ]]; then
    logmsg INFO "[DRY-RUN] Modules to copy: ${DETECTED_MODULES[*]}"
else
    copy_kernel_modules "$KERNEL" "$WORK_DIR" DETECTED_MODULES
fi

# write modules.load
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "${DETECTED_MODULES[*]}" > "${WORK_DIR}/modules.load"
else
    write_modules_load "${WORK_DIR}/modules.load" "${DETECTED_MODULES[@]}"
fi

generate_init_script "$WORK_DIR"
write_banner "$WORK_DIR" "$KERNEL" "$PROFILE_ACTIVE"

# manifest
generate_manifest "$WORK_DIR" "$MANIFEST_TMP"

# create cpio
logmsg INFO "Creating cpio..."
if [[ -f "$IMG_TMP" ]]; then rm -f "$IMG_TMP"; fi
create_cpio_archive "$WORK_DIR" "$IMG_TMP"

# compress
logmsg INFO "Compressing with $COMPRESS..."
compress_initramfs "$IMG_TMP" "$IMG_FINAL_TMP" "$COMPRESS"

# install or simulate install
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] Would install initramfs to /boot as initramfs-${KERNEL}-${PROFILE_ACTIVE}.img"
    echo "[DRY-RUN] Manifest would be placed at /boot/initramfs-${KERNEL}-${PROFILE_ACTIVE}.manifest"
    # keep temp for inspection if requested
    if [[ "$KEEP_TMP" -ne 1 ]]; then
        rm -rf "$WORK_DIR"
    else
        logmsg INFO "Dry-run kept workdir at ${WORK_DIR} for inspection"
    fi
    run_hook_if_exists "post-mkinitramfs" "$IMG_FINAL_TMP" "$MANIFEST_TMP"
    logmsg INFO "Dry-run finished"
    exit 0
fi

DEST_IMG=$(install_image_to_boot "$IMG_FINAL_TMP" "$KERNEL" "$PROFILE_ACTIVE")
MANIFEST_DEST="${BOOT_DIR}/initramfs-${KERNEL}-${PROFILE_ACTIVE}.manifest"
mv -f "$MANIFEST_TMP" "$MANIFEST_DEST" || true

# logging
{
    echo "mkinitramfs run: $(_ts)"
    echo "kernel: $KERNEL"
    echo "profile: $PROFILE_ACTIVE"
    echo "image: $DEST_IMG"
    echo "manifest: $MANIFEST_DEST"
    echo "compressor: $COMPRESS"
    echo "modules: ${DETECTED_MODULES[*]}"
} >> "$LOGFILE"
logmsg INFO "Log written to ${LOGFILE}"

run_hook_if_exists "post-mkinitramfs" "$DEST_IMG" "$MANIFEST_DEST"

# optional update grub (best-effort)
if [[ "$UPDATE_BOOTLOADER" -eq 1 ]]; then
    if command -v update-grub >/dev/null 2>&1; then
        update-grub || logmsg WARN "update-grub failed"
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        grub-mkconfig -o /boot/grub/grub.cfg || logmsg WARN "grub-mkconfig failed"
    else
        logmsg WARN "No grub tool found; skip GRUB update"
    fi
fi

if [[ "$KEEP_TMP" -eq 0 ]]; then
    rm -rf "$WORK_DIR"
else
    logmsg INFO "Temporary workdir retained at ${WORK_DIR}"
fi

logmsg INFO "mkinitramfs completed successfully: ${DEST_IMG}"
exit 0
