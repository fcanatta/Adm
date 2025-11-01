#!/usr/bin/env bash
# /usr/src/adm/scripts/mkinitramfs.sh
# mkinitramfs manager for ADM Build System
# - Robust, idempotent, logs, hooks, auto-rebuild on kernel or bootstrap changes
# - Integrates with bootstrap via /usr/src/adm/state/bootstrap.state
set -euo pipefail
IFS=$'\n\t'

# ---- try to source lib.sh for logging and helpers ----
if [ -n "${ADM_SCRIPTS_DIR-}" ] && [ -f "${ADM_SCRIPTS_DIR}/lib.sh" ]; then
  # shellcheck disable=SC1090
  source "${ADM_SCRIPTS_DIR}/lib.sh"
else
  # Minimal logging fallbacks
  COL_RESET="\033[0m"; COL_INFO="\033[1;34m"; COL_OK="\033[1;32m"; COL_WARN="\033[1;33m"; COL_ERR="\033[1;31m"
  info(){ printf "%b[INFO]%b  %s\n" "${COL_INFO}" "${COL_RESET}" "$*"; }
  ok(){ printf "%b[ OK ]%b  %s\n" "${COL_OK}" "${COL_RESET}" "$*"; }
  warn(){ printf "%b[WARN]%b  %s\n" "${COL_WARN}" "${COL_RESET}" "$*"; }
  err(){ printf "%b[ERR ]%b  %s\n" "${COL_ERR}" "${COL_RESET}" "$*"; }
  fatal(){ printf "%b[FATAL]%b %s\n" "${COL_ERR}" "${COL_RESET}" "$*"; exit 1; }
fi

# ---- configuration (can be overridden by environment) ----
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_SCRIPTS_DIR="${ADM_SCRIPTS_DIR:-${ADM_ROOT}/scripts}"
ADM_LOGS="${ADM_LOGS:-${ADM_ROOT}/logs}"
ADM_STATE="${ADM_STATE:-${ADM_ROOT}/state}"
ADM_BOOT_DIR="${ADM_BOOT_DIR:-/boot}"
ADM_INITRAMFS_DIR="${ADM_INITRAMFS_DIR:-${ADM_ROOT}/initramfs}"
ADM_HOOKS_DIR="${ADM_HOOKS_DIR:-${ADM_ROOT}/hooks/initramfs.d}"
ADM_TMP_BASE="${ADM_TMP_BASE:-${ADM_ROOT}/tmp/initramfs}"
ADM_PROFILE="${ADM_PROFILE:-${ADM_PROFILE:-performance}}"
ADM_INITRAMFS_COMPRESS="${ADM_INITRAMFS_COMPRESS:-xz}"
ADM_KEEP_INITRAMFS="${ADM_KEEP_INITRAMFS:-3}"
ADM_STRIP_BINARIES="${ADM_STRIP_BINARIES:-1}"
ADM_DEBUG_INITRAMFS="${ADM_DEBUG_INITRAMFS:-0}"
REQUIRED_CMDS=(cpio find xargs stat uname awk mktemp sha256sum)

# ---- derived ---
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOGFILE="${ADM_LOGS}/mkinitramfs-${TIMESTAMP}.log"
mkdir -p "${ADM_LOGS}" "${ADM_STATE}" "${ADM_TMP_BASE}" "${ADM_HOOKS_DIR}" "${ADM_INITRAMFS_DIR}"
chmod 755 "${ADM_LOGS}" "${ADM_TMP_BASE}" "${ADM_INITRAMFS_DIR}" 2>/dev/null || true

# ---- traps and cleanup ----
TMPDIR=""
cleanup() {
  local rc=$?
  if [ -n "${TMPDIR}" ] && [ -d "${TMPDIR}" ]; then
    info "Cleaning temporary dir: ${TMPDIR}"
    rm -rf "${TMPDIR}" || warn "Failed to remove ${TMPDIR}"
  fi
  # log exit reason
  if [ "$rc" -ne 0 ]; then
    err "mkinitramfs exited with code ${rc} (see ${LOGFILE})"
  fi
}
trap cleanup EXIT INT TERM

# ---- utility helpers ----
_safe_run() {
  # run command, log stdout/stderr to logfile; on failure print brief and exit
  # usage: _safe_run "desc" cmd args...
  local desc="$1"; shift
  printf "\n--- %s (%s) ---\n" "$desc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${LOGFILE}"
  if ! "$@" >> "${LOGFILE}" 2>&1; then
    err "${desc} failed (see ${LOGFILE})"
    return 1
  else
    ok "${desc}"
    return 0
  fi
}

require_commands() {
  local miss=0
  for c in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      warn "Missing required command: $c"
      miss=1
    fi
  done
  # check optional compressors when selected
  case "${ADM_INITRAMFS_COMPRESS}" in
    xz) command -v xz >/dev/null 2>&1 || { warn "xz not found"; miss=1; } ;;
    zstd) command -v zstd >/dev/null 2>&1 || { warn "zstd not found"; miss=1; } ;;
    lz4) command -v lz4 >/dev/null 2>&1 || { warn "lz4 not found"; miss=1; } ;;
    gzip) command -v gzip >/dev/null 2>&1 || { warn "gzip not found"; miss=1; } ;;
  esac
  [ $miss -eq 0 ] || fatal "One or more required commands missing; install them and retry"
}

hexdigest() { sha256sum "$1" | awk '{print $1}'; }

check_space() {
  # ensure at least min_space MB free on mountpoint of ADM_BOOT_DIR
  local min_mb="${1:-200}"
  local mount=$(df -P "${ADM_BOOT_DIR}" | awk 'NR==2{print $4}')
  local free_kb=$((mount))
  local free_mb=$((free_kb/1024))
  if [ "$free_mb" -lt "$min_mb" ]; then
    fatal "Not enough free space on ${ADM_BOOT_DIR} (${free_mb}MB < ${min_mb}MB). Aborting."
  fi
}

# determine kernel version (default to running kernel)
detect_kernel() {
  local k="${1:-}"
  if [ -n "$k" ]; then
    if [ -d "/lib/modules/${k}" ]; then
      echo "$k"
      return 0
    else
      fatal "Specified kernel modules not found: /lib/modules/${k}"
    fi
  fi
  uname -r
}

# last-record helpers
state_write() {
  mkdir -p "${ADM_STATE}"
  printf "%s\n" "$2" > "${ADM_STATE}/$1"
}
state_read() {
  local f="${ADM_STATE}/$1"
  [ -f "$f" ] && cat "$f" || echo ""
}

# record initramfs metadata
record_initramfs_state() {
  local kernel="$1" path="$2" sha="$3" size="$4"
  mkdir -p "${ADM_STATE}"
  printf "kernel=%s\npath=%s\nsha256=%s\nsize=%s\ntimestamp=%s\n" "$kernel" "$path" "$sha" "$size" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${ADM_STATE}/initramfs-${kernel}.meta"
  # update symlink to current
  ln -sf "${ADM_STATE}/initramfs-${kernel}.meta" "${ADM_STATE}/current.initramfs.meta" || true
  ok "Recorded initramfs state for ${kernel}"
}

run_hooks() {
  local phase="$1"
  if [ -d "${ADM_HOOKS_DIR}" ]; then
    for h in "${ADM_HOOKS_DIR}"/*; do
      [ -x "$h" ] || continue
      case "$(basename "$h")" in
        *.sh) info "Running hook ${phase}: $h"; "$h" "${phase}" >> "${LOGFILE}" 2>&1 || warn "Hook failed: $h";;
      esac
    done
  fi
}

copy_with_deps() {
  # copy a binary and its required shared libs into $TMPDIR (preserving dir structure)
  local bin="$1"
  [ -f "$bin" ] || { warn "Binary not found: $bin"; return 1; }
  local destroot="$2"
  local rel
  rel="/$(basename "$bin")" # We'll place under bin or sbin based on path supplied by caller
  # ensure parent dirs
  mkdir -p "${destroot}$(dirname "$bin")"
  cp -a --parents "$bin" "${destroot}" || return 1
  # ldd libs
  if command -v ldd >/dev/null 2>&1; then
    local libs
    libs=$(ldd "$bin" 2>/dev/null | awk '/=>/ {print $3} /ld-linux/ {print $1}' | sort -u || true)
    for lib in $libs; do
      [ -z "$lib" ] && continue
      mkdir -p "${destroot}$(dirname "$lib")"
      cp -a "$lib" "${destroot}${lib}" 2>/dev/null || true
    done
  fi
  return 0
}

generate_init_script() {
  local out="$1"
  cat > "${out}" <<'INIT_SH'
#!/bin/sh
# basic /init for initramfs created by ADM
set -e
echo "[initramfs] starting init..."
mount -t proc proc /proc || true
mount -t sysfs sys /sys || true
mount -t devtmpfs devtmpfs /dev || true
# run pre-init hooks
for h in /hooks/*.sh; do [ -x "$h" ] && "$h" pre-init; done 2>/dev/null || true
# optionally wait for root device (simple heuristic)
ROOT_LABEL="root"
rootdev=$(blkid -L "$ROOT_LABEL" 2>/dev/null || echo "")
if [ -z "$rootdev" ]; then
  # fallback to first /dev/sd*1 or /dev/nvme0n1p1
  for d in /dev/nvme* /dev/sd*; do
    [ -b "$d" ] || continue
    # prefer partitions
    if echo "$d" | grep -qE 'p[0-9]+$'; then rootdev="$d"; break; fi
  done
fi
if [ -n "$rootdev" ]; then
  echo "[initramfs] mounting root ${rootdev} -> /newroot"
  mkdir -p /newroot
  mount "$rootdev" /newroot || { echo "[initramfs] root mount failed"; /bin/sh; }
else
  echo "[initramfs] Could not determine root device; dropping to shell"
  /bin/sh
fi
# run post-init hooks
for h in /hooks/*.sh; do [ -x "$h" ] && "$h" post-init; done 2>/dev/null || true
# switch root
if [ -x /sbin/init ]; then
  exec switch_root /newroot /sbin/init || exec chroot /newroot /sbin/init
else
  echo "[initramfs] no /sbin/init found in newroot; dropping to shell"
  /bin/sh
fi
INIT_SH
  chmod 755 "${out}"
}

build_initramfs_for_kernel() {
  local kernel="$1"
  # validate modules dir
  local modules_dir="/lib/modules/${kernel}"
  [ -d "${modules_dir}" ] || fatal "Kernel modules directory not found: ${modules_dir}"

  # create temp workdir
  TMPDIR="$(mktemp -d "${ADM_TMP_BASE}/initramfs-${kernel}.XXXXXXXX")"
  info "Using temporary build dir: ${TMPDIR}"
  mkdir -p "${TMPDIR}"/{bin,sbin,usr/bin,usr/sbin,lib,lib64,dev,proc,sys,run,etc,newroot,hooks}
  chmod 755 "${TMPDIR}"*

  # run pre hooks
  run_hooks pre-build

  # choose busybox vs full tools
  if [ -x /bin/busybox ]; then
    mkdir -p "${TMPDIR}/bin"
    cp -a /bin/busybox "${TMPDIR}/bin/" || fatal "Failed copying busybox"
    (cd "${TMPDIR}/bin" && for l in $(./busybox --list); do ln -sf busybox "$l"; done) || true
    ok "Included busybox"
  else
    # copy essential commands (list may be extended)
    local essentials=(/bin/mount /bin/ls /bin/cat /bin/echo /bin/sh /sbin/modprobe /sbin/udevadm /sbin/blkid /sbin/switch_root /bin/mkdir /bin/mv /bin/rm)
    for e in "${essentials[@]}"; do
      if [ -x "$e" ]; then
        copy_with_deps "$e" "${TMPDIR}" || warn "Failed to copy $e"
      else
        warn "Essential binary not found: $e"
      fi
    done
  fi

  # copy kernel modules (selected set)
  info "Copying kernel modules for ${kernel} ..."
  mkdir -p "${TMPDIR}/lib/modules/${kernel}"
  # include key module categories (may be tuned)
  local modlist=(ext4 xfs btrfs vfat squashfs sd_mod ahci nvme nvme_core virtio_blk dm_mod dm_crypt crc32c)
  for m in "${modlist[@]}"; do
    find "${modules_dir}" -type f -name "${m}*.ko*" -exec cp --parents -t "${TMPDIR}" '{}' + 2>/dev/null || true
  done
  # also copy any module dependencies (depmod)
  if command -v depmod >/dev/null 2>&1; then
    _safe_run "depmod for initramfs" depmod -b "${TMPDIR}" "${kernel}"
  fi

  # copy hooks if present in hooks dir
  if [ -d "${ADM_HOOKS_DIR}" ]; then
    cp -a "${ADM_HOOKS_DIR}/." "${TMPDIR}/hooks/" 2>/dev/null || true
    chmod -R 755 "${TMPDIR}/hooks" 2>/dev/null || true
  fi

  # create /init
  generate_init_script "${TMPDIR}/init"
  # strip binaries if requested
  if [ "${ADM_STRIP_BINARIES}" = "1" ] && command -v strip >/dev/null 2>&1; then
    info "Stripping binaries inside initramfs (may reduce size)..."
    find "${TMPDIR}" -type f -executable -exec strip --strip-unneeded {} + 2>/dev/null || true
  fi

  # ensure there is enough space on target
  check_space 100

  # build cpio and compress
  local outname="initramfs-${kernel}.img"
  local outtmp="${ADM_BOOT_DIR}/${outname}.part"
  local outfinal="${ADM_BOOT_DIR}/${outname}"
  info "Building initramfs (compress=${ADM_INITRAMFS_COMPRESS})..."
  case "${ADM_INITRAMFS_COMPRESS}" in
    xz)
      _safe_run "pack cpio | xz" sh -c "(cd \"${TMPDIR}\" && find . -print0 | xargs -0 cpio -H newc -o ) | xz -T0 -9 > \"${outtmp}\""
      ;;
    zstd)
      _safe_run "pack cpio | zstd" sh -c "(cd \"${TMPDIR}\" && find . -print0 | xargs -0 cpio -H newc -o ) | zstd -T0 -19 -o \"${outtmp}\""
      ;;
    gzip)
      _safe_run "pack cpio | gzip" sh -c "(cd \"${TMPDIR}\" && find . -print0 | xargs -0 cpio -H newc -o ) | gzip -9 > \"${outtmp}\""
      ;;
    lz4)
      _safe_run "pack cpio | lz4" sh -c "(cd \"${TMPDIR}\" && find . -print0 | xargs -0 cpio -H newc -o ) | lz4 -9 - \"${outtmp}\""
      ;;
    *)
      fatal "Unsupported compression: ${ADM_INITRAMFS_COMPRESS}"
      ;;
  esac

  # atomic move into place
  mv -f "${outtmp}" "${outfinal}"
  chmod 644 "${outfinal}" 2>/dev/null || true
  ok "Created initramfs: ${outfinal}"

  # compute sha and size
  local fsize sha
  fsize=$(stat -c%s "${outfinal}")
  sha=$(hexdigest "${outfinal}")
  record_initramfs_state "${kernel}" "${outfinal}" "${sha}" "${fsize}"

  run_hooks post-build

  # cleanup tmpdir now (but kept for debug if ADM_DEBUG_INITRAMFS=1)
  if [ "${ADM_DEBUG_INITRAMFS}" -eq 0 ]; then
    rm -rf "${TMPDIR}" || warn "Failed to remove tmpdir ${TMPDIR}"
    TMPDIR=""
  else
    info "Debug mode: preserving tmpdir ${TMPDIR}"
  fi

  # rotate old initramfs images
  rotate_initramfs
}

rotate_initramfs() {
  # keep last N versions
  local keep="${ADM_KEEP_INITRAMFS}"
  local images
  images=$(ls -1t "${ADM_BOOT_DIR}"/initramfs-*.img 2>/dev/null || true)
  local count=0
  for img in ${images}; do
    count=$((count+1))
    if [ "$count" -gt "$keep" ]; then
      rm -f "$img" && info "Removed old initramfs: $img"
    fi
  done
}

auto_rebuild_on_events() {
  # check kernel change or bootstrap change and rebuild automatically
  local last_kernel; last_kernel="$(state_read last.kernel)"
  local cur_kernel; cur_kernel="$(uname -r)"
  local last_bootstrap; last_bootstrap="$(state_read last.bootstrap)"
  local current_bootstrap; current_bootstrap="$( [ -f "${ADM_STATE}/bootstrap.state" ] && stat -c %Y "${ADM_STATE}/bootstrap.state" || echo "" )"
  # if kernel changed or bootstrap timestamp changed -> rebuild
  if [ "$cur_kernel" != "$last_kernel" ]; then
    info "Kernel change detected: ${last_kernel} -> ${cur_kernel}"
    build_initramfs_for_kernel "${cur_kernel}"
    state_write last.kernel "${cur_kernel}"
  elif [ -n "${current_bootstrap}" ] && [ "$current_bootstrap" != "$last_bootstrap" ]; then
    info "Bootstrap change detected (timestamp changed). Rebuilding initramfs for ${cur_kernel} ..."
    build_initramfs_for_kernel "${cur_kernel}"
    state_write last.bootstrap "${current_bootstrap}"
  else
    info "No kernel or bootstrap changes detected (kernel=${cur_kernel})"
  fi
}

# command dispatchers
cmd_build() {
  local kernel="${1:-$(uname -r)}"
  kernel="$(detect_kernel "$kernel")"
  build_initramfs_for_kernel "${kernel}"
}

cmd_auto() {
  # initialize last.kernel if missing
  [ -f "${ADM_STATE}/last.kernel" ] || state_write last.kernel ""
  [ -f "${ADM_STATE}/last.bootstrap" ] || state_write last.bootstrap ""
  auto_rebuild_on_events
}

cmd_rebuild_all() {
  info "Rebuilding initramfs for all kernels found under /lib/modules..."
  for k in $(ls /lib/modules 2>/dev/null || true); do
    build_initramfs_for_kernel "$k"
  done
}

cmd_list() {
  ls -lh "${ADM_BOOT_DIR}"/initramfs-*.img 2>/dev/null || echo "No initramfs images in ${ADM_BOOT_DIR}"
  echo ""
  echo "Recorded metadata:"
  ls -1 "${ADM_STATE}"/initramfs-*.meta 2>/dev/null || echo "No initramfs metadata"
}

cmd_clean() {
  info "Cleaning temporary files under ${ADM_TMP_BASE}"
  rm -rf "${ADM_TMP_BASE}"/* 2>/dev/null || true
  ok "Cleaned"
}

cmd_check() {
  info "Verifying initramfs images SHA256 against recorded metadata..."
  for meta in "${ADM_STATE}"/initramfs-*.meta; do
    [ -f "$meta" ] || continue
    kernel="$(awk -F= '/^kernel=/{print $2}' "$meta")"
    path="$(awk -F= '/^path=/{print $2}' "$meta")"
    recorded_sha="$(awk -F= '/^sha256=/{print $2}' "$meta")"
    if [ ! -f "$path" ]; then
      warn "Image missing for kernel ${kernel}: ${path}"
      continue
    fi
    actual_sha="$(hexdigest "$path")"
    if [ "$actual_sha" != "$recorded_sha" ]; then
      warn "SHA mismatch for ${path}: recorded=${recorded_sha} actual=${actual_sha}"
    else
      ok "Verified ${path}"
    fi
  done
}

_show_help() {
  cat <<EOF
Usage: mkinitramfs.sh <command> [args]
Commands:
  build [kernel]     Build initramfs for a kernel (default: running kernel)
  auto               Check kernel/bootstrap events and rebuild if needed (for cron/hooks)
  rebuild-all        Rebuild for all /lib/modules/* kernels
  list               List generated initramfs images and metadata
  clean              Remove temporary build artifacts
  check              Validate SHA256 of generated images
  help               Show this help
Integration:
  - Will auto-rebuild when kernel changes or when ${ADM_STATE}/bootstrap.state timestamp changes.
  - build.sh or update.sh should call: bash ${ADM_SCRIPTS_DIR}/mkinitramfs.sh auto
EOF
}

# ---- validate environment and required commands ----
require_commands

# ---- dispatch ----
case "${1-}" in
  build) cmd_build "${2-}" ;;
  auto) cmd_auto ;;
  rebuild-all) cmd_rebuild_all ;;
  list) cmd_list ;;
  clean) cmd_clean ;;
  check) cmd_check ;;
  help|--help|-h|"") _show_help ;;
  *) fatal "Unknown command: ${1-:-<none>}. Use help." ;;
esac

exit 0
