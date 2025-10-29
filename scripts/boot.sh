#!/usr/bin/env bash
# /usr/src/adm/scripts/boot.sh
# ADM Build System - initramfs / mkinitramfs creator
# Version: 1.0
# Author: ADM Build (script generated)
set -o errexit
set -o nounset
set -o pipefail

# -------------------------
# Defaults & environment
# -------------------------
ADM_BASE="${ADM_BASE:-/usr/src/adm}"
ADM_SCRIPTS="${ADM_SCRIPTS:-${ADM_BASE}/scripts}"
ADM_LOGS="${ADM_LOGS:-${ADM_BASE}/logs}"
ADM_BOOT="${ADM_BOOT:-/boot}"
ADM_BOOTSTRAP="${ADM_BOOTSTRAP:-${ADM_BASE}/bootstrap}"
ADM_OUTPUT="${ADM_OUTPUT:-${ADM_BASE}/output}"
ADM_TMP_BASE="${ADM_TMP_BASE:-${ADM_BOOTSTRAP}/initramfs}"
BOOT_VERSION="1.0"

# CLI defaults
KVER="auto"
COMPRESS="${COMPRESS:-gzip}"   # gzip,xz,lz4,zstd,none
INCLUDE_FILES=()               # format src:dest
EXTRA_MODULES=()               # list
MK_WRAPPER=0
INSTALL=0
CHROOT=""
FORCE=0
DRY_RUN=0
DEBUG=0
AUTO_YES=0
VERBOSE=0

TS="$(date '+%Y%m%d_%H%M%S')"
LOGFILE="${ADM_LOGS}/boot-${TS}.log"
mkdir -p "${ADM_LOGS}" "${ADM_OUTPUT}" "${ADM_TMP_BASE}" 2>/dev/null || true
touch "$LOGFILE" 2>/dev/null || true

# -------------------------
# Try to source helpers (non-fatal)
# -------------------------
if [[ -r "${ADM_SCRIPTS}/env.sh" ]]; then
  # shellcheck disable=SC1091
  source "${ADM_SCRIPTS}/env.sh" || true
fi
_LOG=0; _UI=0
if [[ -r "${ADM_SCRIPTS}/log.sh" ]]; then
  # shellcheck disable=SC1091
  source "${ADM_SCRIPTS}/log.sh" || true
  _LOG=1
fi
if [[ -r "${ADM_SCRIPTS}/ui.sh" ]]; then
  # shellcheck disable=SC1091
  source "${ADM_SCRIPTS}/ui.sh" || true
  _UI=1
fi

# -------------------------
# Small logging helpers
# -------------------------
log_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info() {
  local msg="$*"
  printf "%s [INFO] %s\n" "$(log_ts)" "$msg" >>"$LOGFILE"
  if [[ $_LOG -eq 1 && "$(type -t log_info 2>/dev/null)" == "function" ]]; then
    log_info "$msg"
  elif [[ $VERBOSE -eq 1 ]]; then
    printf "[INFO] %s\n" "$msg"
  fi
}
log_warn() {
  local msg="$*"
  printf "%s [WARN] %s\n" "$(log_ts)" "$msg" >>"$LOGFILE"
  if [[ $_LOG -eq 1 && "$(type -t log_warn 2>/dev/null)" == "function" ]]; then
    log_warn "$msg"
  else
    printf "[WARN] %s\n" "$msg" >&2
  fi
}
log_error() {
  local msg="$*"
  printf "%s [ERROR] %s\n" "$(log_ts)" "$msg" >>"$LOGFILE"
  if [[ $_LOG -eq 1 && "$(type -t log_error 2>/dev/null)" == "function" ]]; then
    log_error "$msg"
  else
    printf "[ERROR] %s\n" "$msg" >&2
  fi
}

ui_section_start() {
  local t="$1"
  if [[ $_UI -eq 1 && "$(type -t ui_section 2>/dev/null)" == "function" ]]; then
    ui_section "$t"
  else
    printf "[  ] %s\n" "$t"
  fi
}
ui_section_end_ok() {
  local t="$1"
  if [[ $_UI -eq 1 && "$(type -t ui_end_section 2>/dev/null)" == "function" ]]; then
    ui_end_section 0 "$t"
  else
    printf "[✔️] %s... concluído\n" "$t"
  fi
}
ui_section_end_fail() {
  local t="$1"
  if [[ $_UI -eq 1 && "$(type -t ui_end_section 2>/dev/null)" == "function" ]]; then
    ui_end_section 1 "$t"
  else
    printf "[✖] %s... falhou\n" "$t"
  fi
}

# -------------------------
# Utilities
# -------------------------
which_compressor() {
  case "$1" in
    gzip) command -v gzip >/dev/null 2>&1 && printf "%s" "gzip" || return 1 ;;
    xz) command -v xz >/dev/null 2>&1 && printf "%s" "xz" || return 1 ;;
    lz4) command -v lz4 >/dev/null 2>&1 && printf "%s" "lz4" || return 1 ;;
    zstd) command -v zstd >/dev/null 2>&1 && printf "%s" "zstd" || return 1 ;;
    none) printf "%s" "none" ;;
    *) return 1 ;;
  esac
}

safe_cp() {
  # usage: safe_cp src dest (creates dest dir)
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  cp -a --no-target-directory "$src" "$dest"
}

safe_mkdir() { mkdir -p "$1"; chmod 0755 "$1"; }

sha256_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}' || true; }

confirm() {
  if [[ $AUTO_YES -eq 1 ]]; then return 0; fi
  printf "%s [y/N]: " "$1"
  read -r ans
  case "$ans" in y|Y) return 0 ;; *) return 1 ;; esac
}

# copy binary and its required libs (supports chroot)
copy_binary_with_deps() {
  local BIN="$1" TMPROOT="$2" CHROOT_PREFIX="${3:-}"
  if [[ -z "$BIN" || ! -f "$BIN" ]]; then return 1; fi
  local reldest
  reldest="${BIN#/}"
  # target path inside tmp
  local target="${TMPROOT}/${reldest}"
  mkdir -p "$(dirname "$target")"
  cp -a --preserve=mode,ownership,timestamps "$BIN" "$target"

  # ldd may not run on foreign architecture; guard it
  if command -v ldd >/dev/null 2>&1; then
    # run ldd on BIN; if chroot prefix provided, attempt to use chroot ldd
    local lddout
    if [[ -n "$CHROOT_PREFIX" ]]; then
      if [[ -x "${CHROOT_PREFIX}/bin/sh" ]]; then
        # try chroot ldd; fallback to host
        lddout="$(chroot "$CHROOT_PREFIX" /bin/sh -c "ldd '$BIN' 2>/dev/null" || true)"
      else
        lddout="$(ldd "$BIN" 2>/dev/null || true)"
      fi
    else
      lddout="$(ldd "$BIN" 2>/dev/null || true)"
    fi
    # parse libs from ldd output
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      # match '/lib...so.0' or 'libc.so.6 => /lib...'
      local libpath
      libpath="$(printf "%s" "$line" | awk '{for(i=1;i<=NF;i++){ if ($i ~ /^\//) { print $i; exit } }}')"
      if [[ -n "$libpath" && -f "$libpath" ]]; then
        local libdest="${TMPROOT}${libpath}"
        mkdir -p "$(dirname "$libdest")"
        cp -a --preserve=mode,ownership,timestamps "$libpath" "$libdest" || true
      fi
    done <<<"$lddout"
  fi
  return 0
}

# -------------------------
# Phase functions
# -------------------------
# 00 - init
boot_init() {
  ui_section_start "Inicializando boot (init)"
  # create base dirs
  safe_mkdir "$ADM_BOOTSTRAP"
  safe_mkdir "$ADM_OUTPUT"
  safe_mkdir "$ADM_TMP_BASE"
  # create temp working dir for this run
  WORKDIR="${ADM_TMP_BASE}/initramfs-${KVER:-auto}-${TS}"
  if [[ -d "$WORKDIR" && $FORCE -eq 0 ]]; then
    log_warn "WORKDIR $WORKDIR já existe. Use --force para sobrescrever."
    ui_section_end_fail "Inicialização"
    exit 1
  fi
  rm -rf "$WORKDIR" 2>/dev/null || true
  safe_mkdir "$WORKDIR"
  safe_mkdir "${WORKDIR}/bin" "${WORKDIR}/sbin" "${WORKDIR}/usr/bin" "${WORKDIR}/usr/sbin"
  safe_mkdir "${WORKDIR}/lib" "${WORKDIR}/lib64" "${WORKDIR}/etc" "${WORKDIR}/proc" "${WORKDIR}/sys" "${WORKDIR}/dev" "${WORKDIR}/run" "${WORKDIR}/mnt"
  log_info "Workdir criado em $WORKDIR"
  ui_section_end_ok "Inicialização"
}

# 10 - kernel detection
boot_detect_kernel() {
  ui_section_start "Detectando kernel alvo"
  if [[ "$KVER" != "auto" && -n "$KVER" ]]; then
    DETECTED_KVER="$KVER"
  else
    # prefer passed chroot detection if chroot provided
    if [[ -n "$CHROOT" && -d "$CHROOT/boot" ]]; then
      # try newest vmlinuz in chroot
      DETECTED_KVER="$(ls -1 "$CHROOT/boot/vmlinuz-"* 2>/dev/null | sed -E 's#.*/vmlinuz-##' | sort -V | tail -n1 || true)"
    fi
    if [[ -z "${DETECTED_KVER:-}" ]]; then
      DETECTED_KVER="$(uname -r 2>/dev/null || true)"
    fi
    if [[ -z "${DETECTED_KVER:-}" ]]; then
      DETECTED_KVER="unknown"
    fi
  fi
  KVER="$DETECTED_KVER"
  log_info "Kernel alvo: $KVER"
  ui_section_end_ok "Detecção do kernel"
}

# 20 - prepare tree (dev nodes)
boot_prepare_tree() {
  ui_section_start "Preparando árvore do initramfs"
  # create essential dev nodes
  if [[ ! -e "${WORKDIR}/dev/null" ]]; then
    if [[ $DRY_RUN -eq 0 ]]; then
      (cd "${WORKDIR}/dev" && mknod -m 666 null c 1 3 2>/dev/null || true)
    fi
  fi
  if [[ ! -e "${WORKDIR}/dev/console" ]]; then
    if [[ $DRY_RUN -eq 0 ]]; then
      (cd "${WORKDIR}/dev" && mknod -m 600 console c 5 1 2>/dev/null || true)
    fi
  fi
  if [[ ! -e "${WORKDIR}/dev/tty0" ]]; then
    if [[ $DRY_RUN -eq 0 ]]; then
      (cd "${WORKDIR}/dev" && mknod -m 622 tty0 c 4 0 2>/dev/null || true)
    fi
  fi
  ui_section_end_ok "Árvore pronta"
}

# 30 - copy tools (busybox preferred)
boot_copy_tools() {
  ui_section_start "Copiando binários essenciais"
  local tmp="$WORKDIR"
  # prefer busybox if present in chroot or host
  local busybox_cmd=""
  if [[ -n "$CHROOT" && -x "$CHROOT/bin/busybox" ]]; then busybox_cmd="$CHROOT/bin/busybox"; fi
  if [[ -z "$busybox_cmd" && -x "/bin/busybox" ]]; then busybox_cmd="/bin/busybox"; fi

  if [[ -n "$busybox_cmd" ]]; then
    log_info "Usando busybox: $busybox_cmd"
    # copy busybox binary
    copy_binary_with_deps "$busybox_cmd" "$tmp" "${CHROOT:-}"
    # create symlinks for common applets (sh, mount, modprobe)
    for app in sh mount umount ls cat echo grep sed awk cut; do
      # prefer to create symlink to busybox executable inside tmp
      ln -sf "./bin/$(basename "$busybox_cmd")" "${tmp}/bin/$app" 2>/dev/null || true
    done
  else
    # fallback copy selected binaries from host or chroot
    local bins=(/bin/sh /bin/mount /bin/umount /sbin/modprobe /bin/ls /bin/cat /bin/echo /usr/bin/grep /bin/sed /usr/bin/awk /bin/cut)
    for b in "${bins[@]}"; do
      local realb="$b"
      if [[ -n "$CHROOT" && -f "${CHROOT}${b}" ]]; then realb="${CHROOT}${b}"; fi
      if [[ -f "$realb" ]]; then
        copy_binary_with_deps "$realb" "$tmp" "${CHROOT:-}" || log_warn "falha ao copiar $realb"
      fi
    done
  fi
  ui_section_end_ok "Cópia de binários concluída"
}

# 40 - create init
boot_create_init() {
  ui_section_start "Gerando /init"
  local init="${WORKDIR}/init"
  cat >"$init" <<'EOF'
#!/bin/sh
# minimal init for initramfs generated by ADM boot.sh
set -e
echo "initramfs: starting init..."
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
# load modules listed in /modules.lst if present
if [ -f /modules.lst ]; then
  while read -r m; do
    [ -z "$m" ] && continue
    modprobe "$m" 2>/dev/null || true
  done </modules.lst
fi
# find root from kernel cmdline
ROOT=''
for arg in $(cat /proc/cmdline 2>/dev/null); do
  case "$arg" in
    root=*) ROOT="${arg#root=}" ;;
  esac
done
if [ -n "$ROOT" ]; then
  echo "Mounting root: $ROOT"
  # try busybox switch_root if present, else fallback to pivot
  if command -v switch_root >/dev/null 2>&1; then
    exec switch_root "$ROOT" /sbin/init || exec /sbin/init || exec /bin/sh
  else
    exec /sbin/init || exec /bin/sh
  fi
else
  echo "No root specified. Dropping to /bin/sh"
  exec /bin/sh
fi
EOF
  chmod 0755 "$init"
  ui_section_end_ok "/init gerado"
}

# 50 - copy modules
boot_copy_modules() {
  ui_section_start "Coletando e copiando módulos (se existirem)"
  local kver="$KVER"
  local modroot=""
  if [[ -n "$CHROOT" && -d "$CHROOT/lib/modules/$kver" ]]; then
    modroot="${CHROOT}/lib/modules/$kver"
  elif [[ -d "/lib/modules/$kver" ]]; then
    modroot="/lib/modules/$kver"
  else
    log_warn "Diretório de módulos não encontrado para $kver; pulando cópia de módulos"
    ui_section_end_ok "Módulos (pulados)"
    return 0
  fi

  local target_moddir="${WORKDIR}/lib/modules/${kver}"
  mkdir -p "$target_moddir"

  # collect modules: extras + minimal set from depmod if available
  local modules_to_copy=()
  # add extras
  for m in "${EXTRA_MODULES[@]}"; do
    modules_to_copy+=("$m")
  done

  # if depmod available, try to find dependencies for modules listed
  if command -v modprobe >/dev/null 2>&1; then
    for m in "${modules_to_copy[@]}"; do
      # get dependencies via modprobe --show-depends
      modprobe --show-depends "$m" 2>/dev/null | awk '{print $1}' | while read -r modpath; do
        if [[ -f "$modpath" ]]; then
          mkdir -p "$(dirname "${target_moddir}${modpath#/lib/modules/}")"
          cp -a "$modpath" "${target_moddir}${modpath#/lib/modules/}" || true
        fi
      done
    done
  fi

  # As a fallback, copy entire tree if extras empty and module root exists (optional, heavy)
  if [[ ${#modules_to_copy[@]} -eq 0 ]]; then
    # copy entire modules dir but this can be large
    log_info "Nenhum módulo explícito pedido; copiando tree de módulos inteira (pode ser grande)"
    cp -a "$modroot" "$target_moddir/.." 2>/dev/null || true
  fi

  # create module list (simple)
  find "${target_moddir}" -type f -name '*.ko' -print0 2>/dev/null | xargs -0 -r -n1 basename | sort -u >"${WORKDIR}/modules.lst" || true

  ui_section_end_ok "Módulos copiados"
}

# 60 - include extras
boot_include_extras() {
  ui_section_start "Incluindo arquivos extras"
  for inc in "${INCLUDE_FILES[@]}"; do
    # format src:dest
    local src="${inc%%:*}"
    local destrel="${inc#*:}"
    if [[ -z "$src" || -z "$destrel" ]]; then
      log_warn "Include inválido: $inc (use src:dest)"
      continue
    fi
    local destpath="${WORKDIR}/${destrel#/}"
    if [[ ! -e "$src" ]]; then
      log_warn "Arquivo a incluir não existe: $src"
      continue
    fi
    mkdir -p "$(dirname "$destpath")"
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "DRY-RUN incluir $src -> $destpath"
    else
      cp -a "$src" "$destpath" || log_warn "falha ao copiar $src"
      log_info "Incluído $src -> $destpath"
    fi
  done
  ui_section_end_ok "Includes processados"
}

# 70 - create cpio + compress
boot_compress_image() {
  ui_section_start "Gerando e compactando imagem (compress=${COMPRESS})"
  local outname="initramfs-${KVER}-${TS}.img"
  local outfile="${ADM_OUTPUT}/${outname}"
  local compressor
  compressor="$(which_compressor "$COMPRESS" || true)"
  if [[ -z "$compressor" ]]; then
    if [[ "$COMPRESS" == "none" ]]; then
      compressor="none"
    else
      log_warn "Compressor '$COMPRESS' não disponível; tentando auto-detect"
      for c in gzip xz lz4 zstd; do
        if which_compressor "$c" >/dev/null 2>&1; then compressor="$c"; break; fi
      done
      compressor="${compressor:-gzip}"
    fi
  fi

  # create cpio stream
  pushd "$WORKDIR" >/dev/null
  if [[ "$compressor" == "none" ]]; then
    find . | cpio -H newc -o > "$outfile"
  else
    case "$compressor" in
      gzip) find . | cpio -H newc -o | gzip -c > "$outfile" ;;
      xz) find . | cpio -H newc -o | xz -c > "$outfile" ;;
      lz4) find . | cpio -H newc -o | lz4 -z - "$outfile" ;;
      zstd) find . | cpio -H newc -o | zstd -o "$outfile" -q ;;
      *) find . | cpio -H newc -o | gzip -c > "$outfile" ;;
    esac
  fi
  popd >/dev/null

  if [[ ! -f "$outfile" ]]; then
    log_error "Falha ao gerar imagem"
    ui_section_end_fail "Geração de imagem"
    exit 1
  fi

  # compute sha256
  sha256="$(sha256_of "$outfile" || true)"
  printf "%s  %s\n" "$sha256" "$(basename "$outfile")" >"${outfile}.sha256"
  log_info "Imagem criada: $outfile (sha256: $sha256)"
  ui_section_end_ok "Imagem gerada"
  # expose output
  GENERATED_IMAGE="$outfile"
}

# 80 - install
boot_install_image() {
  if [[ $INSTALL -ne 1 ]]; then return 0; fi
  ui_section_start "Instalando imagem em ${ADM_BOOT}"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "DRY-RUN: instalaria $GENERATED_IMAGE -> ${ADM_BOOT}/$(basename "$GENERATED_IMAGE")"
    ui_section_end_ok "Instalação (DRY-RUN)"
    return 0
  fi
  if [[ ! -w "${ADM_BOOT}" && $FORCE -eq 0 ]]; then
    log_warn "${ADM_BOOT} não é gravável. Use --force ou rode como root."
    ui_section_end_fail "Instalação"
    return 1
  fi
  local dest="${ADM_BOOT}/$(basename "$GENERATED_IMAGE")"
  cp -a "$GENERATED_IMAGE" "$dest"
  cp -a "${GENERATED_IMAGE}.sha256" "${dest}.sha256" 2>/dev/null || true
  ln -sf "$dest" "${ADM_BOOT}/initramfs-latest.img"
  log_info "Imagem instalada em $dest"
  ui_section_end_ok "Instalação concluída"
}

# 90 - cleanup
boot_cleanup() {
  ui_section_start "Limpando temporários"
  if [[ $DEBUG -eq 1 ]]; then
    log_info "Debug mode: mantendo $WORKDIR para inspeção"
  else
    rm -rf "$WORKDIR" 2>/dev/null || true
    log_info "Removido $WORKDIR"
  fi
  ui_section_end_ok "Cleanup"
}

# mk wrapper
boot_mk_wrapper() {
  ui_section_start "Gerando wrapper mkinitramfs"
  local wrapper="${ADM_BASE}/bin/mkinitramfs"
  mkdir -p "$(dirname "$wrapper")"
  cat >"$wrapper" <<EOF
#!/usr/bin/env bash
# wrapper to build initramfs quickly
exec "${ADM_SCRIPTS}/boot.sh" --kver "\$1" "\${@:2}"
EOF
  chmod 0755 "$wrapper"
  log_info "Wrapper criado em $wrapper"
  ui_section_end_ok "mkinitramfs criado"
}

# -------------------------
# CLI parsing
# -------------------------
_print_usage() {
  cat <<'EOF'
boot.sh - create initramfs images (mkinitramfs)
Usage: boot.sh [options]
Options:
  --kver <ver|auto>           Kernel version (default auto)
  --compress gzip|xz|lz4|zstd|none   Compressor (default gzip)
  --include src:dest          Include extra file (can repeat)
  --modules m1,m2,...         Additional kernel modules to include
  --mk                        Install mkinitramfs wrapper
  --install                   Copy resulting image to /boot
  --chroot /path              Build using /path as root (chroot)
  --debug                     Keep temporary workdir for inspection
  --force                     Force overwrite existing workdir
  --yes                       Assume yes for installs/fixes
  --dry-run                   Do not perform changes, just simulate
  --verbose                   Verbose output
  --help
EOF
}

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kver) KVER="${2:-}"; shift 2 ;;
    --compress) COMPRESS="${2:-}"; shift 2 ;;
    --include) INCLUDE_FILES+=("$2"); shift 2 ;;
    --modules) IFS=',' read -r -a EXTRA_MODULES <<<"$2"; shift 2 ;;
    --mk) MK_WRAPPER=1; shift ;;
    --install) INSTALL=1; shift ;;
    --chroot) CHROOT="$2"; shift 2 ;;
    --debug) DEBUG=1; shift ;;
    --force) FORCE=1; shift ;;
    --yes) AUTO_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --help|-h) _print_usage; exit 0 ;;
    *) echo "Unknown arg: $1"; _print_usage; exit 2 ;;
  esac
done

# -------------------------
# Pre-check needed tools
# -------------------------
ui_section_start "Verificando dependências (cpio, find, sha256sum, ldd)"
deps_missing=()
for cmd in cpio find sha256sum ldd; do
  if ! command -v "$cmd" >/dev/null 2>&1; then deps_missing+=("$cmd"); fi
done
if [[ ${#deps_missing[@]} -gt 0 ]]; then
  log_error "Dependências faltando: ${deps_missing[*]}; instale-as e tente novamente."
  ui_section_end_fail "Dependências"
  exit 2
fi
ui_section_end_ok "Dependências OK"

# -------------------------
# Main flow
# -------------------------
# prepare KVER if auto (we need WORKDIR name)
if [[ "$KVER" == "auto" || -z "$KVER" ]]; then
  # will be set in boot_detect_kernel
  :
fi

boot_init
boot_detect_kernel
boot_prepare_tree
boot_copy_tools
boot_create_init
boot_copy_modules
boot_include_extras
boot_compress_image

if [[ $MK_WRAPPER -eq 1 ]]; then
  boot_mk_wrapper
fi

boot_install_image
boot_cleanup

log_info "boot.sh completed successfully. Image: ${GENERATED_IMAGE:-none}"
echo
printf "Imagem: %s\nLog: %s\n" "${GENERATED_IMAGE:-none}" "$LOGFILE"

exit 0
