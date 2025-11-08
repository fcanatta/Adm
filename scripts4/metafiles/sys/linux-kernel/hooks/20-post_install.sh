#!/usr/bin/env bash
# Kernel: pós-instalação — mkinitramfs opcional + registro
set -euo pipefail

log(){ command -v adm_step >/dev/null 2>&1 && adm_step "linux-kernel" "final" "$*" || echo "[kernel-post] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[kernel-post][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[kernel-post][WARN] $*"; }

: "${ROOT:?ROOT não definido}"
: "${SRC_DIR:?SRC_DIR não definido}"

KVER="$(cat "${SRC_DIR}/.kver" 2>/dev/null || true)"
[[ -n "${KVER}" ]] || KVER="$(basename -- "$(ls -1 "${ROOT}/lib/modules" 2>/dev/null | sort | tail -n1)")"

# mkinitramfs (se disponível e desejado)
if command -v adm_mkinitramfs >/dev/null 2>&1 && [[ "${KCFG_INITRAMFS:-1}" != "0" ]]; then
  log "gerando initramfs para ${KVER}"
  adm_mkinitramfs build --kver "${KVER}" --root "${ROOT}" ${KCFG_UKI:+--uki} ${KCFG_SIGN:+--sign "${KCFG_SIGN}"} >> "${SRC_DIR}/mkinitramfs.log" 2>&1 || warn "mkinitramfs falhou"
else
  warn "mkinitramfs não executado (desabilitado ou não disponível)"
fi

# Atualiza bootloader (opcional)
if [[ "${KCFG_UPDATE_GRUB:-0}" == "1" ]]; then
  if command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o "${ROOT%/}/boot/grub/grub.cfg" >> "${SRC_DIR}/grub.log" 2>&1 || warn "grub-mkconfig falhou"
  elif command -v grub2-mkconfig >/dev/null 2>&1; then
    grub2-mkconfig -o "${ROOT%/}/boot/grub2/grub.cfg" >> "${SRC_DIR}/grub.log" 2>&1 || warn "grub2-mkconfig falhou"
  fi
fi

# Registro
state_dir="${ROOT}/usr/src/adm/state/kernel/${KVER}"
mkdir -p -- "${state_dir}"
{
  echo "package=sys/linux-kernel"
  echo "version=${KVER}"
  date -u +"built=%Y-%m-%dT%H:%M:%SZ"
} > "${state_dir}/build.info"

ok "pós-instalação concluída"
