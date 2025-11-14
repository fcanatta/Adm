#!/usr/bin/env bash
# 22-rootfs-stage2.sh
# Preparação do rootfs stage1 + chroot seguro + temporary tools stage2 para o ADM.
#
# Funções principais:
#   - Preparar layout do rootfs stage1:
#       /usr/src/adm/rootfs-stage1/
#   - Montar/desmontar /dev, /dev/pts, /proc, /sys, /run
#   - Entrar em chroot com ambiente limpo
#   - Construir temporary tools stage2 (gettext, bison, perl, python, texinfo, util-linux, ...)
#     dentro do chroot, usando o build engine do ADM se disponível.
#
# Não há erros silenciosos. Tudo o que é crítico gera log e aborta via adm_die.
# ----------------------------------------------------------------------
# Requisitos e modo seguro
# ----------------------------------------------------------------------
if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERRO: 22-rootfs-stage2.sh requer bash." >&2
    exit 1
fi

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "ERRO: 22-rootfs-stage2.sh requer bash >= 4." >&2
    exit 1
fi

set -euo pipefail
IFS=$'\n\t'
# ----------------------------------------------------------------------
# Integração com ambiente e logging
# ----------------------------------------------------------------------
ADM_ROOT_DEFAULT="/usr/src/adm"
ADM_ROOT="${ADM_ROOT:-$ADM_ROOT_DEFAULT}"
ADM_ROOTFS_STAGE1="${ADM_ROOTFS_STAGE1:-$ADM_ROOT/rootfs-stage1}"
ADM_SCRIPTS="${ADM_SCRIPTS:-$ADM_ROOT/scripts}"

# Logging: usa 01-log-ui.sh se disponível; senão, fallback simples.
if ! declare -F adm_info >/dev/null 2>&1; then
    adm_log_ts() { date +"%Y-%m-%d %H:%M:%S"; }
    adm_info()   { printf '[%s] [INFO] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_warn()   { printf '[%s] [WARN] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_error()  { printf '[%s] [ERRO] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_die()    { adm_error "$*"; exit 1; }
fi

if ! declare -F adm_stage >/dev/null 2>&1; then
    adm_stage() { adm_info "===== STAGE: $* ====="; }
fi

if ! declare -F adm_ensure_dir >/dev/null 2>&1; then
    adm_ensure_dir() {
        local d="${1:-}"
        if [ -z "$d" ]; then
            adm_die "adm_ensure_dir chamado com caminho vazio"
        fi
        if [ -d "$d" ]; then
            return 0
        fi
        if ! mkdir -p "$d"; then
            adm_die "Falha ao criar diretório: $d"
        fi
    }
fi

if ! declare -F adm_run_with_spinner >/dev/null 2>&1; then
    adm_run_with_spinner() {
        # fallback sem spinner
        local msg="$1"; shift
        adm_info "$msg"
        "$@"
    }
fi

# ----------------------------------------------------------------------
# Helpers de privilégio e montagem
# ----------------------------------------------------------------------

adm_rootfs_require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        adm_die "Este script requer privilégios de root (montagem e chroot)."
    fi
}

adm_rootfs_is_mounted() {
    # Checa se rootfs/subpath está montado.
    # Uso: adm_rootfs_is_mounted /algum/caminho
    local path="${1:-}"
    [ -z "$path" ] && adm_die "adm_rootfs_is_mounted requer caminho"

    if command -v findmnt >/dev/null 2>&1; then
        if findmnt -n "$path" >/dev/null 2>&1; then
            return 0
        fi
    fi

    # Fallback: checa /proc/mounts
    grep -qE "[[:space:]]$path[[:space:]]" /proc/mounts 2>/dev/null
}

adm_rootfs_mount_one() {
    # Monta um sistema de arquivos se ainda não estiver montado.
    # $1: tipo ou "bind"
    # $2: origem (source)
    # $3: destino (target)
    # $4+: opções extras de mount
    local type="${1:-}"
    local src="${2:-}"
    local dst="${3:-}"
    shift 3
    local opts=("$@")

    [ -z "$type" ] && adm_die "adm_rootfs_mount_one requer tipo"
    [ -z "$src" ]  && adm_die "adm_rootfs_mount_one requer origem"
    [ -z "$dst" ]  && adm_die "adm_rootfs_mount_one requer destino"

    if adm_rootfs_is_mounted "$dst"; then
        adm_info "Já montado: $dst (pulando)"
        return 0
    fi

    adm_ensure_dir "$dst"

    if [ "$type" = "bind" ]; then
        adm_info "Montando bind: $src -> $dst"
        if ! mount --bind "$src" "$dst"; then
            adm_die "Falha ao montar bind $src -> $dst"
        fi
    else
        adm_info "Montando $type em $dst"
        if ! mount -t "$type" "${opts[@]}" "$src" "$dst"; then
            adm_die "Falha ao montar $type em $dst"
        fi
    fi
}

adm_rootfs_umount_one() {
    local dst="${1:-}"
    [ -z "$dst" ] && adm_die "adm_rootfs_umount_one requer destino"

    if ! adm_rootfs_is_mounted "$dst"; then
        adm_info "Não está montado: $dst (pulando umount)"
        return 0
    fi

    adm_info "Desmontando $dst"
    if umount "$dst" 2>/dev/null; then
        return 0
    fi

    adm_warn "Falha ao desmontar $dst; tentando umount -l (lazy umount)."
    if umount -l "$dst" 2>/dev/null; then
        adm_warn "Desmontagem lazy feita em $dst."
        return 0
    fi

    adm_die "Não foi possível desmontar $dst (mesmo com lazy umount)."
}

# ----------------------------------------------------------------------
# Preparação do rootfs stage1
# ----------------------------------------------------------------------

adm_rootfs_prepare_layout() {
    adm_stage "Stage rootfs - Preparar layout do rootfs stage1"

    adm_ensure_dir "$ADM_ROOTFS_STAGE1"

    # Diretórios básicos
    local dirs=(
        dev dev/pts dev/shm
        proc
        sys
        run
        etc
        tmp
        var var/log var/tmp var/run
        bin sbin
        usr usr/bin usr/sbin usr/lib usr/lib64 usr/local
        lib lib64
        home
        root
    )

    local d
    for d in "${dirs[@]}"; do
        adm_ensure_dir "$ADM_ROOTFS_STAGE1/$d"
    done

    # Permissão de /tmp e /var/tmp
    chmod 1777 "$ADM_ROOTFS_STAGE1/tmp"      || adm_die "Falha ao ajustar permissão de $ADM_ROOTFS_STAGE1/tmp"
    chmod 1777 "$ADM_ROOTFS_STAGE1/var/tmp"  || adm_die "Falha ao ajustar permissão de $ADM_ROOTFS_STAGE1/var/tmp"

    # /etc/passwd e /etc/group mínimos
    if [ ! -f "$ADM_ROOTFS_STAGE1/etc/passwd" ]; then
        adm_info "Criando /etc/passwd mínimo no rootfs stage1"
        cat >"$ADM_ROOTFS_STAGE1/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/bin:/sbin/nologin
daemon:x:2:2:daemon:/sbin:/sbin/nologin
nobody:x:65534:65534:nobody:/nonexistent:/sbin/nologin
EOF
    fi

    if [ ! -f "$ADM_ROOTFS_STAGE1/etc/group" ]; then
        adm_info "Criando /etc/group mínimo no rootfs stage1"
        cat >"$ADM_ROOTFS_STAGE1/etc/group" <<'EOF'
root:x:0:
bin:x:1:
daemon:x:2:
sys:x:3:
adm:x:4:
tty:x:5:
disk:x:6:
lp:x:7:
mail:x:8:
kmem:x:9:
wheel:x:10:
users:x:100:
nogroup:x:65534:
EOF
    fi

    # /dev mínimo
    adm_rootfs_prepare_dev
}

adm_rootfs_prepare_dev() {
    adm_stage "Stage rootfs - Preparar /dev básico"

    local devdir="$ADM_ROOTFS_STAGE1/dev"
    adm_ensure_dir "$devdir"

    # Se /dev já é mountpoint (por bind), não mexer com mknod direto
    if adm_rootfs_is_mounted "$devdir"; then
        adm_info "$devdir já está montado (provavelmente bind de /dev). Pulando criação de nós."
        return 0
    fi

    # Criar alguns nós básicos apenas se não existirem
    adm_rootfs_mknod_if_missing "$devdir/null"    c 1 3  666
    adm_rootfs_mknod_if_missing "$devdir/zero"    c 1 5  666
    adm_rootfs_mknod_if_missing "$devdir/full"    c 1 7  666
    adm_rootfs_mknod_if_missing "$devdir/random"  c 1 8  666
    adm_rootfs_mknod_if_missing "$devdir/urandom" c 1 9  666
    adm_rootfs_mknod_if_missing "$devdir/tty"     c 5 0  666
    adm_rootfs_mknod_if_missing "$devdir/console" c 5 1  600
}

adm_rootfs_mknod_if_missing() {
    local path="${1:-}"
    local type="${2:-}"
    local major="${3:-}"
    local minor="${4:-}"
    local mode="${5:-666}"

    if [ -z "$path" ] || [ -z "$type" ] || [ -z "$major" ] || [ -z "$minor" ]; then
        adm_die "adm_rootfs_mknod_if_missing chamado com parâmetros inválidos"
    fi

    if [ -e "$path" ]; then
        return 0
    fi

    if ! command -v mknod >/dev/null 2>&1; then
        adm_warn "mknod não está disponível; não foi possível criar $path"
        return 0
    fi

    adm_info "Criando nó de dispositivo: $path (type=$type major=$major minor=$minor mode=$mode)"
    if ! mknod "$path" "$type" "$major" "$minor" 2>/dev/null; then
        adm_warn "Falha ao criar $path com mknod (sem permissão? ambiente restrito?)"
        return 0
    fi

    chmod "$mode" "$path" 2>/dev/null || adm_warn "Falha ao ajustar permissão de $path para $mode"
}

# ----------------------------------------------------------------------
# Montagem e desmontagem de virtual FS no rootfs
# ----------------------------------------------------------------------

adm_rootfs_mount_virtual_fs() {
    adm_stage "Stage rootfs - Montar /dev /proc /sys /run no rootfs stage1"
    adm_rootfs_require_root

    local root="$ADM_ROOTFS_STAGE1"

    [ -d "$root" ] || adm_die "Rootfs stage1 não existe: $root (rode 'rootfs' primeiro)"

    adm_rootfs_mount_one bind /dev "$root/dev"
    adm_rootfs_mount_one bind /dev/pts "$root/dev/pts"
    adm_rootfs_mount_one tmpfs tmpfs "$root/dev/shm" -o "mode=1777"
    adm_rootfs_mount_one proc proc "$root/proc"
    adm_rootfs_mount_one sysfs sys "$root/sys"
    adm_rootfs_mount_one tmpfs tmpfs "$root/run"

    adm_info "Sistemas virtuais montados no rootfs stage1."
}

adm_rootfs_umount_virtual_fs() {
    adm_stage "Stage rootfs - Desmontar /dev /proc /sys /run do rootfs stage1"
    adm_rootfs_require_root

    local root="$ADM_ROOTFS_STAGE1"

    # Ordem inversa
    adm_rootfs_umount_one "$root/run"
    adm_rootfs_umount_one "$root/sys"
    adm_rootfs_umount_one "$root/proc"
    adm_rootfs_umount_one "$root/dev/shm"
    adm_rootfs_umount_one "$root/dev/pts"
    adm_rootfs_umount_one "$root/dev"

    adm_info "Sistemas virtuais desmontados do rootfs stage1."
}

# ----------------------------------------------------------------------
# Chroot helper
# ----------------------------------------------------------------------

ADM_ROOTFS_KEEP_MOUNTS="${ADM_ROOTFS_KEEP_MOUNTS:-0}"

adm_rootfs_chroot_exec() {
    # Executa um comando dentro do chroot (rootfs stage1), com ambiente limpo.
    #
    # Uso:
    #   adm_rootfs_chroot_exec "comando aqui"
    #
    local cmd="${1:-}"

    [ -z "$cmd" ] && adm_die "adm_rootfs_chroot_exec requer comando"

    adm_rootfs_require_root
    adm_rootfs_prepare_layout
    adm_rootfs_mount_virtual_fs

    adm_info "Entrando em chroot em $ADM_ROOTFS_STAGE1: $cmd"

    local rc=0
    if ! chroot "$ADM_ROOTFS_STAGE1" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM:-xterm}" \
        PS1='(adm-chroot) \u:\w\$ ' \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        /bin/bash -lc "$cmd"
    then
        rc=$?
        adm_error "Comando em chroot falhou (rc=$rc): $cmd"
    fi

    if [ "$ADM_ROOTFS_KEEP_MOUNTS" -ne 1 ]; then
        # Tenta desmontar; se falhar, já terá logado erro
        adm_rootfs_umount_virtual_fs
    else
        adm_info "Mantendo sistemas virtuais montados (ADM_ROOTFS_KEEP_MOUNTS=1)."
    fi

    return "$rc"
}

adm_rootfs_chroot_shell() {
    # Abre um shell interativo dentro do chroot.
    adm_rootfs_chroot_exec "/bin/bash"
}

# ----------------------------------------------------------------------
# Stage2 - temporary tools adicionais dentro do chroot
# ----------------------------------------------------------------------

# Lista de pacotes stage2 (nome simplificado: categoria nome)
adm_stage2_temp_tools_list() {
    cat <<EOF
sys gettext
sys bison
sys perl
sys python
sys texinfo
sys util-linux
EOF
}

adm_stage2_build_one_tool_in_chroot() {
    # Constrói uma ferramenta stage2 dentro do chroot usando o build-engine do ADM.
    #
    # Uso:
    #   adm_stage2_build_one_tool_in_chroot categoria nome
    #
    local category="${1:-}"
    local name="${2:-}"

    [ -z "$category" ] && adm_die "adm_stage2_build_one_tool_in_chroot requer categoria"
    [ -z "$name" ]     && adm_die "adm_stage2_build_one_tool_in_chroot requer nome"

    # Comando a ser executado dentro do chroot:
    # - Garante que scripts do ADM existem
    # - Faz source dos scripts principais
    # - Usa adm_build_pkg ou adm_build_engine_build
    #
    local inner_cmd='
set -euo pipefail
IFS=$'\''\n\t'\''
ADM_ROOT="/usr/src/adm"
ADM_SCRIPTS="$ADM_ROOT/scripts"

if [ ! -d "$ADM_SCRIPTS" ]; then
    echo "ERRO: Diretório de scripts do ADM não encontrado em chroot: $ADM_SCRIPTS" >&2
    exit 1
fi

# Prioridade: 00-env-profiles, 01-log-ui, 10-repo-metafile, 12-hooks-patches, 13-binary-cache, 31-build-engine
for s in \
  "00-env-profiles.sh" \
  "01-log-ui.sh" \
  "10-repo-metafile.sh" \
  "12-hooks-patches.sh" \
  "13-binary-cache.sh" \
  "31-build-engine.sh"
do
    if [ -f "$ADM_SCRIPTS/$s" ]; then
        # shellcheck disable=SC1090
        source "$ADM_SCRIPTS/$s"
    else
        echo "AVISO: Script $s não encontrado em $ADM_SCRIPTS (isso pode limitar recursos)." >&2
    fi
done

if declare -F adm_init_env >/dev/null 2>&1; then
    adm_init_env
fi

if declare -F adm_log_global_header >/dev/null 2>&1; then
    adm_log_global_header
fi

# categoria/nome vindos do ambiente
CATEGORY="${ADM_STAGE2_CATEGORY:-}"
NAME="${ADM_STAGE2_NAME:-}"

if [ -z "$CATEGORY" ] || [ -z "$NAME" ]; then
    echo "ERRO: Variáveis ADM_STAGE2_CATEGORY/ADM_STAGE2_NAME não definidas no chroot." >&2
    exit 1
fi

DESTDIR="/"
MODE="stage2"

echo "Construindo stage2: ${CATEGORY}/${NAME} (DESTDIR=${DESTDIR}, MODE=${MODE})" >&2

if declare -F adm_build_pkg >/dev/null 2>&1; then
    adm_build_pkg "$CATEGORY" "$NAME" "$MODE" "$DESTDIR"
elif declare -F adm_build_engine_build >/dev/null 2>&1; then
    adm_build_engine_build "$CATEGORY" "$NAME" "$MODE" "$DESTDIR"
else
    echo "ERRO: Nenhuma função de build encontrada (adm_build_pkg/adm_build_engine_build)." >&2
    exit 1
fi
'

    # Exporta categoria/nome para o ambiente do chroot
    ADM_STAGE2_CATEGORY="$category" \
    ADM_STAGE2_NAME="$name" \
    adm_rootfs_chroot_exec "$inner_cmd"
}

adm_stage2_build_temp_tools() {
    adm_stage "Stage2 - Temporary tools adicionais dentro do chroot"

    adm_rootfs_prepare_layout

    local line category name
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        category="${line%% *}"
        name="${line#* }"
        adm_info "Stage2: construindo $category/$name dentro do chroot."
        adm_run_with_spinner "Stage2: $category/$name" \
            adm_stage2_build_one_tool_in_chroot "$category" "$name"
    done < <(adm_stage2_temp_tools_list)

    adm_info "Temporary tools stage2 construídas dentro do chroot."
}

adm_stage2_build_all() {
    adm_stage "Stage2 - rootfs + temp tools (stage2)"
    adm_rootfs_prepare_layout
    adm_stage2_build_temp_tools
    adm_info "Stage2 completo."
}

# ----------------------------------------------------------------------
# CLI quando executado diretamente
# ----------------------------------------------------------------------

adm_rootfs_stage2_usage() {
    cat <<EOF
Uso: $(basename "$0") <comando>

Comandos:
  rootfs     - Preparar layout básico do rootfs stage1
  mount      - Montar /dev, /dev/pts, /proc, /sys, /run no rootfs stage1
  umount     - Desmontar /dev, /dev/pts, /proc, /sys, /run do rootfs stage1
  shell      - Entrar em shell interativo dentro do chroot do rootfs stage1
  stage2     - Construir temporary tools stage2 dentro do chroot
  all        - Preparar rootfs + construir temporary tools stage2
  help       - Mostrar esta ajuda

Exemplos:
  $(basename "$0") rootfs
  $(basename "$0") mount
  $(basename "$0") shell
  $(basename "$0") stage2
  $(basename "$0") all
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cmd="${1:-help}"
    case "$cmd" in
        rootfs)
            adm_rootfs_prepare_layout
            ;;
        mount)
            adm_rootfs_mount_virtual_fs
            ;;
        umount)
            adm_rootfs_umount_virtual_fs
            ;;
        shell)
            adm_rootfs_chroot_shell
            ;;
        stage2)
            adm_stage2_build_temp_tools
            ;;
        all)
            adm_stage2_build_all
            ;;
        help|-h|--help)
            adm_rootfs_stage2_usage
            ;;
        *)
            adm_error "Comando desconhecido: $cmd"
            adm_rootfs_stage2_usage
            exit 1
            ;;
    esac
fi
