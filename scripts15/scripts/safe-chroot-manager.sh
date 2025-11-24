#!/usr/bin/env bash
# safe-chroot-manager.sh
#
# Gerencia chroots relativamente isolados usando namespaces:
#   - cria chroot
#   - entra/roda comando num chroot com unshare (mount/pid/ipc/uts)
#   - lista
#   - limpa (tmp, logs, cache)
#   - destrói
#
# Objetivo: minimizar contaminação host <-> chroot.
# Limitação: ainda é root “real” dentro do chroot; não é um container hardening completo.
#  Criar um chroot usando o rootfs que você já montou (ex: LFS):
#  sudo ./safe-chroot-manager.sh create lfs --rootfs /mnt/lfs-rootfs
# Entrar com shell isolado:
#  sudo ./safe-chroot-manager.sh enter lfs
# Rodar comando e sair:
#  sudo ./safe-chroot-manager.sh run lfs -- make -k check
# Limpar lixos internos:
#  sudo ./safe-chroot-manager.sh clean lfs
# Destruir (apaga tudo):
#  sudo ./safe-chroot-manager.sh destroy lfs

set -euo pipefail

CHROOT_BASE="${CHROOT_BASE:-/var/chroots}"   # pasta raiz dos chroots
DEFAULT_SHELL="${SHELL:-/bin/bash}"

usage() {
  cat <<EOF
Uso: $0 <comando> [opções]

Comandos:
  create  <nome> --rootfs <dir|tar>   Cria um novo chroot
  enter   <nome>                      Entra em um shell dentro do chroot (isolado)
  run     <nome> -- <cmd...>          Executa um comando dentro do chroot e sai
  list                                Lista chroots existentes
  clean   <nome>                      Limpa coisas voláteis dentro do chroot
  destroy <nome>                      Remove COMPLETAMENTE o chroot

Variáveis importantes:
  CHROOT_BASE   (default: /var/chroots)

Exemplos:
  # Criar chroot a partir de um diretório base:
  $0 create lfs --rootfs /mnt/lfs-rootfs

  # Criar chroot a partir de um tarball:
  $0 create debian-test --rootfs /root/debian-minbase.tar.xz

  # Entrar em shell isolado:
  $0 enter lfs

  # Executar comando isolado:
  $0 run lfs -- make -j4

  # Limpar /tmp, /var/tmp, caches:
  $0 clean lfs

  # Destruir o chroot:
  $0 destroy lfs
EOF
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Este script precisa ser executado como root." >&2
    exit 1
  fi
}

ensure_tools() {
  local missing=()
  for t in unshare mount chroot; do
    if ! command -v "$t" >/dev/null 2>&1; then
      missing+=("$t")
    fi
  done
  if ((${#missing[@]} > 0)); then
    echo "Faltam ferramentas no sistema: ${missing[*]}" >&2
    echo "Instale-as e tente novamente." >&2
    exit 1
  fi
}

chroot_dir() {
  local name="$1"
  echo "${CHROOT_BASE}/${name}"
}

# Cria rootfs do chroot a partir de diretório ou tarball
create_chroot() {
  require_root
  ensure_tools

  local name rootfs
  name="$1"; shift

  if [ "$#" -lt 2 ] || [ "$1" != "--rootfs" ]; then
    echo "Uso: $0 create <nome> --rootfs <dir|tar>" >&2
    exit 1
  fi
  shift # --rootfs
  rootfs="$1"

  local target
  target="$(chroot_dir "$name")"

  if [ -e "$target" ]; then
    echo "Erro: chroot '$name' já existe em '$target'." >&2
    exit 1
  fi

  mkdir -p "$CHROOT_BASE"
  mkdir -p "$target"

  echo ">> Criando chroot '$name' em '$target' a partir de '$rootfs'..."

  if [ -d "$rootfs" ]; then
    # Copia diretório base (cuidado: pode ser pesado)
    # Para algo grande, melhor o usuário usar rsync manualmente.
    rsync -aHAX --numeric-ids "$rootfs"/ "$target"/
  elif [ -f "$rootfs" ]; then
    # Tenta detectar compressão
    case "$rootfs" in
      *.tar)      tar -C "$target" -xf "$rootfs" ;;
      *.tar.gz|*.tgz) tar -C "$target" -xzf "$rootfs" ;;
      *.tar.xz)   tar -C "$target" -xJf "$rootfs" ;;
      *.tar.bz2)  tar -C "$target" -xjf "$rootfs" ;;
      *)
        echo "Tipo de arquivo rootfs não reconhecido: $rootfs" >&2
        exit 1
        ;;
    esac
  else
    echo "rootfs '$rootfs' não é arquivo nem diretório." >&2
    exit 1
  fi

  # Diretórios básicos (se faltarem)
  mkdir -p \
    "$target"/{dev,proc,sys,run,tmp,var,tmp,var/tmp} \
    "$target"/{etc,root,home}

  chmod 1777 "$target/tmp" "$target/var/tmp" || true

  echo ">> Chroot '$name' criado em '$target'."
  echo "   Use: $0 enter $name"
}

# Entra em chroot usando unshare para isolar mount/pid/uts/ipc
enter_chroot() {
  require_root
  ensure_tools

  local name="$1"
  local root
  root="$(chroot_dir "$name")"

  if [ ! -d "$root" ]; then
    echo "Chroot '$name' não existe em '$root'." >&2
    exit 1
  fi

  if [ ! -x "$root/bin/bash" ] && [ ! -x "$root$DEFAULT_SHELL" ]; then
    echo "Aviso: não foi encontrado /bin/bash nem \$SHELL dentro do chroot." >&2
    echo "Certifique-se de que o rootfs está completo." >&2
  fi

  echo ">> Entrando no chroot '$name' usando namespaces (unshare)..."

  # Tudo a seguir roda dentro de um novo namespace de mount/pid/uts/ipc
  # As montagens NÃO vazam pro host.
  unshare --mount --pid --uts --ipc --fork --mount-proc bash <<EOF
set -euo pipefail

ROOT="$root"

# Evita propagação de mounts do novo namespace para o host
mount --make-rprivate /

# Cria pontos de montagem dentro do chroot (sem bind do host)
mkdir -p "\$ROOT"/{dev,proc,sys,run,tmp,var/tmp}

# /proc novo e isolado
mount -t proc proc "\$ROOT/proc"

# /sys opcional, como read-only, sem bind
mount -t sysfs sysfs "\$ROOT/sys" -o ro,nosuid,nodev,noexec || true

# /dev temporário, não compartilhado
mount -t tmpfs tmpfs "\$ROOT/dev" -o mode=755,nosuid

mkdir -p "\$ROOT/dev"/{pts,shm}

# Dispositivos mínimos dentro do chroot
mknod -m 666 "\$ROOT/dev/null"    c 1 3  || true
mknod -m 666 "\$ROOT/dev/zero"    c 1 5  || true
mknod -m 666 "\$ROOT/dev/tty"     c 5 0  || true
mknod -m 666 "\$ROOT/dev/random"  c 1 8  || true
mknod -m 666 "\$ROOT/dev/urandom" c 1 9  || true

# devpts isolado
mount -t devpts devpts "\$ROOT/dev/pts" -o newinstance,ptmxmode=0666,mode=620,gid=5 || true
[ -e "\$ROOT/dev/ptmx" ] || ln -s pts/ptmx "\$ROOT/dev/ptmx"

# /dev/shm temporário
mount -t tmpfs tmpfs "\$ROOT/dev/shm" -o mode=1777,nosuid,nodev

# /tmp isolado
mount -t tmpfs tmpfs "\$ROOT/tmp" -o mode=1777,strictatime
mount -t tmpfs tmpfs "\$ROOT/var/tmp" -o mode=1777,strictatime || true

# hostname isolado
echo "chroot-$name" > /proc/sys/kernel/hostname || true

# Ajusta algumas variáveis de ambiente úteis
export HOME=/root
export PS1="[chroot:$name] \u@\h:\w\\$ "
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Entra no chroot
exec chroot "\$ROOT" ${DEFAULT_SHELL}
EOF
}

run_in_chroot() {
  require_root
  ensure_tools

  local name="$1"; shift

  if [ "$1" != "--" ]; then
    echo "Uso: $0 run <nome> -- <comando...>" >&2
    exit 1
  fi
  shift

  local root
  root="$(chroot_dir "$name")"
  if [ ! -d "$root" ]; then
    echo "Chroot '$name' não existe em '$root'." >&2
    exit 1
  fi

  local cmd=( "$@" )

  echo ">> Executando em chroot '$name': ${cmd[*]}"

  unshare --mount --pid --uts --ipc --fork --mount-proc bash <<EOF
set -euo pipefail

ROOT="$root"

mount --make-rprivate /

mkdir -p "\$ROOT"/{dev,proc,sys,run,tmp,var/tmp}

mount -t proc proc "\$ROOT/proc"
mount -t sysfs sysfs "\$ROOT/sys" -o ro,nosuid,nodev,noexec || true

mount -t tmpfs tmpfs "\$ROOT/dev" -o mode=755,nosuid
mkdir -p "\$ROOT/dev"/{pts,shm}
mknod -m 666 "\$ROOT/dev/null"    c 1 3  || true
mknod -m 666 "\$ROOT/dev/zero"    c 1 5  || true
mknod -m 666 "\$ROOT/dev/tty"     c 5 0  || true
mknod -m 666 "\$ROOT/dev/random"  c 1 8  || true
mknod -m 666 "\$ROOT/dev/urandom" c 1 9  || true
mount -t devpts devpts "\$ROOT/dev/pts" -o newinstance,ptmxmode=0666,mode=620,gid=5 || true
[ -e "\$ROOT/dev/ptmx" ] || ln -s pts/ptmx "\$ROOT/dev/ptmx"
mount -t tmpfs tmpfs "\$ROOT/dev/shm" -o mode=1777,nosuid,nodev

mount -t tmpfs tmpfs "\$ROOT/tmp" -o mode=1777,strictatime
mount -t tmpfs tmpfs "\$ROOT/var/tmp" -o mode=1777,strictatime || true

echo "chroot-$name" > /proc/sys/kernel/hostname || true

export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

exec chroot "\$ROOT" "${cmd[@]}"
EOF
}

list_chroots() {
  mkdir -p "$CHROOT_BASE"
  echo "Chroots em $CHROOT_BASE:"
  find "$CHROOT_BASE" -mindepth 1 -maxdepth 1 -type d -printf "  %f -> %p\n" | sort || true
}

clean_chroot() {
  require_root

  local name="$1"
  local root
  root="$(chroot_dir "$name")"

  if [ ! -d "$root" ]; then
    echo "Chroot '$name' não existe em '$root'." >&2
    exit 1
  fi

  echo ">> Limpando chroot '$name' em '$root'..."
  rm -rf \
    "$root/tmp/"* "$root/tmp/".* 2>/dev/null || true
  rm -rf \
    "$root/var/tmp/"* "$root/var/tmp/".* 2>/dev/null || true

  rm -rf "$root/var/cache/"* 2>/dev/null || true
  rm -rf "$root/var/log/"* 2>/dev/null || true

  echo ">> Limpeza básica concluída."
}

destroy_chroot() {
  require_root

  local name="$1"
  local root
  root="$(chroot_dir "$name")"

  if [ ! -d "$root" ]; then
    echo "Chroot '$name' não existe em '$root'." >&2
    exit 1
  fi

  if [ "$root" = "/" ] || [ "$root" = "" ]; then
    echo "Segurança: root inválido para destruição: '$root'." >&2
    exit 1
  fi

  echo ">> ATENÇÃO: isso vai apagar TUDO em '$root'."
  read -r -p "Tem certeza? (digite 'SIM' para confirmar): " ans
  if [ "$ans" != "SIM" ]; then
    echo "Cancelado."
    exit 1
  fi

  echo ">> Apagando '$root'..."
  rm -rf --one-file-system "$root"
  echo ">> Chroot '$name' destruído."
}

# ---- Dispatcher --------------------------------------------------------------

main() {
  if [ "$#" -lt 1 ]; then
    usage
    exit 1
  fi

  local cmd="$1"; shift || true

  case "$cmd" in
    create)
      [ "$#" -ge 1 ] || { echo "Falta o nome do chroot." >&2; exit 1; }
      create_chroot "$@"
      ;;
    enter)
      [ "$#" -eq 1 ] || { echo "Uso: $0 enter <nome>" >&2; exit 1; }
      enter_chroot "$1"
      ;;
    run)
      [ "$#" -ge 2 ] || { echo "Uso: $0 run <nome> -- <cmd...>" >&2; exit 1; }
      run_in_chroot "$@"
      ;;
    list)
      list_chroots
      ;;
    clean)
      [ "$#" -eq 1 ] || { echo "Uso: $0 clean <nome>" >&2; exit 1; }
      clean_chroot "$1"
      ;;
    destroy)
      [ "$#" -eq 1 ] || { echo "Uso: $0 destroy <nome>" >&2; exit 1; }
      destroy_chroot "$1"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      echo "Comando desconhecido: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
