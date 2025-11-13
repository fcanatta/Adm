#!/usr/bin/env bash
# lib/adm/cleanup.sh
#
# Subsistema de LIMPEZA do ADM
#
# Responsabilidades:
#   - Limpar cache de fontes (sources)
#   - Limpar cache de build
#   - Limpar destdirs antigos
#   - Limpar logs antigos
#   - Limpar arquivos temporários do ADM
#   - Limpar manifests e estados de pacotes removidos
#   - Limpar possíveis mounts de chroot “esquecidos”
#   - Fazer “dry-run” seguro, sem deletar nada se configurado
#
# Nada de erros silenciosos: qualquer falha relevante é logada claramente.
#
# Variáveis de controle:
#   ADM_CLEANUP_DRYRUN=1   → só mostra o que faria, não remove nada
#   ADM_CLEANUP_AGE_DAYS_SOURCES (padrão: 30)
#   ADM_CLEANUP_AGE_DAYS_BUILD   (padrão: 30)
#   ADM_CLEANUP_AGE_DAYS_LOGS    (padrão: 30)
#
# Funções principais:
#   adm_cleanup_sources_cache     – limpa cache de fontes
#   adm_cleanup_build_cache       – limpa cache de build
#   adm_cleanup_destdirs          – remove destdirs antigos
#   adm_cleanup_logs              – apaga logs antigos
#   adm_cleanup_tmp               – remove tmp do ADM
#   adm_cleanup_state_removed     – limpa manifests/estado de pacotes removidos
#   adm_cleanup_chroot_mounts     – tenta desmontar mounts de chroot “pendurados”
#   adm_cleanup_all               – orquestra todas as limpezas
###############################################################################
# Proteção contra múltiplos loads
###############################################################################
if [ -n "${ADM_CLEANUP_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
ADM_CLEANUP_LOADED=1
###############################################################################
# Dependências: log + core + pkg + deps + chroot (opcional)
###############################################################################
# -------- LOG ---------------------------------------------------------
if ! command -v adm_log_cleanup >/dev/null 2>&1; then
    # Fallback mínimo se log.sh ainda não foi carregado
    adm_log()          { printf '%s\n' "$*" >&2; }
    adm_log_info()     { adm_log "[INFO]    $*"; }
    adm_log_warn()     { adm_log "[WARN]    $*"; }
    adm_log_error()    { adm_log "[ERROR]   $*"; }
    adm_log_debug()    { :; }
    adm_log_cleanup()  { adm_log "[CLEANUP] $*"; }
fi

# -------- CORE (paths, helpers) --------------------------------------
if command -v adm_core_init_paths >/dev/null 2>&1; then
    adm_core_init_paths
fi

if ! command -v adm_require_root >/dev/null 2>&1; then
    adm_require_root() {
        if [ "$(id -u 2>/dev/null)" != "0" ]; then
            adm_log_error "Este comando requer privilégios de root."
            return 1
        fi
        return 0
    }
fi

if ! command -v adm_mkdir_p >/dev/null 2>&1; then
    adm_mkdir_p() {
        if [ $# -ne 1 ]; then
            adm_log_error "adm_mkdir_p requer 1 argumento: DIRETÓRIO"
            return 1
        fi
        mkdir -p -- "$1" 2>/dev/null || {
            adm_log_error "Falha ao criar diretório: %s" "$1"
            return 1
        }
    }
fi

if ! command -v adm_rm_rf_safe >/dev/null 2>&1; then
    adm_rm_rf_safe() {
        if [ $# -ne 1 ]; then
            adm_log_error "adm_rm_rf_safe requer 1 argumento: CAMINHO"
            return 1
        fi
        rm -rf -- "$1" 2>/dev/null || {
            adm_log_warn "Falha ao remover recursivamente: %s" "$1"
            return 1
        }
    }
fi

if ! command -v adm_tmpdir_create >/dev/null 2>&1; then
    adm_tmpdir_create() {
        if [ $# -ne 1 ]; then
            adm_log_error "adm_tmpdir_create requer 1 argumento: PREFIXO"
            return 1
        fi
        local prefix="$1"
        local d
        d="$(mktemp -d -t "${prefix}.XXXXXX" 2>/dev/null || echo '')"
        if [ -z "$d" ]; then
            adm_log_error "Falha ao criar diretório temporário (prefixo=%s)." "$prefix"
            return 1
        fi
        printf '%s\n' "$d"
        return 0
    }
fi

# -------- PKG / DEPS (para limpar estado de pacotes) -----------------
if ! command -v adm_pkg_db_read_all >/dev/null 2>&1; then
    adm_pkg_db_read_all() { :; }
fi
if ! command -v adm_pkg_db_init >/dev/null 2>&1; then
    adm_pkg_db_init() { :; }
fi

# -------- CHROOT (opcional) ------------------------------------------
if ! command -v adm_chroot_umount_base >/dev/null 2>&1; then
    adm_chroot_umount_base() { :; }
fi

# -------- PATHS GLOBAIS ----------------------------------------------
: "${ADM_ROOT:=${ADM_ROOT:-/usr/src/adm}}"
: "${ADM_SOURCE_CACHE_DIR:=${ADM_SOURCE_CACHE_DIR:-$ADM_ROOT/cache/sources}}"
: "${ADM_BUILD_CACHE_DIR:=${ADM_BUILD_CACHE_DIR:-$ADM_ROOT/cache/build}}"
: "${ADM_DESTDIR_DIR:=${ADM_DESTDIR_DIR:-$ADM_ROOT/destdir}}"
: "${ADM_LOG_DIR:=${ADM_LOG_DIR:-$ADM_ROOT/logs}}"
: "${ADM_STATE_DIR:=${ADM_STATE_DIR:-$ADM_ROOT/state}}"
: "${ADM_TMP_DIR:=${ADM_TMP_DIR:-$ADM_ROOT/tmp}}"
: "${ADM_DEPS_DB_PATH:=${ADM_DEPS_DB_PATH:-$ADM_STATE_DIR/packages.db}}"
: "${ADM_MANIFEST_DIR:=${ADM_MANIFEST_DIR:-$ADM_STATE_DIR/manifests}}"

adm_mkdir_p "$ADM_STATE_DIR"      || adm_log_error "Falha ao criar ADM_STATE_DIR: %s" "$ADM_STATE_DIR"
adm_mkdir_p "$ADM_MANIFEST_DIR"   || adm_log_error "Falha ao criar ADM_MANIFEST_DIR: %s" "$ADM_MANIFEST_DIR"
adm_mkdir_p "$ADM_TMP_DIR"        || adm_log_error "Falha ao criar ADM_TMP_DIR: %s" "$ADM_TMP_DIR"

###############################################################################
# Variáveis de configuração de limpeza
###############################################################################

: "${ADM_CLEANUP_DRYRUN:=0}"           # 1 = não apaga nada, só mostra
: "${ADM_CLEANUP_AGE_DAYS_SOURCES:=30}"
: "${ADM_CLEANUP_AGE_DAYS_BUILD:=30}"
: "${ADM_CLEANUP_AGE_DAYS_LOGS:=30}"

###############################################################################
# Helpers internos
###############################################################################

adm_cleanup__trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

adm_cleanup__is_dir_safe() {
    # Usa heurística simples para evitar apagar "/" ou "/" muito curtos
    if [ $# -ne 1 ]; then
        adm_log_error "adm_cleanup__is_dir_safe requer 1 argumento: PATH"
        return 1
    fi
    local d="$1"

    [ -z "$d" ] && { adm_log_error "Diretório vazio não é seguro para limpeza."; return 1; }

    case "$d" in
        /|/bin|/sbin|/usr|/usr/bin|/usr/sbin|/lib|/lib64|/etc|/var|/home)
            adm_log_error "Diretório muito sensível para limpeza: %s" "$d"
            return 1
            ;;
    esac

    return 0
}

adm_cleanup__remove_path() {
    # Respeita ADM_CLEANUP_DRYRUN
    if [ $# -ne 1 ]; then
        adm_log_error "adm_cleanup__remove_path requer 1 argumento: PATH"
        return 1
    fi
    local path="$1"

    if [ "$ADM_CLEANUP_DRYRUN" -eq 1 ]; then
        adm_log_cleanup "[DRY-RUN] Removeria: %s" "$path"
        return 0
    fi

    adm_rm_rf_safe "$path"
}

adm_cleanup__remove_file() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_cleanup__remove_file requer 1 argumento: FILE"
        return 1
    fi
    local f="$1"

    if [ "$ADM_CLEANUP_DRYRUN" -eq 1 ]; then
        adm_log_cleanup "[DRY-RUN] Removeria arquivo: %s" "$f"
        return 0
    fi

    rm -f -- "$f" 2>/dev/null || {
        adm_log_warn "Falha ao remover arquivo: %s" "$f"
        return 1
    }
    return 0
}

adm_cleanup__remove_dir_if_empty() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_cleanup__remove_dir_if_empty requer 1 argumento: DIR"
        return 1
    fi
    local d="$1"

    [ -d "$d" ] || return 0

    if [ "$ADM_CLEANUP_DRYRUN" -eq 1 ]; then
        # apenas checa se está vazio
        if [ -z "$(find "$d" -mindepth 1 -maxdepth 1 2>/dev/null | head -n1)" ]; then
            adm_log_cleanup "[DRY-RUN] Removeria diretório vazio: %s" "$d"
        fi
        return 0
    fi

    rmdir -- "$d" 2>/dev/null && adm_log_cleanup "Removido diretório vazio: %s" "$d"
    return 0
}

adm_cleanup__has_find_mtime() {
    # Tenta detectar se find suporta -mtime (em quase todos, sim).
    find . -maxdepth 0 -mtime -1 >/dev/null 2>&1
}

###############################################################################
# Limpeza de cache de fontes (sources)
###############################################################################

# Remove arquivos muito antigos no cache de fontes.
# Usa ADM_CLEANUP_AGE_DAYS_SOURCES.
adm_cleanup_sources_cache() {
    local dir="$ADM_SOURCE_CACHE_DIR"
    if [ ! -d "$dir" ]; then
        adm_log_debug "Cache de fontes não existe: %s (nada a limpar)" "$dir"
        return 0
    fi

    adm_cleanup__is_dir_safe "$dir" || return 1

    local days="$ADM_CLEANUP_AGE_DAYS_SOURCES"
    adm_log_cleanup "Limpando cache de fontes em %s (arquivos com idade > %s dias)." "$dir" "$days"

    if ! adm_cleanup__has_find_mtime; then
        adm_log_warn "'find -mtime' não suportado; limpeza de fontes será ignorada."
        return 0
    fi

    local f
    while IFS= read -r f || [ -n "$f" ]; do
        [ -z "$f" ] && continue
        # Não mexe em diretórios base
        if [ ! -f "$f" ]; then
            continue
        fi
        adm_cleanup__remove_file "$f"
    done <<EOF
$(find "$dir" -type f -mtime "+$days" 2>/dev/null)
EOF

    return 0
}

###############################################################################
# Limpeza de cache de build
###############################################################################

# Remove diretórios de build antigos (não usados recentemente).
# Usa ADM_CLEANUP_AGE_DAYS_BUILD.
adm_cleanup_build_cache() {
    local dir="$ADM_BUILD_CACHE_DIR"
    if [ ! -d "$dir" ]; then
        adm_log_debug "Cache de build não existe: %s (nada a limpar)" "$dir"
        return 0
    fi

    adm_cleanup__is_dir_safe "$dir" || return 1

    local days="$ADM_CLEANUP_AGE_DAYS_BUILD"
    adm_log_cleanup "Limpando cache de build em %s (dirs com idade > %s dias)." "$dir" "$days"

    if ! adm_cleanup__has_find_mtime; then
        adm_log_warn "'find -mtime' não suportado; limpeza de build será ignorada."
        return 0
    fi

    local d
    while IFS= read -r d || [ -n "$d" ]; do
        [ -z "$d" ] && continue
        # Evita apagar o dir raiz
        [ "$d" = "$dir" ] && continue
        if [ -d "$d" ]; then
            adm_cleanup__remove_path "$d"
        fi
    done <<EOF
$(find "$dir" -mindepth 1 -maxdepth 3 -type d -mtime "+$days" 2>/dev/null)
EOF

    return 0
}

###############################################################################
# Limpeza de destdirs
###############################################################################

# Remove destdirs antigos (builds antigos já instalados).
# Opcionalmente poderia cruzar com packages.db para manter apenas o último,
# mas aqui usamos apenas idade.
adm_cleanup_destdirs() {
    local dir="$ADM_DESTDIR_DIR"
    if [ ! -d "$dir" ]; then
        adm_log_debug "DESTDIR_DIR não existe: %s (nada a limpar)" "$dir"
        return 0
    fi

    adm_cleanup__is_dir_safe "$dir" || return 1

    local days="${ADM_CLEANUP_AGE_DAYS_BUILD:-30}"
    adm_log_cleanup "Limpando destdirs em %s (dirs com idade > %s dias)." "$dir" "$days"

    if ! adm_cleanup__has_find_mtime; then
        adm_log_warn "'find -mtime' não suportado; limpeza de destdirs será ignorada."
        return 0
    fi

    local d
    while IFS= read -r d || [ -n "$d" ]; do
        [ -z "$d" ] && continue
        [ "$d" = "$dir" ] && continue
        if [ -d "$d" ]; then
            adm_cleanup__remove_path "$d"
        fi
    done <<EOF
$(find "$dir" -mindepth 1 -maxdepth 4 -type d -mtime "+$days" 2>/dev/null)
EOF

    return 0
}

###############################################################################
# Limpeza de logs
###############################################################################

adm_cleanup_logs() {
    local dir="$ADM_LOG_DIR"
    if [ ! -d "$dir" ]; then
        adm_log_debug "LOG_DIR não existe: %s (nada a limpar)" "$dir"
        return 0
    fi

    adm_cleanup__is_dir_safe "$dir" || return 1

    local days="$ADM_CLEANUP_AGE_DAYS_LOGS"
    adm_log_cleanup "Limpando logs em %s (arquivos com idade > %s dias)." "$dir" "$days"

    if ! adm_cleanup__has_find_mtime; then
        adm_log_warn "'find -mtime' não suportado; limpeza de logs será ignorada."
        return 0
    fi

    local f
    while IFS= read -r f || [ -n "$f" ]; do
        [ -z "$f" ] && continue
        [ -f "$f" ] || continue
        adm_cleanup__remove_file "$f"
    done <<EOF
$(find "$dir" -type f -mtime "+$days" 2>/dev/null)
EOF

    # Tenta remover diretórios vazios (em profundidade)
    local d
    while IFS= read -r d || [ -n "$d" ]; do
        [ -z "$d" ] && continue
        [ "$d" = "$dir" ] && continue
        adm_cleanup__remove_dir_if_empty "$d"
    done <<EOF
$(find "$dir" -type d 2>/dev/null | sort -r)
EOF

    return 0
}

###############################################################################
# Limpeza de TMP do ADM
###############################################################################

adm_cleanup_tmp() {
    local dir="$ADM_TMP_DIR"
    if [ ! -d "$dir" ]; then
        adm_log_debug "TMP_DIR do ADM não existe: %s (nada a limpar)" "$dir"
        return 0
    fi

    adm_cleanup__is_dir_safe "$dir" || return 1

    adm_log_cleanup "Limpando diretório temporário do ADM: %s" "$dir"

    # Remove TUDO dentro (mas não o próprio dir)
    local entry
    while IFS= read -r entry || [ -n "$entry" ]; do
        [ -z "$entry" ] && continue
        [ "$entry" = "$dir" ] && continue
        adm_cleanup__remove_path "$entry"
    done <<EOF
$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null)
EOF

    return 0
}

###############################################################################
# Limpeza de estado de pacotes removidos
###############################################################################

# Remove manifests e possivelmente destdirs de pacotes que constam com status=removed
adm_cleanup_state_removed() {
    adm_pkg_db_init || return 1

    if [ ! -f "$ADM_DEPS_DB_PATH" ]; then
        adm_log_debug "packages.db não existe; nada a limpar de estado."
        return 0
    fi

    adm_log_cleanup "Limpando estado de pacotes com status=removed."

    local line name category version profile libc reason run_deps status
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in
            \#*) continue ;;
        esac

        IFS=$'\t' read -r name category version profile libc reason run_deps status <<<"$line"
        [ -z "$name" ] && continue
        [ -z "$status" ] && status="installed"

        if [ "$status" != "removed" ]; then
            continue
        fi

        local manifest destdir
        manifest="$(printf '%s/%s/%s.list' "$ADM_MANIFEST_DIR" "$category" "$name")"
        destdir="$ADM_DESTDIR_DIR/$category/$name"

        if [ -f "$manifest" ]; then
            adm_log_cleanup "Removendo manifest de pacote removido: %s" "$manifest"
            adm_cleanup__remove_file "$manifest"
        fi

        if [ -d "$destdir" ]; then
            adm_log_cleanup "Removendo destdir de pacote removido: %s" "$destdir"
            adm_cleanup__remove_path "$destdir"
        fi
    done <"$ADM_DEPS_DB_PATH"

    # Tenta limpar diretórios vazios em ADM_MANIFEST_DIR e ADM_DESTDIR_DIR
    local d
    for d in "$ADM_MANIFEST_DIR" "$ADM_DESTDIR_DIR"; do
        [ -d "$d" ] || continue
        while IFS= read -r sub || [ -n "$sub" ]; do
            [ -z "$sub" ] && continue
            [ "$sub" = "$d" ] && continue
            adm_cleanup__remove_dir_if_empty "$sub"
        done <<EOF
$(find "$d" -type d 2>/dev/null | sort -r)
EOF
    done

    return 0
}

###############################################################################
# Limpeza de mounts de chroot “pendurados”
###############################################################################

# Heurística: se ADM_CHROOT_ROOT estiver definido, tenta desmontar os mounts base
# usando adm_chroot_umount_base. Caso não esteja, tenta detectar diretórios
# tipicamente usados como rootfs dentro do ADM (ex: $ADM_ROOT/rootfs/*) e
# desmonta se necessário.
adm_cleanup_chroot_mounts() {
    if [ "$ADM_CLEANUP_DRYRUN" -eq 1 ]; then
        adm_log_cleanup "[DRY-RUN] Limpar mounts de chroot pendurados (não será executado)."
        return 0
    fi

    # 1) Se ADM_CHROOT_ROOT estiver definido, tenta usar.
    if [ -n "${ADM_CHROOT_ROOT:-}" ] && [ -d "$ADM_CHROOT_ROOT" ]; then
        adm_log_cleanup "Tentando desmontar mounts base de chroot em: %s" "$ADM_CHROOT_ROOT"
        adm_chroot_umount_base "$ADM_CHROOT_ROOT" || adm_log_warn "Falha ao desmontar base de chroot em %s (pode não estar montado)." "$ADM_CHROOT_ROOT"
    fi

    # 2) Detecta possíveis rootfs em $ADM_ROOT/rootfs/*
    local rootfs_base="$ADM_ROOT/rootfs"
    if [ -d "$rootfs_base" ]; then
        local r
        while IFS= read -r r || [ -n "$r" ]; do
            [ -d "$r" ] || continue
            adm_log_cleanup "Tentando desmontar mounts de chroot detectado em: %s" "$r"
            adm_chroot_umount_base "$r" || adm_log_warn "Falha ao desmontar base de chroot em %s (pode não estar montado)." "$r"
        done <<EOF
$(find "$rootfs_base" -mindepth 1 -maxdepth 2 -type d 2>/dev/null)
EOF
    fi

    return 0
}

###############################################################################
# Limpeza geral
###############################################################################

# Orquestra todas as limpezas. Pode receber flags simples:
#   adm_cleanup_all              – limpa tudo
#   adm_cleanup_all sources      – só cache de fontes
#   adm_cleanup_all build logs   – só build + logs
#
# Se nenhum argumento é dado, roda tudo.
adm_cleanup_all() {
    local do_sources=0 do_build=0 do_destdir=0 do_logs=0 do_tmp=0 do_state=0 do_chroot=0

    if [ $# -eq 0 ]; then
        do_sources=1
        do_build=1
        do_destdir=1
        do_logs=1
        do_tmp=1
        do_state=1
        do_chroot=1
    else
        local arg
        for arg in "$@"; do
            case "$arg" in
                sources) do_sources=1 ;;
                build)   do_build=1 ;;
                destdir|destdirs) do_destdir=1 ;;
                logs)    do_logs=1 ;;
                tmp)     do_tmp=1 ;;
                state)   do_state=1 ;;
                chroot)  do_chroot=1 ;;
                all)
                    do_sources=1
                    do_build=1
                    do_destdir=1
                    do_logs=1
                    do_tmp=1
                    do_state=1
                    do_chroot=1
                    ;;
                *)
                    adm_log_warn "Argumento desconhecido para adm_cleanup_all: %s" "$arg"
                    ;;
            esac
        done
    fi

    adm_log_cleanup "Iniciando rotina de limpeza (dry-run=%s)." "$ADM_CLEANUP_DRYRUN"

    [ "$do_sources" -eq 1 ] && adm_cleanup_sources_cache
    [ "$do_build"   -eq 1 ] && adm_cleanup_build_cache
    [ "$do_destdir" -eq 1 ] && adm_cleanup_destdirs
    [ "$do_logs"    -eq 1 ] && adm_cleanup_logs
    [ "$do_tmp"     -eq 1 ] && adm_cleanup_tmp
    [ "$do_state"   -eq 1 ] && adm_cleanup_state_removed
    [ "$do_chroot"  -eq 1 ] && adm_cleanup_chroot_mounts

    adm_log_cleanup "Rotina de limpeza concluída."
    return 0
}

###############################################################################
# Inicialização
###############################################################################

adm_cleanup_init() {
    adm_log_debug "Subsistema de limpeza (cleanup.sh) carregado. Dry-run=%s" "$ADM_CLEANUP_DRYRUN"
}

adm_cleanup_init
