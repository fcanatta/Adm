#!/usr/bin/env bash
# (mesmo conteúdo do hook de EFI; duplicado para BIOS)
set -Eeuo pipefail
: "${DESTDIR:=/}"
BOOTDIR="${DESTDIR}/boot"
GRUBDIR="${BOOTDIR}/grub"
CFG="${GRUBDIR}/grub.cfg"

mkdir -p "${GRUBDIR}"
have() { command -v "$1" >/dev/null 2>&1; }
trim() { sed -E 's/^[[:space:]]+|[[:space:]]+$//g'; }

DEF="${DESTDIR}/etc/default/grub"
GRUB_TIMEOUT="5"
GRUB_DISTRIBUTOR="ADM"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
if [[ -f "${DEF}" ]]; then
  set +u; source "${DEF}"; set -u || true
  : "${GRUB_TIMEOUT:=5}"
  : "${GRUB_DISTRIBUTOR:=ADM}"
  : "${GRUB_CMDLINE_LINUX_DEFAULT:=quiet splash}"
  : "${GRUB_CMDLINE_LINUX:=}"
fi
EXTRA_CMDLINE="$(printf "%s %s" "${GRUB_CMDLINE_LINUX}" "${GRUB_CMDLINE_LINUX_DEFAULT}" | trim)"

ROOT_ARG=""
if [[ "${DESTDIR}" == "/" ]]; then
  if have findmnt && have blkid; then
    ROOT_DEV="$(findmnt -no SOURCE / || true)"
    if [[ -n "${ROOT_DEV}" ]]; then
      UUID="$(blkid -s UUID -o value "${ROOT_DEV}" 2>/dev/null || true)"
      LABEL="$(blkid -s LABEL -o value "${ROOT_DEV}" 2>/dev/null || true)"
      if [[ -n "${UUID}" ]]; then ROOT_ARG="root=UUID=${UUID}"
      elif [[ -n "${LABEL}" ]]; then ROOT_ARG="root=LABEL=${LABEL}"
      fi
    fi
  fi
fi
: "${ADM_LABEL:=ADMROOT}"
if [[ -z "${ROOT_ARG}" ]]; then
  ROOT_ARG="root=LABEL=${ADM_LABEL}"
fi

shopt -s nullglob
mapfile -t KFILES < <(cd "${BOOTDIR}" && ls -1 vmlinuz* 2>/dev/null | sort -V || true)

MICROCODE=()
[[ -f "${BOOTDIR}/intel-ucode.img" ]] && MICROCODE+=("/boot/intel-ucode.img")
[[ -f "${BOOTDIR}/amd-ucode.img"   ]] && MICROCODE+=("/boot/amd-ucode.img")

{
  echo "set default=0"
  echo "set timeout=${GRUB_TIMEOUT}"
  echo "set gfxpayload=keep"
  echo
  idx=0
  for kf in "${KFILES[@]}"; do
    kpath="/boot/${kf}"
    ver="${kf#vmlinuz-}"
    [[ "${ver}" == "${kf}" ]] && ver="${kf}"
    cand=( \
      "${BOOTDIR}/initrd-${ver}" \
      "${BOOTDIR}/initramfs-${ver}.img" \
      "${BOOTDIR}/initrd.img-${ver}" \
      "${BOOTDIR}/initrd-${ver}.img" \
      "${BOOTDIR}/initramfs-${ver}" \
      "${BOOTDIR}/initrd" \
      "${BOOTDIR}/initramfs" \
    )
    found_init=""
    for c in "${cand[@]}"; do
      [[ -f "$c" ]] && { found_init="${c}"; break; }
    done

    title="ADM Linux ${ver}"
    echo "menuentry '${title}' --class gnu-linux --class gnu --class os {"
    echo "    echo 'Carregando kernel ${ver}...'"
    echo -n "    linux  ${kpath} ${ROOT_ARG} ro ${EXTRA_CMDLINE}"
    echo
    if (( ${#MICROCODE[@]} > 0 )) || [[ -n "${found_init}" ]]; then
      echo -n "    initrd "
      for mc in "${MICROCODE[@]}"; do echo -n "${mc} "; done
      [[ -n "${found_init}" ]] && echo -n "${found_init}"
      echo
    fi
    echo "}"
    echo
    echo "menuentry '${title} (recovery)' --class gnu-linux --class gnu --class os {"
    echo "    echo 'Carregando kernel ${ver} (single)...'"
    echo -n "    linux  ${kpath} ${ROOT_ARG} ro single ${EXTRA_CMDLINE}"
    echo
    if (( ${#MICROCODE[@]} > 0 )) || [[ -n "${found_init}" ]]; then
      echo -n "    initrd "
      for mc in "${MICROCODE[@]}"; do echo -n "${mc} "; done
      [[ -n "${found_init}" ]] && echo -n "${found_init}"
      echo
    fi
    echo "}"
    echo
    idx=$((idx+1))
  done
} > "${CFG}"

chmod 0644 "${CFG}"
echo "[grubcfg] escrito: ${CFG}"
echo "[grubcfg] ROOT_ARG=${ROOT_ARG}"
echo "[grubcfg] KERNELS=${#KFILES[@]} (microcode: ${#MICROCODE[@]})"
