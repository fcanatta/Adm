#!/usr/bin/env sh
# adm-kinit.sh — Kernel + Initramfs Orchestrator (LFS/ADM)
# POSIX sh; compatível com dash/ash/bash.
set -u
# =========================
# 0) Config & defaults
# =========================
: "${ADM_ROOT:=/usr/src/adm}"
: "${ADM_LOG_COLOR:=auto}"
: "${ADM_STAGE:=host}"
: "${ADM_PIPELINE:=kinit}"

BIN_DIR="$ADM_ROOT/bin"
REG_DIR="$ADM_ROOT/registry/kinit"
LOG_DIR="$ADM_ROOT/logs/kinit"
PRESET_DIR="$ADM_ROOT/kinit/presets"

KEEP_OLD=3
UPDATE_BOOTLOADER="on"
BACKEND="auto"         # auto|dracut|mkinitramfs|mkinitcpio|busybox
KERNEL_IMG=""          # --kernel (vmlinuz|bzImage)
MODULES_DIR=""         # --modules (/lib/modules/<kver>)
KVER=""                # --kver
MICROCODE="auto"       # auto|intel|amd|off
FIRMWARE="auto"        # auto|DIR
COMPRESS="zstd"        # zstd|xz|gzip|none
ROOT_DEV=""            # --root (UUID=... | LABEL=... | /dev/...)
FSTYPE=""              # --fstype (ext4|xfs|btrfs|...)
LUKS="auto"            # auto|off
LVM="auto"             # auto|off
PLYMOUTH="off"         # on|off
STAGE_USE=""

VERBOSE=0

# =========================
# 1) Cores + logging (fallback se adm-log.sh não existir)
# =========================
_is_tty(){ [ -t 1 ]; }
_color_on=0
_color_setup(){
  if [ "${ADM_LOG_COLOR}" = "never" ] || [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ]; then
    _color_on=0
  elif [ "${ADM_LOG_COLOR}" = "always" ] || _is_tty; then
    _color_on=1
  else
    _color_on=0
  fi
}
_b(){ [ $_color_on -eq 1 ] && printf '\033[1m'; }
_rst(){ [ $_color_on -eq 1 ] && printf '\033[0m'; }
_c_mag(){ [ $_color_on -eq 1 ] && printf '\033[35;1m'; }  # estágio rosa
_c_yel(){ [ $_color_on -eq 1 ] && printf '\033[33;1m'; }  # path amarelo
_c_gry(){ [ $_color_on -eq 1 ] && printf '\033[38;5;244m';}

have_adm_log=0
command -v adm_log_info >/dev/null 2>&1 && have_adm_log=1

_ts(){ date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([0-9][0-9]\)$/:\1/'; }
_ctx(){
  st="${ADM_STAGE:-host}"; pipe="${ADM_PIPELINE:-kinit}"; path="${PWD:-/}"
  if [ $_color_on -eq 1 ]; then
    printf "("; _c_mag; printf "%s" "$st"; _rst; _c_gry; printf ":%s" "$pipe"; _rst
    printf " path="; _c_yel; printf "%s" "$path"; _rst; printf ")"
  else
    printf "(%s:%s path=%s)" "$st" "$pipe" "$path"
  fi
}
say(){
  lvl="$1"; shift; msg="$*"
  if [ $have_adm_log -eq 1 ]; then
    case "$lvl" in
      INFO)  adm_log_info  "$msg";;
      WARN)  adm_log_warn  "$msg";;
      ERROR) adm_log_error "$msg";;
      STEP)  adm_log_step_start "$msg" >/dev/null;;
      OK)    adm_log_step_ok;;
      DEBUG) adm_log_debug "$msg";;
      *)     adm_log_info "$msg";;
    esac
  else
    _color_setup
    case "$lvl" in
      INFO) t="[INFO]";; WARN) t="[WARN]";; ERROR) t="[ERROR]";; STEP) t="[STEP]";; OK) t="[ OK ]";; DEBUG) t="[DEBUG]";;
      *) t="[$lvl]";;
    esac
    printf "%s [%s] %s %s\n" "$t" "$(_ts)" "$(_ctx)" "$msg"
  fi
}
die(){ say ERROR "$*"; exit 40; }

# =========================
# 2) Utils
# =========================
ensure_dirs(){
  for d in "$REG_DIR" "$LOG_DIR" "$PRESET_DIR"; do
    [ -d "$d" ] || mkdir -p "$d" || die "não foi possível criar: $d"
  done
}
lower(){ printf "%s" "$1" | tr 'A-Z' 'a-z'; }
trim(){ printf "%s" "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
basename_s(){ p="$1"; b="$(basename "$p" 2>/dev/null || echo "$p")"; printf "%s" "$b" | sed 's/[?].*$//'; }
sha256_file(){ command -v sha256sum >/dev/null 2>&1 || die "sha256sum ausente"; sha256sum "$1" | awk '{print $1}'; }
human(){ num="${1:-0}"; awk -v n="$num" 'BEGIN{ split("B KB MB GB TB",u); i=1; while(n>=1024 && i<5){n/=1024;i++} printf("%.1f %s", n, u[i]) }'; }

safe_rm_rf(){
  p="$1"
  [ -n "$p" ] || { say ERROR "safe_rm_rf: caminho vazio"; return 1; }
  case "$p" in /|"") say ERROR "safe_rm_rf: caminho proibido: $p"; return 1;; esac
  rm -rf -- "$p" 2>/dev/null || { say WARN "falha ao remover $p"; return 1; }
  return 0
}

with_timeout(){
  t="$1"; shift
  if [ "$t" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
    timeout "$t" "$@"
  else
    "$@"
  fi
}

exec_host_or_stage(){
  if [ -n "$STAGE_USE" ]; then
    [ -x "$BIN_DIR/adm-stage.sh" ] || die "adm-stage.sh necessário para --stage"
    "$BIN_DIR/adm-stage.sh" exec --stage "$STAGE_USE" -- "$@"
  else
    "$@"
  fi
}

# =========================
# 3) CLI
# =========================
usage(){
  cat <<'EOF'
Uso:
  adm-kinit.sh detect
  adm-kinit.sh plan   [opções...]
  adm-kinit.sh build  [opções...]
  adm-kinit.sh install [--keep-old N] [--update-bootloader on|off] [--stage {0|1|2}]
  adm-kinit.sh regen  --kver <vers>
  adm-kinit.sh bootloader update|probe
  adm-kinit.sh presets list|set <preset>

Opções comuns (plan/build):
  --kernel PATH(bzImage|vmlinuz)  --modules /lib/modules/<kver>  --kver <vers>
  --microcode auto|intel|amd|off   --firmware auto|DIR
  --compress zstd|xz|gzip|none     --root VAL   --fstype FS
  --luks auto|off                  --lvm auto|off
  --plymouth on|off                --backend auto|dracut|mkinitramfs|mkinitcpio|busybox
  --stage {0|1|2}                  --verbose
EOF
}

parse_common(){
  while [ $# -gt 0 ]; do
    case "$1" in
      --kernel) shift; KERNEL_IMG="$1";;
      --modules) shift; MODULES_DIR="$1";;
      --kver) shift; KVER="$1";;
      --microcode) shift; MICROCODE="$(lower "$1")";;
      --firmware) shift; FIRMWARE="$1";;
      --compress) shift; COMPRESS="$(lower "$1")";;
      --root) shift; ROOT_DEV="$1";;
      --fstype) shift; FSTYPE="$(lower "$1")";;
      --luks) shift; LUKS="$(lower "$1")";;
      --lvm) shift; LVM="$(lower "$1")";;
      --plymouth) shift; PLYMOUTH="$(lower "$1")";;
      --backend) shift; BACKEND="$(lower "$1")";;
      --stage) shift; STAGE_USE="$1"; ADM_STAGE="stage$STAGE_USE";;
      --keep-old) shift; KEEP_OLD="$1";;
      --update-bootloader) shift; UPDATE_BOOTLOADER="$(lower "$1")";;
      --verbose) VERBOSE=$((VERBOSE+1));;
      *) echo "$1";;
    esac
    shift || true
  done
}

# =========================
# 4) Detecção de ambiente
# =========================
detect_kver_from_modules(){
  d="$1"
  [ -d "$d" ] || { echo ""; return; }
  b="$(basename "$d")"
  echo "$b"
}

detect_kver_from_kernel(){
  img="$1"
  [ -f "$img" ] || { echo ""; return; }
  # heurística simples: strings com Linux version X.Y.Z
  v="$(strings "$img" 2>/dev/null | grep -Eo ' [0-9]+\.[0-9]+(\.[0-9]+)?(-[A-Za-z0-9._-]+)?' | head -n1 | trim)"
  [ -n "$v" ] && echo "$v" || echo ""
}

detect_backends(){
  found=""
  command -v dracut >/dev/null 2>&1 && found="${found} dracut"
  command -v update-initramfs >/dev/null 2>&1 && found="${found} mkinitramfs"
  command -v mkinitramfs >/dev/null 2>&1 && found="${found} mkinitramfs"
  command -v mkinitcpio >/dev/null 2>&1 && found="${found} mkinitcpio"
  command -v cpio >/dev/null 2>&1 && command -v busybox >/dev/null 2>&1 && found="${found} busybox"
  echo "$found" | sed 's/^[ ]*//'
}

detect_bootloader(){
  if command -v grub-mkconfig >/dev/null 2>&1 || command -v grub2-mkconfig >/dev/null 2>&1; then
    echo "grub"
  elif command -v bootctl >/dev/null 2>&1; then
    echo "systemd-boot"
  elif command -v extlinux >/dev/null 2>&1 || command -v syslinux >/dev/null 2>&1; then
    echo "syslinux"
  else
    echo "unknown"
  fi
}

detect_root_from_fstab(){
  [ -f /etc/fstab ] || { echo ""; return; }
  # pega primeira raiz com "/"
  awk '$2=="/"{print $1; exit}' /etc/fstab 2>/dev/null
}

detect_fs_from_fstab(){
  [ -f /etc/fstab ] || { echo ""; return; }
  awk '$2=="/"{print $3; exit}' /etc/fstab 2>/dev/null
}

detect_crypto_lvm(){
  luks=off; lvm=off
  command -v cryptsetup >/dev/null 2>&1 && luks=auto
  command -v lvm >/dev/null 2>&1 && lvm=auto
  echo "$luks $lvm"
}

cmd_detect(){
  ensure_dirs
  say STEP "Detecção de ambiente"
  backends="$(detect_backends)"
  bl="$(detect_bootloader)"
  rd="$(detect_root_from_fstab)"
  fs="$(detect_fs_from_fstab)"
  set -- $(detect_crypto_lvm); luks_auto="$1"; lvm_auto="$2"

  echo "Backends disponíveis: $backends"
  echo "Bootloader: $bl"
  echo "Root (fstab): ${rd:-?}"
  echo "FSType (fstab): ${fs:-?}"
  echo "LUKS: $luks_auto  LVM: $lvm_auto"
  say OK
}

# =========================
# 5) Planejamento (plan)
# =========================
choose_backend(){
  case "$BACKEND" in
    dracut|mkinitramfs|mkinitcpio|busybox) echo "$BACKEND"; return;;
    auto)
      for b in dracut mkinitramfs mkinitcpio busybox; do
        echo "$(detect_backends)" | grep -q "$b" && { echo "$b"; return; }
      done
      echo "busybox";;
    *) echo "busybox";;
  esac
}

ensure_kver_and_modules(){
  # Resolve KVER e MODULES_DIR coerentes
  if [ -z "$KVER" ] && [ -n "$MODULES_DIR" ]; then
    KVER="$(detect_kver_from_modules "$MODULES_DIR")"
  fi
  if [ -z "$KVER" ] && [ -n "$KERNEL_IMG" ]; then
    KVER="$(detect_kver_from_kernel "$KERNEL_IMG")"
  fi
  [ -n "$KVER" ] || die "não foi possível determinar --kver (use --kver|--modules|--kernel)"
  [ -n "$MODULES_DIR" ] || MODULES_DIR="/lib/modules/$KVER"
  [ -d "$MODULES_DIR" ] || die "diretório de módulos não existe: $MODULES_DIR"
}

ensure_root_and_fs(){
  [ -n "$ROOT_DEV" ] || ROOT_DEV="$(detect_root_from_fstab)"
  [ -n "$FSTYPE" ]   || FSTYPE="$(detect_fs_from_fstab)"
  [ -n "$ROOT_DEV" ] || say WARN "root não determinado (use --root)"
  [ -n "$FSTYPE" ]   || say WARN "fstype não determinado (use --fstype)"
}

select_microcode(){
  case "$MICROCODE" in
    intel|amd|off) echo "$MICROCODE";;
    auto)
      if [ -d /lib/firmware/intel-ucode ]; then echo "intel";
      elif [ -d /lib/firmware/amd-ucode ]; then echo "amd";
      else echo "off"; fi;;
    *) echo "off";;
  esac
}

select_firmware_dir(){
  case "$FIRMWARE" in
    auto) [ -d /lib/firmware ] && echo "/lib/firmware" || echo "";;
    off|"") echo "";;
    *) echo "$FIRMWARE";;
  esac
}

mk_plan(){
  ensure_dirs
  ensure_kver_and_modules
  ensure_root_and_fs

  # decidir backend e recursos
  be="$(choose_backend)"
  uc="$(select_microcode)"
  fw="$(select_firmware_dir)"

  # decidir luks/lvm efetivos
  luks_eff="$LUKS"; lvm_eff="$LVM"
  [ "$luks_eff" = "auto" ] && command -v cryptsetup >/dev/null 2>&1 || luks_eff="off"
  [ "$lvm_eff"  = "auto" ] && command -v lvm >/dev/null 2>&1 || lvm_eff="off"

  plan_dir="$REG_DIR/$KVER"
  mkdir -p "$plan_dir" || die "não foi possível criar: $plan_dir"
  plan="$plan_dir/kinit.plan"

  {
    echo "KVER=$KVER"
    echo "MODULES_DIR=$MODULES_DIR"
    echo "KERNEL_IMG=$KERNEL_IMG"
    echo "BACKEND=$be"
    echo "MICROCODE=$uc"
    echo "FIRMWARE_DIR=$fw"
    echo "COMPRESS=$COMPRESS"
    echo "ROOT=$ROOT_DEV"
    echo "FSTYPE=$FSTYPE"
    echo "LUKS=$luks_eff"
    echo "LVM=$lvm_eff"
    echo "PLYMOUTH=$PLYMOUTH"
    echo "BOOTLOADER=$(detect_bootloader)"
    echo "TIMESTAMP=$(_ts)"
  } >"$plan" 2>/dev/null || die "não foi possível gravar plan"

  say INFO "Plano salvo: $plan"
  # resumo amigável
  echo "Resumo:"
  echo "  kver=$KVER backend=$be compress=$COMPRESS root=${ROOT_DEV:-?} fstype=${FSTYPE:-?}"
  echo "  microcode=$uc firmware=${fw:-none} luks=$luks_eff lvm=$lvm_eff plymouth=$PLYMOUTH"
  say OK
}
# =========================
# 6) Construção (build)
# =========================
comp_cmd(){
  case "$COMPRESS" in
    zstd) echo "zstd -19 -T0";;
    xz)   echo "xz -T0 -9";;
    gzip) echo "gzip -9";;
    none) echo "cat";;
    *)    echo "zstd -19 -T0";;
  esac
}

mkinit_dracut(){
  out="$1"
  args="--force --kver $KVER"
  [ -n "$KERNEL_IMG" ] && args="$args --kernel-image $KERNEL_IMG"
  case "$COMPRESS" in
    zstd) args="$args --compress zstd";;
    xz)   args="$args --compress xz";;
    gzip) args="$args --compress gzip";;
    none) args="$args --no-compress";;
  esac
  [ "$LUKS" != "off" ] && args="$args --add crypt"
  [ "$LVM"  != "off" ] && args="$args --add lvm"
  [ -n "$FSTYPE" ] && case "$FSTYPE" in btrfs) args="$args --add btrfs";; xfs) args="$args --add xfs";; esac
  [ "$PLYMOUTH" = "on" ] && args="$args --add plymouth"
  say INFO "dracut $args $out"
  dracut $args "$out" >/dev/null 2>&1 || return 1
  return 0
}

mkinit_mkinitramfs(){
  out="$1"
  # Debian/BusyBox initramfs-tools: update-initramfs -k $KVER -c -t (verbose)
  if command -v update-initramfs >/dev/null 2>&1; then
    # gera em /boot por padrão; copiamos depois para out se necessário
    say INFO "update-initramfs -c -k $KVER"
    update-initramfs -c -k "$KVER" >/dev/null 2>&1 || return 1
    # descobrir nome gerado
    g="/boot/initrd.img-$KVER"
    [ -f "$g" ] || g="/boot/initramfs-$KVER.img"
    [ -f "$g" ] || return 1
    cp -a "$g" "$out" || return 1
    return 0
  fi
  # BusyBox mkinitramfs mínimo (não initramfs-tools)
  tmp="$(mktemp -d 2>/dev/null || echo "/tmp/kinit-busy-$$")"
  mkdir -p "$tmp"/{bin,sbin,usr/bin,usr/sbin,etc,proc,sys,dev,run,newroot} || { safe_rm_rf "$tmp"; return 1; }
  # copia busybox
  if command -v busybox >/dev/null 2>&1; then
    cp "$(command -v busybox)" "$tmp/bin/" || { safe_rm_rf "$tmp"; return 1; }
    (cd "$tmp/bin" && ln -sf busybox sh; ln -sf busybox mount; ln -sf busybox cat; ln -sf busybox ln; ln -sf busybox mkdir; ln -sf busybox cp; ln -sf busybox modprobe; ln -sf busybox pivot_root; ln -sf busybox switch_root) || true
  else
    safe_rm_rf "$tmp"; return 1
  fi
  # /init simples
  cat >"$tmp/init"<<'EOFI'
#!/bin/sh
set -eu
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
echo "[initramfs] booting..."
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs devtmpfs /dev || mount -t tmpfs tmpfs /dev
modprobe -q ext4 2>/dev/null || true
modprobe -q xfs  2>/dev/null || true
modprobe -q btrfs 2>/dev/null || true
modprobe -q dm_mod 2>/dev/null || true
# root= via kernel cmdline
CMD="$(cat /proc/cmdline)"
ROOT="$(echo "$CMD" | sed -n 's/.*root=\([^ ]*\).*/\1/p')"
[ -n "$ROOT" ] || ROOT="/dev/sda1"
mkdir -p /newroot
mount "$ROOT" /newroot || { echo "FALHA: mount ROOT=$ROOT"; exec sh; }
# switch_root
exec switch_root /newroot /sbin/init
EOFI
  chmod +x "$tmp/init" || true
  # módulos do kernel (best-effort)
  if [ -d "$MODULES_DIR" ]; then
    mkdir -p "$tmp/lib/modules" && cp -a "$MODULES_DIR" "$tmp/lib/modules/" 2>/dev/null || true
    depmod -a "$KVER" 2>/dev/null || true
  fi
  # firmware opcional
  [ -n "$(select_firmware_dir)" ] && { mkdir -p "$tmp/lib/firmware" && cp -a "$(select_firmware_dir)"/* "$tmp/lib/firmware/" 2>/dev/null || true; }
  # empacotar
  comp="$(comp_cmd)"
  (cd "$tmp" && find . -print0 | cpio --null -o -H newc 2>/dev/null | sh -c "$comp > '$out'") || { safe_rm_rf "$tmp"; return 1; }
  safe_rm_rf "$tmp" || true
  return 0
}

mkinit_mkinitcpio(){
  out="$1"
  conf="$(mktemp 2>/dev/null || echo "/tmp/mkcpio-$$.conf")"
  hooks="base udev autodetect modconf block filesystems fsck"
  [ "$LUKS" != "off" ] && hooks="base udev keyboard keymap $hooks encrypt"
  [ "$LVM"  != "off" ] && hooks="$hooks lvm2"
  [ "$PLYMOUTH" = "on" ] && hooks="$hooks plymouth"
  {
    echo "MODULES=()"
    echo "BINARIES=()"
    echo "FILES=()"
    echo "HOOKS=($hooks)"
    case "$COMPRESS" in
      zstd) echo 'COMPRESSION="zstd"';;
      xz)   echo 'COMPRESSION="xz"';;
      gzip) echo 'COMPRESSION="gzip"';;
      none) echo 'COMPRESSION="cat"';;
    esac
  } >"$conf"
  say INFO "mkinitcpio -k $KVER -c $conf -g $out"
  mkinitcpio -k "$KVER" -c "$conf" -g "$out" >/dev/null 2>&1 || { rm -f "$conf"; return 1; }
  rm -f "$conf" || true
  return 0
}

build_initramfs(){
  ensure_dirs
  ensure_kver_and_modules
  out="/boot/initramfs-$KVER.img"
  be="$(choose_backend)"

  case "$be" in
    dracut)      mkinit_dracut "$out" || die "dracut falhou";;
    mkinitramfs) mkinit_mkinitramfs "$out" || die "mkinitramfs falhou";;
    mkinitcpio)  mkinit_mkinitcpio "$out" || die "mkinitcpio falhou";;
    busybox)     mkinit_mkinitramfs "$out" || die "busybox initramfs falhou";;
    *)           die "backend desconhecido: $be";;
  esac

  [ -f "$out" ] || die "initramfs não encontrado após build: $out"
  size="$(stat -c %s "$out" 2>/dev/null || echo 0)"
  hash="$(sha256_file "$out" 2>/dev/null || echo -)"
  say INFO "initramfs gerado: $out (size=$(human "$size"), sha256=$hash)"
  # meta
  meta="$REG_DIR/$KVER/kinit.meta"
  mkdir -p "$(dirname "$meta")" || die "não foi possível criar meta dir"
  {
    echo "KVER=$KVER"
    echo "BACKEND=$be"
    echo "COMPRESS=$COMPRESS"
    echo "INITRAMFS=$out"
    echo "INITRAMFS_SHA256=$hash"
    echo "TIMESTAMP=$(_ts)"
  } >"$meta" 2>/dev/null || die "falha ao gravar meta"
}

# =========================
# 7) Instalação em /boot + bootloader
# =========================
backup_boot(){
  ts="$(date +%Y%m%d-%H%M%S)"
  dst="$REG_DIR/$KVER/backups"
  mkdir -p "$dst" || die "não foi possível criar backup dir"
  out="$dst/boot-$ts.tar.zst"
  say INFO "backup de /boot → $out"
  if command -v zstd >/dev/null 2>&1; then
    (cd /boot && tar cf - . 2>/dev/null | zstd -q -T0 -o "$out") || die "falha backup /boot"
  else
    (cd /boot && tar cJf "$out".xz . 2>/dev/null) || die "falha backup /boot"
  fi
  # retenção
  n_keep="$KEEP_OLD"
  cnt="$(ls -1t "$dst"/boot-* 2>/dev/null | wc -l | awk '{print $1}')"
  if [ "$cnt" -gt "$n_keep" ]; then
    ls -1t "$dst"/boot-* 2>/dev/null | tail -n +"$((n_keep+1))" | while read -r old; do rm -f "$old" 2>/dev/null || true; done
  fi
}

install_kernel_and_initramfs(){
  ensure_kver_and_modules
  # kernel image destino
  kdst="/boot/vmlinuz-$KVER"
  mapdst="/boot/System.map-$KVER"
  initrd="/boot/initramfs-$KVER.img"

  [ -f "$initrd" ] || die "initramfs não encontrado: $initrd"
  [ -n "$KERNEL_IMG" ] && { cp -f "$KERNEL_IMG" "$kdst" || die "falha ao instalar kernel"; }
  # System.map best-effort (se existir lado a lado ao kernel)
  if [ -n "$KERNEL_IMG" ]; then
    kdir="$(dirname "$KERNEL_IMG")"
    [ -f "$kdir/System.map" ] && cp -f "$kdir/System.map" "$mapdst" 2>/dev/null || true
  fi
  # symlinks convenientes
  ln -sfn "vmlinuz-$KVER" /boot/vmlinuz 2>/dev/null || true
  ln -sfn "initramfs-$KVER.img" /boot/initramfs.img 2>/dev/null || true

  say INFO "kernel/initramfs instalados em /boot"
}

update_bootloader_grub(){
  # gera grub.cfg com entradas padrão
  cfg="/boot/grub/grub.cfg"; [ -d /boot/grub ] || mkdir -p /boot/grub || true
  if command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o "$cfg" >/dev/null 2>&1 || return 1
  elif command -v grub2-mkconfig >/dev/null 2>&1; then
    grub2-mkconfig -o "$cfg" >/dev/null 2>&1 || return 1
  else
    return 1
  fi
  say INFO "GRUB atualizado: $cfg"
  return 0
}

update_bootloader_systemd_boot(){
  [ -d /boot/loader/entries ] || mkdir -p /boot/loader/entries || true
  ent="/boot/loader/entries/adm-$KVER.conf"
  {
    echo "title   ADM Linux $KVER"
    echo "linux   /vmlinuz-$KVER"
    echo "initrd  /initramfs-$KVER.img"
    printf "options root=%s rw " "${ROOT_DEV:-/dev/sda1}"
    [ -n "$FSTYPE" ] && printf "rootfstype=%s " "$FSTYPE"
    [ "$PLYMOUTH" = "on" ] && printf "quiet splash "
    echo
  } >"$ent" 2>/dev/null || return 1
  say INFO "systemd-boot entry: $ent"
  return 0
}

update_bootloader_syslinux(){
  [ -d /boot/extlinux ] || mkdir -p /boot/extlinux || true
  cfg="/boot/extlinux/extlinux.conf"
  {
    echo "DEFAULT adm"
    echo "TIMEOUT 5"
    echo "LABEL adm"
    echo "  LINUX /vmlinuz-$KVER"
    echo "  INITRD /initramfs-$KVER.img"
    printf "  APPEND root=%s rw " "${ROOT_DEV:-/dev/sda1}"
    [ -n "$FSTYPE" ] && printf "rootfstype=%s " "$FSTYPE"
    [ "$PLYMOUTH" = "on" ] && printf "quiet splash "
    echo
  } >"$cfg" 2>/dev/null || return 1
  say INFO "syslinux atualizado: $cfg"
  return 0
}

update_bootloader(){
  [ "$UPDATE_BOOTLOADER" = "on" ] || { say INFO "update-bootloader=off (pulado)"; return 0; }
  bl="$(detect_bootloader)"
  case "$bl" in
    grub)         update_bootloader_grub || return 1;;
    systemd-boot) update_bootloader_systemd_boot || return 1;;
    syslinux)     update_bootloader_syslinux || return 1;;
    *)            say WARN "bootloader desconhecido; pulei atualização";;
  esac
  return 0
}

cmd_plan(){
  rem="$(parse_common "$@")"; set -- $rem
  mk_plan
}

cmd_build(){
  rem="$(parse_common "$@")"; set -- $rem
  build_initramfs
}

cmd_install(){
  rem="$(parse_common "$@")"; set -- $rem
  [ "$(id -u)" -eq 0 ] || die "precisa de root para instalar em /boot"
  backup_boot
  if ! install_kernel_and_initramfs; then
    say ERROR "falha na instalação — restaurando backup"
    # rollback simples: extrair último backup
    last="$(ls -1t "$REG_DIR/$KVER/backups"/boot-* 2>/dev/null | head -n1)"
    [ -n "$last" ] && {
      case "$last" in
        *.zst) zstd -dc "$last" | (cd /boot && tar xpf -) ;;
        *.xz)  xz  -dc "$last" | (cd /boot && tar xpf -) ;;
        *)     (cd /boot && tar xpf "$last") ;;
      esac
    }
    exit 21
  fi
  if ! update_bootloader; then
    say ERROR "bootloader falhou — restaurando backup"
    last="$(ls -1t "$REG_DIR/$KVER/backups"/boot-* 2>/dev/null | head -n1)"
    [ -n "$last" ] && {
      case "$last" in
        *.zst) zstd -dc "$last" | (cd /boot && tar xpf -) ;;
        *.xz)  xz  -dc "$last" | (cd /boot && tar xpf -) ;;
        *)     (cd /boot && tar xpf "$last") ;;
      esac
    }
    exit 22
  fi

  # atualizar meta com kernel hash
  kdst="/boot/vmlinuz-$KVER"
  initrd="/boot/initramfs-$KVER.img"
  hashk="-"; hashr="-"
  [ -f "$kdst" ] && hashk="$(sha256_file "$kdst" 2>/dev/null || echo -)"
  [ -f "$initrd" ] && hashr="$(sha256_file "$initrd" 2>/dev/null || echo -)"
  meta="$REG_DIR/$KVER/kinit.meta"
  {
    echo "KVER=$KVER"
    echo "KERNEL=$kdst"
    echo "KERNEL_SHA256=$hashk"
    echo "INITRAMFS=$initrd"
    echo "INITRAMFS_SHA256=$hashr"
    echo "BOOTLOADER=$(detect_bootloader)"
    echo "ROOT=${ROOT_DEV:-}"
    echo "FSTYPE=${FSTYPE:-}"
    echo "TIMESTAMP=$(_ts)"
  } >"$meta" 2>/dev/null || true

  say OK
}
# =========================
# 8) Regen / Bootloader util / Presets
# =========================
cmd_regen(){
  # Regenerar initramfs para um KVER já instalado (reusa plano ou detecta backend)
  rem="$(parse_common "$@")"; set -- $rem
  [ -n "$KVER" ] || die "use --kver"
  ensure_dirs
  [ -d "/lib/modules/$KVER" ] || die "/lib/modules/$KVER ausente"
  MODULES_DIR="/lib/modules/$KVER"
  build_initramfs
  cmd_install --kver "$KVER" >/dev/null 2>&1 || die "falha em install após regen"
  say OK
}

cmd_bootloader(){
  action="${1:-update}"
  case "$action" in
    update) update_bootloader || exit 22 ;;
    probe)  echo "$(detect_bootloader)" ;;
    *)      die "ação inválida para bootloader";;
  esac
}

cmd_presets(){
  op="${1:-list}"
  case "$op" in
    list)
      ensure_dirs
      ls -1 "$PRESET_DIR" 2>/dev/null | sed 's/\.conf$//' || true
      ;;
    set)
      p="${2:-}"; [ -n "$p" ] || die "informe o preset: presets set <nome>"
      f="$PRESET_DIR/$p.conf"
      [ -f "$f" ] || die "preset não encontrado: $p"
      # cada linha KEY=VAL atualiza variável correspondente
      while IFS='=' read -r k v; do
        [ -z "$k" ] && continue
        case "$k" in
          BACKEND) BACKEND="$(lower "$v")";;
          COMPRESS) COMPRESS="$(lower "$v")";;
          MICROCODE) MICROCODE="$(lower "$v")";;
          FIRMWARE) FIRMWARE="$v";;
          LUKS) LUKS="$(lower "$v")";;
          LVM) LVM="$(lower "$v")";;
          PLYMOUTH) PLYMOUTH="$(lower "$v")";;
          ROOT) ROOT_DEV="$v";;
          FSTYPE) FSTYPE="$(lower "$v")";;
        esac
      done <"$f"
      say INFO "preset aplicado: $p"
      ;;
    *) die "subcomando inválido para presets";;
  esac
}

# =========================
# 9) Main
# =========================
main(){
  _color_setup
  cmd="${1:-}"; shift || true
  case "$cmd" in
    detect)    cmd_detect;;
    plan)      cmd_plan "$@";;
    build)     cmd_build "$@";;
    install)   cmd_install "$@";;
    regen)     cmd_regen "$@";;
    bootloader) cmd_bootloader "$@";;
    presets)   cmd_presets "$@";;
    -h|--help|help|"") usage; exit 0;;
    *) say ERROR "subcomando desconhecido: $cmd"; usage; exit 10;;
  esac
}

main "$@"
