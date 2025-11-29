#!/usr/bin/env bash
set -euo pipefail

#========================================================
#  ADM Manager - Gerenciador de programas para Linux From Scratch
#  - Prepara estrutura do LFS
#  - Monta / desmonta FS virtuais
#  - Entra em chroot (opcionalmente com unshare)
#========================================================

LFS_CONFIG="${LFS_CONFIG:-/etc/adm.conf}"

# Valores padrão (podem ser sobrescritos pelo arquivo de config)
LFS="${LFS:-/mnt/lfs}"
LFS_USER="${LFS_USER:-lfsbuild}"
LFS_GROUP="${LFS_GROUP:-lfsbuild}"
LFS_SOURCES_DIR="${LFS_SOURCES_DIR:-$LFS/sources}"
LFS_TOOLS_DIR="${LFS_TOOLS_DIR:-$LFS/tools}"
LFS_LOG_DIR="${LFS_LOG_DIR:-$LFS/logs}"
LFS_BUILD_SCRIPTS_DIR="${LFS_BUILD_SCRIPTS_DIR:-$LFS/build-scripts}"

CHROOT_SECURE="${CHROOT_SECURE:-1}"  # 1 = tentar unshare, 0 = chroot simples

#--------------------------------------------------------
# Helpers
#--------------------------------------------------------

die() {
    echo "Erro: $*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "este script precisa ser executado como root."
    fi
}

load_config() {
    if [[ -f "$LFS_CONFIG" ]]; then
        # shellcheck source=/dev/null
        . "$LFS_CONFIG"
    fi
}

usage() {
    cat <<EOF
Uso: $0 <comando> [opções]

Comandos principais:
  init                 Prepara estrutura básica do LFS (pastas, permissões)
  create-user          Cria usuário/grupo para construção (LFS_USER/LFS_GROUP)
  mount                Monta sistemas de arquivos virtuais no LFS
  umount               Desmonta sistemas de arquivos virtuais do LFS
  chroot               Entra em chroot (seguro se possível)
  chroot-plain         Entra em chroot simples (sem unshare, etc.)
  status               Mostra status básico do ambiente LFS
  run-build <script>   Executa script de build dentro do LFS
                       (espera script em \$LFS_BUILD_SCRIPTS_DIR)

Opções via variáveis de ambiente ou config:
  LFS                 Diretório base do LFS (padrão: /mnt/lfs)
  LFS_USER            Usuário de construção (padrão: lfsbuild)
  LFS_GROUP           Grupo de construção (padrão: lfsbuild)
  CHROOT_SECURE=0/1   Ativa/desativa chroot com unshare (padrão: 1)

Arquivo de configuração (opcional):
  $LFS_CONFIG

Exemplos:
  $0 init
  $0 create-user
  $0 mount
  $0 chroot
  $0 run-build binutils-pass1.sh
EOF
}

#--------------------------------------------------------
# Funções principais
#--------------------------------------------------------

init_layout() {
    echo ">> Criando estrutura básica em $LFS ..."
    mkdir -pv "$LFS"
    mkdir -pv "$LFS_SOURCES_DIR" "$LFS_TOOLS_DIR" "$LFS_LOG_DIR" "$LFS_BUILD_SCRIPTS_DIR"

    # Permissões recomendadas para sources
    chmod -v a+wt "$LFS_SOURCES_DIR" || true

    # Estrutura mínima para chroot
    mkdir -pv "$LFS"/{bin,boot,etc,home,lib,lib64,usr,var,proc,sys,dev,run,tmp}
    chmod -v 1777 "$LFS/tmp"

    echo ">> Estrutura básica criada."
}

create_build_user() {
    echo ">> Criando usuário/grupo de build ($LFS_USER:$LFS_GROUP)..."

    if ! getent group "$LFS_GROUP" >/dev/null 2>&1; then
        groupadd "$LFS_GROUP"
        echo "  - Grupo $LFS_GROUP criado."
    else
        echo "  - Grupo $LFS_GROUP já existe."
    fi

    if ! id "$LFS_USER" >/dev/null 2>&1; then
        useradd -s /bin/bash -g "$LFS_GROUP" -m -k /dev/null "$LFS_USER"
        echo "  - Usuário $LFS_USER criado."
    else
        echo "  - Usuário $LFS_USER já existe."
    fi

    chown -v "$LFS_USER:$LFS_GROUP" "$LFS_SOURCES_DIR" "$LFS_TOOLS_DIR" "$LFS_LOG_DIR" "$LFS_BUILD_SCRIPTS_DIR"

    echo ">> Usuário/grupo de build configurados."
}

mount_virtual_fs() {
    echo ">> Montando sistemas de arquivos virtuais em $LFS ..."

    mountpoint -q "$LFS" || die "Diretório $LFS não está montado como sistema de arquivos raiz (mas isso é opcional)."

    # /dev
    if ! mountpoint -q "$LFS/dev"; then
        mount --bind /dev "$LFS/dev"
        echo "  - /dev montado."
    fi

    # /dev/pts
    if ! mountpoint -q "$LFS/dev/pts"; then
        mount -t devpts devpts "$LFS/dev/pts" -o gid=5,mode=620
        echo "  - devpts em /dev/pts montado."
    fi

    # /proc
    if ! mountpoint -q "$LFS/proc"; then
        mount -t proc proc "$LFS/proc"
        echo "  - /proc montado."
    fi

    # /sys
    if ! mountpoint -q "$LFS/sys"; then
        mount -t sysfs sysfs "$LFS/sys"
        echo "  - /sys montado."
    fi

    # /run
    if ! mountpoint -q "$LFS/run"; then
        mount -t tmpfs tmpfs "$LFS/run"
        echo "  - /run montado."
    fi

    echo ">> Sistemas de arquivos virtuais montados."
}

umount_virtual_fs() {
    echo ">> Desmontando sistemas de arquivos virtuais de $LFS ..."

    # Desmontar na ordem inversa
    for mp in run sys proc dev/pts dev; do
        if mountpoint -q "$LFS/$mp"; then
            umount "$LFS/$mp"
            echo "  - $LFS/$mp desmontado."
        fi
    done

    echo ">> Desmontagem concluída."
}

enter_chroot_plain() {
    echo ">> Entrando em chroot simples em $LFS ..."
    exec chroot "$LFS" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM:-xterm}" \
        PS1='(lfs-chroot) \u:\w\$ ' \
        PATH=/usr/bin:/usr/sbin:/bin:/sbin \
        /bin/bash --login
}

enter_chroot_secure() {
    echo ">> Entrando em chroot (modo seguro) em $LFS ..."

    if ! command -v unshare >/dev/null 2>&1; then
        echo ">> 'unshare' não encontrado; caindo para chroot simples."
        enter_chroot_plain
        return
    fi

    # Aqui criamos novos namespaces (pid, mount, uts, ipc) para isolar mais o ambiente
    exec unshare --mount --uts --ipc --pid --fork --mount-proc \
         chroot "$LFS" /usr/bin/env -i \
         HOME=/root \
         TERM="${TERM:-xterm}" \
         PS1='(lfs-secure) \u:\w\$ ' \
         PATH=/usr/bin:/usr/sbin:/bin:/sbin \
         /bin/bash --login
}

status() {
    cat <<EOF
=== ADM Manager Status ===
LFS base...............: $LFS
Sources................: $LFS_SOURCES_DIR
Tools..................: $LFS_TOOLS_DIR
Logs...................: $LFS_LOG_DIR
Build scripts..........: $LFS_BUILD_SCRIPTS_DIR
LFS_USER / LFS_GROUP...: $LFS_USER / $LFS_GROUP
Chroot seguro (unshare): $( [[ "$CHROOT_SECURE" -eq 1 ]] && echo "ATIVADO" || echo "DESATIVADO" )

Montagens:
$(mount | grep "on $LFS" || echo "  (sem montagens relacionadas a $LFS)")

EOF
}

run_build_script() {
    local script_name="${1:-}"

    [[ -z "$script_name" ]] && die "Informe o nome do script de build. Ex: run-build binutils-pass1.sh"

    local script_path="$LFS_BUILD_SCRIPTS_DIR/$script_name"

    [[ -x "$script_path" ]] || die "Script de build $script_path não existe ou não é executável."

    echo ">> Executando script de build dentro do chroot: $script_name"

    # Garantir FS virtuais montados
    mount_virtual_fs

    # Use um chroot simples mas chamando diretamente o script, para build automatizado
    chroot "$LFS" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM:-xterm}" \
        PATH=/usr/bin:/usr/sbin:/bin:/sbin \
        /bin/bash -lc "/build-scripts/$script_name"
}

#--------------------------------------------------------
# Main
#--------------------------------------------------------

main() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    load_config
    require_root

    local cmd="$1"; shift || true

    case "$cmd" in
        init)
            init_layout
            ;;
        create-user)
            create_build_user
            ;;
        mount)
            mount_virtual_fs
            ;;
        umount)
            umount_virtual_fs
            ;;
        chroot)
            mount_virtual_fs
            if [[ "$CHROOT_SECURE" -eq 1 ]]; then
                enter_chroot_secure
            else
                enter_chroot_plain
            fi
            ;;
        chroot-plain)
            mount_virtual_fs
            enter_chroot_plain
            ;;
        status)
            status
            ;;
        run-build)
            run_build_script "$@"
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            echo "Comando desconhecido: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
