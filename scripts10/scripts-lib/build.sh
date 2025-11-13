#!/usr/bin/env bash
# lib/adm/build.sh
#
# Subsistema de BUILD do ADM
#
# Responsabilidades:
#   - Carregar metafile do pacote (repo/metafile)
#   - Buscar fontes (fetch.sh) com cache
#   - Extrair fontes para diretório de build
#   - Detectar sistema de build, linguagens, compiladores, linkers, libs (detect.sh)
#   - Aplicar profile de compilação (env_profiles.sh)
#   - Executar configure / build / test / install com lógica específica por tipo
#   - Suporte opcional a chroot (chroot.sh)
#   - Executar hooks (pre_*/post_*) automaticamente
#
# Objetivo: ZERO erros silenciosos. Qualquer abuso de API ou falha importante
# gera adm_log_* bem claro.
###############################################################################
# PARTE 0 – Proteção contra múltiplos loads
###############################################################################
if [ -n "${ADM_BUILD_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
ADM_BUILD_LOADED=1
###############################################################################
# PARTE 1 – Dependências: log, core, env, repo, deps, fetch, detect, chroot
###############################################################################
# --- LOG --------------------------------------------------------------
if ! command -v adm_log_build >/dev/null 2>&1; then
    # Fallback mínimo se log.sh ainda não foi carregado
    adm_log()        { printf '%s\n' "$*" >&2; }
    adm_log_info()   { adm_log "[INFO]   $*"; }
    adm_log_warn()   { adm_log "[WARN]   $*"; }
    adm_log_error()  { adm_log "[ERROR]  $*"; }
    adm_log_debug()  { :; }
    adm_log_build()  { adm_log "[BUILD]  $*"; }
    adm_log_stage()  { adm_log "[STAGE]  $*"; }
    adm_log_fetch()  { adm_log "[FETCH]  $*"; }
    adm_log_detect() { adm_log "[DETECT] $*"; }
    adm_log_pkg()    { adm_log "[PKG]    $*"; }
fi

# --- CORE + PATHS -----------------------------------------------------
if command -v adm_core_init_paths >/dev/null 2>&1; then
    adm_core_init_paths
fi

# fallback adm_run / adm_run_or_die / adm_rm_rf_safe
if ! command -v adm_run >/dev/null 2>&1; then
    adm_run() {
        if [ $# -lt 1 ]; then
            adm_log_error "adm_run requer pelo menos 1 argumento (comando)."
            return 1
        fi
        "$@"
        local rc=$?
        [ $rc -ne 0 ] && adm_log_error "Comando falhou (rc=%d): %s" "$rc" "$*"
        return $rc
    }
fi

if ! command -v adm_run_or_die >/devnull 2>&1; then
    adm_run_or_die() {
        if ! adm_run "$@"; then
            adm_log_error "Comando obrigatório falhou: %s" "$*"
            exit 1
        fi
    }
fi

if ! command -v adm_rm_rf_safe >/dev/null 2>&1; then
    adm_rm_rf_safe() {
        if [ $# -ne 1 ]; then
            adm_log_error "adm_rm_rf_safe requer 1 argumento: CAMINHO"
            return 1
        fi
        rm -rf -- "$1"
    }
fi

# --- ENV / PROFILES ---------------------------------------------------
if ! command -v adm_env_apply_profile >/dev/null 2>&1; then
    adm_log_warn "env_profiles.sh não carregado; adm_env_apply_profile ausente. CFLAGS/CXXFLAGS podem não estar setados."
    adm_env_apply_profile() { :; }
fi

# --- REPO -------------------------------------------------------------
if ! command -v adm_repo_load_metafile >/dev/null 2>&1; then
    adm_log_error "repo.sh não carregado; adm_repo_load_metafile ausente. build.sh não pode funcionar corretamente."
fi
if ! command -v adm_repo_hooks_dir >/dev/null 2>&1; then
    adm_log_warn "adm_repo_hooks_dir não disponível; hooks não funcionarão."
    adm_repo_hooks_dir() { return 1; }
fi
if ! command -v adm_repo_parse_deps >/dev/null 2>&1; then
    adm_log_warn "adm_repo_parse_deps não disponível; parse de listas sources/sha será simplificado."
    adm_repo_parse_deps() {
        # fallback trivial: troca vírgulas por quebras de linha
        printf '%s\n' "$1" | tr ',' '\n'
    }
fi

# --- FETCH ------------------------------------------------------------
if ! command -v adm_fetch_url >/dev/null 2>&1; then
    adm_log_error "fetch.sh não carregado; adm_fetch_url ausente. build.sh não consegue baixar fontes."
fi

# --- DETECT -----------------------------------------------------------
if ! command -v adm_detect_build_system >/dev/null 2>&1; then
    adm_log_warn "detect.sh não carregado; detecção de build system será limitada."
    adm_detect_build_system() { printf 'unknown\n'; }
    adm_detect_all() { :; }
fi

# --- CHROOT -----------------------------------------------------------
if ! command -v adm_chroot_exec >/dev/null 2>&1 && ! command -v adm_chroot_enter >/dev/null 2>&1; then
    # Não é fatal; apenas não teremos suporte automático a chroot.
    adm_chroot_exec() {
        adm_log_error "adm_chroot_exec chamado mas chroot.sh não está carregado."
        return 1
    }
fi

# --- PATHS GLOBAIS ----------------------------------------------------
: "${ADM_ROOT:=${ADM_ROOT:-/usr/src/adm}}"
: "${ADM_BUILD_CACHE_DIR:=${ADM_BUILD_CACHE_DIR:-$ADM_ROOT/cache/build}}"
: "${ADM_SOURCE_CACHE_DIR:=${ADM_SOURCE_CACHE_DIR:-$ADM_ROOT/cache/sources}}"
: "${ADM_DESTDIR_DIR:=${ADM_DESTDIR_DIR:-$ADM_ROOT/destdir}}"
: "${ADM_LOG_DIR:=${ADM_LOG_DIR:-$ADM_ROOT/logs}}"

: "${ADM_BUILD_LOG_DIR:=$ADM_LOG_DIR/build}"
: "${ADM_BUILD_USE_CHROOT:=0}"      # 0 = desativado, 1 = usar chroot
: "${ADM_CHROOT_ROOT:=}"           # path do rootfs quando usar chroot (obrigatório se ADM_BUILD_USE_CHROOT=1)

# Garante diretórios principais
adm_mkdir_p "$ADM_BUILD_CACHE_DIR"   || adm_log_error "Falha ao criar ADM_BUILD_CACHE_DIR: %s" "$ADM_BUILD_CACHE_DIR"
adm_mkdir_p "$ADM_DESTDIR_DIR"       || adm_log_error "Falha ao criar ADM_DESTDIR_DIR: %s"     "$ADM_DESTDIR_DIR"
adm_mkdir_p "$ADM_BUILD_LOG_DIR"     || adm_log_error "Falha ao criar ADM_BUILD_LOG_DIR: %s"   "$ADM_BUILD_LOG_DIR"

###############################################################################
# PARTE 2 – Helpers internos gerais
###############################################################################

adm_build__trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

adm_build__validate_identifier() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_build__validate_identifier requer 1 argumento."
        return 1
    fi
    local s="$1"
    if [ -z "$s" ]; then
        adm_log_error "Identificador não pode ser vazio."
        return 1
    fi
    case "$s" in
        *[!A-Za-z0-9._-]*)
            adm_log_error "Identificador inválido: '%s' (permitido: letras, números, ., -, _)" "$s"
            return 1
            ;;
    esac
    return 0
}

adm_build__pkg_key() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_build__pkg_key requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi
    printf '%s/%s\n' "$1" "$2"
}

# Execução com suporte opcional a chroot, em um diretório específico
adm_build__run_in_dir() {
    # args: DIR CMD [ARGS...]
    if [ $# -lt 2 ]; then
        adm_log_error "adm_build__run_in_dir requer pelo menos 2 argumentos: DIR CMD [ARGS...]"
        return 1
    fi
    local dir="$1"; shift
    local cmd="$1"; shift

    if [ ! -d "$dir" ]; then
        adm_log_error "Diretório de trabalho não existe: %s" "$dir"
        return 1
    fi

    if [ "$ADM_BUILD_USE_CHROOT" -eq 1 ]; then
        if [ -z "$ADM_CHROOT_ROOT" ]; then
            adm_log_error "ADM_BUILD_USE_CHROOT=1 mas ADM_CHROOT_ROOT não está definido."
            return 1
        fi
        if ! command -v adm_chroot_exec >/dev/null 2>&1; then
            adm_log_error "adm_chroot_exec não disponível; não é possível usar chroot em builds."
            return 1
        fi

        # Assumimos que 'dir' é VÁLIDO DENTRO DO CHROOT também (mesmo caminho
        # absoluto). Quem configura o rootfs precisa garantir isso.
        local cmdline
        # Monta um comando seguro para bash -lc
        # shellcheck disable=SC2145
        cmdline="cd '$dir' && exec '$cmd'" 
        if [ $# -gt 0 ]; then
            # precisamos inserir os args de forma segura
            local a; for a in "$@"; do
                cmdline="$cmdline '$(printf "%s" "$a" | sed \"s/'/'\\\\''/g\")'"
            done
        fi

        adm_log_build "CHROOT exec: root=%s, dir=%s, cmd=%s" "$ADM_CHROOT_ROOT" "$dir" "$cmdline"
        adm_chroot_exec "$ADM_CHROOT_ROOT" /bin/sh -lc "$cmdline"
        local rc=$?
        [ $rc -ne 0 ] && adm_log_error "Comando em chroot falhou (rc=%d): %s" "$rc" "$cmdline"
        return $rc
    else
        adm_log_build "Exec: (dir=%s) %s %s" "$dir" "$cmd" "$*"
        ( cd "$dir" && "$cmd" "$@" )
        local rc=$?
        [ $rc -ne 0 ] && adm_log_error "Comando falhou (rc=%d) em dir=%s: %s %s" "$rc" "$dir" "$cmd" "$*"
        return $rc
    fi
}

# Arquivo de log do pacote
adm_build__log_path() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_build__log_path requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi
    local category="$1" pkg="$2"
    printf '%s/%s-%s.log' "$ADM_BUILD_LOG_DIR" "$category" "$pkg"
}

###############################################################################
# PARTE 3 – Metafile, fontes e diretórios de build/destdir
###############################################################################

# Carrega metafile de um pacote para prefixo ADM_META_
adm_build__load_metafile() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_build__load_metafile requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi
    local category="$1" pkg="$2"

    adm_build__validate_identifier "$category" || return 1
    adm_build__validate_identifier "$pkg"      || return 1

    if ! command -v adm_repo_load_metafile >/dev/null 2>&1; then
        adm_log_error "adm_repo_load_metafile não disponível; não é possível carregar metafile."
        return 1
    fi

    adm_repo_load_metafile "$category" "$pkg" "ADM_META_" || {
        adm_log_error "Falha ao carregar metafile para %s/%s" "$category" "$pkg"
        return 1
    }

    # Só log de debug
    adm_log_debug "Metafile carregado para %s/%s: version=%s" \
        "$category" "$pkg" "${ADM_META_version:-<vazio>}"

    return 0
}

# Define caminhos de build/destdir para um pacote
adm_build__paths_for_pkg() {
    # args: CATEGORIA PACOTE
    if [ $# -ne 2 ]; then
        adm_log_error "adm_build__paths_for_pkg requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi
    local category="$1" pkg="$2"

    adm_BUILD_PKG_KEY="$(adm_build__pkg_key "$category" "$pkg")" || return 1

    # Diretório onde código será construído
    if [ "$ADM_BUILD_USE_CHROOT" -eq 1 ] && [ -n "$ADM_CHROOT_ROOT" ]; then
        # Construir DENTRO do rootfs. Exemplo: /path-do-rootfs/usr/src/adm/build/base/gcc
        ADM_BUILD_DIR_HOST="$ADM_CHROOT_ROOT/usr/src/adm/build/$category/$pkg"
        ADM_BUILD_DIR_CHROOT="/usr/src/adm/build/$category/$pkg"
    else
        ADM_BUILD_DIR_HOST="$ADM_BUILD_CACHE_DIR/$category/$pkg"
        ADM_BUILD_DIR_CHROOT="$ADM_BUILD_DIR_HOST"
    fi

    # Destdir para instalar antes de copiar para /
    if [ "$ADM_BUILD_USE_CHROOT" -eq 1 ] && [ -n "$ADM_CHROOT_ROOT" ]; then
        ADM_DESTDIR_PKG="$ADM_CHROOT_ROOT$ADM_DESTDIR_DIR/$category/$pkg"
        ADM_DESTDIR_CHROOT="$ADM_DESTDIR_DIR/$category/$pkg"
    else
        ADM_DESTDIR_PKG="$ADM_DESTDIR_DIR/$category/$pkg"
        ADM_DESTDIR_CHROOT="$ADM_DESTDIR_PKG"
    fi

    export ADM_BUILD_PKG_KEY ADM_BUILD_DIR_HOST ADM_BUILD_DIR_CHROOT ADM_DESTDIR_PKG ADM_DESTDIR_CHROOT

    return 0
}

# Extrai extensão principal do arquivo (para escolher ferramenta de extração)
adm_build__archive_type() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_build__archive_type requer 1 argumento: ARQUIVO"
        printf 'unknown\n'
        return 1
    fi
    local f="$1"

    case "$f" in
        *.tar.gz|*.tgz)   printf 'tar.gz\n' ;;
        *.tar.xz|*.txz)   printf 'tar.xz\n' ;;
        *.tar.bz2|*.tbz2) printf 'tar.bz2\n' ;;
        *.tar.lz)         printf 'tar.lz\n' ;;
        *.tar.zst|*.tzst) printf 'tar.zst\n' ;;
        *.tar)            printf 'tar\n' ;;
        *.zip)            printf 'zip\n' ;;
        *.7z)             printf '7z\n' ;;
        *)
            printf 'unknown\n'
            ;;
    esac
}

# Extrai um arquivo de fonte para um diretório de destino
adm_build__extract_one() {
    # args: ARCHIVE DESTDIR
    if [ $# -ne 2 ]; then
        adm_log_error "adm_build__extract_one requer 2 argumentos: ARQUIVO DESTDIR"
        return 1
    fi
    local archive="$1" dest="$2"

    if [ ! -f "$archive" ]; then
        adm_log_error "Arquivo de fonte não encontrado para extração: %s" "$archive"
        return 1
    fi

    adm_mkdir_p "$dest" || {
        adm_log_error "Falha ao criar diretório de extração: %s" "$dest"
        return 1
    }

    local type
    type="$(adm_build__archive_type "$archive")" || type="unknown"

    adm_log_build "Extraindo %s (%s) para %s" "$archive" "$type" "$dest"

    case "$type" in
        tar.gz)  tar -C "$dest" -xzf "$archive" 2>/dev/null ;;
        tar.xz)  tar -C "$dest" -xJf "$archive" 2>/dev/null ;;
        tar.bz2) tar -C "$dest" -xjf "$archive" 2>/dev/null ;;
        tar.lz)  tar -C "$dest" --lzip  -xf "$archive" 2>/dev/null ;;
        tar.zst) tar -C "$dest" --zstd  -xf "$archive" 2>/dev/null ;;
        tar)     tar -C "$dest" -xf "$archive" 2>/dev/null ;;
        zip)
            if command -v unzip >/dev/null 2>&1; then
                unzip -q "$archive" -d "$dest" 2>/dev/null
            else
                adm_log_error "unzip não encontrado para extrair: %s" "$archive"
                return 1
            fi
            ;;
        7z)
            if command -v 7z >/dev/null 2>&1; then
                7z x -y "$archive" -o"$dest" >/dev/null 2>&1
            else
                adm_log_error "7z não encontrado para extrair: %s" "$archive"
                return 1
            fi
            ;;
        unknown)
            adm_log_error "Tipo de arquivo de fonte desconhecido: %s" "$archive"
            return 1
            ;;
    esac

    local rc=$?
    [ $rc -ne 0 ] && adm_log_error "Falha ao extrair: %s" "$archive"
    return $rc
}

# Busca e extrai fontes baseadas em ADM_META_sources/sha256sums
# Preenche variáveis globais:
#   ADM_BUILD_SRC_ROOT  – diretório raiz dos fontes (pasta principal)
#   ADM_BUILD_SRC_DIR   – diretório que será usado como src_dir para build
adm_build__fetch_and_unpack_sources() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_build__fetch_and_unpack_sources requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi
    local category="$1" pkg="$2"

    # Espera-se ADM_META_sources e ADM_META_sha256sums já carregadas
    local sources_csv="${ADM_META_sources:-}"
    local sha_csv="${ADM_META_sha256sums:-}"

    if [ -z "$sources_csv" ]; then
        adm_log_error "metafile de %s/%s não define 'sources'." "$category" "$pkg"
        return 1
    fi

    local pkg_id; pkg_id="$(adm_build__pkg_key "$category" "$pkg")" || return 1

    local -a SOURCES=()
    local -a SHAS=()

    # Usa parser de lista do repo (funciona bem para CSV simples)
    local s
    while IFS= read -r s || [ -n "$s" ]; do
        s="$(adm_build__trim "$s")"
        [ -z "$s" ] && continue
        SOURCES+=("$s")
    done <<EOF
$(adm_repo_parse_deps "$sources_csv")
EOF

    if [ -n "$sha_csv" ]; then
        while IFS= read -r s || [ -n "$s" ]; do
            s="$(adm_build__trim "$s")"
            [ -z "$s" ] && continue
            SHAS+=("$s")
        done <<EOF
$(adm_repo_parse_deps "$sha_csv")
EOF
    fi

    if [ "${#SOURCES[@]}" -eq 0 ]; then
        adm_log_error "Nenhuma fonte válida após parse para %s" "$pkg_id"
        return 1
    fi

    # Diretório de build precisa existir (ADM_BUILD_DIR_HOST)
    adm_mkdir_p "$ADM_BUILD_DIR_HOST" || {
        adm_log_error "Não foi possível criar diretório de build: %s" "$ADM_BUILD_DIR_HOST"
        return 1
    }

    # Baixa fontes individualmente (capturando caminho local)
    local i url sha path
    local -a LOCAL_ARCHIVES=()

    for i in "${!SOURCES[@]}"; do
        url="${SOURCES[$i]}"
        sha=""
        [ $i -lt ${#SHAS[@]} ] && sha="${SHAS[$i]}"

        # Cria hint legível
        local hint base
        base="${url##*/}"
        [ -z "$base" ] && base="src-$i"
        hint="${pkg_id//\//-}-$base"

        adm_log_fetch "Baixando fonte %d/%d (%s) para %s" \
            "$((i+1))" "${#SOURCES[@]}" "$url" "$pkg_id"

        path="$(adm_fetch_url "$url" "$hint" "$sha")" || {
            adm_log_error "Falha ao obter fonte '%s' para %s" "$url" "$pkg_id"
            return 1
        }
        LOCAL_ARCHIVES+=("$path")
    done

    # Extrai todas as fontes no diretório de build
    adm_log_build "Extraindo fontes para %s" "$ADM_BUILD_DIR_HOST"
    adm_rm_rf_safe "$ADM_BUILD_DIR_HOST" || :
    adm_mkdir_p "$ADM_BUILD_DIR_HOST" || {
        adm_log_error "Não foi possível recriar diretório de build: %s" "$ADM_BUILD_DIR_HOST"
        return 1
    }

    for path in "${LOCAL_ARCHIVES[@]}"; do
        adm_build__extract_one "$path" "$ADM_BUILD_DIR_HOST" || return 1
    done

    # Determinar diretório raiz do código (primeiro subdir criado, se existir)
    local first_dir
    first_dir="$(find "$ADM_BUILD_DIR_HOST" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)" || first_dir=""

    if [ -n "$first_dir" ]; then
        ADM_BUILD_SRC_ROOT="$ADM_BUILD_DIR_HOST"
        ADM_BUILD_SRC_DIR="$first_dir"
    else
        # Se não criou dirs, talvez o código seja no próprio build_dir
        ADM_BUILD_SRC_ROOT="$ADM_BUILD_DIR_HOST"
        ADM_BUILD_SRC_DIR="$ADM_BUILD_DIR_HOST"
    fi

    export ADM_BUILD_SRC_ROOT ADM_BUILD_SRC_DIR
    adm_log_build "Fonte raiz para %s: SRC_DIR=%s" "$pkg_id" "$ADM_BUILD_SRC_DIR"
    return 0
}

###############################################################################
# PARTE 4 – Hooks (pre/post)
###############################################################################

# Executa um hook se existir.
# Hooks moram em: repo/<categoria>/<pacote>/hooks/<nome_hook>
# Nome de hook típico: pre_configure, post_configure, pre_build, post_build,
#                      pre_install, post_install, test, pre_fetch, post_fetch...
adm_build__run_hook() {
    # args: CATEGORIA PACOTE HOOK_NAME [WORKDIR]
    if [ $# -lt 3 ] || [ $# -gt 4 ]; then
        adm_log_error "adm_build__run_hook requer 3 ou 4 argumentos: CATEGORIA PACOTE HOOK [WORKDIR]"
        return 1
    fi
    local category="$1" pkg="$2" hook="$3"
    local workdir="${4:-$ADM_BUILD_SRC_DIR}"

    if ! command -v adm_repo_hooks_dir >/dev/null 2>&1; then
        adm_log_debug "Hooks não suportados (adm_repo_hooks_dir ausente)."
        return 0
    fi

    local hooks_dir
    hooks_dir="$(adm_repo_hooks_dir "$category" "$pkg" 2>/dev/null)" || return 0
    local hook_path="$hooks_dir/$hook"

    if [ ! -f "$hook_path" ]; then
        adm_log_debug "Hook não encontrado (%s) para %s/%s" "$hook" "$category" "$pkg"
        return 0
    fi
    if [ ! -x "$hook_path" ]; then
        adm_log_warn "Hook encontrado mas não executável (%s) para %s/%s" "$hook" "$category" "$pkg"
        chmod +x "$hook_path" 2>/dev/null || :
    fi

    adm_log_build "Executando hook '%s' para %s/%s" "$hook" "$category" "$pkg"

    # Exporta algumas variáveis de contexto úteis para o hook
    ADM_PKG_CATEGORY="$category"
    ADM_PKG_NAME="$pkg"
    ADM_PKG_VERSION="${ADM_META_version:-}"
    ADM_PKG_BUILD_DIR="$ADM_BUILD_DIR_HOST"
    ADM_PKG_SRC_DIR="$ADM_BUILD_SRC_DIR"
    ADM_PKG_DESTDIR="$ADM_DESTDIR_PKG"
    ADM_PKG_DESTDIR_CHROOT="$ADM_DESTDIR_CHROOT"

    export ADM_PKG_CATEGORY ADM_PKG_NAME ADM_PKG_VERSION \
           ADM_PKG_BUILD_DIR ADM_PKG_SRC_DIR ADM_PKG_DESTDIR ADM_PKG_DESTDIR_CHROOT

    # IMPORTANTE: assumimos que o repo do ADM é visível no chroot no mesmo path
    # se ADM_BUILD_USE_CHROOT=1. Caso contrário, hooks não funcionarão em chroot.
    if [ "$ADM_BUILD_USE_CHROOT" -eq 1 ]; then
        adm_build__run_in_dir "$workdir" "$hook_path"
    else
        ( cd "$workdir" && "$hook_path" )
    fi
    local rc=$?
    [ $rc -ne 0 ] && adm_log_error "Hook '%s' retornou código %d para %s/%s" "$hook" "$rc" "$category" "$pkg"
    return $rc
}

###############################################################################
# PARTE 5 – Drivers de build por tipo de sistema
###############################################################################

# --- AUTOTOOLS --------------------------------------------------------
adm_build__driver_autotools() {
    # args: SRC_DIR DESTDIR
    if [ $# -ne 2 ]; then
        adm_log_error "adm_build__driver_autotools requer 2 argumentos: SRC_DIR DESTDIR"
        return 1
    fi
    local src="$1" destdir="$2"

    local configure_script
    if [ -x "$src/configure" ]; then
        configure_script="$src/configure"
    else
        adm_log_error "Sistema autotools detectado mas configure não encontrado em: %s" "$src"
        return 1
    fi

    adm_mkdir_p "$destdir" || {
        adm_log_error "Falha ao criar DESTDIR: %s" "$destdir"
        return 1
    }

    local prefix="/usr"
    local sysconfdir="/etc"
    local localstatedir="/var"

    adm_build__run_in_dir "$src" "$configure_script" \
        --prefix="$prefix" \
        --sysconfdir="$sysconfdir" \
        --localstatedir="$localstatedir" || return 1

    # Compilar
    adm_build__run_in_dir "$src" make -j"${ADM_BUILD_JOBS:-$(nproc 2>/dev/null || echo 1)}" || return 1

    # Testes opcionais
    case "${ADM_PROFILE_TESTS:-auto}" in
        yes)
            adm_build__run_in_dir "$src" make check || adm_log_warn "Testes 'make check' falharam (continuando)."
            ;;
        auto)
            # tenta rodar se target existir
            if grep -qE '^[[:space:]]*check:' "$src/Makefile" 2>/dev/null; then
                adm_build__run_in_dir "$src" make check || adm_log_warn "Testes 'make check' falharam (continuando)."
            fi
            ;;
        no)
            adm_log_build "Tests desabilitados via profile."
            ;;
    esac

    # Instalar em DESTDIR
    adm_build__run_in_dir "$src" make install DESTDIR="$destdir" || return 1

    return 0
}

# --- CMAKE ------------------------------------------------------------
adm_build__driver_cmake() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_build__driver_cmake requer 2 argumentos: SRC_DIR DESTDIR"
        return 1
    fi
    local src="$1" destdir="$2"

    if ! command -v cmake >/dev/null 2>&1; then
        adm_log_error "cmake não encontrado no PATH, mas projeto é CMake."
        return 1
    fi

    local build="$src/build"
    adm_rm_rf_safe "$build" || :
    adm_mkdir_p "$build" || {
        adm_log_error "Falha ao criar build dir CMake: %s" "$build"
        return 1
    }

    local generator="Unix Makefiles"
    if command -v ninja >/dev/null 2>&1; then
        generator="Ninja"
    fi

    adm_build__run_in_dir "$build" cmake \
        -G "$generator" \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_INSTALL_DOCDIR=share/doc \
        -DCMAKE_INSTALL_MANDIR=share/man \
        -DCMAKE_INSTALL_SYSCONFDIR=/etc \
        "$src" || return 1

    if [ "$generator" = "Ninja" ]; then
        adm_build__run_in_dir "$build" ninja || return 1
        case "${ADM_PROFILE_TESTS:-auto}" in
            yes)  adm_build__run_in_dir "$build" ninja test || adm_log_warn "Testes ninja falharam (continuando)." ;;
            auto) adm_build__run_in_dir "$build" ninja test || adm_log_warn "Testes ninja falharam (continuando)." ;;
            no)   adm_log_build "Tests desabilitados via profile." ;;
        esac
        adm_build__run_in_dir "$build" ninja install DESTDIR="$destdir" || return 1
    else
        adm_build__run_in_dir "$build" make -j"${ADM_BUILD_JOBS:-$(nproc 2>/dev/null || echo 1)}" || return 1
        case "${ADM_PROFILE_TESTS:-auto}" in
            yes)  adm_build__run_in_dir "$build" ctest || adm_log_warn "ctest falhou (continuando)." ;;
            auto) adm_build__run_in_dir "$build" ctest || adm_log_warn "ctest falhou (continuando)." ;;
            no)   adm_log_build "Tests desabilitados via profile." ;;
        esac
        adm_build__run_in_dir "$build" make install DESTDIR="$destdir" || return 1
    fi

    return 0
}

# --- MESON ------------------------------------------------------------
adm_build__driver_meson() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_build__driver_meson requer 2 argumentos: SRC_DIR DESTDIR"
        return 1
    fi
    local src="$1" destdir="$2"

    if ! command -v meson >/dev/null 2>&1; then
        adm_log_error "meson não encontrado no PATH, mas projeto é Meson."
        return 1
    fi

    local build="$src/build"
    adm_rm_rf_safe "$build" || :
    adm_mkdir_p "$build" || {
        adm_log_error "Falha ao criar build dir Meson: %s" "$build"
        return 1
    }

    adm_build__run_in_dir "$src" meson setup "$build" \
        --prefix=/usr \
        --buildtype=release \
        --libdir=lib \
        --sysconfdir=/etc || return 1

    adm_build__run_in_dir "$build" meson compile || return 1

    case "${ADM_PROFILE_TESTS:-auto}" in
        yes|auto)
            adm_build__run_in_dir "$build" meson test || adm_log_warn "meson test falhou (continuando)."
            ;;
        no)
            adm_log_build "Tests desabilitados via profile."
            ;;
    esac

    adm_build__run_in_dir "$build" meson install --destdir "$destdir" || return 1
    return 0
}

# --- CARGO (Rust) -----------------------------------------------------
adm_build__driver_cargo() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_build__driver_cargo requer 2 argumentos: SRC_DIR DESTDIR"
        return 1
    fi
    local src="$1" destdir="$2"

    if ! command -v cargo >/dev/null 2>&1; then
        adm_log_error "cargo não encontrado no PATH, mas projeto é Rust (Cargo)."
        return 1
    fi

    adm_mkdir_p "$destdir" || {
        adm_log_error "Falha ao criar DESTDIR: %s" "$destdir"
        return 1
    }

    adm_build__run_in_dir "$src" cargo build --release || return 1

    case "${ADM_PROFILE_TESTS:-auto}" in
        yes|auto)
            adm_build__run_in_dir "$src" cargo test --release || adm_log_warn "cargo test falhou (continuando)."
            ;;
        no)
            adm_log_build "Tests desabilitados via profile."
            ;;
    esac

    # instalação genérica: construímos binários em target/release
    local bin
    for bin in "$src/target/release/"*; do
        [ -x "$bin" ] || continue
        adm_mkdir_p "$destdir/usr/bin" || return 1
        cp -f "$bin" "$destdir/usr/bin/" || return 1
    done

    return 0
}

# --- GO ---------------------------------------------------------------
adm_build__driver_go() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_build__driver_go requer 2 argumentos: SRC_DIR DESTDIR"
        return 1
    fi
    local src="$1" destdir="$2"

    if ! command -v go >/dev/null 2>&1; then
        adm_log_error "go não encontrado no PATH, mas projeto parece Go."
        return 1
    fi

    adm_mkdir_p "$destdir/usr/bin" || {
        adm_log_error "Falha ao criar DESTDIR bin: %s/usr/bin" "$destdir"
        return 1
    }

    adm_build__run_in_dir "$src" go build ./... || return 1

    # Heurística: procura main.go, tenta gerar binários com nome do pacote
    local main_files
    main_files="$(find "$src" -maxdepth 2 -type f -name 'main.go' 2>/dev/null)" || main_files=""
    if [ -n "$main_files" ]; then
        local mf dir name
        while IFS= read -r mf || [ -n "$mf" ]; do
            dir="$(dirname "$mf")"
            name="$(basename "$dir")"
            adm_build__run_in_dir "$dir" go build -o "$destdir/usr/bin/$name" . || return 1
        done <<EOF
$main_files
EOF
    fi

    return 0
}

# --- PYTHON (setuptools/pyproject) -----------------------------------
adm_build__driver_python() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_build__driver_python requer 2 argumentos: SRC_DIR DESTDIR"
        return 1
    fi
    local src="$1" destdir="$2"

    if ! command -v python3 >/dev/null 2>&1; then
        adm_log_error "python3 não encontrado no PATH, mas projeto parece Python."
        return 1
    fi

    adm_mkdir_p "$destdir" || {
        adm_log_error "Falha ao criar DESTDIR: %s" "$destdir"
        return 1
    }

    if [ -f "$src/pyproject.toml" ]; then
        adm_build__run_in_dir "$src" python3 -m pip install . --root "$destdir" --no-compile || return 1
    elif [ -f "$src/setup.py" ]; then
        adm_build__run_in_dir "$src" python3 setup.py install --root="$destdir" --optimize=1 || return 1
    else
        adm_log_error "Projeto Python sem pyproject.toml ou setup.py em: %s" "$src"
        return 1
    fi

    return 0
}

# --- NPM / Node -------------------------------------------------------
adm_build__driver_node() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_build__driver_node requer 2 argumentos: SRC_DIR DESTDIR"
        return 1
    fi
    local src="$1" destdir="$2"

    if ! command -v npm >/dev/null 2>&1; then
        adm_log_error "npm não encontrado no PATH, mas projeto parece Node."
        return 1
    fi

    adm_mkdir_p "$destdir/usr/lib/node_modules" || {
        adm_log_error "Falha ao criar DESTDIR: %s" "$destdir/usr/lib/node_modules"
        return 1
    }

    adm_build__run_in_dir "$src" npm install || return 1
    adm_build__run_in_dir "$src" npm test   || adm_log_warn "npm test falhou (continuando)."

    # Instala globalmente em /usr/lib/node_modules (DESTDIR-aware)
    adm_build__run_in_dir "$src" npm install --global --prefix "$destdir/usr" . || return 1

    return 0
}

# --- MAKE genérico ----------------------------------------------------
adm_build__driver_make() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_build__driver_make requer 2 argumentos: SRC_DIR DESTDIR"
        return 1
    fi
    local src="$1" destdir="$2"

    if [ ! -f "$src/Makefile" ] && [ ! -f "$src/makefile" ] && [ ! -f "$src/GNUmakefile" ]; then
        adm_log_error "Driver 'make' chamado mas nenhum Makefile encontrado em: %s" "$src"
        return 1
    fi

    adm_mkdir_p "$destdir" || {
        adm_log_error "Falha ao criar DESTDIR: %s" "$destdir"
        return 1
    }

    adm_build__run_in_dir "$src" make -j"${ADM_BUILD_JOBS:-$(nproc 2>/dev/null || echo 1)}" || return 1

    case "${ADM_PROFILE_TESTS:-auto}" in
        yes|auto)
            if grep -qE '^[[:space:]]*test:' "$src/Makefile" 2>/dev/null; then
                adm_build__run_in_dir "$src" make test || adm_log_warn "Testes 'make test' falharam (continuando)."
            fi
            ;;
        no)
            adm_log_build "Tests desabilitados via profile."
            ;;
    esac

    # tenta make install DESTDIR; se não existir, loga e segue
    if grep -qE '^[[:space:]]*install:' "$src/Makefile" 2>/dev/null; then
        adm_build__run_in_dir "$src" make install DESTDIR="$destdir" || return 1
    else
        adm_log_warn "Makefile não tem alvo 'install'; nada será instalado automaticamente."
    fi

    return 0
}

###############################################################################
# PARTE 6 – Orquestração do build de um pacote
###############################################################################

# Calcula número de jobs para compilação (MAKEFLAGS etc.)
adm_build__compute_jobs() {
    local jobs_default=1

    if command -v nproc >/dev/null 2>&1; then
        jobs_default="$(nproc 2>/dev/null || echo 1)"
    fi

    if [ -n "${ADM_CONF_jobs_default:-}" ]; then
        # se maior que 0, usa; se 0, auto; se inválido, ignora
        case "${ADM_CONF_jobs_default}" in
            ''|0)
                ;;
            *[!0-9]*)
                adm_log_warn "ADM_CONF_jobs_default inválido: %s; usando auto." "$ADM_CONF_jobs_default"
                ;;
            *)
                jobs_default="${ADM_CONF_jobs_default}"
                ;;
        esac
    fi

    ADM_BUILD_JOBS="$jobs_default"
    export ADM_BUILD_JOBS
}

# Função principal: build (e instalar em DESTDIR) um pacote
#
# Uso:
#   adm_build_package CATEGORIA PACOTE
#
# Fluxo:
#   - aplica profile
#   - carrega metafile
#   - prepara paths
#   - baixa e extrai fontes
#   - detecta build system
#   - roda hooks + driver apropriado
#   - deixa arquivos instalados em ADM_DESTDIR_PKG
adm_build_package() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_build_package requer 2 argumentos: CATEGORIA PACOTE"
        return 1
    fi
    local category="$1" pkg="$2"

    adm_build__validate_identifier "$category" || return 1
    adm_build__validate_identifier "$pkg"      || return 1

    local pkg_id; pkg_id="$(adm_build__pkg_key "$category" "$pkg")" || return 1

    adm_log_pkg "=== BUILD de pacote %s ===" "$pkg_id"

    # Aplica profile (CFLAGS, etc.)
    adm_env_apply_profile || adm_log_warn "Falha ao aplicar profile; prosseguindo com ambiente atual."

    adm_build__compute_jobs

    # Prepara paths
    adm_build__paths_for_pkg "$category" "$pkg" || return 1

    # Carrega metafile
    adm_build__load_metafile "$category" "$pkg" || return 1

    # Limpa diretório de build e destdir anteriores
    adm_rm_rf_safe "$ADM_BUILD_DIR_HOST" || :
    adm_rm_rf_safe "$ADM_DESTDIR_PKG"    || :
    adm_mkdir_p "$ADM_BUILD_DIR_HOST"    || return 1
    adm_mkdir_p "$ADM_DESTDIR_PKG"       || return 1

    # Hooks de fetch
    adm_build__run_hook "$category" "$pkg" "pre_fetch" "$ADM_BUILD_DIR_HOST" || return 1

    # Baixa + extrai fontes
    adm_build__fetch_and_unpack_sources "$category" "$pkg" || return 1

    adm_build__run_hook "$category" "$pkg" "post_fetch" "$ADM_BUILD_SRC_DIR" || return 1

    # Detecta build system e ferramentas
    local build_system
    build_system="$(adm_detect_build_system "$ADM_BUILD_SRC_DIR" 2>/dev/null || printf 'unknown')" || build_system="unknown"
    build_system="$(adm_build__trim "$build_system")"
    [ -z "$build_system" ] && build_system="unknown"

    adm_log_detect "Build system para %s: %s" "$pkg_id" "$build_system"

    # Dump opcional de detecção completa em log
    local detect_log
    detect_log="$(mktemp -t adm-detect-XXXXXX 2>/dev/null || echo '')"
    if [ -n "$detect_log" ]; then
        adm_detect_all "$ADM_BUILD_SRC_DIR" >"$detect_log" 2>/dev/null || :
        adm_log_debug "Resumo de detecção para %s:\n%s" "$pkg_id" "$(cat "$detect_log" 2>/dev/null || echo '')"
        rm -f "$detect_log" 2>/dev/null || :
    fi

    # Hooks de configure
    adm_build__run_hook "$category" "$pkg" "pre_configure" "$ADM_BUILD_SRC_DIR" || return 1

    local rc=0
    case "$build_system" in
        autotools)
            adm_build__driver_autotools "$ADM_BUILD_SRC_DIR" "$ADM_DESTDIR_CHROOT" || rc=$?
            ;;
        cmake)
            adm_build__driver_cmake "$ADM_BUILD_SRC_DIR" "$ADM_DESTDIR_CHROOT" || rc=$?
            ;;
        meson)
            adm_build__driver_meson "$ADM_BUILD_SRC_DIR" "$ADM_DESTDIR_CHROOT" || rc=$?
            ;;
        cargo)
            adm_build__driver_cargo "$ADM_BUILD_SRC_DIR" "$ADM_DESTDIR_CHROOT" || rc=$?
            ;;
        go)
            adm_build__driver_go "$ADM_BUILD_SRC_DIR" "$ADM_DESTDIR_CHROOT" || rc=$?
            ;;
        python)
            adm_build__driver_python "$ADM_BUILD_SRC_DIR" "$ADM_DESTDIR_CHROOT" || rc=$?
            ;;
        node)
            adm_build__driver_node "$ADM_BUILD_SRC_DIR" "$ADM_DESTDIR_CHROOT" || rc=$?
            ;;
        make)
            adm_build__driver_make "$ADM_BUILD_SRC_DIR" "$ADM_DESTDIR_CHROOT" || rc=$?
            ;;
        unknown|*)
            adm_log_warn "Sistema de build desconhecido para %s; tentando driver 'make' genérico." "$pkg_id"
            adm_build__driver_make "$ADM_BUILD_SRC_DIR" "$ADM_DESTDIR_CHROOT" || rc=$?
            ;;
    esac

    if [ $rc -ne 0 ]; then
        adm_log_error "Build falhou para %s (tipo %s, rc=%d)." "$pkg_id" "$build_system" "$rc"
        return $rc
    fi

    # Hook pós-configure/pós-build/pós-install
    adm_build__run_hook "$category" "$pkg" "post_configure" "$ADM_BUILD_SRC_DIR" || return 1
    adm_build__run_hook "$category" "$pkg" "post_build"     "$ADM_BUILD_SRC_DIR" || return 1
    adm_build__run_hook "$category" "$pkg" "pre_install"    "$ADM_BUILD_SRC_DIR" || return 1
    adm_build__run_hook "$category" "$pkg" "post_install"   "$ADM_DESTDIR_PKG"   || return 1

    # Hook de testes específicos
    adm_build__run_hook "$category" "$pkg" "test" "$ADM_BUILD_SRC_DIR" || {
        adm_log_warn "Hook 'test' retornou erro para %s (continuando)." "$pkg_id"
    }

    adm_log_pkg "=== BUILD de %s concluído com sucesso. DESTDIR=%s ===" "$pkg_id" "$ADM_DESTDIR_PKG"
    return 0
}

###############################################################################
# PARTE 7 – Inicialização
###############################################################################

adm_build_init() {
    adm_log_debug "Subsistema de build (build.sh) carregado. Build cache: %s" "$ADM_BUILD_CACHE_DIR"
}

adm_build_init
