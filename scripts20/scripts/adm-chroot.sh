#!/usr/bin/env bash
# adm-chroot - entra em chroot no rootfs do sistema em construção (glibc/musl)
# com montagem e desmontagem seguras, pronto para usar o adm dentro do chroot.
#
# Suporta dry-run:
#   adm-chroot --dry-run glibc
#   adm-chroot -n /opt/systems/glibc-rootfs

set -euo pipefail

### CONFIGURAÇÕES PADRÃO #######################################################

ROOTFS_GLIBC_DEFAULT="/opt/systems/glibc-rootfs"
ROOTFS_MUSL_DEFAULT="/opt/systems/musl-rootfs"

ADM_BIN_HOST="/usr/bin/adm"
ADM_PACKAGES_HOST="/usr/src/adm/packages"
ADM_ETC_HOST="/etc/adm"

ADM_BIN_CHROOT="/usr/bin/adm"
ADM_PACKAGES_CHROOT="/usr/src/adm/packages"
ADM_ETC_CHROOT="/etc/adm"

DRY_RUN=0

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
Uso: $(basename "$0") [--dry-run|-n] [glibc|musl|/caminho/do/rootfs]

Sem argumentos, tenta usar:
  - ${ROOTFS_GLIBC_DEFAULT} (se existir), senão
  - ${ROOTFS_MUSL_DEFAULT}  (se existir)

Opções:
  -n, --dry-run   Apenas mostra o que seria feito (não monta, não copia, não entra em chroot).

Exemplos:
  $(basename "$0") glibc
  $(basename "$0") musl
  $(basename "$0") /opt/systems/glibc-rootfs
  $(basename "$0") --dry-run glibc
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

detect_chroot_libc() {
    local rootfs="$1"

    case "$rootfs" in
        *glibc-rootfs*) echo "glibc" ;;
        *musl-rootfs*)  echo "musl"  ;;
        "$ROOTFS_GLIBC_DEFAULT") echo "glibc" ;;
        "$ROOTFS_MUSL_DEFAULT")  echo "musl"  ;;
        *)
            # desconhecido, deixa vazio
            echo ""
            ;;
    esac
}

### MONTAGEM / DESMONTAGEM #####################################################

ROOTFS=""
mounted_points=()

mount_if_needed() {
    local src="$1" dst="$2" type="${3:-}" opts="${4:-}"

    if [ "$DRY_RUN" -eq 1 ]; then
        if [ -n "$type" ]; then
            info "[DRY-RUN] montaria: src=${src}, dst=${dst}, tipo=${type}, opts=${opts:-<nenhum>}"
        else
            info "[DRY-RUN] faria bind: src=${src}, dst=${dst}, opts=${opts:-<nenhum>}"
        fi
        return 0
    fi

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

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY-RUN] desmontaria: $dst"
        return 0
    fi

    if mountpoint -q "$dst" 2>/dev/null; then
        umount "$dst" || {
            warn "Falha ao desmontar $dst, tentando lazy umount..."
            umount -l "$dst" || warn "Ainda não consegui desmontar $dst (verifique manualmente)."
        }
        ok "Desmontado: $dst"
    fi
}

cleanup_mounts() {
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

parse_args() {
    local positional=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -n|--dry-run)
                DRY_RUN=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                positional+=("$1")
                ;;
        esac
        shift
    done
    # retorna argumentos posicionais em $@
    set -- "${positional[@]}"
    echo "$@"
}

main() {
    # Parse de opções (dry-run, etc.)
    local rest
    rest="$(parse_args "$@")" || exit 1
    # shellcheck disable=SC2086
    set -- $rest

    ROOTFS="$(detect_rootfs "${1:-}")"
    ROOTFS="${ROOTFS%/}"  # remove barra final se tiver

    if [ ! -d "$ROOTFS" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            err "ROOTFS não encontrado: $ROOTFS (dry-run apenas avisando)"
            exit 0
        else
            err "ROOTFS não encontrado: $ROOTFS"
            exit 1
        fi
    fi

    info "Usando ROOTFS: $ROOTFS"
    [ "$DRY_RUN" -eq 1 ] && warn "MODO DRY-RUN ATIVADO: nenhuma alteração real será feita."

    # Registra cleanup em qualquer saída (mesmo em dry-run é seguro)
    trap cleanup_mounts EXIT INT TERM

    # Deduz tipo de libc do chroot (glibc/musl quando possível)
    local chroot_libc
    chroot_libc="$(detect_chroot_libc "$ROOTFS")"
    if [ -n "$chroot_libc" ]; then
        info "Libc detectada para o chroot: $chroot_libc"
    else
        warn "Não foi possível deduzir a libc do chroot (glibc/musl). ADM_LIBC ficará vazio dentro do chroot."
    fi

    # Diretórios básicos
    local basic_dirs=(
        "$ROOTFS/dev"
        "$ROOTFS/proc"
        "$ROOTFS/sys"
        "$ROOTFS/run"
        "$ROOTFS/tmp"
        "$ROOTFS/etc"
        "$ROOTFS/usr/bin"
        "$ROOTFS/var/log/adm"
        "$ROOTFS/var/lib/adm"
        "$ROOTFS/var/cache/adm/sources"
        "$ROOTFS/var/cache/adm/packages"
    )

    for d in "${basic_dirs[@]}"; do
        if [ "$DRY_RUN" -eq 1 ]; then
            info "[DRY-RUN] criaria diretório: $d"
        else
            mkdir -p "$d"
        fi
    done

    # Copiar resolv.conf
    if [ -f /etc/resolv.conf ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            info "[DRY-RUN] copiaria /etc/resolv.conf -> $ROOTFS/etc/resolv.conf"
        else
            cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
            ok "Copiado /etc/resolv.conf para $ROOTFS/etc/resolv.conf"
        fi
    else
        warn "/etc/resolv.conf não encontrado no host; DNS pode não funcionar dentro do chroot."
    fi

    # Copiar o binário do adm
    if [ -x "$ADM_BIN_HOST" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            info "[DRY-RUN] copiaria $ADM_BIN_HOST -> $ROOTFS$ADM_BIN_CHROOT"
        else
            cp -f "$ADM_BIN_HOST" "$ROOTFS$ADM_BIN_CHROOT"
            chmod +x "$ROOTFS$ADM_BIN_CHROOT"
            ok "Copiado adm: $ADM_BIN_HOST -> $ROOTFS$ADM_BIN_CHROOT"
        fi
    else
        warn "adm não encontrado em $ADM_BIN_HOST; você não terá 'adm' dentro do chroot."
    fi

    # Copiar /etc/adm (profiles e configurações do adm) para dentro do chroot
    if [ -d "$ADM_ETC_HOST" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            info "[DRY-RUN] copiaria recursivamente $ADM_ETC_HOST -> $ROOTFS$ADM_ETC_CHROOT"
        else
            mkdir -p "$ROOTFS$ADM_ETC_CHROOT"
            cp -a "$ADM_ETC_HOST/." "$ROOTFS$ADM_ETC_CHROOT/"
            ok "Copiado /etc/adm (profiles, configs) para $ROOTFS$ADM_ETC_CHROOT"
        fi
    else
        warn "Diretório /etc/adm não encontrado no host; profiles do adm podem não estar disponíveis no chroot."
    fi

    # Bind do diretório de pacotes
    if [ -d "$ADM_PACKAGES_HOST" ]; then
        mount_if_needed "$ADM_PACKAGES_HOST" "$ROOTFS$ADM_PACKAGES_CHROOT"
    else
        warn "Diretório de pacotes não encontrado no host: $ADM_PACKAGES_HOST"
    fi

    # Montagens básicas
    mount_if_needed proc               "$ROOTFS/proc"      "proc"
    mount_if_needed sysfs              "$ROOTFS/sys"       "sysfs"
    mount_if_needed /dev               "$ROOTFS/dev"
    mount_if_needed /dev/pts           "$ROOTFS/dev/pts"
    if [ -d /run ]; then
        mount_if_needed /run           "$ROOTFS/run"
    fi

    ok "Todas as montagens necessárias foram consideradas."

    # escolher shell dentro do chroot
    local chroot_shell="/tools/bin/bash"
    if [ ! -x "$ROOTFS$chroot_shell" ]; then
        chroot_shell="/bin/bash"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        if [ -x "$ROOTFS$chroot_shell" ]; then
            ok "[DRY-RUN] shell disponível em $ROOTFS$chroot_shell"
        else
            warn "[DRY-RUN] nenhum shell encontrado em $ROOTFS/tools/bin/bash ou $ROOTFS/bin/bash"
        fi
    else
        if [ ! -x "$ROOTFS$chroot_shell" ]; then
            err "Nenhum shell encontrado em $ROOTFS/tools/bin/bash ou $ROOTFS/bin/bash"
            exit 1
        fi
    fi

    # PATH típico para construção (LFS style)
    local chroot_path="/tools/bin:/bin:/usr/bin:/sbin:/usr/sbin"

    if [ "$DRY_RUN" -eq 1 ]; then
        info "[DRY-RUN] entraria em chroot com:"
        info "  ROOTFS = $ROOTFS"
        info "  SHELL  = $chroot_shell"
        info "  PATH   = $chroot_path"
        info "  ADM_ROOTFS = /"
        [ -n "$chroot_libc" ] && info "  ADM_LIBC   = $chroot_libc" || info "  ADM_LIBC   = <vazio>"
        info "[DRY-RUN] fim. Nenhuma ação foi executada."
        return 0
    fi

    info "Entrando no chroot (shell: $chroot_shell)..."
    info "Dentro do chroot, para usar o adm, execute: adm <comando>"

    chroot "$ROOTFS" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM:-xterm}" \
        PS1="[adm-chroot:\u@\h \w]\\$ " \
        PATH="$chroot_path" \
        ADM_ROOTFS="/" \
        ADM_LIBC="$chroot_libc" \
        /bin/bash -c "
            if [ -x '$chroot_shell' ]; then
                exec '$chroot_shell' --login
            else
                exec /bin/bash --login
            fi
        "

    ok "Saiu do chroot. Desmontando tudo..."
}

main "$@"
