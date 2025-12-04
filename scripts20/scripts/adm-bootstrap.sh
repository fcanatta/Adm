#!/usr/bin/env bash
# adm-bootstrap - prepara rootfs, entra em chroot e executa uma fila de builds com o adm.
#
# Host mode: prepara e monta o rootfs, copia adm/configs, entra no chroot e chama este
# mesmo script em "inner mode" para rodar adm build/install em sequência.
#
# Uso no host:
#   adm-bootstrap [glibc|musl|/caminho/rootfs] [categoria/pacote ...]
#
# Se NÃO forem passados pacotes na linha de comando, lê a fila em:
#   /etc/adm/bootstrap.queue
# (um pacote por linha, de preferência no formato categoria/programa).
#
# Dentro do chroot (inner mode), o script:
#   - lê /etc/adm/bootstrap.queue ou a lista passada
#   - lê estado em /var/lib/adm/bootstrap-state
#   - retoma a partir do último índice concluído com sucesso
#   - mostra tudo colorido e com logs individuais em /var/log/adm

set -euo pipefail

###############################################################################
# CORES COMPARTILHADAS
###############################################################################

if [ -t 1 ]; then
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    BLUE=$'\033[34m'
    MAGENTA=$'\033[35m'
    CYAN=$'\033[36m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; BOLD=""; RESET=""
fi

log_host()  { printf "%s\n" "$*"; }
info_host() { printf "%s[INFO]%s %s\n" "$BLUE" "$RESET" "$*"; }
ok_host()   { printf "%s[OK]%s %s\n"   "$GREEN" "$RESET" "$*"; }
warn_host() { printf "%s[WARN]%s %s\n" "$YELLOW" "$RESET" "$*"; }
err_host()  { printf "%s[ERRO]%s %s\n" "$RED" "$RESET" "$*" >&2; }

log_inner()  { printf "%s\n" "$*"; }
info_inner() { printf "%s[INFO]%s %s\n" "$BLUE" "$RESET" "$*"; }
ok_inner()   { printf "%s[✔]%s %s\n"   "$GREEN" "$RESET" "$*"; }
warn_inner() { printf "%s[WARN]%s %s\n" "$YELLOW" "$RESET" "$*"; }
err_inner()  { printf "%s[ERRO]%s %s\n" "$RED" "$RESET" "$*" >&2; }

###############################################################################
# MODO HOST (fora do chroot)
###############################################################################

ROOTFS_GLIBC_DEFAULT="/opt/systems/glibc-rootfs"
ROOTFS_MUSL_DEFAULT="/opt/systems/musl-rootfs"

ADM_BIN_HOST="/usr/bin/adm"
ADM_ETC_HOST="/etc/adm"
ADM_PACKAGES_HOST="/usr/src/adm/packages"

ADM_BIN_CHROOT="/usr/bin/adm"
ADM_ETC_CHROOT="/etc/adm"
ADM_PACKAGES_CHROOT="/usr/src/adm/packages"

BOOTSTRAP_QUEUE_FILE="/etc/adm/bootstrap.queue"

detect_rootfs_host() {
    local arg="${1:-}"

    if [ -n "$arg" ]; then
        case "$arg" in
            glibc) echo "$ROOTFS_GLIBC_DEFAULT"; return 0 ;;
            musl)  echo "$ROOTFS_MUSL_DEFAULT";  return 0 ;;
            /*)    echo "$arg";                 return 0 ;;
            *)
                err_host "Argumento de rootfs inválido: $arg"
                exit 1
                ;;
        esac
    fi

    if [ -d "$ROOTFS_GLIBC_DEFAULT" ]; then
        echo "$ROOTFS_GLIBC_DEFAULT"
    elif [ -d "$ROOTFS_MUSL_DEFAULT" ]; then
        echo "$ROOTFS_MUSL_DEFAULT"
    else
        err_host "Nenhum rootfs padrão encontrado:"
        err_host "  - $ROOTFS_GLIBC_DEFAULT"
        err_host "  - $ROOTFS_MUSL_DEFAULT"
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
        *) echo "" ;;
    esac
}

mount_points=()

mount_if_needed_host() {
    local src="$1" dst="$2" type="${3:-}" opts="${4:-}"

    if mountpoint -q "$dst" 2>/dev/null; then
        info_host "Já montado: $dst"
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

    mount_points+=("$dst")
    ok_host "Montado: $dst"
}

umount_safe_host() {
    local dst="$1"

    if mountpoint -q "$dst" 2>/dev/null; then
        umount "$dst" || {
            warn_host "Falha ao desmontar $dst, tentando umount -l..."
            umount -l "$dst" || warn_host "Não foi possível desmontar $dst (verifique manualmente)."
        }
        ok_host "Desmontado: $dst"
    fi
}

cleanup_mounts_host() {
    local i
    for (( i=${#mount_points[@]}-1; i>=0; i-- )); do
        umount_safe_host "${mount_points[$i]}"
    done
}

host_main() {
    [ "$(id -u)" -eq 0 ] || {
        err_host "Este script precisa ser executado como root."
        exit 1
    }

    local rootfs_arg=""
    local pkgs=()

    # Se o primeiro argumento for glibc/musl ou caminho absoluto, é o rootfs
    if [ $# -gt 0 ]; then
        case "$1" in
            glibc|musl|/*)
                rootfs_arg="$1"
                shift
                ;;
        esac
    fi

    while [ $# -gt 0 ]; do
        pkgs+=("$1")
        shift
    done

    local ROOTFS
    ROOTFS="$(detect_rootfs_host "$rootfs_arg")"
    ROOTFS="${ROOTFS%/}"

    if [ ! -d "$ROOTFS" ]; then
        err_host "ROOTFS não encontrado: $ROOTFS"
        exit 1
    fi

    local chroot_libc
    chroot_libc="$(detect_chroot_libc "$ROOTFS")"

    info_host "Usando ROOTFS: $ROOTFS"
    [ -n "$chroot_libc" ] && info_host "Libc detectada para o chroot: $chroot_libc" || warn_host "Não foi possível deduzir libc (ADM_LIBC ficará vazio)."

    trap cleanup_mounts_host EXIT INT TERM

    # Diretórios básicos dentro do rootfs
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
        "$ROOTFS/root"
    )

    for d in "${basic_dirs[@]}"; do
        mkdir -p "$d"
    done

    # resolv.conf para DNS dentro do chroot
    if [ -f /etc/resolv.conf ]; then
        cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
        ok_host "Copiado /etc/resolv.conf -> $ROOTFS/etc/resolv.conf"
    else
        warn_host "/etc/resolv.conf não encontrado no host; DNS pode não funcionar no chroot."
    fi

    # adm binário
    if [ -x "$ADM_BIN_HOST" ]; then
        cp -f "$ADM_BIN_HOST" "$ROOTFS$ADM_BIN_CHROOT"
        chmod +x "$ROOTFS$ADM_BIN_CHROOT"
        ok_host "Copiado adm: $ADM_BIN_HOST -> $ROOTFS$ADM_BIN_CHROOT"
    else
        warn_host "adm não encontrado em $ADM_BIN_HOST; 'adm' não estará disponível no chroot."
    fi

    # /etc/adm com profiles e configs
    if [ -d "$ADM_ETC_HOST" ]; then
        mkdir -p "$ROOTFS$ADM_ETC_CHROOT"
        cp -a "$ADM_ETC_HOST/." "$ROOTFS$ADM_ETC_CHROOT/"
        ok_host "Copiado /etc/adm -> $ROOTFS$ADM_ETC_CHROOT"
    else
        warn_host "/etc/adm não encontrado no host; profiles do adm podem não estar disponíveis no chroot."
    fi

    # Bind /usr/src/adm/packages
    if [ -d "$ADM_PACKAGES_HOST" ]; then
        mount_if_needed_host "$ADM_PACKAGES_HOST" "$ROOTFS$ADM_PACKAGES_CHROOT"
    else
        warn_host "Diretório de pacotes não encontrado no host: $ADM_PACKAGES_HOST"
    fi

    # Montagens básicas
    mount_if_needed_host proc          "$ROOTFS/proc" "proc"
    mount_if_needed_host sysfs         "$ROOTFS/sys"  "sysfs"
    mount_if_needed_host /dev          "$ROOTFS/dev"
    mount_if_needed_host /dev/pts      "$ROOTFS/dev/pts"
    if [ -d /run ]; then
        mount_if_needed_host /run      "$ROOTFS/run"
    fi

    ok_host "Todas as montagens necessárias foram realizadas."

    # Escolher shell dentro do chroot
    local chroot_shell="/tools/bin/bash"
    if [ ! -x "$ROOTFS$chroot_shell" ]; then
        chroot_shell="/bin/bash"
    fi
    if [ ! -x "$ROOTFS$chroot_shell" ]; then
        err_host "Nenhum shell encontrado em $ROOTFS/tools/bin/bash ou $ROOTFS/bin/bash"
        exit 1
    fi

    # PATH de build típico
    local chroot_path="/tools/bin:/bin:/usr/bin:/sbin:/usr/sbin"

    # Copiar este script para dentro do chroot (inner script)
    local inner_script="/root/adm-bootstrap-inner.sh"
    cp -f "$0" "$ROOTFS$inner_script"
    chmod +x "$ROOTFS$inner_script"
    ok_host "Copiado bootstrap para dentro do chroot: $ROOTFS$inner_script"

    info_host "Entrando no chroot para executar fila de build com o adm..."

    # Passar a fila (se vazia, inner usará /etc/adm/bootstrap.queue)
    chroot "$ROOTFS" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM:-xterm}" \
        PS1="[adm-bootstrap:\u@\h \w]\\$ " \
        PATH="$chroot_path" \
        ADM_BOOTSTRAP_INNER=1 \
        ADM_BOOTSTRAP_LIBC="$chroot_libc" \
        ADM_BOOTSTRAP_STATE_FILE="/var/lib/adm/bootstrap-state" \
        ADM_BOOTSTRAP_QUEUE_FILE="$BOOTSTRAP_QUEUE_FILE" \
        /bin/bash "$inner_script" "${pkgs[@]}"

    ok_host "Fila de bootstrap encerrada. Saindo do chroot."
}

###############################################################################
# MODO INNER (dentro do chroot)
###############################################################################

inner_load_queue() {
    # Se argumentos foram passados, eles são a fila
    if [ "$#" -gt 0 ]; then
        QUEUE=("$@")
        return 0
    fi

    # Senão, ler do arquivo de fila
    local qfile="${ADM_BOOTSTRAP_QUEUE_FILE:-/etc/adm/bootstrap.queue}"
    if [ ! -f "$qfile" ]; then
        err_inner "Nenhuma fila de pacotes passada e arquivo $qfile não existe."
        exit 1
    fi

    QUEUE=()
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        QUEUE+=("$line")
    done < "$qfile"

    if [ "${#QUEUE[@]}" -eq 0 ]; then
        err_inner "Fila $qfile está vazia."
        exit 1
    fi
}

inner_read_state() {
    STATE_FILE="${ADM_BOOTSTRAP_STATE_FILE:-/var/lib/adm/bootstrap-state}"
    LAST_OK_INDEX="-1"
    LAST_OK_PKG=""
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE" || true
    fi
}

inner_write_state() {
    local idx="$1" pkg="$2"
    mkdir -p "$(dirname "$STATE_FILE")"
    {
        echo "LAST_OK_INDEX=\"$idx\""
        echo "LAST_OK_PKG=\"$pkg\""
        echo "LAST_OK_TIME=\"$(date +'%Y-%m-%d %H:%M:%S')\""
    } > "$STATE_FILE"
}

inner_show_header() {
    local total="$1"
    info_inner "${BOLD}===== ADM BOOTSTRAP (total de pacotes: $total) =====${RESET}"
    [ -n "${ADM_BOOTSTRAP_LIBC:-}" ] && info_inner "Libc: ${ADM_BOOTSTRAP_LIBC}" || info_inner "Libc: (não definida)"
    info_inner "State file: ${STATE_FILE}"
    info_inner ""
}

inner_show_pkg_info() {
    local idx="$1" total="$2" pkg="$3"

    local cat="" name="$pkg"
    if echo "$pkg" | grep -q "/"; then
        cat="${pkg%/*}"
        name="${pkg#*/}"
    fi

    local dep_str="(sem deps)"
    if [ -n "$cat" ]; then
        local depfile="/usr/src/adm/packages/${cat}/${name}/${name}.deps"
        if [ -f "$depfile" ]; then
            dep_str="$(grep -Ev '^\s*($|#)' "$depfile" || true)"
            [ -z "$dep_str" ] && dep_str="(sem deps)"
        fi
    fi

    local ver_str="(?)"
    # Se já tiver meta (instalado), tentar pegar versão
    local meta_glob="/var/lib/adm/db/${cat}__${name}__"*.meta
    for meta in $meta_glob; do
        [ -f "$meta" ] || continue
        unset PKG_VERSION
        # shellcheck disable=SC1090
        . "$meta"
        ver_str="${PKG_VERSION:-$ver_str}"
        break
    done

    printf "%s[%d/%d]%s %s%s%s (versão: %s)\n" \
        "$CYAN" "$((idx+1))" "$total" "$RESET" "$BOLD" "$pkg" "$RESET" "$ver_str"
    printf "  Dependências: %s\n" "$dep_str"
}

inner_main() {
    # Estamos dentro do chroot
    if ! command -v adm >/dev/null 2>&1; then
        err_inner "'adm' não encontrado dentro do chroot. Verifique se foi copiado para /usr/bin/adm."
        exit 1
    fi

    inner_load_queue "$@"
    inner_read_state

    local total="${#QUEUE[@]}"
    inner_show_header "$total"

    if [ "$LAST_OK_INDEX" != "-1" ]; then
        ok_inner "Último pacote concluído: índice ${LAST_OK_INDEX}, pacote '${LAST_OK_PKG}'"
        echo
    fi

    local i pkg
    for i in "${!QUEUE[@]}"; do
        pkg="${QUEUE[$i]}"

        # Se já foi concluído antes, mostrar como OK e pular
        if [ "$LAST_OK_INDEX" != "" ] && [ "$i" -le "${LAST_OK_INDEX:- -1}" ]; then
            printf "%s< ✔️ >%s %s (já concluído, pulando)\n" "$GREEN" "$RESET" "$pkg"
            continue
        fi

        echo
        inner_show_pkg_info "$i" "$total" "$pkg"

        local cat="" name="$pkg"
        if echo "$pkg" | grep -q "/"; then
            cat="${pkg%/*}"
            name="${pkg#*/}"
        fi
        local log_name="${name//\//_}"
        local log_file="/var/log/adm/bootstrap-${i}-${log_name}.log"

        printf "  Log: %s%s%s\n" "$MAGENTA" "$log_file" "$RESET"
        printf "  Etapas: %sbuild%s -> %sinstall%s\n" "$BLUE" "$RESET" "$BLUE" "$RESET"

        # Executar build + install
        {
            echo "===== $(date +'%Y-%m-%d %H:%M:%S') - Iniciando ${pkg} ====="
            echo "Etapa: adm build ${pkg}"
            adm build "$pkg"
            echo "Etapa: adm install ${pkg}"
            adm install "$pkg"
            echo "===== $(date +'%Y-%m-%d %H:%M:%S') - SUCESSO ${pkg} ====="
        } >> "$log_file" 2>&1 || {
            err_inner "Falha na construção/instalação de ${pkg}. Veja o log: $log_file"
            printf "%s< ✖ >%s %s\n" "$RED" "$RESET" "$pkg"
            exit 1
        }

        inner_write_state "$i" "$pkg"
        printf "%s< ✔️ >%s %s concluído com sucesso.\n" "$GREEN" "$RESET" "$pkg"
    done

    echo
    ok_inner "Todos os ${total} pacotes da fila foram construídos/instalados com sucesso."
}

###############################################################################
# DISPATCH
###############################################################################

if [ "${ADM_BOOTSTRAP_INNER:-0}" = "1" ]; then
    # Dentro do chroot
    inner_main "$@"
else
    # No host
    host_main "$@"
fi
