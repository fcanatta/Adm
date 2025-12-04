#!/usr/bin/env bash
# adm-chroot - entra em chroot no rootfs do sistema em construção (glibc/musl)
# com montagem e desmontagem seguras, pronto para usar o adm dentro do chroot.

set -euo pipefail

### CONFIGURAÇÕES PADRÃO #######################################################

ROOTFS_GLIBC_DEFAULT="/opt/systems/glibc-rootfs"
ROOTFS_MUSL_DEFAULT="/opt/systems/musl-rootfs"

ADM_BIN_HOST="/usr/bin/adm"
ADM_PACKAGES_HOST="/usr/src/adm/packages"

# Você pode ajustar isso se seu adm estiver em outro lugar dentro do chroot:
ADM_BIN_CHROOT="/usr/bin/adm"
ADM_PACKAGES_CHROOT="/usr/src/adm/packages"

### CORES SIMPLES #############################################################

if [ -t 1 ]; then
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    BLUE=$'\033[34m'
    RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

log()  { printf "%s\n" "$*"; }
info() { printf "%s[INFO]%s %s\n" "$BLUE" "$RESET" "$*"; }
ok()   { printf "%s[OK]%s %s\n"   "$GREEN" "$RESET" "$*"; }
warn() { printf "%s[WARN]%s %s\n" "$YELLOW" "$RESET" "$*"; }
err()  { printf "%s[ERRO]%s %s\n" "$RED" "$RESET" "$*" >&2; }

usage() {
    cat <<EOF
Uso: $(basename "$0") [glibc|musl|/caminho/do/rootfs]

Sem argumentos, tenta usar:
  - ${ROOTFS_GLIBC_DEFAULT} (se existir), senão
  - ${ROOTFS_MUSL_DEFAULT}  (se existir)

Exemplos:
  $(basename "$0") glibc
  $(basename "$0") musl
  $(basename "$0") /opt/systems/glibc-rootfs
EOF
}

### RESOLUÇÃO DO ROOTFS #######################################################

detect_rootfs() {
    local arg="${1:-}"

    if [ -n "$arg" ]; then
        case "$arg" in
            glibc)
                echo "$ROOTFS_GLIBC_DEFAULT"
                return 0
                ;;
            musl)
                echo "$ROOTFS_MUSL_DEFAULT"
                return 0
                ;;
            /*)
                echo "$arg"
                return 0
                ;;
            *)
                err "Argumento inválido: $arg"
                usage
                exit 1
                ;;
        esac
    fi

    if [ -d "$ROOTFS_GLIBC_DEFAULT" ]; then
        echo "$ROOTFS_GLIBC_DEFAULT"
    elif [ -d "$ROOTFS_MUSL_DEFAULT" ]; then
        echo "$ROOTFS_MUSL_DEFAULT"
    else
        err "Nenhum rootfs padrão encontrado:"
        err "  - $ROOTFS_GLIBC_DEFAULT"
        err "  - $ROOTFS_MUSL_DEFAULT"
        usage
        exit 1
    fi
}

### MONTAGEM / DESMONTAGEM #####################################################

ROOTFS=""
mounted_points=()

mount_if_needed() {
    local src="$1" dst="$2" type="${3:-}" opts="${4:-}"
    if mountpoint -q "$dst" 2>/dev/null; then
        info "Já montado: $dst"
        return 0
    fi

    mkdir -p "$dst"

    if [ -n "$type" ]; then
        if [ -n "$opts" ]; then
            mount -t "$type" -o "$opts" "$src" "$dst"
        else
            mount -t "$type" "$src" "$dst"
        fi
    else
        # bind mount
        if [ -n "$opts" ]; then
            mount --bind -o "$opts" "$src" "$dst"
        else
            mount --bind "$src" "$dst"
        fi
    fi

    mounted_points+=("$dst")
    ok "Montado: $dst"
}

umount_safe() {
    local dst="$1"
    if mountpoint -q "$dst" 2>/dev/null; then
        umount "$dst" || {
            warn "Falha ao desmontar $dst, tentando lazy umount..."
            umount -l "$dst" || warn "Ainda não consegui desmontar $dst (verifique manualmente)."
        }
        ok "Desmontado: $dst"
    fi
}

cleanup_mounts() {
    # desmonta na ordem inversa
    local i
    for (( i=${#mounted_points[@]}-1; i>=0; i-- )); do
        umount_safe "${mounted_points[$i]}"
    done
}

### CHECAGENS ###############################################################

[ "$(id -u)" -eq 0 ] || {
    err "Este script precisa ser executado como root."
    exit 1
}

main() {
    ROOTFS="$(detect_rootfs "${1:-}")"
    ROOTFS="${ROOTFS%/}"  # remove barra final se tiver

    [ -d "$ROOTFS" ] || {
        err "ROOTFS não encontrado: $ROOTFS"
        exit 1
    }

    info "Usando ROOTFS: $ROOTFS"

    # Registra cleanup em qualquer saída
    trap cleanup_mounts EXIT INT TERM

    # Garantir diretórios básicos
    mkdir -p \
        "$ROOTFS"/{dev,proc,sys,run,tmp,etc,usr/bin} \
        "$ROOTFS$(dirname "$ADM_PACKAGES_CHROOT")"

    # Copiar resolv.conf para ter DNS dentro do chroot
    if [ -f /etc/resolv.conf ]; then
        cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
        ok "Copiado /etc/resolv.conf para $ROOTFS/etc/resolv.conf"
    else
        warn "/etc/resolv.conf não encontrado no host; DNS pode não funcionar dentro do chroot."
    fi

    # Copiar o binário do adm para dentro do chroot
    if [ -x "$ADM_BIN_HOST" ]; then
        cp -f "$ADM_BIN_HOST" "$ROOTFS$ADM_BIN_CHROOT"
        chmod +x "$ROOTFS$ADM_BIN_CHROOT"
        ok "Copiado adm: $ADM_BIN_HOST -> $ROOTFS$ADM_BIN_CHROOT"
    else
        warn "adm não encontrado em $ADM_BIN_HOST; você não terá 'adm' dentro do chroot."
    fi

    # Bind do diretório de pacotes (/usr/src/adm/packages)
    if [ -d "$ADM_PACKAGES_HOST" ]; then
        mount_if_needed "$ADM_PACKAGES_HOST" "$ROOTFS$ADM_PACKAGES_CHROOT"
    else
        warn "Diretório de pacotes não encontrado no host: $ADM_PACKAGES_HOST"
    fi

    # Montagens básicas para o chroot
    mount_if_needed proc               "$ROOTFS/proc"      "proc"
    mount_if_needed sysfs              "$ROOTFS/sys"       "sysfs"
    mount_if_needed /dev               "$ROOTFS/dev"
    mount_if_needed /dev/pts           "$ROOTFS/dev/pts"
    if [ -d /run ]; then
        mount_if_needed /run           "$ROOTFS/run"
    fi
    # /tmp geralmente é só diretório, mas se quiser pode bind-mountar também
    # mount_if_needed /tmp "$ROOTFS/tmp"

    ok "Todas as montagens necessárias foram feitas."

    # escolher shell dentro do chroot
    local chroot_shell="/tools/bin/bash"
    if [ ! -x "$ROOTFS$chroot_shell" ]; then
        chroot_shell="/bin/bash"
    fi
    if [ ! -x "$ROOTFS$chroot_shell" ]; then
        err "Nenhum shell encontrado em $ROOTFS/tools/bin/bash ou $ROOTFS/bin/bash"
        exit 1
    fi

    # PATH típico para fase de construção (LFS-like)
    local chroot_path="/tools/bin:/bin:/usr/bin:/sbin:/usr/sbin"

    info "Entrando no chroot (shell: $chroot_shell)..."
    info "Para usar o adm dentro do chroot, rode: adm <comando>"

    chroot "$ROOTFS" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM:-xterm}" \
        PS1="[adm-chroot:\u@\h \w]\\$ " \
        PATH="$chroot_path" \
        /bin/bash -c "
            # se o shell principal for /tools/bin/bash, ajusta login
            if [ -x '$chroot_shell' ]; then
                exec '$chroot_shell' --login
            else
                exec /bin/bash --login
            fi
        "

    ok "Saiu do chroot. Desmontando tudo..."
}

main "$@"
