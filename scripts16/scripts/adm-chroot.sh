#!/usr/bin/env bash
set -euo pipefail

# adm-chroot.sh
# Helper para preparar, entrar e desmontar um chroot para usar o adm com segurança.
#
# Uso:
#   ADM_CHROOT=/mnt/lfs adm-chroot.sh prepare
#   ADM_CHROOT=/mnt/lfs adm-chroot.sh enter
#   ADM_CHROOT=/mnt/lfs adm-chroot.sh teardown
#   ADM_CHROOT=/mnt/lfs adm-chroot.sh status
#
# Ou:
#   adm-chroot.sh prepare /mnt/lfs
#   adm-chroot.sh enter /mnt/lfs
#   adm-chroot.sh teardown /mnt/lfs
#   adm-chroot.sh status /mnt/lfs
#
# Por padrão, a ordem de escolha do diretório do chroot é:
#   1. argumento da linha de comando
#   2. variável ADM_CHROOT
#   3. variável LFS
#   4. /mnt/lfs

ADM_CHROOT_HELPER_VERSION="1.1"

# -----------------------------------------------------------------------------
# Helpers básicos
# -----------------------------------------------------------------------------

die() {
  echo "[adm-chroot][ERRO] $*" >&2
  exit 1
}

log() {
  echo "[adm-chroot] $*"
}

debug() {
  if [[ "${ADM_CHROOT_DEBUG:-0}" = "1" ]]; then
    echo "[adm-chroot][DEBUG] $*"
  fi
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Este script precisa ser executado como root."
  fi
}

ensure_dir() {
  local d="$1"
  if [[ ! -d "$d" ]]; then
    mkdir -pv "$d"
  fi
}

# Detecta se um caminho já está montado
is_mounted() {
  local target="$1"
  # mountpoint é mais confiável se existir
  if command -v mountpoint >/dev/null 2>&1; then
    if mountpoint -q "$target" 2>/dev/null; then
      return 0
    fi
    return 1
  fi
  # fallback: olhar /proc/mounts
  grep -qE "[[:space:]]$(printf '%s' "$target" | sed 's#/#\\/#g')[[:space:]]" /proc/mounts
}

do_mount() {
  local src="$1"
  local dst="$2"
  local fstype="$3"
  local opts="$4"

  ensure_dir "$dst"

  if is_mounted "$dst"; then
    debug "Já montado: $dst"
    return 0
  fi

  if [[ "$fstype" = "bind" ]]; then
    log "Bind-mount $src -> $dst (opts=$opts)"
    if [[ -n "$opts" ]]; then
      mount --bind "$src" "$dst"
      mount -o remount,"$opts" "$dst"
    else
      mount --bind "$src" "$dst"
    fi
  else
    log "Montando $src em $dst (tipo=$fstype, opts=$opts)"
    if [[ -n "$opts" ]]; then
      mount -vt "$fstype" -o "$opts" "$src" "$dst"
    else
      mount -vt "$fstype" "$src" "$dst"
    fi
  fi
}

do_umount() {
  local dst="$1"
  if is_mounted "$dst"; then
    log "Desmontando $dst"
    umount "$dst"
  else
    debug "Não montado: $dst"
  fi
}

# -----------------------------------------------------------------------------
# Determinar diretório do chroot
# -----------------------------------------------------------------------------

get_chroot_dir() {
  local arg="${1:-}"
  if [[ -n "$arg" ]]; then
    printf '%s\n' "$arg"
  elif [[ -n "${ADM_CHROOT:-}" ]]; then
    printf '%s\n' "$ADM_CHROOT"
  elif [[ -n "${LFS:-}" ]]; then
    printf '%s\n' "$LFS"
  else
    printf '%s\n' "/mnt/lfs"
  fi
}

# -----------------------------------------------------------------------------
# Preparar chroot (montagens + adm)
# -----------------------------------------------------------------------------

prepare_chroot() {
  require_root

  local chroot_dir
  chroot_dir="$(get_chroot_dir "${1:-}")"

  log "Usando diretório de chroot: $chroot_dir"
  ensure_dir "$chroot_dir"

  # Estrutura básica
  ensure_dir "$chroot_dir/dev"
  ensure_dir "$chroot_dir/dev/pts"
  ensure_dir "$chroot_dir/proc"
  ensure_dir "$chroot_dir/sys"
  ensure_dir "$chroot_dir/run"

  # Montagens essenciais (estilo LFS)
  do_mount /dev        "$chroot_dir/dev"      bind   ""
  do_mount devpts      "$chroot_dir/dev/pts"  devpts "gid=5,mode=620"
  do_mount proc        "$chroot_dir/proc"     proc   "nosuid,noexec,nodev"
  do_mount sysfs       "$chroot_dir/sys"      sysfs  "nosuid,noexec,nodev"
  do_mount tmpfs       "$chroot_dir/run"      tmpfs  "mode=0755,nosuid,nodev"

  # /dev/shm dentro do chroot
  if [[ ! -d "$chroot_dir/dev/shm" ]]; then
    mkdir -pv "$chroot_dir/dev/shm"
  fi
  if ! is_mounted "$chroot_dir/dev/shm"; then
    do_mount tmpfs "$chroot_dir/dev/shm" tmpfs "mode=1777,nosuid,nodev"
  fi

  # Garantir /usr/bin existe
  ensure_dir "$chroot_dir/usr/bin"

  # Copiar /usr/bin/adm para dentro do chroot se não existir
  if [[ ! -x "$chroot_dir/usr/bin/adm" ]]; then
    if [[ -x /usr/bin/adm ]]; then
      log "Copiando /usr/bin/adm para dentro do chroot"
      cp -v /usr/bin/adm "$chroot_dir/usr/bin/adm"
      chmod 755 "$chroot_dir/usr/bin/adm"
    else
      die "/usr/bin/adm não encontrado no sistema host."
    fi
  else
    debug "adm já está presente em $chroot_dir/usr/bin/adm"
  fi

  # Estrutura do adm dentro do chroot
  ensure_dir "$chroot_dir/var/lib/adm"
  ensure_dir "$chroot_dir/var/lib/adm/cache/src"
  ensure_dir "$chroot_dir/var/lib/adm/cache/bin"
  ensure_dir "$chroot_dir/var/lib/adm/recipes"
  ensure_dir "$chroot_dir/var/log/adm"
  ensure_dir "$chroot_dir/var/tmp/adm/build"

  # Bind-mount de /var/lib/adm (estado + recipes + cache) para compartilhar com host
  # Se quiser chroot completamente isolado, comente estes binds e copie recipes/estado na mão.
  if [[ -d /var/lib/adm ]]; then
    do_mount /var/lib/adm "$chroot_dir/var/lib/adm" bind ""
  else
    log "Aviso: /var/lib/adm não existe no host, usando diretório vazio no chroot."
  fi

  # Bind-mount de /var/log/adm
  if [[ -d /var/log/adm ]]; then
    do_mount /var/log/adm "$chroot_dir/var/log/adm" bind ""
  fi

  # Bind-mount do diretório de build do adm
  if [[ -d /var/tmp/adm/build ]]; then
    do_mount /var/tmp/adm/build "$chroot_dir/var/tmp/adm/build" bind ""
  fi

  log "Chroot preparado com sucesso em: $chroot_dir"
}

# -----------------------------------------------------------------------------
# Entrar no chroot
# -----------------------------------------------------------------------------

enter_chroot() {
  require_root
  local chroot_dir
  chroot_dir="$(get_chroot_dir "${1:-}")"

  # Garante que está preparado
  prepare_chroot "$chroot_dir"

  log "Entrando no chroot em $chroot_dir"
  chroot "$chroot_dir" /usr/bin/env -i \
    HOME=/root \
    TERM="${TERM:-xterm-256color}" \
    PS1="(adm-chroot) \\u@\\h:\\w\\$ " \
    PATH="/usr/bin:/usr/sbin:/bin:/sbin" \
    /bin/bash --login
}

# -----------------------------------------------------------------------------
# Teardown (desmontar tudo que montamos)
# -----------------------------------------------------------------------------

teardown_chroot() {
  require_root
  local chroot_dir
  chroot_dir="$(get_chroot_dir "${1:-}")"

  log "Desmontando chroot em $chroot_dir"

  # Ordem inversa das montagens
  do_umount "$chroot_dir/dev/shm"      || true
  do_umount "$chroot_dir/run"         || true
  do_umount "$chroot_dir/sys"         || true
  do_umount "$chroot_dir/proc"        || true
  do_umount "$chroot_dir/dev/pts"     || true
  do_umount "$chroot_dir/dev"         || true

  # Bind mounts do adm
  do_umount "$chroot_dir/var/tmp/adm/build" || true
  do_umount "$chroot_dir/var/log/adm"       || true
  do_umount "$chroot_dir/var/lib/adm"       || true

  log "Teardown do chroot concluído."
}

# -----------------------------------------------------------------------------
# Status (mostrar o que está montado)
# -----------------------------------------------------------------------------

status_chroot() {
  local chroot_dir
  chroot_dir="$(get_chroot_dir "${1:-}")"

  log "Status do chroot em $chroot_dir:"
  printf '  %-35s %s\n' "Ponto" "Montado?"
  printf '  %-35s %s\n' "-----------------------------------" "--------"

  for d in \
    "$chroot_dir/dev" \
    "$chroot_dir/dev/pts" \
    "$chroot_dir/dev/shm" \
    "$chroot_dir/proc" \
    "$chroot_dir/sys"  \
    "$chroot_dir/run"  \
    "$chroot_dir/var/lib/adm" \
    "$chroot_dir/var/log/adm" \
    "$chroot_dir/var/tmp/adm/build"
  do
    if is_mounted "$d"; then
      printf '  %-35s %s\n' "$d" "SIM"
    else
      printf '  %-35s %s\n' "$d" "não"
    fi
  done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

usage() {
  cat <<EOF
adm-chroot.sh v${ADM_CHROOT_HELPER_VERSION}

Uso: $0 <prepare|enter|teardown|status> [DIR]

  prepare   - prepara o chroot (monta tudo, copia adm, bind-mount do /var/lib/adm)
  enter     - prepara e entra no chroot com /bin/bash --login
  teardown  - desmonta os mounts criados no chroot
  status    - mostra o estado atual dos mounts importantes

  DIR       - diretório do chroot (default: \$ADM_CHROOT, \$LFS, ou /mnt/lfs)

Exemplos:
  ADM_CHROOT=/mnt/lfs $0 prepare
  ADM_CHROOT=/mnt/lfs $0 enter
  ADM_CHROOT=/mnt/lfs $0 teardown
  ADM_CHROOT=/mnt/lfs $0 status

  $0 enter /mnt/lfs
EOF
}

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    prepare)
      prepare_chroot "${1:-}"
      ;;
    enter)
      enter_chroot "${1:-}"
      ;;
    teardown)
      teardown_chroot "${1:-}"
      ;;
    status)
      status_chroot "${1:-}"
      ;;
    ""|help|-h|--help)
      usage
      ;;
    *)
      die "Comando desconhecido: $cmd"
      ;;
  esac
}

main "$@"
