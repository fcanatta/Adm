#!/usr/bin/env sh
# adm-stage.sh — Gerente de estágios (stage0/1/2) do sistema ADM
# POSIX sh; compatível com dash/ash/bash. Sem dependências obrigatórias.
set -u
# =========================
# 0) Configurações e defaults
# =========================
: "${ADM_ROOT:=/usr/src/adm}"
: "${ADM_LOG_COLOR:=auto}"
: "${ADM_STAGE:=host}"                     # estágio atual (fora do chroot)
: "${ADM_PIPELINE:=stage}"

ROOTFS_BASE="$ADM_ROOT/rootfs"
REG_DIR="$ADM_ROOT/registry/stage"
LOG_DIR="$ADM_ROOT/logs/toolchain"
BIN_DIR="$ADM_ROOT/bin"
BIND_CACHE="$ADM_ROOT/cache"
BIND_BUILD="$ADM_ROOT/build"
BIND_META="$ADM_ROOT/metafile"
BIND_PROFILES="$ADM_ROOT/profiles"

# Flags padrão de montagem
: "${ADM_STAGE_TMP_NOEXEC:=1}"
: "${ADM_STAGE_CACHE_RW:=0}"
: "${ADM_STAGE_DNS:=host}"                 # host|public
: "${ADM_STAGE_SHELL:=/bin/sh}"

# =========================
# 1) Cores e logging fallback
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
_c_mag(){ [ $_color_on -eq 1 ] && printf '\033[35;1m'; }  # estágio rosa negrito
_c_yel(){ [ $_color_on -eq 1 ] && printf '\033[33;1m'; }  # caminho amarelo negrito
_c_gry(){ [ $_color_on -eq 1 ] && printf '\033[38;5;244m';}

have_adm_log=0
command -v adm_log_info >/dev/null 2>&1 && have_adm_log=1

_ts(){ date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([0-9][0-9]\)$/:\1/'; }
_ctx(){
  st="${ADM_STAGE:-host}"; pipe="${ADM_PIPELINE:-stage}"; path="${PWD:-/}"
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
# 2) Utilidades gerais
# =========================
need_root(){
  if [ "$(id -u)" != "0" ]; then
    die "esta operação requer root (tente com sudo)"
  fi
}
ensure_dirs(){
  for d in "$ROOTFS_BASE" "$REG_DIR" "$LOG_DIR"; do
    [ -d "$d" ] || mkdir -p "$d" || die "não foi possível criar diretório: $d"
  done
}
stage_path(){
  case "$1" in
    0|1|2) printf "%s/stage%s" "$ROOTFS_BASE" "$1";;
    *) die "stage inválido: $1 (use 0|1|2)";;
  esac
}
is_mounted(){
  # retorna 0 se $2 está montado em $1
  mp="$1"; type="$2"
  awk -v mp="$mp" -v t="$type" '$2==mp && ($3==t || t=="any") {f=1} END{exit f?0:1}' /proc/mounts 2>/dev/null
}
mount_if_needed(){
  mp="$1"; type="$2"; opts="$3"; src="$4"
  if is_mounted "$mp" "$type"; then
    say DEBUG "já montado: $mp ($type)"
    return 0
  fi
  case "$type" in
    proc)  mount -t proc proc "$mp" || return 1;;
    sysfs) mount -t sysfs sysfs "$mp" || return 1;;
    devpts) mount -t devpts devpts "$mp" -o "$opts" || mount -t devpts devpts "$mp" || return 1;;
    tmpfs) mount -t tmpfs tmpfs "$mp" -o "$opts" || mount -t tmpfs tmpfs "$mp" || return 1;;
    bind)  mount --bind "$src" "$mp" || return 1; [ -n "$opts" ] && mount -o remount,"$opts" "$mp" || true;;
    *)     mount -t "$type" "$src" "$mp" -o "$opts" || return 1;;
  esac
}
umount_if_mounted(){
  mp="$1"
  if awk -v mp="$mp" '$2==mp{f=1} END{exit f?0:1}' /proc/mounts 2>/dev/null; then
    umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || return 1
  fi
  return 0
}
detect_tool(){
  command -v "$1" >/dev/null 2>&1
}
bytes_free(){
  df -P "$1" 2>/dev/null | awk 'NR==2{print $4*1024}'
}

# =========================
# 3) Hooks (no-op seguro)
# =========================
run_hook(){
  event="$1"; st="$2"
  # ordem de busca: stage geral → geral por evento
  cand1="$ADM_ROOT/metafile/stage/stage${st}/${event}.sh"
  cand2="$ADM_ROOT/metafile/_hooks/${event}.sh"
  [ -f "$cand1" ] && { say INFO "hook: $cand1"; sh "$cand1" "$st" || die "hook falhou: $cand1"; return 0; }
  [ -f "$cand2" ] && { say INFO "hook: $cand2"; sh "$cand2" "$st" || die "hook falhou: $cand2"; return 0; }
  say DEBUG "hook ausente para ${event} (ok)"
  return 0
}

# =========================
# 4) Criação do rootfs
# =========================
mk_base_layout(){
  root="$1"
  for d in \
    /bin /sbin /lib /lib64 /usr/bin /usr/sbin /usr/lib /usr/lib64 \
    /etc /var /run /tmp /proc /sys /dev /dev/pts /root /home /adm; do
    [ -d "$root$d" ] || mkdir -p "$root$d" || die "falha mkdir $root$d"
  done
  chmod 1777 "$root/tmp" "$root/var/tmp" 2>/dev/null || true
  [ -f "$root/etc/passwd" ] || printf "root:x:0:0:root:/root:/bin/sh\n" >"$root/etc/passwd"
  [ -f "$root/etc/group" ]  || printf "root:x:0:\n" >"$root/etc/group"
  [ -f "$root/etc/nsswitch.conf" ] || printf "passwd: files\nshadow: files\ngroup: files\nhosts: files dns\n" >"$root/etc/nsswitch.conf"
}
seed_busybox(){
  root="$1"
  if detect_tool busybox; then
    say INFO "seed: instalando busybox no rootfs (links básicos)"
    cp "$(command -v busybox)" "$root/bin/" || say WARN "não foi possível copiar busybox"
    chroot "$root" /bin/busybox --install -s >/dev/null 2>&1 || true
  else
    say WARN "busybox não encontrado; prosseguindo sem seed"
  fi
}

cmd_create(){
  need_root
  [ $# -ge 1 ] || die "uso: create --stage {0|1|2} [--skeleton=minimal|busybox]"
  stage=""; skeleton="minimal"
  while [ $# -gt 0 ]; do
    case "$1" in
      --stage) shift; stage="$1";;
      --skeleton) shift; skeleton="$1";;
      *) die "parâmetro desconhecido: $1";;
    esac; shift || true
  done
  root="$(stage_path "$stage")"
  ensure_dirs
  say STEP "CREATE stage${stage} em $root"
  [ -d "$root" ] || mkdir -p "$root" || die "não foi possível criar $root"
  mk_base_layout "$root"
  [ "$skeleton" = "busybox" ] && seed_busybox "$root"
  run_hook "pre_stage_create" "$stage"
  # marcador de estado
  echo "CREATED_AT=$(_ts)" >"$REG_DIR/stage${stage}.state" 2>/dev/null || true
  say OK
  run_hook "post_stage_create" "$stage"
}

# =========================
# 5) Montagens/binds
# =========================
mount_core(){
  root="$1"; stage="$2"
  say STEP "MOUNT stage${stage} em $root"
  # proc/sys/dev/devpts
  mount_if_needed "$root/proc"  proc "" ""      || die "falha mount proc"
  mount_if_needed "$root/sys"   sysfs "" ""     || die "falha mount sysfs"
  mount_if_needed "$root/dev"   bind "rbind" "/dev" || die "falha bind /dev"
  mount_if_needed "$root/dev/pts" devpts "gid=5,mode=620" "" || say WARN "falha devpts (tty afetados)"
  # tmpfs /run e /tmp
  tmpopts="mode=0755"
  [ "$ADM_STAGE_TMP_NOEXEC" -eq 1 ] && tmpopts="$tmpopts,nosuid,nodev,noexec"
  mount_if_needed "$root/run" tmpfs "$tmpopts" "" || die "falha tmpfs /run"
  mount_if_needed "$root/tmp" tmpfs "$tmpopts" "" || die "falha tmpfs /tmp"
  # DNS
  case "$ADM_STAGE_DNS" in
    host)
      if [ -f /etc/resolv.conf ]; then cp -f /etc/resolv.conf "$root/etc/resolv.conf" || say WARN "resolv.conf: cópia falhou"
      else printf "nameserver 1.1.1.1\n" >"$root/etc/resolv.conf"; fi
      ;;
    public)
      printf "nameserver 1.1.1.1\nnameserver 9.9.9.9\n" >"$root/etc/resolv.conf" 2>/dev/null || true
      ;;
    *) say WARN "ADM_STAGE_DNS inválido: $ADM_STAGE_DNS";;
  esac
  # Binds ADM
  [ -d "$root/adm" ] || mkdir -p "$root/adm"
  # bin
  if [ -d "$BIN_DIR" ]; then
    mkdir -p "$root/adm/bin"; mount_if_needed "$root/adm/bin" bind "ro,bind" "$BIN_DIR" || say WARN "bind bin falhou"
  else say WARN "bin não encontrado ($BIN_DIR)"; fi
  # profiles
  if [ -d "$BIND_PROFILES" ]; then
    mkdir -p "$root/adm/profiles"; mount_if_needed "$root/adm/profiles" bind "ro,bind" "$BIND_PROFILES" || say WARN "bind profiles falhou"
  fi
  # metafile
  if [ -d "$BIND_META" ]; then
    mkdir -p "$root/adm/metafile"; mount_if_needed "$root/adm/metafile" bind "ro,bind" "$BIND_META" || say WARN "bind metafile falhou"
  fi
  # cache
  if [ -d "$BIND_CACHE" ]; then
    mkdir -p "$root/adm/cache"
    if [ "$ADM_STAGE_CACHE_RW" -eq 1 ]; then
      mount_if_needed "$root/adm/cache" bind "rw,bind" "$BIND_CACHE" || say WARN "bind cache RW falhou"
    else
      mount_if_needed "$root/adm/cache" bind "ro,bind" "$BIND_CACHE" || say WARN "bind cache RO falhou"
    fi
  fi
  # build
  if [ -d "$BIND_BUILD" ]; then
    mkdir -p "$root/adm/build"; mount_if_needed "$root/adm/build" bind "rw,bind" "$BIND_BUILD" || say WARN "bind build falhou"
  fi
  say OK
}
umount_core(){
  root="$1"
  say STEP "UMOUNT $root"
  # Ordem reversa dos binds e mounts
  for m in \
    "$root/adm/build" "$root/adm/cache" "$root/adm/metafile" "$root/adm/profiles" "$root/adm/bin" \
    "$root/tmp" "$root/run" "$root/dev/pts" "$root/dev" "$root/sys" "$root/proc"
  do
    umount_if_mounted "$m" || say WARN "não foi possível desmontar: $m"
  done
  say OK
}

cmd_mount(){
  need_root
  [ $# -ge 2 ] || die "uso: mount --stage {0|1|2}"
  stage=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --stage) shift; stage="$1";;
      *) die "parâmetro desconhecido: $1";;
    esac; shift || true
  done
  root="$(stage_path "$stage")"
  [ -d "$root" ] || die "rootfs do stage${stage} não existe (crie com 'create')"
  run_hook "pre_stage_mount" "$stage"
  mount_core "$root" "$stage"
  echo "MOUNTED_AT=$(_ts)" >>"$REG_DIR/stage${stage}.state" 2>/dev/null || true
  run_hook "post_stage_mount" "$stage"
}

cmd_umount(){
  need_root
  [ $# -ge 2 ] || die "uso: umount --stage {0|1|2}"
  stage=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --stage) shift; stage="$1";;
      --lazy) LAZY=1;;  # aceito mas tratamos em umount_if_mounted
      *) die "parâmetro desconhecido: $1";;
    esac; shift || true
  done
  root="$(stage_path "$stage")"
  run_hook "pre_stage_umount" "$stage"
  umount_core "$root"
  echo "UMOUNTED_AT=$(_ts)" >>"$REG_DIR/stage${stage}.state" 2>/dev/null || true
  run_hook "post_stage_umount" "$stage"
}

# =========================
# 6) Enter/Exec (chroot)
# =========================
prepare_enter_env(){
  root="$1"; stage="$2"
  # PS1 colorido com estágio rosa e cwd amarelo
  PS1_VAL='\u@\h '$(_c_mag && :)'[stage'"$stage"']'$(_rst && :)' '$(_c_yel && :)'\w'$(_rst && :)' \n\$ '
  # Se adm-profile.sh existir, exporta flags
  if [ -x "$BIN_DIR/adm-profile.sh" ]; then
    say INFO "exportando perfil efetivo dentro do chroot (se aplicável)"
    eval "$("$BIN_DIR/adm-profile.sh" export 2>/dev/null)" || say WARN "adm-profile export falhou (seguindo)"
  else
    say WARN "adm-profile.sh não encontrado; prosseguindo sem export"
  fi
  export PS1="$PS1_VAL" TERM="${TERM:-xterm}" LC_ALL="${LC_ALL:-C}" LANG="${LANG:-C}"
  export ADM_STAGE="stage$stage" ADM_PIPELINE="stage" ADM_PKG_DIR="/adm/build"
}
cmd_enter(){
  need_root
  [ $# -ge 2 ] || die "uso: enter --stage {0|1|2} [--shell=/bin/bash]"
  stage=""; shell="$ADM_STAGE_SHELL"
  while [ $# -gt 0 ]; do
    case "$1" in
      --stage) shift; stage="$1";;
      --shell) shift; shell="$1";;
      *) die "parâmetro desconhecido: $1";;
    esac; shift || true
  done
  root="$(stage_path "$stage")"
  [ -d "$root" ] || die "rootfs do stage${stage} não existe"
  # Garante mounts
  mount_core "$root" "$stage"
  prepare_enter_env "$root" "$stage"
  run_hook "pre_stage_enter" "$stage"
  if [ ! -x "$root/$shell" ]; then
    say WARN "shell $shell indisponível no chroot; usando /bin/sh"
    shell="/bin/sh"
  fi
  say INFO "entrando em chroot stage${stage} (shell=$shell)"
  chroot "$root" "$shell"
  rc=$?
  run_hook "post_stage_enter" "$stage"
  exit $rc
}
cmd_exec(){
  need_root
  [ $# -ge 3 ] || die "uso: exec --stage {0|1|2} -- cmd arg..."
  stage=""
  # parse até encontrar --
  while [ $# -gt 0 ]; do
    case "$1" in
      --stage) shift; stage="$1";;
      --) shift; break;;
      *) die "parâmetro desconhecido (use -- para separar o comando): $1";;
    esac; shift || true
  done
  [ -n "$stage" ] || die "faltou --stage"
  [ $# -ge 1 ] || die "faltou comando após --"
  root="$(stage_path "$stage")"
  [ -d "$root" ] || die "rootfs do stage${stage} não existe"
  mount_core "$root" "$stage"
  prepare_enter_env "$root" "$stage"
  run_hook "pre_stage_exec" "$stage"
  say INFO "executando no stage${stage}: $*"
  chroot "$root" "$@" ; rc=$?
  run_hook "post_stage_exec" "$stage"
  exit $rc
}
# =========================
# 7) Status / Snapshot / Pack / Unpack / Rebuild / Destroy
# =========================
cmd_status(){
  [ $# -ge 2 ] || die "uso: status --stage {0|1|2}"
  stage=""; while [ $# -gt 0 ]; do case "$1" in --stage) shift; stage="$1";; *) die "parâmetro desconhecido: $1";; esac; shift || true; done
  root="$(stage_path "$stage")"
  [ -d "$root" ] || die "rootfs do stage${stage} não existe"
  _rule="===================================================="
  _color_setup
  printf "%s\n" "$_rule"; _b; printf "STATUS stage%s " "$stage"; _rst; printf "%s\n" "$(_ctx)"; printf "%s\n" "$_rule"
  printf "%-16s %s\n" "Rootfs:" "$root"
  printf "%-16s %s\n" "Montagens:" ""
  awk -v p="$root" '$2 ~ "^"p {printf "  - %-10s %s\n",$3,$2}' /proc/mounts
  printf "%-16s %s\n" "Espaço livre:" "$(bytes_free "$root") bytes"
  [ -f "$REG_DIR/stage${stage}.state" ] && { printf "%-16s %s\n" "State:" "$(tr '\n' ' ' < "$REG_DIR/stage${stage}.state")"; }
  # Detecta toolchain (melhor esforço)
  if [ -x "$root/usr/bin/gcc" ]; then gccver="$(chroot "$root" /usr/bin/gcc -dumpfullversion 2>/dev/null || echo '-')"; printf "%-16s gcc %s\n" "Toolchain:" "$gccver"
  elif [ -x "$root/usr/bin/clang" ]; then clangver="$(chroot "$root" /usr/bin/clang --version 2>/dev/null | sed -n '1s/.*version \([^ ]*\).*/\1/p')" ; printf "%-16s clang %s\n" "Toolchain:" "$clangver"
  else printf "%-16s %s\n" "Toolchain:" "não detectado"; fi
  printf "%s\n" "$_rule"
}

cmd_snapshot(){
  need_root
  [ $# -ge 2 ] || die "uso: snapshot --stage {0|1|2} [--note='txt']"
  stage=""; note=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --stage) shift; stage="$1";;
      --note) shift; note="$1";;
      *) die "parâmetro desconhecido: $1";;
    esac; shift || true
  done
  root="$(stage_path "$stage")"
  [ -d "$root" ] || die "rootfs do stage${stage} não existe"
  snapdir="$ROOTFS_BASE/stage${stage}.snapshot"
  mkdir -p "$snapdir" || die "não foi possível criar $snapdir"
  ts="$(date +%Y%m%d-%H%M%S)"
  dest="$snapdir/$ts"
  say STEP "SNAPSHOT stage${stage} → $dest (rsync)"
  detect_tool rsync && rsync -aHAX --delete "$root"/ "$dest"/ 2>/dev/null || { say WARN "rsync indisponível; usando tar | tar"; (cd "$root" && tar cf - .) | (mkdir -p "$dest" && cd "$dest" && tar xf -) || die "snapshot falhou"; }
  printf "SNAP_AT=%s NOTE=%s\n" "$(_ts)" "$note" >>"$REG_DIR/stage${stage}.state" 2>/dev/null || true
  say OK
}

cmd_pack(){
  need_root
  [ $# -ge 2 ] || die "uso: pack --stage {0|1|2} [--output=/caminho.tar.zst]"
  stage=""; out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --stage) shift; stage="$1";;
      --output) shift; out="$1";;
      *) die "parâmetro desconhecido: $1";;
    esac; shift || true
  done
  root="$(stage_path "$stage")"
  [ -d "$root" ] || die "rootfs do stage${stage} não existe"
  [ -n "$out" ] || out="$ROOTFS_BASE/rootfs-stage${stage}.tar.zst"
  say STEP "PACK stage${stage} → $out"
  if detect_tool zstd; then
    (cd "$root" && tar cf - .) | zstd -q -T0 -o "$out" || die "pack falhou"
  elif detect_tool xz; then
    (cd "$root" && tar cJf "$out".xz .) || die "pack xz falhou"; out="$out.xz"
  else
    (cd "$root" && tar cf "$out".tar .) || die "pack tar falhou"; out="$out.tar"
  fi
  say OK
  printf "PACK_AT=%s FILE=%s\n" "$(_ts)" "$out" >>"$REG_DIR/stage${stage}.state" 2>/dev/null || true
}

cmd_unpack(){
  need_root
  [ $# -ge 3 ] || die "uso: unpack --stage {0|1|2} --input=/arquivo.tar.*"
  stage=""; inp=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --stage) shift; stage="$1";;
      --input) shift; inp="$1";;
      *) die "parâmetro desconhecido: $1";;
    esac; shift || true
  done
  [ -f "$inp" ] || die "arquivo não encontrado: $inp"
  root="$(stage_path "$stage")"
  say STEP "UNPACK → $root de $inp"
  mkdir -p "$root" || die "não foi possível criar $root"
  rm -rf "$root"/* 2>/dev/null || true
  case "$inp" in
    *.zst) detect_tool zstd || die "zstd não encontrado"; zstd -dc "$inp" | (cd "$root" && tar xf -) || die "unpack zst falhou";;
    *.xz)  (cd "$root" && tar xJf "$inp") || die "unpack xz falhou";;
    *.tar) (cd "$root" && tar xf "$inp") || die "unpack tar falhou";;
    *) die "formato não suportado: $inp";;
  esac
  say OK
}

cmd_rebuild(){
  need_root
  [ $# -ge 2 ] || die "uso: rebuild --stage {0|1|2}"
  stage=""; while [ $# -gt 0 ]; do case "$1" in --stage) shift; stage="$1";; *) die "parâmetro desconhecido: $1";; esac; shift || true; done
  root="$(stage_path "$stage")"
  say STEP "REBUILD stage${stage}"
  cmd_umount --stage "$stage" || true
  rm -rf "$root" 2>/dev/null || true
  cmd_create --stage "$stage" --skeleton=minimal
  say OK
}

cmd_destroy(){
  need_root
  [ $# -ge 2 ] || die "uso: destroy --stage {0|1|2} [--force]"
  stage=""; force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --stage) shift; stage="$1";;
      --force) force=1;;
      *) die "parâmetro desconhecido: $1";;
    esac; shift || true
  done
  root="$(stage_path "$stage")"
  say STEP "DESTROY stage${stage}"
  cmd_umount --stage "$stage" || true
  if [ $force -eq 1 ]; then
    rm -rf "$root" 2>/dev/null || die "falha ao remover $root"
  else
    printf "Confirma destruir %s? (yes/no): " "$root"
    read ans || ans="no"
    [ "$ans" = "yes" ] && rm -rf "$root" 2>/dev/null || die "abandonado pelo usuário"
  fi
  rm -f "$REG_DIR/stage${stage}.state" 2>/dev/null || true
  say OK
}

# =========================
# 8) CLI / Usage
# =========================
usage(){
  cat <<'EOF'
Uso: adm-stage.sh <subcomando> [opções]

Subcomandos:
  create  --stage {0|1|2} [--skeleton=minimal|busybox]
  mount   --stage {0|1|2}
  umount  --stage {0|1|2} [--lazy]
  enter   --stage {0|1|2} [--shell=/bin/bash]
  exec    --stage {0|1|2} -- <comando> [args...]
  status  --stage {0|1|2}
  snapshot --stage {0|1|2} [--note="texto"]
  pack    --stage {0|1|2} [--output=/path/rootfs-stageX.tar.zst]
  unpack  --stage {0|1|2} --input=/path/rootfs-stageX.tar.*
  rebuild --stage {0|1|2}
  destroy --stage {0|1|2} [--force]

Ambiente:
  ADM_ROOT=/usr/src/adm          Base do projeto
  ADM_LOG_COLOR=auto|always|never
  ADM_STAGE_TMP_NOEXEC=1         Monta /tmp e /run com nosuid,nodev,noexec
  ADM_STAGE_CACHE_RW=0           Monta cache RW (padrão RO)
  ADM_STAGE_DNS=host|public      DNS dentro do chroot
  ADM_STAGE_SHELL=/bin/sh        Shell para enter
EOF
}

main(){
  _color_setup
  ensure_dirs
  cmd="${1:-}"; [ -n "${cmd:-}" ] || { usage; exit 2; }
  shift || true
  case "$cmd" in
    create)   cmd_create "$@";;
    mount)    cmd_mount "$@";;
    umount)   cmd_umount "$@";;
    enter)    cmd_enter "$@";;
    exec)     cmd_exec "$@";;
    status)   cmd_status "$@";;
    snapshot) cmd_snapshot "$@";;
    pack)     cmd_pack "$@";;
    unpack)   cmd_unpack "$@";;
    rebuild)  cmd_rebuild "$@";;
    destroy)  cmd_destroy "$@";;
    -h|--help|help) usage;;
    *) die "subcomando desconhecido: $cmd (use --help)";;
  case_esac_fallback_fix
  }
}

# Corrige shell sem 'case ... esac' quebrado por copy-paste
main "$@"
