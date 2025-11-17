#!/usr/bin/env bash

# runtime.sh – Utilidades de runtime do ADM
#
# Integração:
#   - ui.sh  → adm_ui_log_*, adm_ui_set_context, adm_ui_set_log_file
#   - db.sh  → adm_db_init, adm_db_read_meta, DB_META_*
#
# Funções principais (biblioteca):
#   adm_runtime_detect_init
#   adm_runtime_ldconfig
#   adm_runtime_enable_service <service>
#   adm_runtime_disable_service <service>
#   adm_runtime_start_service <service>
#   adm_runtime_stop_service <service>
#   adm_runtime_restart_service <service>
#   adm_runtime_apply_post_install <pkg>
#
# CLI:
#   adm runtime detect-init
#   adm runtime ldconfig
#   adm runtime enable-svc  <service>
#   adm runtime disable-svc <service>
#   adm runtime start-svc   <service>
#   adm runtime stop-svc    <service>
#   adm runtime restart-svc <service>
#   adm runtime apply-post-install <pkg>

ADM_ROOT="/usr/src/adm"
ADM_SCRIPTS="$ADM_ROOT/scripts"
ADM_RUNTIME_INIT=""     # systemd|runit|sysv|unknown
UI_OK=0

# -----------------------------
# Carregar módulos
# -----------------------------
load_runtime_module() {
    local f="$1"
    if [ -r "$ADM_SCRIPTS/$f" ]; then
        # shellcheck source=/usr/src/adm/scripts/$f
        . "$ADM_SCRIPTS/$f"
        return 0
    fi
    return 1
}

load_runtime_module "ui.sh" && UI_OK=1
load_runtime_module "db.sh"

# -----------------------------
# Logging
# -----------------------------
rt_log_info()  { [ "$UI_OK" -eq 1 ] && adm_ui_log_info  "$*" || printf '[INFO] %s\n'  "$*"; }
rt_log_warn()  { [ "$UI_OK" -eq 1 ] && adm_ui_log_warn  "$*" || printf '[WARN] %s\n'  "$*"; }
rt_log_error() { [ "$UI_OK" -eq 1 ] && adm_ui_log_error "$*" || printf '[ERROR] %s\n' "$*"; }

rt_die() {
    rt_log_error "$@"
    exit 1
}

rt_timestamp() {
    date +"%Y%m%d-%H%M%S"
}

# -----------------------------
# Detecção do init system
# -----------------------------
adm_runtime_detect_init() {
    # Se já foi detectado, retorna
    if [ -n "$ADM_RUNTIME_INIT" ]; then
        printf '%s\n' "$ADM_RUNTIME_INIT"
        return 0
    fi

    # systemd: PID 1 = systemd ou /run/systemd/system
    if [ -d /run/systemd/system ] || ps -p 1 -o comm= 2>/dev/null | grep -qi systemd; then
        ADM_RUNTIME_INIT="systemd"
    elif command -v sv >/dev/null 2>&1 || [ -d /etc/runit ] || [ -d /etc/sv ]; then
        ADM_RUNTIME_INIT="runit"
    elif [ -x /sbin/openrc ] || [ -d /etc/init.d ]; then
        ADM_RUNTIME_INIT="sysv"
    else
        ADM_RUNTIME_INIT="unknown"
    fi

    rt_log_info "Init system detectado: $ADM_RUNTIME_INIT"
    printf '%s\n' "$ADM_RUNTIME_INIT"
    return 0
}

# -----------------------------
# ldconfig seguro
# -----------------------------
adm_runtime_ldconfig() {
    # não falhar se ldconfig não existir
    if ! command -v ldconfig >/dev/null 2>&1; then
        rt_log_warn "ldconfig não encontrado; ignorando"
        return 0
    fi

    # precisa ser root
    if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
        rt_log_warn "ldconfig requer root; ignorando"
        return 0
    fi

    rt_log_info "Executando ldconfig..."
    if ! ldconfig 2>/dev/null; then
        rt_log_error "ldconfig retornou erro"
        return 1
    fi

    rt_log_info "ldconfig concluído com sucesso"
    return 0
}

# -----------------------------
# Helpers: execução de comandos
# -----------------------------
_rt_run_cmd() {
    # Execução de comando com log, sem esconder falha
    # Uso: _rt_run_cmd "descrição" comando args...
    local desc="$1"; shift
    rt_log_info "$desc"
    if ! "$@"; then
        rt_log_error "Falha: $desc (cmd: $*)"
        return 1
    fi
    return 0
}

# -----------------------------
# Ações para systemd
# -----------------------------
_rt_systemd_enable()  { _rt_run_cmd "systemd: habilitando serviço $1"  systemctl enable  "$1"; }
_rt_systemd_disable() { _rt_run_cmd "systemd: desabilitando serviço $1" systemctl disable "$1"; }
_rt_systemd_start()   { _rt_run_cmd "systemd: iniciando serviço $1"     systemctl start   "$1"; }
_rt_systemd_stop()    { _rt_run_cmd "systemd: parando serviço $1"       systemctl stop    "$1"; }
_rt_systemd_restart() { _rt_run_cmd "systemd: reiniciando serviço $1"   systemctl restart "$1"; }

# -----------------------------
# Ações para runit
# -----------------------------
_rt_runit_enable() {
    # Habilitar = link em /etc/service
    local svc="$1"
    local svdir="/etc/sv/$svc"
    local sdir="/etc/service/$svc"

    [ -d "$svdir" ] || { rt_log_error "runit: diretório de serviço não existe: $svdir"; return 1; }

    if [ ! -d /etc/service ]; then
        rt_log_warn "runit: /etc/service não existe; criando"
        mkdir -p /etc/service 2>/dev/null || {
            rt_log_error "runit: não foi possível criar /etc/service"
            return 1
        }
    fi

    if [ ! -e "$sdir" ]; then
        _rt_run_cmd "runit: habilitando serviço $svc" ln -s "$svdir" "$sdir" || return 1
    fi
    return 0
}

_rt_runit_disable() {
    local svc="$1"
    local sdir="/etc/service/$svc"
    if [ -e "$sdir" ]; then
        _rt_run_cmd "runit: desabilitando serviço $svc" rm -f "$sdir" || return 1
    fi
    return 0
}

_rt_runit_start()   { _rt_run_cmd "runit: iniciando serviço $1"  sv up   "$1"; }
_rt_runit_stop()    { _rt_run_cmd "runit: parando serviço $1"    sv down "$1"; }
_rt_runit_restart() { _rt_run_cmd "runit: reiniciando serviço $1" sv restart "$1"; }

# -----------------------------
# Ações para sysv/openrc
# -----------------------------
_rt_sysv_enable() {
    local svc="$1"
    if command -v rc-update >/dev/null 2>&1; then
        _rt_run_cmd "sysv/openrc: adicionando serviço $svc ao default" rc-update add "$svc" default
    elif command -v update-rc.d >/dev/null 2>&1; then
        _rt_run_cmd "sysv: habilitando serviço $svc" update-rc.d "$svc" defaults
    elif command -v chkconfig >/dev/null 2>&1; then
        _rt_run_cmd "sysv: habilitando serviço $svc" chkconfig "$svc" on
    else
        rt_log_warn "sysv: nenhuma ferramenta de enable encontrada (rc-update/update-rc.d/chkconfig)"
        return 1
    fi
}

_rt_sysv_disable() {
    local svc="$1"
    if command -v rc-update >/dev/null 2>&1; then
        _rt_run_cmd "sysv/openrc: removendo serviço $svc do default" rc-update del "$svc" default
    elif command -v update-rc.d >/dev/null 2>&1; then
        _rt_run_cmd "sysv: desabilitando serviço $svc" update-rc.d -f "$svc" remove
    elif command -v chkconfig >/dev/null 2>&1; then
        _rt_run_cmd "sysv: desabilitando serviço $svc" chkconfig "$svc" off
    else
        rt_log_warn "sysv: nenhuma ferramenta de disable encontrada"
        return 1
    fi
}

_rt_sysv_start() {
    local svc="$1"
    if command -v rc-service >/dev/null 2>&1; then
        _rt_run_cmd "sysv/openrc: iniciando serviço $svc" rc-service "$svc" start
    elif [ -x "/etc/init.d/$svc" ]; then
        _rt_run_cmd "sysv: iniciando serviço $svc" "/etc/init.d/$svc" start
    else
        rt_log_error "sysv: script de serviço não encontrado para $svc"
        return 1
    fi
}

_rt_sysv_stop() {
    local svc="$1"
    if command -v rc-service >/dev/null 2>&1; then
        _rt_run_cmd "sysv/openrc: parando serviço $svc" rc-service "$svc" stop
    elif [ -x "/etc/init.d/$svc" ]; then
        _rt_run_cmd "sysv: parando serviço $svc" "/etc/init.d/$svc" stop
    else
        rt_log_error "sysv: script de serviço não encontrado para $svc"
        return 1
    fi
}

_rt_sysv_restart() {
    local svc="$1"
    if command -v rc-service >/dev/null 2>&1; then
        _rt_run_cmd "sysv/openrc: reiniciando serviço $svc" rc-service "$svc" restart
    elif [ -x "/etc/init.d/$svc" ]; then
        _rt_run_cmd "sysv: reiniciando serviço $svc" "/etc/init.d/$svc" restart
    else
        rt_log_error "sysv: script de serviço não encontrado para $svc"
        return 1
    fi
}
# -----------------------------
# Wrappers de alto nível (enable/disable/start/stop/restart)
# -----------------------------
adm_runtime_enable_service() {
    local svc="$1"
    [ -z "$svc" ] && { rt_log_error "adm_runtime_enable_service: nome de serviço vazio"; return 1; }

    local init
    init="$(adm_runtime_detect_init)"

    case "$init" in
        systemd) _rt_systemd_enable "$svc" ;;
        runit)   _rt_runit_enable   "$svc" ;;
        sysv)    _rt_sysv_enable    "$svc" ;;
        *)
            rt_log_warn "Init desconhecido ($init); não é possível habilitar serviço $svc"
            return 1
            ;;
    esac
}

adm_runtime_disable_service() {
    local svc="$1"
    [ -z "$svc" ] && { rt_log_error "adm_runtime_disable_service: nome de serviço vazio"; return 1; }

    local init
    init="$(adm_runtime_detect_init)"

    case "$init" in
        systemd) _rt_systemd_disable "$svc" ;;
        runit)   _rt_runit_disable   "$svc" ;;
        sysv)    _rt_sysv_disable    "$svc" ;;
        *)
            rt_log_warn "Init desconhecido ($init); não é possível desabilitar serviço $svc"
            return 1
            ;;
    esac
}

adm_runtime_start_service() {
    local svc="$1"
    [ -z "$svc" ] && { rt_log_error "adm_runtime_start_service: nome de serviço vazio"; return 1; }

    local init
    init="$(adm_runtime_detect_init)"

    case "$init" in
        systemd) _rt_systemd_start "$svc" ;;
        runit)   _rt_runit_start   "$svc" ;;
        sysv)    _rt_sysv_start    "$svc" ;;
        *)
            rt_log_warn "Init desconhecido ($init); não é possível iniciar serviço $svc"
            return 1
            ;;
    esac
}

adm_runtime_stop_service() {
    local svc="$1"
    [ -z "$svc" ] && { rt_log_error "adm_runtime_stop_service: nome de serviço vazio"; return 1; }

    local init
    init="$(adm_runtime_detect_init)"

    case "$init" in
        systemd) _rt_systemd_stop "$svc" ;;
        runit)   _rt_runit_stop   "$svc" ;;
        sysv)    _rt_sysv_stop    "$svc" ;;
        *)
            rt_log_warn "Init desconhecido ($init); não é possível parar serviço $svc"
            return 1
            ;;
    esac
}

adm_runtime_restart_service() {
    local svc="$1"
    [ -z "$svc" ] && { rt_log_error "adm_runtime_restart_service: nome de serviço vazio"; return 1; }

    local init
    init="$(adm_runtime_detect_init)"

    case "$init" in
        systemd) _rt_systemd_restart "$svc" ;;
        runit)   _rt_runit_restart   "$svc" ;;
        sysv)    _rt_sysv_restart    "$svc" ;;
        *)
            rt_log_warn "Init desconhecido ($init); não é possível reiniciar serviço $svc"
            return 1
            ;;
    esac
}

# -----------------------------
# Integração com DB para pós-instalação
# -----------------------------
adm_runtime_apply_post_install() {
    local pkg="$1"
    [ -z "$pkg" ] && { rt_log_error "adm_runtime_apply_post_install: pacote vazio"; return 1; }

    if [ "$UI_OK" -eq 1 ]; then
        adm_ui_set_context "runtime" "$pkg"
        adm_ui_set_log_file "runtime" "$pkg" || true
    fi

    if ! declare -F adm_db_init >/dev/null 2>&1 || ! declare -F adm_db_read_meta >/dev/null 2>&1; then
        rt_log_warn "db.sh não suporta adm_db_init/adm_db_read_meta; ignorando integração de runtime para $pkg"
        return 0
    fi

    adm_db_init || { rt_log_error "Falha em adm_db_init"; return 1; }

    if ! adm_db_read_meta "$pkg"; then
        rt_log_error "Pacote $pkg não encontrado no DB; não aplicando runtime"
        return 1
    fi

    # DB_META_INIT pode ser 'systemd', 'runit', 'sysv', ou vazio
    local init="${DB_META_INIT:-}"
    local svc="$pkg"   # convenção: nome do serviço = nome do pacote; se não for, hooks do pacote podem customizar

    if [ -n "$init" ] && [ "$init" != "none" ]; then
        # Forçar init para aderir ao metadata, mas ainda revalida ambiente para segurança
        ADM_RUNTIME_INIT="$init"
        rt_log_info "Aplicando runtime de serviço para $pkg (init=$ADM_RUNTIME_INIT, svc=$svc)"

        # Habilita e reinicia o serviço, se existir
        adm_runtime_enable_service "$svc"  || rt_log_warn "Não foi possível habilitar serviço $svc"
        adm_runtime_restart_service "$svc" || rt_log_warn "Não foi possível reiniciar serviço $svc"
    else
        rt_log_info "Pacote $pkg não declara init no DB; nenhum serviço será manipulado"
    fi

    # Atualizar cache de bibliotecas
    adm_runtime_ldconfig

    rt_log_info "Runtime pós-instalação aplicado para $pkg"
    return 0
}

# -----------------------------
# CLI
# -----------------------------
rt_print_help() {
    cat <<EOF
Uso:
  adm runtime detect-init
  adm runtime ldconfig
  adm runtime enable-svc  <servico>
  adm runtime disable-svc <servico>
  adm runtime start-svc   <servico>
  adm runtime stop-svc    <servico>
  adm runtime restart-svc <servico>
  adm runtime apply-post-install <pacote>

EOF
}

# Quando chamado diretamente como script: runtime.sh <subcomando> ...
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    CMD="$1"
    shift || true

    case "$CMD" in
        detect-init)
            adm_runtime_detect_init
            ;;
        ldconfig)
            adm_runtime_ldconfig || exit 1
            ;;
        enable-svc)
            [ -z "$1" ] && rt_print_help && exit 1
            adm_runtime_enable_service "$1" || exit 1
            ;;
        disable-svc)
            [ -z "$1" ] && rt_print_help && exit 1
            adm_runtime_disable_service "$1" || exit 1
            ;;
        start-svc)
            [ -z "$1" ] && rt_print_help && exit 1
            adm_runtime_start_service "$1" || exit 1
            ;;
        stop-svc)
            [ -z "$1" ] && rt_print_help && exit 1
            adm_runtime_stop_service "$1" || exit 1
            ;;
        restart-svc)
            [ -z "$1" ] && rt_print_help && exit 1
            adm_runtime_restart_service "$1" || exit 1
            ;;
        apply-post-install)
            [ -z "$1" ] && rt_print_help && exit 1
            adm_runtime_apply_post_install "$1" || exit 1
            ;;
        *)
            rt_print_help
            exit 1
            ;;
    esac
fi
