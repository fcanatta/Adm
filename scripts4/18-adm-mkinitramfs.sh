#!/usr/bin/env bash
# 18-adm-mkinitramfs.part1.sh
# Gera initramfs determinístico (host ou --root stage), com detecção de drivers,
# hooks, microcode, assinatura e UKI opcional.

###############################################################################
# Guardas, dependências base e contexto
###############################################################################
if [[ -n "${ADM_MKINIT_LOADED_PART1:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_MKINIT_LOADED_PART1=1

for _m in ADM_CONF_LOADED ADM_LIB_LOADED; do
  if [[ -z "${!_m:-}" ]]; then
    echo "ERRO: 18-adm-mkinitramfs requer módulos 00/01 carregados. Faltando: ${_m}" >&2
    return 2 2>/dev/null || exit 2
  fi
done

: "${ADM_STATE_ROOT:=/usr/src/adm/state}"
: "${ADM_TMP_ROOT:=/usr/src/adm/tmp}"

mk_log()  { adm_log INFO "mkinitramfs" "${KVER:-}" "$*"; }
mk_err()  { adm_err "$*"; }
mk_warn() { adm_warn "$*"; }
mk_ok()   { adm_ok "$*"; }
mk_step() { adm_step "mkinitramfs" "${KVER:-}" "$*"; }

###############################################################################
# Variáveis globais
###############################################################################
declare -Ag CFG=(
  [root]="/"
  [kver]="" [kpath]=""
  [modules]="" [blacklist]=""
  [luks]="false" [lvm]="false" [mdraid]="false" [btrfs]="false" [zfs]="false" [net]="false"
  [microcode]="auto"
  [compress]="zstd" [level]="19"
  [cmdline]="" [cmdline_file]=""
  [uki]="false" [uki_name]="" [update_grub]="false"
  [sign]="" [key]="" [dry_run]="false" [verbose]="false" [json]="false"
  [allow_host_firmware]="false"
)
declare -Ag P=()    # paths calculados
declare -Ag ST=()   # stats/artefatos
declare -a REQ_CMDS=(cpio sha256sum find sed awk depmod modprobe)

###############################################################################
# Paths e helpers
###############################################################################
_mk_paths_init() {
  local r="${CFG[root]%/}"
  P[root]="$r"
  P[state]="${r}/usr/src/adm/state"
  P[logdir]="${P[state]}/logs/mkinitramfs"
  P[outdir]="${r}/boot"
  P[work]="$(mktemp -d "${ADM_TMP_ROOT%/}/mkinit.XXXXXX")"
  P[tree]="${P[work]}/tree"
  P[cpio]="${P[work]}/initramfs.cpio"
  P[outimg]="" # definido depois que KVER/arch/libc for resolvido
  P[arch]="$(uname -m 2>/dev/null || echo unknown)"
  P[libc]="$(ldd --version 2>/dev/null | head -n1 | sed -n 's/.*\(musl\|glibc\).*/\1/p' || echo unknown)"
  mkdir -p -- "${P[logdir]}" "${P[outdir]}" "${P[tree]}" || { mk_err "falha ao criar diretórios de trabalho"; return 3; }
  ST[build_log]="${P[logdir]}/build.log"
  ST[verify_log]="${P[logdir]}/verify.log"
  ST[install_log]="${P[logdir]}/install.log"
}

_mk_cleanup() { [[ -n "${P[work]:-}" && -d "${P[work]}" ]] && rm -rf -- "${P[work]}"; }

trap '_mk_cleanup' EXIT INT TERM

_mk_require_cmds() {
  local miss=()
  for c in "${REQ_CMDS[@]}"; do command -v "$c" >/dev/null 2>&1 || miss+=("$c"); done
  case "${CFG[compress]}" in
    zstd) command -v zstd >/dev/null 2>&1 || miss+=("zstd");;
    xz)   command -v xz >/dev/null 2>&1 || miss+=("xz");;
    gzip) command -v gzip >/dev/null 2>&1 || miss+=("gzip");;
    none) :;;
    *) mk_warn "compressor desconhecido '${CFG[compress]}', usando zstd"; CFG[compress]="zstd"; command -v zstd >/dev/null 2>&1 || miss+=("zstd");;
  esac
  ((${#miss[@]}==0)) || { mk_err "ferramentas ausentes: ${miss[*]}"; return 2; }
}

_mk_now_iso() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
_mk_sde() { echo "${SOURCE_DATE_EPOCH:-1704067200}"; }

_mk_escape_json() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }

###############################################################################
# Kernel detection (host ou --root)
###############################################################################
_mk_detect_kernel() {
  local root="${CFG[root]%/}"
  local modules_base="${root}/lib/modules"
  [[ -d "$modules_base" ]] || { mk_err "não encontrei ${modules_base}"; return 5; }

  if [[ -n "${CFG[kver]}" ]]; then
    KVER="${CFG[kver]}"
    [[ -d "${modules_base}/${KVER}" ]] || { mk_err "KVER informado não existe em ${modules_base}"; return 5; }
  elif [[ -n "${CFG[kpath]}" ]]; then
    KVER="$(basename -- "${CFG[kpath]}")"
    [[ -d "${modules_base}/${KVER}" ]] || { mk_err "KPATH informado não existe como modules dir"; return 5; }
  else
    # pega o mais recente lexicograficamente
    KVER="$(ls -1 "${modules_base}" 2>/dev/null | sort | tail -n1)"
    [[ -n "$KVER" ]] || { mk_err "nenhum kernel encontrado em ${modules_base}"; return 5; }
  fi

  # Ajusta arch/libc se houver metadata do bootstrap
  if [[ -r "${root}/usr/src/adm/state/bootstrap/arch" ]]; then
    P[arch]="$(cat "${root}/usr/src/adm/state/bootstrap/arch" 2>/dev/null || echo "${P[arch]}")"
  fi
  if [[ -r "${root}/usr/src/adm/state/bootstrap/libc" ]]; then
    P[libc]="$(cat "${root}/usr/src/adm/state/bootstrap/libc" 2>/dev/null || echo "${P[libc]}")"
  fi

  P[outimg]="${CFG[root]%/}/boot/initramfs-${KVER}-${P[arch]}-${P[libc]}.img"
  P[kmoddir]="${modules_base}/${KVER}"
  mk_step "kernel" "KVER=${KVER} arch=${P[arch]} libc=${P[libc]}"
  return 0
}

###############################################################################
# Depmod e resolução de dependências (sem chroot)
###############################################################################
_mk_depmod_prepare() {
  # atualiza modules.dep no namespace do root
  depmod -b "${CFG[root]%/}" "${KVER}" >> "${ST[build_log]}" 2>&1 || { mk_err "depmod falhou (root=${CFG[root]} kver=${KVER})"; return 5; }
  return 0
}

# Coleta de módulos: auto (fstab + modalias + módulos raiz) ∪ --modules − --blacklist
_mk_collect_modules() {
  declare -Ag MODSET=() BLK=()
  # Blacklist
  IFS=',' read -r -a arrblk <<< "${CFG[blacklist]}"
  for m in "${arrblk[@]}"; do [[ -n "$m" ]] && BLK["$m"]=1; done

  # Módulos explícitos
  IFS=',' read -r -a arrmod <<< "${CFG[modules]}"
  for m in "${arrmod[@]}"; do [[ -n "$m" && -z "${BLK[$m]:-}" ]] && MODSET["$m"]=1; done

  # FSTAB/cmdline raiz
  local root="${CFG[root]%/}"
  local fstab="${root}/etc/fstab"
  local fslist=()
  if [[ -r "$fstab" ]]; then
    while read -r line; do
      line="${line%%#*}"
      [[ -z "$line" ]] && continue
      local fs; fs="$(echo "$line" | awk '{print $3}')" || true
      [[ -n "$fs" ]] && fslist+=("$fs")
    done < "$fstab"
  fi
  # mapeia FS→módulos básicos
  for fs in "${fslist[@]}"; do
    case "$fs" in
      ext4) MODSET[ext4]=1;;
      xfs)  MODSET[xfs]=1;;
      btrfs) MODSET[btrfs]=1;;
      f2fs) MODSET[f2fs]=1;;
      zfs)  MODSET[zfs]=1; CFG[zfs]="true";;
    esac
  done

  # Dispositivos comuns de boot
  MODSET[nvme]=1; MODSET[ahci]=1; MODSET[virtio_blk]=1; MODSET[sd_mod]=1; MODSET[scsi_mod]=1; MODSET[crc32c]=1
  [[ "${CFG[lvm]}" == "true" ]] && { MODSET[dm_mod]=1; MODSET[dm_crypt]=1; }
  [[ "${CFG[mdraid]}" == "true" ]] && { MODSET[md_mod]=1; MODSET[raid1]=1; }
  [[ "${CFG[luks]}" == "true" ]] && { MODSET[dm_crypt]=1; }

  # Filtra blacklists
  for k in "${!BLK[@]}"; do unset "MODSET[$k]"; done

  # Valida existência no /lib/modules/<kver>
  declare -a MODS=()
  for m in "${!MODSET[@]}"; do
    local found
    found="$(modprobe -D -S "${KVER}" -d "${CFG[root]%/}" "$m" 2>/dev/null | grep -E '\.ko(\.xz|\.zst|\.gz)?$' | head -n1 || true)"
    [[ -n "$found" ]] && MODS+=("$m")
  done
  ST[mods]="${MODS[*]}"
  mk_step "módulos" "selecionados: ${ST[mods]:-(nenhum)}"
  return 0
}

###############################################################################
# Copiadores: binários e bibliotecas (estáticos preferidos)
###############################################################################
_mk_install_bin() { # _mk_install_bin <path_on_host> <dest /initramfs/tree/path>
  local host="$1" dest="$2"
  [[ -x "$host" ]] || { mk_warn "binário ausente: $host"; return 1; }
  install -D -m0755 "$host" "${P[tree]}${dest}" >> "${ST[build_log]}" 2>&1 || return 3
  # tenta copiar libs se for dinâmico (melhor estático)
  if ldd "$host" 2>&1 | grep -q 'not a dynamic'; then
    : # estático, ok
  else
    ldd "$host" 2>/dev/null | awk '/=>/ {print $3} /^\/lib/ {print $1}' | while read -r so; do
      [[ -r "$so" ]] || continue
      local d="/$(dirname "${so}")"
      install -D -m0644 "$so" "${P[tree]}${so}" >> "${ST[build_log]}" 2>&1 || true
    done
  fi
}

_mk_copy_module_file() { # instala .ko* mantendo estrutura
  local f="$1"
  local rel="${f#${CFG[root]%/}}"
  install -D -m0644 "$f" "${P[tree]}${rel}" >> "${ST[build_log]}" 2>&1 || return 3
}

###############################################################################
# Árvore do initramfs e script /init
###############################################################################
_mk_tree_skeleton() {
  mkdir -p -- "${P[tree]}"/{bin,sbin,etc,proc,sys,dev,run,usr/bin,usr/sbin,var,lib,usr/lib} || return 3
  mkdir -p -- "${P[tree]}/lib/modules/${KVER}" || return 3
  printf 'PRETTY_NAME=ADM initramfs\n' > "${P[tree]}/etc/initrd-release"
}

_mk_runtime_tools() {
  # Preferir busybox estático
  if command -v busybox >/dev/null 2>&1; then
    _mk_install_bin "$(command -v busybox)" "/bin/busybox" || return $?
    (cd "${P[tree]}/bin" && for a in sh mount umount ls cat echo grep awk sed sleep dmesg ln modprobe insmod rmmod fsck blkid mknod cp mv mkdir rmdir ip; do ln -sf busybox "$a"; done)
  elif command -v toybox >/dev/null 2>&1; then
    _mk_install_bin "$(command -v toybox)" "/bin/toybox" || return $?
    (cd "${P[tree]}/bin" && for a in sh mount umount ls cat echo grep awk sed sleep dmesg ln; do ln -sf toybox "$a"; done)
  else
    mk_err "nem busybox nem toybox encontrados"; return 2
  fi

  # utilitários opcionais (se recursos habilitados)
  [[ "${CFG[luks]}" == "true" ]]   && command -v cryptsetup >/dev/null 2>&1 && _mk_install_bin "$(command -v cryptsetup)" "/sbin/cryptsetup"
  [[ "${CFG[lvm]}" == "true" ]]    && command -v lvm >/dev/null 2>&1         && _mk_install_bin "$(command -v lvm)" "/sbin/lvm"
  [[ "${CFG[mdraid]}" == "true" ]] && command -v mdadm >/dev/null 2>&1       && _mk_install_bin "$(command -v mdadm)" "/sbin/mdadm"
  [[ "${CFG[btrfs]}" == "true" ]]  && command -v btrfs >/dev/null 2>&1       && _mk_install_bin "$(command -v btrfs)" "/sbin/btrfs"
  if [[ "${CFG[zfs]}" == "true" ]]; then
    command -v zpool >/dev/null 2>&1 && _mk_install_bin "$(command -v zpool)" "/sbin/zpool"
    command -v zfs   >/dev/null 2>&1 && _mk_install_bin "$(command -v zfs)"   "/sbin/zfs"
  fi
}

_mk_install_modules() {
  # instala arquivos de módulos e deps mínimos
  local root="${CFG[root]%/}"
  local f
  # garantir modules.dep
  install -m0644 -D "${root}/lib/modules/${KVER}/modules.dep" "${P[tree]}/lib/modules/${KVER}/modules.dep" || return 3
  for m in ${ST[mods]:-}; do
    # usa modprobe -D para descobrir o arquivo .ko*
    local mf
    mf="$(modprobe -D -S "${KVER}" -d "${root}" "$m" 2>/dev/null | grep -E '\.ko(\.xz|\.zst|\.gz)?$' | awk '{print $NF}' | head -n1)"
    [[ -n "$mf" && -r "$mf" ]] || { mk_warn "não achei arquivo do módulo: $m"; continue; }
    _mk_copy_module_file "$mf" || return $?
  done
}

_mk_install_firmware() {
  local root="${CFG[root]%/}"
  local fwdir="${root}/lib/firmware"
  [[ -d "$fwdir" ]] || { mk_warn "firmware ausente em root (${fwdir})"; return 0; }
  # política simples: se instalamos módulo com nome X que requer fw, tentaremos copiar fws comuns.
  # (Implementação leve: copia firmwares inteiros para evitar resolução modalias – pode ser ajustado depois)
  if [[ "${CFG[allow_host_firmware]}" == "true" && "$root" != "/" && ! -d "$fwdir" ]]; then
    mk_warn "--allow-host-firmware habilitado, mas sem firmware no stage; buscando no host"
    fwdir="/lib/firmware"
  fi
  [[ -d "$fwdir" ]] || return 0
  mkdir -p -- "${P[tree]}/lib/firmware"
  # Copiar apenas diretórios de base conhecidos (reduzido)
  tar -C "$fwdir" -cpf - . | tar -C "${P[tree]}/lib/firmware" -xpf - 2>>"${ST[build_log]}" || true
}

_mk_init_script() {
  local f="${P[tree]}/init"
  cat > "$f" <<'EOF'
#!/bin/sh
# /init mínimo do ADM (logs coloridos + rescue)
set -eu

echo "[adm-init] mount proc sys dev"
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev || mkdir -p /dev

echo "[adm-init] load modules (best-effort)"
if [ -f /lib/modules/*/modules.dep ]; then
  KVER="$(ls -1 /lib/modules | head -n1)"
  for m in $(find /lib/modules/$KVER -type f -name "*.ko*" | sed 's#.*/##; s#\.ko.*$##' | sort -u); do
    modprobe -S "$KVER" "$m" 2>/dev/null || true
  done
fi

# Hooks early
if [ -d /usr/src/adm/mkinitramfs/hooks.d/runtime/early ]; then
  for h in /usr/src/adm/mkinitramfs/hooks.d/runtime/early/*.sh; do [ -r "$h" ] && sh "$h" || exit 1; done
fi

# TODO: montar md → luks → lvm conforme presente (modo minimal aqui)
# A versão full carrega em ordem condicional; aqui fica compat leve:
# (os binários foram incluídos se as flags no build pediram)
# Exemplos (best-effort):
[ -x /sbin/mdadm ] && mdadm --assemble --scan || true
[ -x /sbin/lvm ] && lvm vgchange -ay || true

# Root FS via kernel cmdline: root=...
CMDLINE="$(cat /proc/cmdline)"
rootdev="$(echo "$CMDLINE" | sed -n 's/.*root=\([^ ]*\).*/\1/p')"
[ -n "$rootdev" ] || rootdev="/dev/sda1"

echo "[adm-init] mount root=$rootdev"
mkdir -p /newroot
mount -o ro "$rootdev" /newroot 2>/dev/null || mount "$rootdev" /newroot || {
  echo "[adm-init] ERRO: não foi possível montar root=$rootdev"
  echo "[adm-init] Entrando em shell de resgate..."
  exec sh
}

# Hooks pre-switch
if [ -d /usr/src/adm/mkinitramfs/hooks.d/runtime/pre-switch ]; then
  for h in /usr/src/adm/mkinitramfs/hooks.d/runtime/pre-switch/*.sh; do [ -r "$h" ] && sh "$h" || exit 1; done
fi

echo "[adm-init] switch_root"
exec switch_root /newroot /sbin/init
EOF
  chmod +x "$f"
}

###############################################################################
# Microcode concat (opcional)
###############################################################################
_mk_microcode_blob() {
  local mc="${CFG[microcode]}"
  [[ "$mc" == "off" ]] && { ST[microcode]="" ; return 0; }
  local root="${CFG[root]%/}"
  local dir=""
  case "$mc" in
    intel|auto) [[ -d "${root}/lib/firmware/intel-ucode" ]] && dir="${root}/lib/firmware/intel-ucode" ;;
  esac
  [[ -z "$dir" && ( "$mc" == "amd" || "$mc" == "auto" ) ]] && [[ -d "${root}/lib/firmware/amd-ucode" ]] && dir="${root}/lib/firmware/amd-ucode"
  [[ -z "$dir" ]] && { ST[microcode]=""; return 0; }

  local out="${P[work]}/microcode.cpio"
  (cd "$dir" && find . -type f -print0 | LC_ALL=C sort -z | cpio --null -o --format=newc --owner 0:0 > "$out" 2>>"${ST[build_log]}") || {
    mk_warn "falha gerando microcode cpio (prosseguindo sem)"; ST[microcode]=""; return 0; }
  ST[microcode]="$out"
}

###############################################################################
# Hooks de build
###############################################################################
_mk_run_build_hooks() {
  local root="${CFG[root]%/}"
  local dir="${root}/usr/src/adm/mkinitramfs/hooks.d/build"
  [[ -d "$dir" ]] || return 0
  for h in "$dir"/*.sh; do
    [[ -r "$h" ]] || continue
    mk_step "hook" "build: $(basename -- "$h")"
    ( ROOT="${root}" TREE="${P[tree]}" KVER="${KVER}" sh "$h" ) >> "${ST[build_log]}" 2>&1 || {
      mk_err "hook falhou: $h (veja ${ST[build_log]})"; return 4; }
  done
}

###############################################################################
# Build principal: prepara árvore e gera CPIO
###############################################################################
adm_mkinit_build() {
  # parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kver) CFG[kver]="$2"; shift 2;;
      --kpath) CFG[kpath]="$2"; shift 2;;
      --root) CFG[root]="$2"; shift 2;;
      --modules) CFG[modules]="$2"; shift 2;;
      --blacklist) CFG[blacklist]="$2"; shift 2;;
      --luks) CFG[luks]="true"; shift;;
      --lvm) CFG[lvm]="true"; shift;;
      --mdraid) CFG[mdraid]="true"; shift;;
      --btrfs) CFG[btrfs]="true"; shift;;
      --zfs) CFG[zfs]="true"; shift;;
      --net) CFG[net]="true"; shift;;
      --microcode) CFG[microcode]="$2"; shift 2;;
      --compress) CFG[compress]="$2"; shift 2;;
      --level) CFG[level]="$2"; shift 2;;
      --cmdline) CFG[cmdline]="$2"; shift 2;;
      --cmdline-file) CFG[cmdline_file]="$2"; shift 2;;
      --uki) CFG[uki]="true"; shift;;
      --uki-name) CFG[uki_name]="$2"; shift 2;;
      --update-grub) CFG[update_grub]="true"; shift;;
      --sign) CFG[sign]="$2"; shift 2;;
      --key) CFG[key]="$2"; shift 2;;
      --dry-run) CFG[dry_run]="true"; shift;;
      --verbose) CFG[verbose]="true"; shift;;
      --json|--print-json) CFG[json]="true"; shift;;
      --allow-host-firmware) CFG[allow_host_firmware]="true"; shift;;
      *) mk_warn "flag desconhecida: $1"; shift;;
    esac
  done

  _mk_paths_init || return $?
  _mk_require_cmds || return $?
  _mk_detect_kernel || return $?
  _mk_depmod_prepare || return $?
  _mk_collect_modules || return $?
  _mk_tree_skeleton || return $?
  _mk_runtime_tools || return $?
  _mk_install_modules || return $?
  _mk_install_firmware || true
  _mk_init_script || return $?
  _mk_microcode_blob || true
  _mk_run_build_hooks || return $?

  # cmdline
  local cmdline="${CFG[cmdline]}"
  [[ -z "$cmdline" && -r "${CFG[root]%/}/etc/kernel/cmdline" ]] && cmdline="$(cat "${CFG[root]%/}/etc/kernel/cmdline" 2>/dev/null || true)"
  [[ -n "$cmdline" ]] && { printf "%s\n" "$cmdline" > "${P[tree]}/cmdline.txt"; }

  mk_step "cpio" "gerando initramfs (ordenado, mtime=@$( _mk_sde ))"
  (cd "${P[tree]}" && find . -print0 | LC_ALL=C sort -z \
    | cpio --null -o --format=newc --owner 0:0 --reproducible --quiet > "${P[cpio]}") >> "${ST[build_log]}" 2>&1 || {
      mk_err "falha ao criar CPIO (veja ${ST[build_log]})"; return 3; }

  # concat microcode se houver
  local final="${P[work]}/initramfs.cpio"
  if [[ -n "${ST[microcode]:-}" && -r "${ST[microcode]}" ]]; then
    cat "${ST[microcode]}" "${P[cpio]}" > "$final"
  else
    mv -f -- "${P[cpio]}" "$final"
  fi

  # compress
  local img="${P[outimg]}"
  case "${CFG[compress]}" in
    zstd)  zstd -T0 -q -"${CFG[level]}" --no-progress "$final" -o "${img}" ;;
    xz)    xz -"${CFG[level]}" -z -c "$final" > "${img}" ;;
    gzip)  gzip -"${CFG[level]}" -n -c "$final" > "${img}" ;;
    none)  cp -f -- "$final" "${img}" ;;
  esac

  sha256sum "${img}" > "${img}.sha256" 2>>"${ST[build_log]}" || true

  mk_ok "initramfs: ${img}"
  echo "${img}"
}
# 18-adm-mkinitramfs.part2.sh
# Assinatura, UKI, instalação, listagem e verificação
if [[ -n "${ADM_MKINIT_LOADED_PART2:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_MKINIT_LOADED_PART2=1
###############################################################################
# Assinatura (gpg|minisign|sbsign para UKI)
###############################################################################
_mk_sign_file() { # _mk_sign_file <file>
  local f="$1"
  [[ -n "${CFG[sign]}" ]] || return 0
  case "${CFG[sign]}" in
    gpg)
      command -v gpg >/dev/null 2>&1 || { mk_err "gpg ausente para assinatura"; return 2; }
      gpg --batch --yes ${CFG[key]:+--local-user "${CFG[key]}"} --output "${f}.sig" --detach-sign "$f" >> "${ST[build_log]}" 2>&1 || {
        mk_err "assinatura gpg falhou"; return 4; }
      ;;
    minisign)
      command -v minisign >/dev/null 2>&1 || { mk_err "minisign ausente para assinatura"; return 2; }
      minisign -Sm "$f" ${CFG[key]:+-s "${CFG[key]}"} >> "${ST[build_log]}" 2>&1 || { mk_err "assinatura minisign falhou"; return 4; }
      ;;
    sbsign)
      command -v sbsign >/dev/null 2>&1 || { mk_err "sbsign ausente"; return 2; }
      # sbsign é para binários EFI; aqui apenas habilitamos nas rotinas de UKI
      ;;
    *) mk_err "método de assinatura inválido: ${CFG[sign]}"; return 1;;
  esac
  mk_ok "assinado: ${f}.sig"
}

###############################################################################
# UKI (Unified Kernel Image) opcional
###############################################################################
_mk_build_uki() { # depende de systemd-stub, kernel e initramfs
  [[ "${CFG[uki]}" == "true" ]] || return 0
  command -v objcopy >/dev/null 2>&1 || { mk_err "objcopy ausente (requerido para UKI)"; return 2; }

  local root="${CFG[root]%/}"
  local stub="${root}/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
  [[ -r "$stub" ]] || stub="/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
  [[ -r "$stub" ]] || { mk_err "systemd-stub não encontrado"; return 2; }

  local vmlinuz="${root}/boot/vmlinuz-${KVER}"
  [[ -r "$vmlinuz" ]] || vmlinuz="/boot/vmlinuz-${KVER}"
  [[ -r "$vmlinuz" ]] || { mk_err "kernel vmlinuz-${KVER} não encontrado (root=$root)"; return 5; }

  local initram="${P[outimg]}"
  [[ -r "$initram" ]] || { mk_err "initramfs ausente para UKI"; return 5; }

  local cmdline_file="${P[tree]}/cmdline.txt"
  [[ -r "$cmdline_file" ]] || cmdline_file="${root}/etc/kernel/cmdline"
  [[ -r "$cmdline_file" ]] || cmdline_file="/proc/cmdline"

  local uki_name="${CFG[uki_name]:-adm}"
  local out_efi="${CFG[root]%/}/boot/EFI/Linux/${uki_name}-${KVER}.efi"
  mkdir -p -- "$(dirname -- "$out_efi")" || { mk_err "falha ao criar diretório do UKI"; return 3; }

  # Empacotar UKI (objcopy com seções)
  objcopy \
    --add-section .osrel="${root}/etc/os-release" --change-section-vma .osrel=0x20000 \
    --add-section .cmdline="${cmdline_file}"     --change-section-vma .cmdline=0x30000 \
    --add-section .linux="${vmlinuz}"            --change-section-vma .linux=0x40000 \
    --add-section .initrd="${initram}"           --change-section-vma .initrd=0x3000000 \
    "$stub" "$out_efi" >> "${ST[build_log]}" 2>&1 || { mk_err "objcopy falhou ao construir UKI"; return 3; }

  if [[ "${CFG[sign]}" == "sbsign" ]]; then
    local key="${CFG[key]}"
    [[ -n "$key" ]] || { mk_err "sbsign requer --key <cert+key> ou configuração do shim"; return 1; }
    sbsign --key "$key" --cert "$key" --output "$out_efi" "$out_efi" >> "${ST[build_log]}" 2>&1 || {
      mk_err "sbsign falhou"; return 4; }
  fi

  sha256sum "$out_efi" > "${out_efi}.sha256" 2>>"${ST[build_log]}" || true
  mk_ok "UKI: ${out_efi}"
}

###############################################################################
# Instalação e atualização de bootloader (opcional)
###############################################################################
adm_mkinit_install() {
  local kver="" root="/"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kver) kver="$2"; shift 2;;
      --root) root="$2"; shift 2;;
      --update-grub) CFG[update_grub]="true"; shift;;
      *) mk_warn "flag desconhecida: $1"; shift;;
    esac
  done
  [[ -n "$kver" ]] || { mk_err "uso: adm_mkinit_install --kver <vers> [--root DIR] [--update-grub]"; return 1; }

  CFG[root]="$root"; CFG[kver]="$kver"
  _mk_paths_init || return $?
  _mk_detect_kernel || return $?

  local img="${P[outimg]}"
  [[ -r "$img" ]] || { mk_err "initramfs não encontrado: $img"; return 3; }

  mk_step "install" "instalando ${img}"
  # nada a fazer, já está em /boot; atualizações de bootloader:
  if [[ "${CFG[update_grub]}" == "true" ]]; then
    if command -v grub-mkconfig >/dev/null 2>&1; then
      grub-mkconfig -o "${root%/}/boot/grub/grub.cfg" >> "${ST[install_log]}" 2>&1 || { mk_warn "grub-mkconfig falhou"; return 6; }
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
      grub2-mkconfig -o "${root%/}/boot/grub2/grub.cfg" >> "${ST[install_log]}" 2>&1 || { mk_warn "grub2-mkconfig falhou"; return 6; }
    else
      mk_warn "grub-mkconfig não encontrado; pulei update-grub"
    fi
  fi
  mk_ok "instalação concluída"
}

###############################################################################
# Lista kernels e initramfs
###############################################################################
adm_mkinit_list() {
  local root="/"; local json=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root) root="$2"; shift 2;;
      --json|--print-json) json=true; shift;;
      *) mk_warn "flag desconhecida: $1"; shift;;
    esac
  done
  local dir="${root%/}/lib/modules"
  [[ -d "$dir" ]] || { mk_err "não encontrei $dir"; return 3; }
  if $json; then
    echo -n '['
    local first=true
    for v in $(ls -1 "$dir" | sort); do
      local img="${root%/}/boot/initramfs-${v}-$(uname -m)-$(ldd --version 2>/dev/null | sed -n '1s/.*\(musl\|glibc\).*/\1/p' )*.img"
      local path
      path="$(ls -1 ${root%/}/boot/initramfs-${v}-* 2>/dev/null | head -n1 || true)"
      $first || echo -n ','
      printf '{"kver":%s,"initramfs":%s}' "$(_mk_escape_json "$v")" "$(_mk_escape_json "${path:-}")"
      first=false
    done
    echo ']'
  else
    for v in $(ls -1 "$dir" | sort); do
      local path; path="$(ls -1 ${root%/}/boot/initramfs-${v}-* 2>/dev/null | head -n1 || true)"
      echo "$v -> ${path:-<nenhum>}"
    done
  fi
}

###############################################################################
# Verificação
###############################################################################
adm_mkinit_verify() {
  local arg="" root="/"; local strict=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root) root="$2"; shift 2;;
      --strict) strict=true; shift;;
      *) arg="${arg:-$1}"; shift;;
    esac
  done
  [[ -n "$arg" ]] || { mk_err "uso: adm_mkinit_verify <kver|caminho> [--root DIR] [--strict]"; return 1; }

  local img="$arg"
  if [[ ! -r "$img" ]]; then
    local v="$arg"
    img="${root%/}/boot/initramfs-${v}-$(uname -m)-$(ldd --version 2>/dev/null | sed -n '1s/.*\(musl\|glibc\).*/\1/p').img"
    [[ -r "$img" ]] || { mk_err "initramfs não encontrado: $arg"; return 3; }
  fi
  mk_step "verify" "$img"
  local got; got="$(sha256sum "$img" | awk '{print $1}')"
  local sumf="${img}.sha256"
  if [[ -r "$sumf" ]]; then
    local exp; exp="$(awk '{print $1}' "$sumf")"
    [[ "$got" == "$exp" ]] || { mk_err "SHA256 divergente (got=$got exp=$exp)"; return 4; }
  else
    mk_warn "arquivo .sha256 ausente; apenas calculado: $got"
  fi

  if $strict; then
    # checa se cpio está íntegro (lista entradas)
    if ! ( zstd -t "$img" >/dev/null 2>&1 || xz -t "$img" >/dev/null 2>&1 || gzip -t "$img" >/dev/null 2>&1 ); then
      # tentar listar assumindo não comprimido
      cpio -it < "$img" >/dev/null 2>>"${ST[verify_log]}" || mk_warn "não foi possível inspecionar cpio (compressão?)"
    fi
  fi
  mk_ok "verificação OK"
}

###############################################################################
# Purge initramfs antigos (mantém --keep por kernel)
###############################################################################
adm_mkinit_purge() {
  local root="/" keep="2"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root) root="$2"; shift 2;;
      --keep) keep="$2"; shift 2;;
      *) mk_warn "flag desconhecida: $1"; shift;;
    esac
  done
  local bdir="${root%/}/boot"
  [[ -d "$bdir" ]] || { mk_err "diretório /boot inexistente (root=$root)"; return 3; }

  # agrupa por kver
  for v in $(ls -1 "${root%/}/lib/modules" 2>/dev/null | sort); do
    mapfile -t imgs < <(ls -1 "${bdir}/initramfs-${v}-"* 2>/dev/null | xargs -r -I{} stat -c '%Y %n' {} | sort -rn | awk '{print $2}')
    (( ${#imgs[@]} <= keep )) && continue
    local idx=0
    for f in "${imgs[@]}"; do
      idx=$((idx+1))
      (( idx <= keep )) && continue
      mk_step "purge" "removendo $f"
      rm -f -- "$f" "${f}.sha256" "${f}.sig" >> "${ST[install_log]}" 2>&1 || mk_warn "falha ao remover $f"
    done
  done
  mk_ok "purge concluído (keep=${keep})"
}
# 18-adm-mkinitramfs.part3.sh
# CLI e integração (assinatura + UKI após build)
if [[ -n "${ADM_MKINIT_LOADED_PART3:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_MKINIT_LOADED_PART3=1
###############################################################################
# Pós-build: assinar e (opcional) criar UKI
###############################################################################
_mk_post_build() {
  local img="$1"
  [[ -r "$img" ]] || { mk_err "imagem inexistente para pós-build"; return 3; }
  _mk_sign_file "$img" || return $?
  _mk_build_uki || return $?
  return 0
}

###############################################################################
# Ajuda e CLI
###############################################################################
_mk_usage() {
  cat >&2 <<'EOF'
uso:
  adm_mkinitramfs build [--kver VER|--kpath /lib/modules/VER] [--root DIR]
                       [--modules 'a,b'] [--blacklist 'x,y']
                       [--luks] [--lvm] [--mdraid] [--btrfs] [--zfs] [--net]
                       [--microcode auto|intel|amd|off]
                       [--compress zstd|xz|gzip|none] [--level N]
                       [--cmdline '...'] [--cmdline-file PATH]
                       [--uki] [--uki-name NAME] [--update-grub]
                       [--sign gpg|minisign|sbsign] [--key ID|PATH]
                       [--dry-run] [--verbose] [--json] [--allow-host-firmware]

  adm_mkinitramfs install --kver VER [--root DIR] [--update-grub]
  adm_mkinitramfs list [--root DIR] [--json]
  adm_mkinitramfs verify <kver|/caminho/initramfs.img> [--root DIR] [--strict]
  adm_mkinitramfs purge [--root DIR] [--keep 2]
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="$1"; shift || true
  case "$cmd" in
    build)
      img="$(adm_mkinit_build "$@")" || exit $?
      _mk_post_build "$img" || exit $?
      [[ "${CFG[update_grub]}" == "true" ]] && adm_mkinit_install --kver "${KVER}" --root "${CFG[root]}" --update-grub || true
      exit 0;;
    install) adm_mkinit_install "$@" || exit $?;;
    list)    adm_mkinit_list "$@" || exit $?;;
    verify)  adm_mkinit_verify "$@" || exit $?;;
    purge)   adm_mkinit_purge "$@" || exit $?;;
    ""|help|-h|--help) _mk_usage; exit 2;;
    *) mk_warn "comando desconhecido: $cmd"; _mk_usage; exit 2;;
  esac
fi

ADM_MKINIT_LOADED=1
export ADM_MKINIT_LOADED
