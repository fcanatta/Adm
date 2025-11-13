#!/usr/bin/env bash
# lib/adm/chroot.sh
#
# Subsistema de CHROOT do ADM
#
# Objetivos:
#   - Entrar e sair de um chroot de forma SEGURA e LIMPA
#   - Minimizar contaminação do host (bind-mounts controlados)
#   - Garantir desmontagens mesmo em caso de erro parcial
#   - Zero erros silenciosos: tudo que der errado é logado claramente
#
# Funções principais:
#   adm_chroot_enter ROOT [CMD...]
#       → monta proc/sys/dev/run/tmp etc, entra no chroot
#         se CMD for vazio, abre /bin/bash (ou /bin/sh)
#
#   adm_chroot_exec ROOT CMD...
#       → igual ao enter, mas sempre com comando (não interativo)
#
#   adm_chroot_mount_base ROOT
#       → apenas monta tudo, sem entrar
#
#   adm_chroot_umount_base ROOT
#       → desmonta em ordem inversa, com checagens
#
# Convenções:
#   - ROOT é o diretório que representa / dentro do chroot (ex: /usr/src/adm/rootfs/stage2)
#   - Requer root (id -u == 0).
###############################################################################
# Proteção contra múltiplos loads
###############################################################################
if [ -n "${ADM_CHROOT_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
ADM_CHROOT_LOADED=1
###############################################################################
# Dependências: log + core
###############################################################################
if ! command -v adm_log_chroot >/dev/null 2>&1; then
    # Fallback mínimo se log.sh ainda não foi carregado
    adm_log()         { printf '%s\n' "$*" >&2; }
    adm_log_chroot()  { adm_log "[CHROOT] $*"; }
    adm_log_info()    { adm_log "[INFO]   $*"; }
    adm_log_warn()    { adm_log "[WARN]   $*"; }
    adm_log_error()   { adm_log "[ERROR]  $*"; }
    adm_log_debug()   { :; }
fi

if command -v adm_core_init_paths >/dev/null 2>&1; then
    adm_core_init_paths
fi

# Fallback para adm_require_root, se core.sh não foi carregado
if ! command -v adm_require_root >/dev/null 2>&1; then
    adm_require_root() {
        if [ "$(id -u 2>/dev/null)" != "0" ]; then
            adm_log_error "Este comando requer privilégios de root."
            return 1
        fi
        return 0
    }
fi

###############################################################################
# Helpers internos
###############################################################################

# Normaliza ROOT para caminho absoluto e validações básicas
adm_chroot__normalize_root() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_chroot__normalize_root requer 1 argumento: ROOT"
        return 1
    fi
    local root="$1"

    if [ -z "$root" ]; then
        adm_log_error "adm_chroot: ROOT não pode ser vazio."
        return 1
    fi

    # Se não for absoluto, tenta converter com pwd
    case "$root" in
        /*) : ;;
        *)
            root="$(cd "$root" 2>/dev/null && pwd)" || {
                adm_log_error "adm_chroot: não foi possível resolver ROOT: %s" "$root"
                return 1
            }
            ;;
    esac

    # Proíbe usar / como root de chroot (mitigação de desastre)
    if [ "$root" = "/" ]; then
        adm_log_error "adm_chroot: ROOT não pode ser '/'."
        return 1
    fi

    if [ ! -d "$root" ]; then
        adm_log_error "adm_chroot: diretório ROOT não existe: %s" "$root"
        return 1
    fi

    printf '%s\n' "$root"
    return 0
}

# Verifica se algo está montado em um target específico
adm_chroot__is_mounted() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_chroot__is_mounted requer 1 argumento: PATH"
        return 1
    fi
    local target="$1"

    # evita falsos positivos (espacos)
    awk -v tgt="$target" '$2 == tgt {found=1} END{exit !found}' /proc/self/mounts 2>/dev/null
}

# Faz um mount se ainda não estiver montado
adm_chroot__mount_once() {
    # args: SOURCE TARGET FSTYPE OPTIONS
    if [ $# -ne 4 ]; then
        adm_log_error "adm_chroot__mount_once requer 4 argumentos: SRC TARGET FSTYPE OPTS"
        return 1
    fi
    local src="$1" tgt="$2" fstype="$3" opts="$4"

    if adm_chroot__is_mounted "$tgt"; then
        adm_log_debug "Ponto já montado, pulando: %s" "$tgt"
        return 0
    fi

    # Garante diretório de destino
    if ! mkdir -p "$tgt" 2>/dev/null; then
        adm_log_error "Falha ao criar diretório de mount: %s" "$tgt"
        return 1
    fi

    local cmd=(mount)
    [ -n "$fstype" ] && cmd+=("-t" "$fstype")
    [ -n "$opts" ]   && cmd+=("-o" "$opts")
    cmd+=("$src" "$tgt")

    adm_log_chroot "Montando: %s" "${cmd[*]}"

    if ! "${cmd[@]}" >/dev/null 2>&1; then
        adm_log_error "Falha ao montar %s em %s" "$src" "$tgt"
        return 1
    fi

    return 0
}

# Desmonta se estiver montado, com retries
adm_chroot__umount_if_mounted() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_chroot__umount_if_mounted requer 1 argumento: TARGET"
        return 1
    fi
    local tgt="$1"

    if ! adm_chroot__is_mounted "$tgt"; then
        adm_log_debug "Ponto não montado, pulando umount: %s" "$tgt"
        return 0
    fi

    local tries=3
    local i
    for i in $(seq 1 "$tries"); do
        if umount "$tgt" >/dev/null 2>&1; then
            adm_log_chroot "Desmontado: %s" "$tgt"
            return 0
        fi
        adm_log_warn "Falha ao desmontar %s (tentativa %d/%d)" "$tgt" "$i" "$tries"
        sleep 1
    done

    adm_log_error "Não foi possível desmontar %s após %d tentativas." "$tgt" "$tries"
    return 1
}

# Copia resolv.conf (opcional, para DNS dentro do chroot)
adm_chroot__setup_resolv_conf() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_chroot__setup_resolv_conf requer 1 argumento: ROOT"
        return 1
    fi
    local root="$1"

    local host_resolv="/etc/resolv.conf"
    local chroot_resolv="$root/etc/resolv.conf"

    [ -f "$host_resolv" ] || {
        adm_log_warn "Host /etc/resolv.conf não encontrado; DNS no chroot pode falhar."
        return 0
    }

    if ! mkdir -p "$root/etc" 2>/dev/null; then
        adm_log_error "Falha ao criar %s para resolv.conf" "$root/etc"
        return 1
    fi

    # Preferimos bind em vez de cópia; se falhar, copiamos.
    if ! adm_chroot__is_mounted "$chroot_resolv"; then
        if mount --bind "$host_resolv" "$chroot_resolv" >/dev/null 2>&1; then
            adm_log_chroot "Bind de resolv.conf host → chroot: %s" "$chroot_resolv"
            return 0
        else
            # tenta fallback copia simples
            if cp -f "$host_resolv" "$chroot_resolv" 2>/dev/null; then
                adm_log_chroot "Copiado resolv.conf host → chroot: %s" "$chroot_resolv"
                return 0
            fi
            adm_log_warn "Falha ao montar/copy resolv.conf para chroot."
        fi
    fi

    return 0
}

###############################################################################
# Montagem base dentro do chroot
###############################################################################

# Mapeamento de pontos de mount que vamos usar (em ordem de montagem)
# Ordem: dev, dev/pts, proc, sys, run, tmp
#
# DEV:     /dev         → rbind do host, mas isolado com rslave quando possível
# DEVPTS:  /dev/pts     → devpts
# PROC:    /proc        → proc
# SYS:     /sys         → sysfs
# RUN:     /run         → tmpfs (opcional) ou bind do host, aqui preferimos bind
# TMP:     /tmp         → tmpfs (isolado)

adm_chroot_mount_base() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_chroot_mount_base requer 1 argumento: ROOT"
        return 1
    fi

    local root
    root="$(adm_chroot__normalize_root "$1")" || return 1

    if ! adm_require_root; then
        return 1
    fi

    adm_log_chroot "Montando ambiente base para chroot em: %s" "$root"

    # /dev – bind e isolação (quando suportado)
    if ! adm_chroot__is_mounted "$root/dev"; then
        if ! mkdir -p "$root/dev" 2>/dev/null; then
            adm_log_error "Falha ao criar %s" "$root/dev"
            return 1
        fi
        adm_log_chroot "Bind-mount /dev → %s/dev" "$root"
        if ! mount --rbind /dev "$root/dev" >/dev/null 2>&1; then
            adm_log_error "Falha ao bind-mount /dev em %s/dev" "$root"
            return 1
        fi
        # Tenta marcar como rslave para não propagar mount de volta
        mount --make-rslave "$root/dev" >/dev/null 2>&1 || adm_log_debug "Não foi possível 'make-rslave' em %s/dev (não crítico)." "$root"
    else
        adm_log_debug "%s/dev já montado." "$root"
    fi

    # /dev/pts
    adm_chroot__mount_once devpts "$root/dev/pts" devpts "gid=5,mode=620" || return 1

    # /proc
    adm_chroot__mount_once proc "$root/proc" proc "nosuid,noexec,nodev" || return 1

    # /sys
    adm_chroot__mount_once sys "$root/sys" sysfs "nosuid,noexec,nodev,ro" || return 1

    # /run – preferimos bind read-only, mas muitos programas escreverão em /run.
    # Aqui usamos bind normal; se quiser mais isolamento, trocar por tmpfs.
    if ! adm_chroot__is_mounted "$root/run"; then
        if [ -d /run ]; then
            mkdir -p "$root/run" 2>/dev/null || {
                adm_log_error "Falha ao criar %s" "$root/run"
                return 1
            }
            if ! mount --bind /run "$root/run" >/dev/null 2>&1; then
                adm_log_warn "Falha ao bind-mount /run em %s/run; tentando tmpfs." "$root"
                # fallback: tmpfs
                adm_chroot__mount_once tmpfs "$root/run" tmpfs "mode=0755,nosuid,nodev" || return 1
            fi
        else
            adm_log_warn "/run não existe no host; montando tmpfs em %s/run" "$root"
            adm_chroot__mount_once tmpfs "$root/run" tmpfs "mode=0755,nosuid,nodev" || return 1
        fi
    fi

    # /tmp – sempre tmpfs para isolamento
    adm_chroot__mount_once tmpfs "$root/tmp" tmpfs "mode=1777,nosuid,nodev" || return 1

    # resolv.conf (opcional, mas muito útil)
    adm_chroot__setup_resolv_conf "$root" || adm_log_warn "Problema ao configurar resolv.conf no chroot (prosseguindo)."

    adm_log_chroot "Montagens base do chroot concluídas para: %s" "$root"
    return 0
}

###############################################################################
# Desmontagem base
###############################################################################

adm_chroot_umount_base() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_chroot_umount_base requer 1 argumento: ROOT"
        return 1
    fi

    local root
    root="$(adm_chroot__normalize_root "$1")" || return 1

    if ! adm_require_root; then
        return 1
    fi

    adm_log_chroot "Desmontando ambiente base do chroot em: %s" "$root"

    local rc=0

    # Ordem reversa da montagem
    adm_chroot__umount_if_mounted "$root/tmp"  || rc=1
    adm_chroot__umount_if_mounted "$root/run"  || rc=1
    adm_chroot__umount_if_mounted "$root/sys"  || rc=1
    adm_chroot__umount_if_mounted "$root/proc" || rc=1
    adm_chroot__umount_if_mounted "$root/dev/pts" || rc=1
    adm_chroot__umount_if_mounted "$root/dev" || rc=1

    # Se resolv.conf for bind-mount, tenta desmontar também
    adm_chroot__umount_if_mounted "$root/etc/resolv.conf" || :

    if [ $rc -ne 0 ]; then
        adm_log_error "Uma ou mais desmontagens falharam para ROOT=%s. Verifique manualmente." "$root"
        return 1
    fi

    adm_log_chroot "Desmontagem base concluída para: %s" "$root"
    return 0
}

###############################################################################
# Execução de chroot
###############################################################################

# Prepara ambiente (PATH etc.) dentro do chroot
adm_chroot__env_setup() {
    # Não recebe argumentos; executado já dentro do chroot via 'env -i'
    # Mantemos PATH razoável.
    export PATH="/usr/bin:/usr/sbin:/bin:/sbin"
    # Mais ajustes poderiam ser feitos aqui (locale mínima, etc).
}

# Entra no chroot, montagem automática + shell/comando
#
# Uso:
#   adm_chroot_enter ROOT
#       → entra com /bin/bash ou /bin/sh
#
#   adm_chroot_enter ROOT CMD ARGS...
#       → executa CMD dentro do chroot
adm_chroot_enter() {
    if [ $# -lt 1 ]; then
        adm_log_error "adm_chroot_enter requer pelo menos 1 argumento: ROOT [CMD...]"
        return 1
    fi

    local root="$1"; shift

    root="$(adm_chroot__normalize_root "$root")" || return 1

    if ! adm_require_root; then
        return 1
    fi

    # Monta base
    if ! adm_chroot_mount_base "$root"; then
        adm_log_error "Falha ao montar base do chroot; abortando entrada."
        return 1
    fi

    # Define comando padrão
    local cmd
    if [ $# -eq 0 ]; then
        if [ -x "$root/bin/bash" ]; then
            cmd="/bin/bash"
        elif [ -x "$root/bin/sh" ]; then
            cmd="/bin/sh"
        else
            adm_log_error "Nenhum shell padrão encontrado em %s (esperado /bin/bash ou /bin/sh)." "$root"
            adm_chroot_umount_base "$root" || adm_log_warn "Falha ao limpar chroot após erro de shell."
            return 1
        fi
    else
        cmd="$1"; shift
    fi

    adm_log_chroot "Entrando no chroot: ROOT=%s CMD=%s" "$root" "$cmd"

    # Usamos env -i para limpar ambiente e chamar função de setup
    # Atenção: se /usr/bin/env não existir no chroot, isso pode falhar.
    # Como mitigação, usamos env do host mas chroot antes de executar cmd.
    local rc=0

    if [ $# -gt 0 ]; then
        # Com argumento(s) extras
        chroot "$root" /usr/bin/env -i PATH="/usr/bin:/usr/sbin:/bin:/sbin" "$cmd" "$@" || rc=$?
    else
        # Sem args extras
        chroot "$root" /usr/bin/env -i PATH="/usr/bin:/usr/sbin:/bin:/sbin" "$cmd" || rc=$?
    fi

    if [ $rc -ne 0 ]; then
        adm_log_warn "Chroot retornou código de saída %d." "$rc"
    fi

    # Tenta desmontar sempre após sair
    if ! adm_chroot_umount_base "$root"; then
        adm_log_error "Falha ao desmontar ambiente do chroot após saída (ROOT=%s)." "$root"
        # ainda retornamos rc do chroot; mas já logamos o problema
    fi

    return $rc
}

# Execução não interativa: exige CMD
#
# Uso:
#   adm_chroot_exec ROOT CMD ARGS...
adm_chroot_exec() {
    if [ $# -lt 2 ]; then
        adm_log_error "adm_chroot_exec requer pelo menos 2 argumentos: ROOT CMD [ARGS...]"
        return 1
    fi
    local root="$1"; shift

    adm_chroot_enter "$root" "$@"
}

###############################################################################
# Inicialização
###############################################################################

adm_chroot_init() {
    adm_log_debug "Subsistema de chroot carregado."
}

adm_chroot_init
