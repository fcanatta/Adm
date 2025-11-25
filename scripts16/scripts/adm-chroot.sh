#!/usr/bin/env bash
set -euo pipefail
# adm-chroot.sh
# Helper para preparar, entrar e desmontar um chroot para usar o adm com segurança.
# Uso:
#   ADM_CHROOT=/mnt/lfs adm-chroot.sh prepare
#   ADM_CHROOT=/mnt/lfs adm-chroot.sh enter
#   ADM_CHROOT=/mnt/lfs adm-chroot.sh teardown
#
# Ou:
#   adm-chroot.sh prepare /mnt/lfs
#   adm-chroot.sh enter /mnt/lfs
#   adm-chroot.sh teardown /mnt/lfs
# -----------------------------------------------------------------------------
# Helpers básicos
# -----------------------------------------------------------------------------

die() {
  echo "ERRO: $*" >&2
  exit 1
}

log() {
  echo "[adm-chroot] $*"
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Este script precisa ser executado como root."
  fi
}

# Detecta se um caminho já está montado
is_mounted() {
  local target="$1"
  if command -v mountpoint >/dev/null 2>&1; then
    if mountpoint -q "$target" 2>/dev/null; then
      return 0
    fi
  fi
  grep -qE "[[:space:]]$(printf '%s' "$target" | sed 's#/#\\/#g')[[:space:]]" /proc/mounts
}

ensure_dir() {
  local d="$1"
  if [[ ! -d "$d" ]]; then
    mkdir -pv "$d"
  fi
}

do_mount() {
  local opts="$1" src="$2" dst="$3" fstype="${4:-}"

  ensure_dir "$dst"

  if is_mounted "$dst"; then
    log "Já montado: $dst"
    return 0
  fi

  if [[ -n "$fstype" ]]; then
    log "Montando $src em $dst (tipo=$fstype, opts=$opts)"
    mount -vt "$fstype" -o "$opts" "$src" "$dst"
  else
    log "Bind-mount $src -> $dst (opts=$opts)"
    mount --bind $opts "$src" "$dst"
  fi
}

do_umount() {
  local dst="$1"
  if is_mounted "$dst"; then
    log "Desmontando $dst"
    umount "$dst"
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
    # default LFS clássico
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
  do_mount ""         /dev        "$chroot_dir/dev"
  do_mount "gid=5,mode=620" devpts "$chroot_dir/dev/pts" devpts
  do_mount ""         proc        "$chroot_dir/proc"     proc
  do_mount ""         sysfs       "$chroot_dir/sys"      sysfs
  do_mount "mode=0755,nosuid,nodev" tmpfs "$chroot_dir/run" tmpfs

  # /dev/shm dentro do chroot → apontar pra /run/shm se não existir
  if [[ ! -d "$chroot_dir/dev/shm" ]]; then
    mkdir -pv "$chroot_dir/dev/shm"
    mount --bind "$chroot_dir/run" "$chroot_dir/dev/shm" || true
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
    log "adm já está presente em $chroot_dir/usr/bin/adm"
  fi

  # Estrutura do adm dentro do chroot
  ensure_dir "$chroot_dir/var/lib/adm"
  ensure_dir "$chroot_dir/var/lib/adm/cache/src"
  ensure_dir "$chroot_dir/var/lib/adm/cache/bin"
  ensure_dir "$chroot_dir/var/lib/adm/recipes"
  ensure_dir "$chroot_dir/var/log/adm"
  ensure_dir "$chroot_dir/var/tmp/adm/build"

  # Bind-mount de /var/lib/adm (estado + recipes + cache) para compartilhar com host
  # Se você quiser chroot totalmente isolado, comente estas linhas e copie na mão.
  if [[ -d /var/lib/adm ]]; then
    do_mount "" /var/lib/adm "$chroot_dir/var/lib/adm"
  else
    log "Aviso: /var/lib/adm não existe no host, usando diretório vazio no chroot."
  fi

  # Bind-mount de /var/log/adm
  if [[ -d /var/log/adm ]]; then
    do_mount "" /var/log/adm "$chroot_dir/var/log/adm"
  fi

  # Bind-mount do diretório de build do adm
  if [[ -d /var/tmp/adm/build ]]; then
    do_mount "" /var/tmp/adm/build "$chroot_dir/var/tmp/adm/build"
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
  do_umount "$chroot_dir/dev/shm" || true
  do_umount "$chroot_dir/run"
  do_umount "$chroot_dir/sys"
  do_umount "$chroot_dir/proc"
  do_umount "$chroot_dir/dev/pts"
  do_umount "$chroot_dir/dev"

  # Bind mounts do adm
  do_umount "$chroot_dir/var/tmp/adm/build" || true
  do_umount "$chroot_dir/var/log/adm"       || true
  do_umount "$chroot_dir/var/lib/adm"       || true

  log "Teardown do chroot concluído."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

usage() {
  cat <<EOF
Uso: $0 <prepare|enter|teardown> [DIR]

  prepare   - prepara o chroot (monta tudo, copia adm, bind-mount do /var/lib/adm)
  enter     - prepara e entra no chroot com /bin/bash --login
  teardown  - desmonta os mounts criados no chroot

  DIR       - diretório do chroot (default: \$ADM_CHROOT, \$LFS, ou /mnt/lfs)

Exemplos:
  ADM_CHROOT=/mnt/lfs $0 prepare
  ADM_CHROOT=/mnt/lfs $0 enter
  ADM_CHROOT=/mnt/lfs $0 teardown

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
    ""|help|-h|--help)
      usage
      ;;
    *)
      die "Comando desconhecido: $cmd"
      ;;
  esac
}

main "$@"
