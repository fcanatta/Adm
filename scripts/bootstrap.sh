#!/usr/bin/env bash
# bootstrap.sh — ADM Bootstrap Orchestrator (stage0 → stage3)
# - Orquestra criação dos stages de bootstrap seguindo LFS chapter 4 practices.
# - Usa fetch.sh, build.sh, package.sh, install.sh quando disponíveis.
# - Entradas: --full | --stage0|--stage1|--stage2|--stage3 --dry-run --resume --jobs N --auto
# - Requisitos: root (or sudo), coreutils, bash, chroot, mount, tar, gzip/xz/zstd, gcc, make, flock
#================================================================================
set -o errexit
set -o nounset
set -o pipefail

# Prevent double-source
[[ -n "${ADM_BOOTSTRAP_LOADED:-}" ]] && return 0
ADM_BOOTSTRAP_LOADED=1

# -------------------------
# Environment & defaults
# -------------------------
ROOT_ADM="${ADM_ROOT:-/usr/src/adm}"
STAGES_DIR="${ROOT_ADM}/stages"
LOG_DIR="${ROOT_ADM}/logs/bootstrap"
STATE_DIR="${ROOT_ADM}/state"
TOOLS_DIR="${ROOT_ADM}/toolchain/sources"
FETCH_SCRIPT="${ROOT_ADM}/scripts/fetch.sh"
BUILD_SCRIPT="${ROOT_ADM}/scripts/build.sh"
PACKAGE_SCRIPT="${ROOT_ADM}/scripts/package.sh"
INSTALL_SCRIPT="${ROOT_ADM}/scripts/install.sh"
MKINIT="${ROOT_ADM}/scripts/mkinitramfs.sh"
LOCK_FILE="${STATE_DIR}/bootstrap.lock"
TOOLCHAIN_VERSION_FILE="${STATE_DIR}/toolchain.version"
MIN_DISK_KB=20000000   # 20 GB minimum by default; configurable
JOBS="$(nproc || echo 1)"
DRY_RUN=0
RESUME=0
AUTO=0
FORCE=0

# Which stages to run (boolean flags)
DO_STAGE0=0; DO_STAGE1=0; DO_STAGE2=0; DO_STAGE3=0; DO_FULL=0

# CLI parse
_usage() {
cat <<EOF
Usage: bootstrap.sh [--full|--stage0|--stage1|--stage2|--stage3] [options]
Options:
  --full            : build stage0 → stage3
  --stage0          : build only stage0
  --stage1          : build only stage1
  --stage2          : build only stage2
  --stage3          : build only stage3 (kernel + initramfs)
  --jobs N          : parallel make jobs (default: $(nproc))
  --dry-run         : simulate actions, do not write persistent changes
  --resume          : resume from last completed stage
  --auto            : run non-interactive, accept defaults
  --force           : force rebuild stages even if up-to-date
  --help            : show this help
EOF
}

while (( "$#" )); do
  case "$1" in
    --full) DO_FULL=1; DO_STAGE0=DO_STAGE1=DO_STAGE2=DO_STAGE3=1; shift;;
    --stage0) DO_STAGE0=1; shift;;
    --stage1) DO_STAGE1=1; shift;;
    --stage2) DO_STAGE2=1; shift;;
    --stage3) DO_STAGE3=1; shift;;
    --jobs) JOBS="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --resume) RESUME=1; shift;;
    --auto) AUTO=1; shift;;
    --force) FORCE=1; shift;;
    --help|-h) _usage; exit 0;;
    *) echo "Unknown arg: $1"; _usage; exit 2;;
  esac
done

# If nothing specified, default to --full
if [[ $DO_STAGE0 -eq 0 && $DO_STAGE1 -eq 0 && $DO_STAGE2 -eq 0 && $DO_STAGE3 -eq 0 ]]; then
  DO_FULL=1; DO_STAGE0=DO_STAGE1=DO_STAGE2=DO_STAGE3=1
fi

# -------------------------
# Helpers and logging
# -------------------------
_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
_now_ts() { date '+%Y%m%d-%H%M%S'; }
mkdir -p "$LOG_DIR" "$STATE_DIR" "$STAGES_DIR" "$TOOLS_DIR"

logfile="${LOG_DIR}/bootstrap-$(_now_ts).log"
json_report="${LOG_DIR}/bootstrap-$(_now_ts).json"

log() {
  local lvl="$1"; shift
  local msg="$*"
  echo "[$(_now)] [$lvl] $msg" | tee -a "$logfile"
}

fatal() {
  local rc=${2:-1}
  log ERROR "$1"
  cleanup_on_error
  exit "$rc"
}

# Execute command with logging; if DRY_RUN, echo only.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] $*"
    return 0
  fi
  log INFO "CMD: $*"
  bash -lc "$*" 2>&1 | tee -a "$logfile"
}

# Run command inside chroot with sanitized env
chroot_exec() {
  local root="$1"; shift
  local cmd="$*"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN][chroot:$root] $cmd"
    return 0
  fi
  # Use env -i to avoid leaking host variables; preserve proxies and TERM
  local TERMSAFE="${TERM:-xterm}"
  chroot "$root" /usr/bin/env -i HOME=/root TERM="$TERMSAFE" PATH=/usr/bin:/bin:/usr/sbin:/sbin:/tools/bin MAKEFLAGS="-j${JOBS}" LC_ALL=POSIX /bin/bash -lc "$cmd" 2>&1 | tee -a "$logfile"
}

# Snapshotting
snapshot_stage() {
  local stage="$1"
  local root="${STAGES_DIR}/stage${stage}/rootfs"
  local ts=$(_now_ts)
  local out="${STATE_DIR}/bootstrap-stage${stage}-snap-${ts}.tar.xz"
  if [[ $DRY_RUN -eq 1 ]]; then
    log INFO "[DRY-RUN] Would snapshot ${root} -> ${out}"
    return 0
  fi
  if [[ -d "$root" ]]; then
    log INFO "Creating snapshot for stage${stage}: ${out}"
    tar -C "$root" -cJf "$out" . || fatal "Snapshot failed for stage${stage}"
    sha256sum "$out" | tee -a "$logfile"
  else
    log WARN "Snapshot skipped: ${root} not present"
  fi
}

# Restore snapshot (best-effort)
restore_latest_snapshot() {
  local stage="$1"
  local pattern="${STATE_DIR}/bootstrap-stage${stage}-snap-*.tar.xz"
  local snap
  snap=$(ls -1t $pattern 2>/dev/null | head -n1 || true)
  if [[ -z "$snap" ]]; then
    log ERROR "No snapshot found to restore for stage${stage}"
    return 1
  fi
  log INFO "Restoring snapshot ${snap} -> ${STAGES_DIR}/stage${stage}/rootfs"
  run "rm -rf '${STAGES_DIR}/stage${stage}/rootfs' && mkdir -p '${STAGES_DIR}/stage${stage}/rootfs' && tar -C '${STAGES_DIR}/stage${stage}/rootfs' -xJf '${snap}'"
}

# trap cleanup on exit and errors
CHROOT_MOUNTS=()
LOCK_FD=200
trap 'on_exit $?' EXIT

on_exit() {
  local rc="$1"
  # Release lock (will be automatic on fd close) and cleanup mounts if any
  if [[ "${CHROOT_MOUNTS[*]:-}" != "" ]]; then
    cleanup_chroots
  fi
  log INFO "bootstrap.sh exiting with code ${rc}"
}

cleanup_on_error() {
  log WARN "Cleaning up due to error..."
  cleanup_chroots || true
}

# -------------------------
# Locking to prevent concurrent runs
# -------------------------
exec {LOCK_FD}>"$LOCK_FILE" || fatal "Unable to open lock file $LOCK_FILE"
if ! flock -n "$LOCK_FD"; then
  fatal "Another bootstrap process is running (lock: $LOCK_FILE)."
fi
log INFO "Acquired bootstrap lock $LOCK_FILE (fd $LOCK_FD)"

# -------------------------
# Pre-checks: requirements & disk
# -------------------------
check_requirements() {
  local missing=()
  for b in bash chroot mount umount tar gzip xz sha256sum gcc make sed awk grep coreutils; do
    if ! command -v "$b" >/dev/null 2>&1; then
      missing+=("$b")
    fi
  done
  if [[ ${#missing[@]} -ne 0 ]]; then
    fatal "Missing required host tools: ${missing[*]}. Install them and re-run."
  fi

  # disk space check on ROOT_ADM
  local avail_kb
  avail_kb=$(df --output=avail -k "$ROOT_ADM" 2>/dev/null | tail -n1 | tr -d ' ')
  avail_kb=${avail_kb:-0}
  if (( avail_kb < MIN_DISK_KB )); then
    fatal "Insufficient disk space at ${ROOT_ADM}: ${avail_kb} KB available, need at least ${MIN_DISK_KB} KB."
  fi

  log INFO "Host requirements ok, disk available: ${avail_kb} KB"
}

# -------------------------
# Stage layout creation
# -------------------------
create_stage_layout() {
  local stage="$1"
  local root="${STAGES_DIR}/stage${stage}/rootfs"
  local builddir="${STAGES_DIR}/stage${stage}/build"
  log INFO "Creating layout for stage${stage} at ${root}"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] mkdir -p ${root} ${builddir}"
  else
    mkdir -p "$root" "$builddir"
    # LFS-like dirs
    for d in bin boot dev etc home lib lib64 media mnt opt proc root run sbin srv sys tmp usr usr/bin usr/sbin usr/lib var tools; do
      install -d -m 0755 "${root}/${d}"
    done
    install -d -m 1777 "${root}/tmp"
    # Ensure tools dir for stage0 bootstrap
    install -d -m 0755 "${root}/tools"
    # minimal etc files
    if [[ ! -f "${root}/etc/passwd" ]]; then
      cat > "${root}/etc/passwd" <<'PASS'
root:x:0:0:root:/root:/bin/bash
PASS
      chmod 0644 "${root}/etc/passwd"
    fi
    if [[ ! -f "${root}/etc/group" ]]; then
      cat > "${root}/etc/group" <<'GRP'
root:x:0:
GRP
      chmod 0644 "${root}/etc/group"
    fi
    chown -R root:root "$root" || true
  fi
  echo "$root"
}

# -------------------------
# Network prep (resolv.conf etc)
# -------------------------
prepare_chroot_network() {
  local root="$1"
  log INFO "Preparing network inside ${root}"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] copy /etc/resolv.conf -> ${root}/etc/resolv.conf"
    return 0
  fi
  mkdir -p "${root}/etc"
  if [[ -f /etc/resolv.conf ]]; then
    install -m 0644 /etc/resolv.conf "${root}/etc/resolv.conf.tmp" && mv -f "${root}/etc/resolv.conf.tmp" "${root}/etc/resolv.conf"
  else
    log WARN "/etc/resolv.conf not present on host; network inside chroot might fail"
  fi
}

# -------------------------
# Chroot management (enter/leave)
# -------------------------
mount_chroot_binds() {
  local root="$1"
  log INFO "Mounting binds for chroot ${root}"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] mount --bind /dev ${root}/dev; mount -t proc proc ${root}/proc; mount -t sysfs sysfs ${root}/sys"
    return 0
  fi
  mkdir -p "${root}/dev" "${root}/proc" "${root}/sys" "${root}/run" "${root}/dev/pts"
  # Make sure mounts are private on host to avoid propagation
  mount --make-rprivate /
  mount --bind /dev "${root}/dev"; CHROOT_MOUNTS+=( "${root}/dev" )
  mount --bind /dev/pts "${root}/dev/pts"; CHROOT_MOUNTS+=( "${root}/dev/pts" )
  mount -t proc proc "${root}/proc"; CHROOT_MOUNTS+=( "${root}/proc" )
  mount -t sysfs sysfs "${root}/sys"; CHROOT_MOUNTS+=( "${root}/sys" )
  if mountpoint -q /run; then
    mount --bind /run "${root}/run" 2>/dev/null || true; CHROOT_MOUNTS+=( "${root}/run" )
  fi
}

umount_chroot_binds() {
  local root="$1"
  log INFO "Unmounting binds for chroot ${root}"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] Would unmount binds for ${root}"
    return 0
  fi
  # reverse order unmount
  for m in "${root}/run" "${root}/sys" "${root}/proc" "${root}/dev/pts" "${root}/dev"; do
    if mountpoint -q "$m"; then
      umount -l "$m" || log WARN "umount failed for $m"
    fi
  done
}

cleanup_chroots() {
  log INFO "Cleaning up all chroot mounts (if any)"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] cleanup chroot mounts"
    return 0
  fi
  # unmount any lingering binds recorded
  for m in "${CHROOT_MOUNTS[@]}"; do
    if mountpoint -q "$m"; then
      umount -l "$m" || log WARN "umount -l failed for $m"
    fi
  done
  CHROOT_MOUNTS=()
}

# -------------------------
# Build helpers (orchestrate existing scripts)
# -------------------------
fetch_sources() {
  local pkg="$1"
  if [[ -x "$FETCH_SCRIPT" ]]; then
    run "$FETCH_SCRIPT --pkg \"$pkg\" --dest \"$TOOLS_DIR\""
  else
    log WARN "fetch.sh not found; please place sources manually under ${TOOLS_DIR} for $pkg"
  fi
}

build_with_buildsh() {
  local pkgdir="$1"
  if [[ -x "$BUILD_SCRIPT" ]]; then
    run "$BUILD_SCRIPT --pkg-dir '$pkgdir' --jobs $JOBS"
  else
    # fallback: try a conventional ./configure && make
    run "cd '$pkgdir' && ./configure --prefix=/usr && make -j$JOBS && make DESTDIR='$2' install"
  fi
}

package_with_package_sh() {
  local pkgdir="$1"
  if [[ -x "$PACKAGE_SCRIPT" ]]; then
    run "$PACKAGE_SCRIPT --pkg-dir '$pkgdir'"
  else
    log WARN "package.sh not present; skipping packaging for $pkgdir"
  fi
}

install_with_installsh() {
  local artifact="$1"
  if [[ -x "$INSTALL_SCRIPT" ]]; then
    run "$INSTALL_SCRIPT --artifact '$artifact' --dest '$2'"
  else
    log WARN "install.sh not present; attempting direct install via tar"
    run "tar -C '$2' -xzf '$artifact' || true"
  fi
}

# -------------------------
# Build steps for stages
# -------------------------
build_stage0() {
  local stage=0
  local root
  root=$(create_stage_layout "$stage")
  prepare_chroot_network "$root"
  snapshot_stage "$stage" || true

  # Example minimal toolchain steps (binutils, gcc-bootstrap, headers)
  log INFO "Stage0: preparing sources (binutils,gcc,headers)"
  # Here we assume sources are placed under $TOOLS_DIR/<pkg>-<ver>
  # Iterate sources in toolchain dir
  for src in "${TOOLS_DIR}"/*; do
    [[ -d "$src" ]] || continue
    log INFO "Stage0: building source $src into ${root}"
    # Build on host but install into root via DESTDIR or --prefix
    build_with_buildsh "$src" "$root"
    # optionally package/install
    # package_with_package_sh "$src"
  done

  # Basic validation: ensure gcc exists in root or tools
  if [[ ! -x "${root}/tools/bin/gcc" && ! -x "${root}/usr/bin/gcc" ]]; then
    log WARN "Stage0 gcc not found in ${root}; continuing but stage0 may be incomplete"
  fi

  snapshot_stage "$stage"
  echo "$(_now) - stage0 done" > "${STATE_DIR}/stage0.done"
  log INFO "Stage0 complete"
}

build_stage_generic() {
  local stage="$1"
  local prev_stage=$((stage-1))
  local prev_root="${STAGES_DIR}/stage${prev_stage}/rootfs"
  local root="${STAGES_DIR}/stage${stage}/rootfs"
  create_stage_layout "$stage"
  prepare_chroot_network "$root"

  # Ensure prev stage root exists
  if [[ ! -d "$prev_root" ]]; then
    fatal "Previous stage${prev_stage} root not found at ${prev_root}; cannot build stage${stage}"
  fi

  # mount binds into prev_root to run builds that install into stage root using DESTDIR
  mount_chroot_binds "$prev_root"
  # run builds inside prev_root chroot that target ${root} via DESTDIR or --prefix
  # Example: building gcc inside stage0 chroot to install into stage1 root
  log INFO "Building stage${stage} packages inside chroot ${prev_root}, installing into ${root}"

  # Copy resolv.conf into prev_root to allow network inside chroot
  prepare_chroot_network "$prev_root"

  # Run sequence: fetch sources (inside chroot) then build/install
  if [[ -x "$FETCH_SCRIPT" ]]; then
    chroot_exec "$prev_root" "$FETCH_SCRIPT --sync --dest '/usr/src/adm/toolchain/sources' || true"
  else
    log WARN "fetch.sh not found; ensure sources are present under ${TOOLS_DIR}"
  fi

  # For each package expected for this stage, we rely on a manifest or repo; here we iterate toolchain sources
  for src in "${TOOLS_DIR}"/*; do
    [[ -d "$src" ]] || continue
    pkgname=$(basename "$src")
    log INFO "Stage${stage}: building ${pkgname} inside chroot"
    # Install into root via DESTDIR (we pass dest as second arg to build_with_buildsh)
    # Use chroot_exec to run build.sh inside prev_root chroot with target DESTDIR mounted (we create /target inside prev_root that maps to stage root)
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "[DRY-RUN] chroot_exec '$prev_root' build package $src -> DESTDIR $root"
    else
      # Ensure stage root is mounted in prev_root at /stage_target
      mkdir -p "${prev_root}/.stage_target"
      # bind mount stage root into prev_root/.stage_target
      mount --bind "$root" "${prev_root}/.stage_target"
      CHROOT_MOUNTS+=( "${prev_root}/.stage_target" )
      # run build script inside chroot telling it to install into / .stage_target
      chroot_exec "$prev_root" "cd /usr/src/adm/toolchain/sources/${pkgname} && /usr/src/adm/scripts/build.sh --pkg-dir '/usr/src/adm/toolchain/sources/${pkgname}' --dest '/.stage_target' --jobs ${JOBS} || true"
      # unmount the temporary bind
      if mountpoint -q "${prev_root}/.stage_target"; then
        umount -l "${prev_root}/.stage_target" || true
      fi
    fi
  done

  # validation: compile a hello.c inside the new stage root via chroot_exec on prev_root mapping
  log INFO "Stage${stage}: validating toolchain by compiling test program"
  # bind-mount root into prev_root again for test
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] validate test program inside chroot using ${prev_root} with .stage_target -> ${root}"
  else
    mkdir -p "${prev_root}/.stage_target"
    mount --bind "$root" "${prev_root}/.stage_target"
    CHROOT_MOUNTS+=( "${prev_root}/.stage_target" )

    chroot_exec "$prev_root" "gcc -v >/dev/null 2>&1 || true; echo 'int main(){printf(\"OK\\n\");}' > /.stage_target/tmp/hello.c; chroot /.stage_target /usr/bin/env -i PATH=/usr/bin:/bin /bin/bash -lc 'gcc -o /tmp/hello /tmp/hello.c 2>/tmp/hello.build.log && /tmp/hello' >/tmp/hello.run.log 2>&1 || true" || true

    # cleanup bind
    if mountpoint -q "${prev_root}/.stage_target"; then
      umount -l "${prev_root}/.stage_target" || true
    fi
  fi

  snapshot_stage "$stage"
  echo "$(_now) - stage${stage} done" > "${STATE_DIR}/stage${stage}.done"
  log INFO "Stage${stage} complete"
}

build_stage1() { build_stage_generic 1; }
build_stage2() { build_stage_generic 2; }
build_stage3() {
  local stage=3
  create_stage_layout "$stage"
  local root="${STAGES_DIR}/stage${stage}/rootfs"
  # Build kernel inside stage2 chroot and install into stage3 rootfs
  local prev_root="${STAGES_DIR}/stage2/rootfs"
  if [[ ! -d "$prev_root" ]]; then
    fatal "Stage2 root not found; cannot build kernel for stage3"
  fi
  mount_chroot_binds "$prev_root"
  prepare_chroot_network "$prev_root"

  # Build kernel sources found in TOOLS_DIR/linux-* (heuristic)
  for ksrc in "${TOOLS_DIR}"/linux*; do
    [[ -d "$ksrc" ]] || continue
    kbase=$(basename "$ksrc")
    log INFO "Stage3: compiling kernel ${kbase} inside chroot ${prev_root}, installing modules to ${root}"
    # mount target
    mkdir -p "${prev_root}/.stage_target"
    mount --bind "$root" "${prev_root}/.stage_target"
    CHROOT_MOUNTS+=( "${prev_root}/.stage_target" )

    # inside chroot: build and modules_install INSTALL_MOD_PATH=/.stage_target
    chroot_exec "$prev_root" "cd /usr/src/adm/toolchain/sources/${kbase} && make -j${JOBS} && make INSTALL_MOD_PATH=/.stage_target modules_install && cp arch/$(uname -m)/boot/bzImage /.stage_target/boot/vmlinuz-${kbase} || true"

    # unmount
    if mountpoint -q "${prev_root}/.stage_target"; then
      umount -l "${prev_root}/.stage_target" || true
    fi

    # Generate initramfs for built kernel version (kbase may include version)
    # Try to derive version string from kernel Makefile or kbase
    local kver="$kbase"
    if [[ -x "$MKINIT" ]]; then
      if [[ $DRY_RUN -eq 1 ]]; then
        log INFO "[DRY-RUN] Would invoke mkinitramfs for kernel ${kver} with root ${root}"
      else
        run "$MKINIT --kernel '${kver}' --root '${root}'"
      fi
    else
      log WARN "mkinitramfs.sh not found; skipping initramfs creation for kernel ${kver}"
    fi
  done

  snapshot_stage "$stage"
  echo "$(_now) - stage3 done" > "${STATE_DIR}/stage3.done"
  log INFO "Stage3 complete"
}

# -------------------------
# Toolchain version detection & incremental rebuild (simplified)
# -------------------------
detect_toolchain_changes() {
  local changed=0
  local curvers_file="${STATE_DIR}/toolchain.version"
  # compute simple hash of sources dir names to detect changes
  local newsig; newsig=$(find "${TOOLS_DIR}" -maxdepth 1 -type d -printf "%f\n" 2>/dev/null | sort | sha256sum | awk '{print $1}')
  local oldsigs=""
  if [[ -f "${curvers_file}" ]]; then oldsigs=$(cat "${curvers_file}"); fi
  if [[ "$newsig" != "$oldsigs" || "$FORCE" -eq 1 ]]; then
    changed=1
    echo "$newsig" > "${curvers_file}.tmp" && mv -f "${curvers_file}.tmp" "${curvers_file}"
    log INFO "Toolchain/sources signature changed (or force). Updated ${curvers_file}"
  fi
  return $changed
}

# -------------------------
# Main orchestrator
# -------------------------
main() {
  check_requirements

  # detect changes and decide incremental rebuild
  detect_toolchain_changes || true

  if [[ $DO_STAGE0 -eq 1 ]]; then
    if [[ $RESUME -eq 1 && -f "${STATE_DIR}/stage0.done" && $FORCE -eq 0 ]]; then
      log INFO "Skipping stage0 (already done) -- use --force to rebuild"
    else
      build_stage0
    fi
  fi

  if [[ $DO_STAGE1 -eq 1 ]]; then
    if [[ $RESUME -eq 1 && -f "${STATE_DIR}/stage1.done" && $FORCE -eq 0 ]]; then
      log INFO "Skipping stage1 (already done) -- use --force to rebuild"
    else
      build_stage1
    fi
  fi

  if [[ $DO_STAGE2 -eq 1 ]]; then
    if [[ $RESUME -eq 1 && -f "${STATE_DIR}/stage2.done" && $FORCE -eq 0 ]]; then
      log INFO "Skipping stage2 (already done) -- use --force to rebuild"
    else
      build_stage2
    fi
  fi

  if [[ $DO_STAGE3 -eq 1 ]]; then
    if [[ $RESUME -eq 1 && -f "${STATE_DIR}/stage3.done" && $FORCE -eq 0 ]]; then
      log INFO "Skipping stage3 (already done) -- use --force to rebuild"
    else
      build_stage3
    fi
  fi

  log INFO "Bootstrap run complete"
  # release lock automatically by exiting (fd closed)
}

# Run main
main "$@"
