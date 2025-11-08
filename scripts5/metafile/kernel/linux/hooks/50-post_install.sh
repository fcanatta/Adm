#!/usr/bin/env sh
# Instala módulos em DESTDIR e copia vmlinuz/System.map para DESTDIR/boot

set -eu
: "${SRC_DIR:?}"
: "${BUILD_DIR:?}"
: "${DESTDIR:?}"

O="$(cat "${BUILD_DIR}/.kbuild_O" 2>/dev/null || echo "$SRC_DIR")"
KREL="$(cat "${BUILD_DIR}/.kernelrelease" 2>/dev/null || make O="$O" -s kernelrelease)"

# Instala módulos
make O="$O" modules_install INSTALL_MOD_PATH="$DESTDIR"

# Instala kernel image + System.map
mkdir -p "$DESTDIR/boot" || true

img=""
case "${ADM_KERNEL_IMAGE:-bzImage}" in
  bzImage) img="$O/arch/x86/boot/bzImage";;
  Image)   img="$O/arch/arm64/boot/Image";;  # ajuste se usar outra arch
  zImage)  img="$O/arch/arm/boot/zImage";;
  *)       img="$O/arch/$(uname -m)/boot/${ADM_KERNEL_IMAGE}";;
esac
[ -f "$img" ] || { echo "Imagem do kernel não encontrada: $img" >&2; exit 1; }

cp -f "$img"                 "$DESTDIR/boot/vmlinuz-$KREL"
[ -f "$O/System.map" ] && cp -f "$O/System.map" "$DESTDIR/boot/System.map-$KREL" || true
[ -f "$O/.config" ]     && cp -f "$O/.config"   "$DESTDIR/boot/config-$KREL"     || true

# Metadados auxiliares
{
  echo "NAME=linux"
  echo "KERNELRELEASE=${KREL}"
  echo "IMAGE=${ADM_KERNEL_IMAGE:-bzImage}"
  echo "BOOT_IMAGE=/boot/vmlinuz-${KREL}"
  echo "MODULES_DIR=/lib/modules/${KREL}"
  echo "TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$DESTDIR/boot/.adm-linux-${KREL}.meta" 2>/dev/null || true

# Dica: o adm (CLI) já detecta 'linux' e chama o adm-kinit.sh depois da instalação.
# Se quiser forçar aqui, exporte ADM_KERNEL_RUN_KINIT=1 antes do build e descomente:
# if [ "${ADM_KERNEL_RUN_KINIT:-0}" -eq 1 ] && command -v adm-kinit.sh >/dev/null 2>&1; then
#   adm-kinit.sh plan && adm-kinit.sh build && adm-kinit.sh install --keep-old 3
# fi
