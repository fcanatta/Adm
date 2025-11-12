#!/usr/bin/env bash
set -Eeuo pipefail
: "${DESTDIR:=/}"
: "${PREFIX:=/usr}"

mkdir -p "${DESTDIR}${PREFIX}/sbin"
cat > "${DESTDIR}${PREFIX}/sbin/adm-mkimage" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail

# Defaults
ROOT="${ADM_ROOT:-/}"
OUT="${ADM_OUT:-/usr/src/adm/out}"
FS="${ADM_FS:-ext4}"        # ext4|btrfs
SIZE_MB="${ADM_IMG_SIZE:-4096}"
LABEL="${ADM_LABEL:-ADMROOT}"
MAKE_ISO="${ADM_ISO:-0}"    # 1 = tenta ISO EFI
DATE="$(date +%Y%m%d)"
KERNEL="${ADM_KERNEL:-}"
INITRD="${ADM_INITRD:-}"

mkdir -p "$OUT"
echo "[mkimage] ROOT=$ROOT FS=$FS SIZE_MB=$SIZE_MB LABEL=$LABEL OUT=$OUT"

# 1) ROOTFS archive
RTF="${OUT}/rootfs-${DATE}.tar.zst"
echo "[mkimage] criando rootfs: $RTF"
tar --numeric-owner --xattrs --acls -C "$ROOT" -cpf - . | zstd -19 -T0 -o "$RTF"

# 2) DISK image (partitionless fs image)
IMG="${OUT}/disk-${FS}-${SIZE_MB}MiB-${DATE}.img"
echo "[mkimage] criando imagem: $IMG"
truncate -s "${SIZE_MB}M" "$IMG"

case "$FS" in
  ext4)
    mkfs.ext4 -F -L "$LABEL" "$IMG"
    ;;
  btrfs)
    mkfs.btrfs -f -L "$LABEL" "$IMG"
    ;;
  *)
    echo "[mkimage] ERRO: FS inválido: $FS" >&2; exit 2
    ;;
esac

# 3) Monta e popula
MP="$(mktemp -d)"
cleanup() { umount "$MP" 2>/dev/null || true; rmdir "$MP" 2>/dev/null || true; }
trap cleanup EXIT

mount -o loop "$IMG" "$MP"
echo "[mkimage] extraindo rootfs em $MP"
tar -C "$MP" -xpf "$RTF"

# 4) kernel/initrd (se indicados)
if [[ -z "$KERNEL" ]]; then
  # tenta detectar
  KERNEL="$(ls "$ROOT"/boot/vmlinuz* 2>/dev/null | head -n1 || true)"
fi
if [[ -n "$KERNEL" && -f "$KERNEL" ]]; then
  mkdir -p "$MP/boot"
  cp -f "$KERNEL" "$MP/boot/"
  echo "[mkimage] kernel copiado: $(basename "$KERNEL")"
fi
if [[ -z "$INITRD" ]]; then
  INITRD="$(ls "$ROOT"/boot/initrd* "$ROOT"/boot/initramfs* 2>/dev/null | head -n1 || true)"
fi
if [[ -n "$INITRD" && -f "$INITRD" ]]; then
  mkdir -p "$MP/boot"
  cp -f "$INITRD" "$MP/boot/"
  echo "[mkimage] initrd copiado: $(basename "$INITRD")"
fi

sync
umount "$MP"; rmdir "$MP"
trap - EXIT
echo "[mkimage] imagem pronta: $IMG"

# 5) ISO EFI opcional (requer grub-mkrescue + xorriso + mtools)
if [[ "$MAKE_ISO" == "1" ]]; then
  if command -v grub-mkrescue >/dev/null 2>&1 && command -v xorriso >/dev/null 2>&1 && command -v mformat >/dev/null 2>&1; then
    ISODIR="$(mktemp -d)"
    mkdir -p "$ISODIR/boot/grub" "$ISODIR/EFI/BOOT"
    # Copia kernel/initrd/dtb se existirem
    if [[ -n "$KERNEL" && -f "$KERNEL" ]]; then cp -f "$KERNEL" "$ISODIR/boot/"; fi
    if [[ -n "$INITRD" && -f "$INITRD" ]]; then cp -f "$INITRD" "$ISODIR/boot/"; fi

    # grub.cfg básico
    cat > "$ISODIR/boot/grub/grub.cfg" <<'CFG'
set timeout=5
set default=0
menuentry "ADM Linux" {
    linux  /boot/vmlinuz root=/dev/ram0 rw
    initrd /boot/initrd
}
CFG
    ISO="${OUT}/adm-${DATE}.iso"
    echo "[mkimage] criando ISO EFI: $ISO"
    grub-mkrescue -o "$ISO" "$ISODIR" || {
      echo "[mkimage] aviso: grub-mkrescue falhou, verifique dependências"; exit 0; }
    rm -rf "$ISODIR"
    echo "[mkimage] ISO pronta: $ISO"
  else
    echo "[mkimage] ISO pulada (faltam grub-mkrescue/xorriso/mtools)"
  fi
fi

echo "[mkimage] DONE"
SH
chmod +x "${DESTDIR}${PREFIX}/sbin/adm-mkimage"
echo "[adm-mkimage] /usr/sbin/adm-mkimage instalado."
