#!/usr/bin/env bash
# lib/adm/verify.sh
#
# Subsistema de VERIFICAÇÃO do ADM
#
# Responsabilidades:
#   - Verificar integridade de:
#       * Toolchain (cross-tools e final)
#       * Rootfs (stage2/base)
#       * Pacotes instalados (packages.db + manifests + filesystem)
#       * Manifests órfãos / inconsistências
#   - Validar binários (ELF, libs não encontradas via ldd quando disponível)
#   - Validar estrutura mínima de um rootfs / do sistema host
#   - Expor funções de alto nível:
#       * adm_verify_toolchain_cross
#       * adm_verify_toolchain_final
#       * adm_verify_rootfs
#       * adm_verify_package
#       * adm_verify_packages_all
#       * adm_verify_all
#
# Objetivo: ZERO erros silenciosos – qualquer problema relevante gera log claro.
#
# Configuração:
#   ADM_VERIFY_MAX_ERRORS – se >0, para depois de N falhas (default: 0 = sem limite)
#   ADM_VERIFY_VERBOSE    – 0/1 (default: 1)
#   ADM_VERIFY_STRICT     – 0/1 (default: 0, warnings não contam como erro global)
#
# Convenções:
#   - Raiz de instalação padrão: ADM_INSTALL_ROOT (default "/")
#   - Raiz cross-toolchain:      ADM_CROSS_TOOLS_DIR
#   - Rootfs stage2/base:        ADM_ROOTFS_STAGE2_DIR
###############################################################################
# Proteção contra múltiplos loads
###############################################################################
if [ -n "${ADM_VERIFY_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
ADM_VERIFY_LOADED=1
###############################################################################
# Dependências: log + core + pkg + detect + chroot (opcionais)
###############################################################################
# -------- LOG ---------------------------------------------------------
if ! command -v adm_log_verify >/dev/null 2>&1; then
    # Fallback mínimo se log.sh ainda não foi carregado
    adm_log()         { printf '%s\n' "$*" >&2; }
    adm_log_info()    { adm_log "[INFO]    $*"; }
    adm_log_warn()    { adm_log "[WARN]    $*"; }
    adm_log_error()   { adm_log "[ERROR]   $*"; }
    adm_log_debug()   { :; }
    adm_log_verify()  { adm_log "[VERIFY]  $*"; }
fi

# -------- CORE (paths, helpers) --------------------------------------
if command -v adm_core_init_paths >/dev/null 2>&1; then
    adm_core_init_paths
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

if ! command -v adm_require_root >/dev/null 2>&1; then
    adm_require_root() {
        if [ "$(id -u 2>/dev/null)" != "0" ]; then
            adm_log_error "Este comando requer privilégios de root."
            return 1
        fi
        return 0
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

# -------- PKG / DB / MANIFESTS ---------------------------------------
if ! command -v adm_pkg_db_read_all >/dev/null 2>&1; then
    adm_pkg_db_read_all() { :; }
fi
if ! command -v adm_pkg_db_init >/dev/null 2>&1; then
    adm_pkg_db_init() { :; }
fi

# -------- DETECT (opcional) ------------------------------------------
if ! command -v adm_detect_all >/dev/null 2>&1; then
    adm_detect_all() { :; }
fi

# -------- CHROOT (opcional) ------------------------------------------
if ! command -v adm_chroot_umount_base >/dev/null 2>&1; then
    adm_chroot_umount_base() { :; }
fi

# -------- PATHS GLOBAIS ----------------------------------------------
: "${ADM_ROOT:=${ADM_ROOT:-/usr/src/adm}}"
: "${ADM_STATE_DIR:=${ADM_STATE_DIR:-$ADM_ROOT/state}}"
: "${ADM_DESTDIR_DIR:=${ADM_DESTDIR_DIR:-$ADM_ROOT/destdir}}"
: "${ADM_LOG_DIR:=${ADM_LOG_DIR:-$ADM_ROOT/logs}}"
: "${ADM_TMP_DIR:=${ADM_TMP_DIR:-$ADM_ROOT/tmp}}"

: "${ADM_CROSS_TOOLS_DIR:=${ADM_CROSS_TOOLS_DIR:-$ADM_ROOT/cross-tools}}"
: "${ADM_ROOTFS_STAGE2_DIR:=${ADM_ROOTFS_STAGE2_DIR:-$ADM_ROOT/rootfs/stage2}}"

: "${ADM_INSTALL_ROOT:=${ADM_INSTALL_ROOT:-/}}"
: "${ADM_MANIFEST_DIR:=${ADM_MANIFEST_DIR:-$ADM_STATE_DIR/manifests}}"
: "${ADM_DEPS_DB_PATH:=${ADM_DEPS_DB_PATH:-$ADM_STATE_DIR/packages.db}}"

adm_mkdir_p "$ADM_STATE_DIR"    || adm_log_error "Falha ao criar ADM_STATE_DIR: %s" "$ADM_STATE_DIR"
adm_mkdir_p "$ADM_MANIFEST_DIR" || adm_log_error "Falha ao criar ADM_MANIFEST_DIR: %s" "$ADM_MANIFEST_DIR"
adm_mkdir_p "$ADM_TMP_DIR"      || adm_log_error "Falha ao criar ADM_TMP_DIR: %s" "$ADM_TMP_DIR"

###############################################################################
# Configuração de verificação
###############################################################################

: "${ADM_VERIFY_MAX_ERRORS:=0}"   # 0 = sem limite
: "${ADM_VERIFY_VERBOSE:=1}"      # 1 = loga PASS também
: "${ADM_VERIFY_STRICT:=0}"       # 1 = WARN conta como erro global

###############################################################################
# Contadores globais
###############################################################################

ADM_VERIFY_CHECKS=0
ADM_VERIFY_WARNINGS=0
ADM_VERIFY_ERRORS=0

adm_verify_reset_counters() {
    ADM_VERIFY_CHECKS=0
    ADM_VERIFY_WARNINGS=0
    ADM_VERIFY_ERRORS=0
}

###############################################################################
# Helpers internos
###############################################################################

adm_verify__trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

adm_verify__maybe_abort_on_limit() {
    if [ "$ADM_VERIFY_MAX_ERRORS" -gt 0 ] && [ "$ADM_VERIFY_ERRORS" -ge "$ADM_VERIFY_MAX_ERRORS" ]; then
        adm_log_error "Limite de erros de verificação atingido (%s). Abortando verificações restantes." "$ADM_VERIFY_MAX_ERRORS"
        return 1
    fi
    return 0
}

adm_verify__record_result() {
    # args: STATUS CONTEXT MESSAGE...
    # STATUS: PASS|WARN|FAIL
    if [ $# -lt 2 ]; then
        adm_log_error "adm_verify__record_result requer pelo menos 2 argumentos: STATUS CONTEXTO [MENSAGEM...]"
        return 1
    fi
    local status="$1" ctx="$2"; shift 2
    local msg="$*"

    ADM_VERIFY_CHECKS=$((ADM_VERIFY_CHECKS + 1))

    case "$status" in
        PASS)
            if [ "$ADM_VERIFY_VERBOSE" -eq 1 ]; then
                adm_log_verify "[OK]   (%s) %s" "$ctx" "$msg"
            fi
            ;;
        WARN)
            ADM_VERIFY_WARNINGS=$((ADM_VERIFY_WARNINGS + 1))
            adm_log_warn "[VERIFY:%s] %s" "$ctx" "$msg"
            ;;
        FAIL)
            ADM_VERIFY_ERRORS=$((ADM_VERIFY_ERRORS + 1))
            adm_log_error "[VERIFY:%s] %s" "$ctx" "$msg"
            ;;
        *)
            adm_log_error "STATUS inválido em adm_verify__record_result: %s" "$status"
            return 1
            ;;
    esac

    adm_verify__maybe_abort_on_limit || return 1
    return 0
}

adm_verify_summary() {
    local rc=0
    if [ "$ADM_VERIFY_ERRORS" -gt 0 ]; then
        rc=1
    elif [ "$ADM_VERIFY_STRICT" -eq 1 ] && [ "$ADM_VERIFY_WARNINGS" -gt 0 ]; then
        rc=1
    fi

    adm_log_verify "Resumo: checks=%s, warnings=%s, errors=%s (strict=%s, rc=%s)" \
        "$ADM_VERIFY_CHECKS" "$ADM_VERIFY_WARNINGS" "$ADM_VERIFY_ERRORS" "$ADM_VERIFY_STRICT" "$rc"

    return $rc
}

###############################################################################
# Verificações básicas de arquivos / diretórios / binários
###############################################################################

adm_verify_file_exists() {
    # args: PATH [type]
    # type: file|dir|symlink|exec
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then
        adm_log_error "adm_verify_file_exists requer 1 ou 2 argumentos: PATH [TIPO]"
        return 1
    fi
    local path="$1" type="${2:-any}"

    local ctx="file_exists:$path"

    case "$type" in
        file)
            if [ -f "$path" ]; then
                adm_verify__record_result PASS "$ctx" "Arquivo existe."
            else
                adm_verify__record_result FAIL "$ctx" "Arquivo NÃO existe."
            fi
            ;;
        dir)
            if [ -d "$path" ]; then
                adm_verify__record_result PASS "$ctx" "Diretório existe."
            else
                adm_verify__record_result FAIL "$ctx" "Diretório NÃO existe."
            fi
            ;;
        symlink)
            if [ -L "$path" ]; then
                adm_verify__record_result PASS "$ctx" "Symlink existe."
            else
                adm_verify__record_result FAIL "$ctx" "Symlink NÃO existe."
            fi
            ;;
        exec)
            if [ -x "$path" ] && [ -f "$path" ]; then
                adm_verify__record_result PASS "$ctx" "Binário executável existe."
            else
                adm_verify__record_result FAIL "$ctx" "Binário executável NÃO encontrado."
            fi
            ;;
        any)
            if [ -e "$path" ]; then
                adm_verify__record_result PASS "$ctx" "Caminho existe."
            else
                adm_verify__record_result FAIL "$ctx" "Caminho NÃO existe."
            fi
            ;;
        *)
            adm_log_error "Tipo inválido para adm_verify_file_exists: %s" "$type"
            return 1
            ;;
    esac

    return 0
}

adm_verify_binary_elf() {
    # args: PATH
    if [ $# -ne 1 ]; then
        adm_log_error "adm_verify_binary_elf requer 1 argumento: PATH"
        return 1
    fi
    local path="$1"
    local ctx="binary_elf:$path"

    if [ ! -f "$path" ]; then
        adm_verify__record_result FAIL "$ctx" "Arquivo não existe para verificar ELF."
        return 0
    fi

    if ! command -v file >/dev/null 2>&1; then
        adm_verify__record_result WARN "$ctx" "Comando 'file' não disponível; não é possível verificar ELF."
        return 0
    fi

    local out
    out="$(file "$path" 2>/dev/null || true)"
    if printf '%s\n' "$out" | grep -qi 'ELF'; then
        adm_verify__record_result PASS "$ctx" "Arquivo é ELF: $out"
    else
        adm_verify__record_result WARN "$ctx" "Arquivo não parece ELF: $out"
    fi
    return 0
}

adm_verify_binary_ldd() {
    # args: PATH
    if [ $# -ne 1 ]; then
        adm_log_error "adm_verify_binary_ldd requer 1 argumento: PATH"
        return 1
    fi
    local path="$1"
    local ctx="binary_ldd:$path"

    if [ ! -x "$path" ]; then
        adm_verify__record_result FAIL "$ctx" "Binário não executável ou não existe."
        return 0
    fi

    if ! command -v ldd >/dev/null 2>&1; then
        adm_verify__record_result WARN "$ctx" "Comando 'ldd' não disponível; pulando verificação de libs."
        return 0
    fi

    local out missing=0
    out="$(ldd "$path" 2>/dev/null || true)"
    if printf '%s\n' "$out" | grep -q 'not found'; then
        missing=1
    fi

    if [ "$missing" -eq 0 ]; then
        adm_verify__record_result PASS "$ctx" "ldd não reportou libs ausentes."
    else
        adm_verify__record_result FAIL "$ctx" "ldd encontrou bibliotecas ausentes:\n$out"
    fi

    return 0
}

###############################################################################
# Verificação de toolchain (cross e final)
###############################################################################

adm_verify_toolchain_cross() {
    # Verifica presença mínima de ferramentas no ADM_CROSS_TOOLS_DIR
    local root="$ADM_CROSS_TOOLS_DIR"
    local ctx="toolchain_cross"

    if [ ! -d "$root" ]; then
        adm_verify__record_result FAIL "$ctx" "Diretório cross-tools não existe: $root"
        return 0
    fi

    adm_verify__record_result PASS "$ctx" "Diretório cross-tools presente: $root"

    # Lista mínima de ferramentas cross (podem ter prefixo, então checamos qualquer gcc, as, ld, etc.)
    local bin
    for bin in gcc cc as ld ar nm strip; do
        # procura *-gcc, *-as etc. dentro de $root/bin
        if find "$root/bin" -maxdepth 1 -type f -name "*-$bin" 2>/dev/null | grep -q .; then
            adm_verify__record_result PASS "$ctx" "Ferramenta cross '*-$bin' encontrada em $root/bin."
        else
            adm_verify__record_result WARN "$ctx" "Ferramenta cross '*-$bin' NÃO encontrada em $root/bin."
        fi
    done

    # GCC principal (qualquer *-gcc) – tenta rodar --version
    local gcc
    gcc="$(find "$root/bin" -maxdepth 1 -type f -name "*-gcc" 2>/dev/null | head -n1 || true)"
    if [ -n "$gcc" ]; then
        if "$gcc" --version >/dev/null 2>&1; then
            adm_verify__record_result PASS "$ctx" "Cross-GCC executou --version com sucesso: $gcc"
        else
            adm_verify__record_result FAIL "$ctx" "Cross-GCC existe mas falhou ao rodar --version: $gcc"
        fi
    else
        adm_verify__record_result FAIL "$ctx" "Nenhum cross-GCC encontrado em $root/bin."
    fi

    return 0
}

adm_verify_toolchain_final() {
    # Verifica toolchain "final" no root de instalação atual
    local root="$ADM_INSTALL_ROOT"
    local ctx="toolchain_final"

    if [ ! -d "$root" ]; then
        adm_verify__record_result FAIL "$ctx" "ADM_INSTALL_ROOT não existe: $root"
        return 0
    fi

    # Checa binutils e gcc (sem prefixo, dentro do rootfs ou do host)
    local prefix_root
    prefix_root="$root"

    adm_verify_file_exists "$prefix_root/usr/bin/gcc" exec
    adm_verify_binary_elf "$prefix_root/usr/bin/gcc"

    adm_verify_file_exists "$prefix_root/usr/bin/ld" exec
    adm_verify_binary_elf "$prefix_root/usr/bin/ld"

    adm_verify_file_exists "$prefix_root/usr/bin/as" exec
    adm_verify_binary_elf "$prefix_root/usr/bin/as"

    # Se o root != "/" provavelmente estamos verificando um rootfs; para ldd,
    # precisamos de chroot – aqui apenas tentamos para o host.
    if [ "$root" = "/" ]; then
        adm_verify_binary_ldd "/usr/bin/gcc"
        adm_verify_binary_ldd "/usr/bin/ld" || true
    else
        adm_verify__record_result WARN "$ctx" "Não executando ldd em rootfs não montado na / (sem chroot automático aqui)."
    fi

    return 0
}

###############################################################################
# Verificação de rootfs (estrutura básica)
###############################################################################

adm_verify_rootfs_basic() {
    # args: ROOT
    if [ $# -ne 1 ]; then
        adm_log_error "adm_verify_rootfs_basic requer 1 argumento: ROOT"
        return 1
    fi
    local root="$1"
    local ctx="rootfs_basic:$root"

    if [ ! -d "$root" ]; then
        adm_verify__record_result FAIL "$ctx" "Rootfs não existe: $root"
        return 0
    fi

    adm_verify__record_result PASS "$ctx" "Rootfs encontrado: $root"

    # Dirs obrigatórios
    local d
    for d in bin usr usr/bin lib etc var tmp; do
        if [ -d "$root/$d" ]; then
            adm_verify__record_result PASS "$ctx" "Diretório presente: /$d"
        else
            adm_verify__record_result FAIL "$ctx" "Diretório ausente no rootfs: /$d"
        fi
    done

    # /tmp deve ser 1777 – checamos se possível
    if [ -d "$root/tmp" ]; then
        local mode
        mode="$(stat -c '%a' "$root/tmp" 2>/dev/null || echo '')"
        if [ -n "$mode" ]; then
            if [ "$mode" = "1777" ] || [ "$mode" = "0777" ]; then
                adm_verify__record_result PASS "$ctx" "/tmp tem permissão plausível: $mode"
            else
                adm_verify__record_result WARN "$ctx" "/tmp com permissão inesperada: $mode (esperado 1777)"
            fi
        else
            adm_verify__record_result WARN "$ctx" "Não foi possível ler permissões de /tmp em $root."
        fi
    fi

    # /bin/sh obrigatório
    if [ -x "$root/bin/sh" ]; then
        adm_verify__record_result PASS "$ctx" "/bin/sh presente e executável."
    else
        adm_verify__record_result FAIL "$ctx" "/bin/sh ausente ou não executável."
    fi

    # /usr/bin/env é muito usado
    if [ -x "$root/usr/bin/env" ]; then
        adm_verify__record_result PASS "$ctx" "/usr/bin/env presente."
    else
        adm_verify__record_result WARN "$ctx" "/usr/bin/env ausente."
    fi

    return 0
}

adm_verify_rootfs_stage2() {
    local root="$ADM_ROOTFS_STAGE2_DIR"
    local ctx="rootfs_stage2"

    adm_verify_rootfs_basic "$root"

    # Alguns binários críticos em stage2/base
    local bin
    for bin in /bin/bash /usr/bin/gcc /usr/bin/ld /usr/bin/pkg-config /usr/bin/python3; do
        if [ -x "$root$bin" ]; then
            adm_verify__record_result PASS "$ctx" "Binário crítico presente: $bin"
        else
            adm_verify__record_result WARN "$ctx" "Binário crítico ausente no rootfs: $bin"
        fi
    done

    return 0
}

###############################################################################
# Verificação de pacotes e manifests
###############################################################################

adm_verify_manifest_for_package() {
    # args: CATEGORY NAME
    if [ $# -ne 2 ]; then
        adm_log_error "adm_verify_manifest_for_package requer 2 argumentos: CATEGORIA NOME"
        return 1
    fi
    local category="$1" name="$2"
    local manifest="$ADM_MANIFEST_DIR/$category/$name.list"
    local ctx="pkg_manifest:$category/$name"

    if [ ! -f "$manifest" ]; then
        adm_verify__record_result FAIL "$ctx" "Manifest não encontrado: $manifest"
        return 0
    fi

    adm_verify__record_result PASS "$ctx" "Manifest encontrado: $manifest"

    local missing=0 total=0 present=0
    local rel full

    while IFS= read -r rel || [ -n "$rel" ]; do
        rel="$(adm_verify__trim "$rel")"
        [ -z "$rel" ] && continue
        [ "$rel" = "." ] && continue
        total=$((total + 1))
        full="$ADM_INSTALL_ROOT/$rel"

        if [ -e "$full" ]; then
            present=$((present + 1))
        else
            missing=$((missing + 1))
            adm_verify__record_result FAIL "$ctx" "Arquivo da manifest ausente no sistema: $full"
        fi
    done <"$manifest"

    if [ "$total" -eq 0 ]; then
        adm_verify__record_result WARN "$ctx" "Manifest vazia para pacote."
    fi

    if [ "$missing" -eq 0 ]; then
        adm_verify__record_result PASS "$ctx" "Todos os arquivos listados na manifest existem (total=$total)."
    else
        adm_verify__record_result FAIL "$ctx" "Existem arquivos ausentes (missing=$missing, total=$total)."
    fi

    return 0
}

adm_verify_package_basic() {
    # args: CATEGORY NAME VERSION
    if [ $# -ne 3 ]; then
        adm_log_error "adm_verify_package_basic requer 3 argumentos: CATEGORIA NOME VERSÃO"
        return 1
    fi
    local category="$1" name="$2" version="$3"
    local ctx="pkg_basic:$category/$name"

    # Verifica alguns arquivos típicos (heurístico)
    local bin
    local any=0 found=0

    for bin in "/usr/bin/$name" "/bin/$name" "/usr/sbin/$name" "/sbin/$name"; do
        any=1
        if [ -x "$ADM_INSTALL_ROOT$bin" ]; then
            found=1
            adm_verify__record_result PASS "$ctx" "Binário provável presente: $bin (versão esperada=$version)"
            break
        fi
    done

    if [ "$any" -eq 1 ] && [ "$found" -eq 0 ]; then
        adm_verify__record_result WARN "$ctx" "Nenhum binário com nome '$name' encontrado em paths típicos."
    fi

    return 0
}

adm_verify_packages_all() {
    adm_pkg_db_init || return 1
    if [ ! -f "$ADM_DEPS_DB_PATH" ]; then
        adm_verify__record_result WARN "packages_all" "packages.db não existe; nenhum pacote registrado."
        return 0
    fi

    adm_log_verify "Verificando todos os pacotes instalados (packages.db: %s)" "$ADM_DEPS_DB_PATH"

    local line name category version profile libc reason run_deps status
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        case "$line" in
            \#*) continue ;;
        esac

        IFS=$'\t' read -r name category version profile libc reason run_deps status <<<"$line"
        [ -z "$name" ] && continue
        [ -z "$status" ] && status="installed"

        if [ "$status" != "installed" ]; then
            continue
        fi

        adm_verify_manifest_for_package "$category" "$name"
        adm_verify_package_basic "$category" "$name" "$version"
    done <"$ADM_DEPS_DB_PATH"

    return 0
}

###############################################################################
# Verificação global
###############################################################################

adm_verify_all() {
    adm_verify_reset_counters

    # 1) Toolchain cross (se existir)
    adm_verify_toolchain_cross

    # 2) Toolchain final (no root atual)
    adm_verify_toolchain_final

    # 3) Rootfs stage2 (se existir)
    if [ -d "$ADM_ROOTFS_STAGE2_DIR" ]; then
        adm_verify_rootfs_stage2
    else
        adm_verify__record_result WARN "rootfs_stage2" "Rootfs stage2 não existe: $ADM_ROOTFS_STAGE2_DIR"
    fi

    # 4) Pacotes / manifests
    adm_verify_packages_all

    # 5) Pequenas verificações adicionais do sistema host
    adm_verify_file_exists "/proc" dir
    adm_verify_file_exists "/sys"  dir
    adm_verify_file_exists "/dev"  dir

    # 6) Resumo final (retorna código)
    adm_verify_summary
}

###############################################################################
# Inicialização
###############################################################################

adm_verify_init() {
    adm_log_debug "Subsistema de verificação (verify.sh) carregado. strict=%s max_errors=%s" \
        "$ADM_VERIFY_STRICT" "$ADM_VERIFY_MAX_ERRORS"
}

adm_verify_init
