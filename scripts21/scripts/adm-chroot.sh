#!/usr/bin/env bash
#
# adm-chroot.sh
#
# Gerencia um chroot seguro dentro do ROOTFS do ADM:
#   - prepara o ambiente (mounts /dev, /proc, /sys, /run, /opt/adm, /tmp, etc)
#   - entra em shell interativo dentro do chroot
#   - executa comandos únicos dentro do chroot (exec)
#   - desmonta tudo de forma segura
#
# Características:
#   - sem erros silenciosos (falhas importantes derrubam o script)
#   - não deixa mounts esquecidos (usa arquivo de estado por profile)
#   - garante que /opt/adm do host esteja disponível no chroot
#   - saída colorida, organizada
#
# Uso:
#   ADM_PROFILE=glibc ./adm-chroot.sh prepare
#   ADM_PROFILE=glibc ./adm-chroot.sh enter
#   ADM_PROFILE=glibc ./adm-chroot.sh exec "adm.sh bootstrap all"
#   ADM_PROFILE=glibc ./adm-chroot.sh umount
#   ADM_PROFILE=glibc ./adm-chroot.sh status
#

set -euo pipefail

# ------------------------- CONFIG DEFAULTS -------------------------

ADM_SH="${ADM_SH:-/opt/adm/adm.sh}"
ADM_PROFILE="${ADM_PROFILE:-glibc}"
ADM_PROFILE_DIR="${ADM_PROFILE_DIR:-/opt/adm/profiles}"
ADM_ROOT_DIR="${ADM_ROOT_DIR:-/opt/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-/opt/adm/state}"
ADM_LOG_DIR="${ADM_LOG_DIR:-/opt/adm/logs}"

mkdir -p "$ADM_STATE_DIR" "$ADM_LOG_DIR"

# --------------------------- CORES / UI ----------------------------

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_MAGENTA=$'\033[35m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_MAGENTA=""; C_CYAN=""
fi

log() {
  local level="$1"; shift
  local color="$C_RESET"
  case "$level" in
    INFO)  color="$C_BLUE" ;;
    WARN)  color="$C_YELLOW" ;;
    ERRO)  color="$C_RED" ;;
    OK)    color="$C_GREEN" ;;
  esac
  printf "%s[%s]%s %s\n" "$color" "$level" "$C_RESET" "$*" >&2
}

die() {
  log "ERRO" "$*"
  exit 1
}

banner() {
  local msg="$1"
  printf "\n${C_MAGENTA}==========${C_RESET} ${C_BOLD}%s${C_RESET} ${C_MAGENTA}==========${C_RESET}\n" "$msg"
}

# --------------------------- HELPERS ----------------------------

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Este script precisa ser executado como root."
  fi
}

load_profile() {
  local pf="${ADM_PROFILE_DIR}/${ADM_PROFILE}.profile"
  [[ -f "$pf" ]] || die "Profile não encontrado: $pf"

  # shellcheck source=/dev/null
  . "$pf"

  : "${ROOTFS:?ROOTFS não definido no profile ${ADM_PROFILE}.profile}"
  : "${CHOST:?CHOST não definido no profile ${ADM_PROFILE}.profile}"

  log "INFO" "Profile carregado: $ADM_PROFILE (ROOTFS=$ROOTFS, CHOST=$CHOST)"
}

STATE_FILE() {
  echo "$ADM_STATE_DIR/chroot-${ADM_PROFILE}.mounts"
}

is_subdir_of_root() {
  local path="$1"
  local real
  real="$(readlink -f "$path" || echo "")"
  [[ -n "$real" ]] || return 1
  [[ "$real" != "/" ]] || return 1
  return 0
}

ensure_rootfs_safe() {
  [[ -d "$ROOTFS" ]] || die "ROOTFS não existe: $ROOTFS"
  is_subdir_of_root "$ROOTFS" || die "ROOTFS inválido ou perigoso: $ROOTFS"
}

mountpoint_in_root() {
  local sub="$1"
  echo "$ROOTFS$sub"
}

do_mount() {
  local src="$1"
  local dest="$2"
  shift 2
  local opts=("$@")

  if mountpoint -q "$dest"; then
    log "INFO" "Já montado: $dest"
    return 0
  fi

  if [[ "$src" == "none" ]]; then
    log "INFO" "Montando $dest (${opts[*]})"
    mount "${opts[@]}" "$dest"
  else
    log "INFO" "Bind-mount $src -> $dest (${opts[*]})"
    mount "${opts[@]}" "$src" "$dest"
  fi
}

record_mount() {
  local dest="$1"
  local sf; sf="$(STATE_FILE)"
  grep -qxF "$dest" "$sf" 2>/dev/null || echo "$dest" >> "$sf"
}

# --------------------------- PREPARE ----------------------------

prepare_mounts() {
  require_root
  load_profile
  ensure_rootfs_safe

  local sf; sf="$(STATE_FILE)"
  : > "$sf"

  # Diretórios base
  mkdir -p \
    "$(mountpoint_in_root /dev)" \
    "$(mountpoint_in_root /dev/pts)" \
    "$(mountpoint_in_root /proc)" \
    "$(mountpoint_in_root /sys)" \
    "$(mountpoint_in_root /run)" \
    "$(mountpoint_in_root /tmp)" \
    "$(mountpoint_in_root /var/tmp)" \
    "$(mountpoint_in_root /opt)" \
    "$(mountpoint_in_root /etc)"

  # /dev e /dev/pts
  do_mount /dev     "$(mountpoint_in_root /dev)"     --bind
  record_mount "$(mountpoint_in_root /dev)"

  mkdir -p /dev/pts "$(mountpoint_in_root /dev/pts)"
  do_mount /dev/pts "$(mountpoint_in_root /dev/pts)" --bind
  record_mount "$(mountpoint_in_root /dev/pts)"

  # /proc
  do_mount none "$(mountpoint_in_root /proc)" -t proc proc
  record_mount "$(mountpoint_in_root /proc)"

  # /sys
  do_mount none "$(mountpoint_in_root /sys)" -t sysfs sys
  record_mount "$(mountpoint_in_root /sys)"

  # /run
  do_mount none "$(mountpoint_in_root /run)" -t tmpfs tmpfs
  record_mount "$(mountpoint_in_root /run)"

  # /tmp e /var/tmp
  chmod 1777 "$(mountpoint_in_root /tmp)" "$(mountpoint_in_root /var/tmp)" || \
    die "Falha ao ajustar permissões de /tmp e /var/tmp"

  # /opt/adm
  if [[ -d "$ADM_ROOT_DIR" ]]; then
    mkdir -p "$(mountpoint_in_root /opt/adm)"
    do_mount "$ADM_ROOT_DIR" "$(mountpoint_in_root /opt/adm)" --bind
    record_mount "$(mountpoint_in_root /opt/adm)"
  else
    die "ADM_ROOT_DIR não encontrado: $ADM_ROOT_DIR (esperado /opt/adm ou similar)"
  fi

  # resolv.conf para DNS
  if [[ -f /etc/resolv.conf ]]; then
    cp -L /etc/resolv.conf "$(mountpoint_in_root /etc/resolv.conf)"
  fi

  # Verificação mínima
  if ! mountpoint -q "$(mountpoint_in_root /proc)"; then
    die "/proc não parece estar montado dentro do ROOTFS."
  fi

  log "OK" "Mounts preparados com sucesso para chroot em $ROOTFS"
}

# --------------------------- UNMOUNT ----------------------------

unmount_all() {
  require_root
  load_profile
  ensure_rootfs_safe

  local sf; sf="$(STATE_FILE)"

  if [[ ! -f "$sf" ]]; then
    log "WARN" "Nenhum estado de mounts encontrado ($sf). Tentando fallback."
    local fallback=(
      /opt/adm
      /dev/pts
      /dev
      /proc
      /sys
      /run
    )
    local sub
    for sub in "${fallback[@]}"; do
      local mp
      mp="$(mountpoint_in_root "$sub")"
      if mountpoint -q "$mp"; then
        log "INFO" "Desmontando (fallback): $mp"
        umount "$mp" || die "Falha ao desmontar $mp"
      fi
    done
    return 0
  fi

  mapfile -t mps < "$sf"
  for (( idx=${#mps[@]}-1 ; idx>=0 ; idx-- )); do
    local mp="${mps[idx]}"
    if mountpoint -q "$mp"; then
      log "INFO" "Desmontando: $mp"
      umount "$mp" || die "Falha ao desmontar $mp"
    else
      log "INFO" "Não montado (ignorando): $mp"
    fi
  done

  rm -f "$sf"
  log "OK" "Todos os mounts registrados foram desmontados para profile=$ADM_PROFILE"
}

status_mounts() {
  load_profile
  ensure_rootfs_safe

  banner "Status de mounts para ROOTFS=$ROOTFS"

  grep " $ROOTFS" /proc/mounts || {
    echo "(nenhuma entrada em /proc/mounts para $ROOTFS)"
  }

  local sf; sf="$(STATE_FILE)"
  if [[ -f "$sf" ]]; then
    echo
    echo "${C_CYAN}Mounts registrados (${sf}):${C_RESET}"
    cat "$sf"
  else
    echo
    echo "${C_YELLOW}Nenhum arquivo de estado encontrado para este profile.${C_RESET}"
  fi
}

# --------------------------- CHROOT ----------------------------

enter_chroot_shell() {
  require_root
  load_profile
  ensure_rootfs_safe

  local sf; sf="$(STATE_FILE)"
  if [[ ! -f "$sf" ]]; then
    banner "Preparando mounts para chroot"
    prepare_mounts
  fi

  banner "Entrando no chroot (ROOTFS=$ROOTFS)"

  local chroot_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  if [[ -d "$ROOTFS/tools/bin" ]]; then
    chroot_path="/tools/bin:${chroot_path}"
  fi

  if [[ ! -x "$ROOTFS/bin/sh" && ! -x "$ROOTFS/bin/bash" ]]; then
    die "Nenhum shell encontrado em $ROOTFS/bin/sh ou /bin/bash."
  fi

  local shell_cmd="/bin/bash"
  if [[ ! -x "$ROOTFS$shell_cmd" ]]; then
    shell_cmd="/bin/sh"
  fi

  chroot "$ROOTFS" /usr/bin/env -i \
    HOME=/root \
    TERM="${TERM:-linux}" \
    PATH="$chroot_path" \
    ADM_PROFILE="$ADM_PROFILE" \
    CHOST="$CHOST" \
    ADM_CHROOT=1 \
    PS1="[adm-chroot:$ADM_PROFILE] \\u@\\h:\\w\\$ " \
    "$shell_cmd" --login
}

exec_in_chroot() {
  require_root
  load_profile
  ensure_rootfs_safe

  if [[ $# -lt 1 ]]; then
    die "Uso: $0 exec \"comando ...\""
  fi

  local cmd="$*"
  local sf; sf="$(STATE_FILE)"

  if [[ ! -f "$sf" ]]; then
    banner "Preparando mounts para chroot"
    prepare_mounts
  fi

  banner "Executando no chroot: $cmd"

  local chroot_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  if [[ -d "$ROOTFS/tools/bin" ]]; then
    chroot_path="/tools/bin:${chroot_path}"
  fi

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  local log_file="$ADM_LOG_DIR/chroot-exec-${ADM_PROFILE}-${ts}.log"

  log "INFO" "Log do comando será salvo em: $log_file"

  set -o pipefail
  chroot "$ROOTFS" /usr/bin/env -i \
    HOME=/root \
    TERM="${TERM:-linux}" \
    PATH="$chroot_path" \
    ADM_PROFILE="$ADM_PROFILE" \
    CHOST="$CHOST" \
    ADM_CHROOT=1 \
    /bin/sh -lc "$cmd" 2>&1 | tee "$log_file"
  local status=${PIPESTATUS[0]}
  set +o pipefail

  if (( status != 0 )); then
    die "Comando dentro do chroot falhou com status $status (veja o log em $log_file)."
  fi

  log "OK" "Comando dentro do chroot executado com sucesso."
}

usage() {
  cat <<EOF
Uso: $(basename "$0") <comando>

Comandos:
  prepare    - prepara o ROOTFS para chroot (mounts /dev, /proc, /sys, /run, /opt/adm, etc)
  enter      - entra em um shell interativo dentro do chroot
  exec CMD   - executa CMD dentro do chroot, com log e status corretos
  umount     - desmonta todos os mounts associados a este profile
  status     - mostra mounts atuais relacionados ao ROOTFS e o estado salvo

Exemplos:
  ADM_PROFILE=glibc $(basename "$0") prepare
  ADM_PROFILE=glibc $(basename "$0") enter
  ADM_PROFILE=glibc $(basename "$0") exec "adm.sh bootstrap all"
  ADM_PROFILE=glibc $(basename "$0") umount
EOF
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  local cmd="$1"; shift || true

  case "$cmd" in
    prepare)
      banner "Preparando chroot"
      prepare_mounts
      ;;
    enter)
      enter_chroot_shell
      ;;
    exec)
      exec_in_chroot "$@"
      ;;
    umount)
      banner "Desmontando mounts do chroot"
      unmount_all
      ;;
    status)
      status_mounts
      ;;
    *)
      usage
      die "Comando desconhecido: $cmd"
      ;;
  esac
}

main "$@"
