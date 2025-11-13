#!/usr/bin/env bash
# lib/adm/env_profiles.sh
#
# Gestão de ambiente + profiles do ADM:
#  - Carrega config global (config/adm.conf)
#  - Detecta libc do sistema (glibc/musl) e define defaults
#  - Gerencia profiles: listar, mostrar, criar, setar, aplicar
#  - Exporta variáveis de build (CFLAGS, CXXFLAGS, LDFLAGS, MAKEFLAGS, ADM_LIBC, ADM_TARGET, etc.)
#
# Objetivo: zero erros silenciosos – qualquer problema relevante gera log claro.
#==============================================================================
# PARTE 0 – Proteção contra múltiplos loads
#==============================================================================
if [ -n "${ADM_ENV_PROFILES_LOADED:-}" ]; then
    # Já carregado
    return 0 2>/dev/null || exit 0
fi
ADM_ENV_PROFILES_LOADED=1
#==============================================================================
# PARTE 1 – Dependências: log + core
#==============================================================================
# Espera-se que log.sh e core.sh já tenham sido carregados pelo bin/adm.
# Mas, para robustez, checa se algumas funções essenciais existem.
if ! command -v adm_log_info >/dev/null 2>&1; then
    # Fallback mínimo se log.sh não foi carregado
    adm_log()       { printf '%s\n' "$*" >&2; }
    adm_log_info()  { adm_log "[INFO]  $*"; }
    adm_log_warn()  { adm_log "[WARN]  $*"; }
    adm_log_error() { adm_log "[ERROR] $*"; }
    adm_log_debug() { :; }
fi

if ! command -v adm_core_init_paths >/dev/null 2>&1; then
    adm_log_error "env_profiles.sh requer core.sh (função adm_core_init_paths não encontrada)."
    # Não encerramos aqui para evitar quebrar o shell chamador, mas registramos erro.
fi

# Garante inicialização de caminhos básicos do ADM
if command -v adm_core_init_paths >/dev/null 2>&1; then
    adm_core_init_paths
fi

#==============================================================================
# PARTE 2 – Carregamento de config global
#==============================================================================

# Variáveis globais da config (prefixo ADM_CONF_)
ADM_CONF_loaded=0

# Carrega config global de config/adm.conf (se existir)
adm_env_load_global_config() {
    if [ "$ADM_CONF_loaded" -eq 1 ]; then
        return 0
    fi

    local conf_file
    conf_file="${ADM_CONFIG_DIR:-${ADM_ROOT:-/usr/src/adm}/config}/adm.conf"

    if [ -f "$conf_file" ]; then
        if command -v adm_read_kv_file >/dev/null 2>&1; then
            adm_read_kv_file "$conf_file" "ADM_CONF_" || {
                adm_log_error "Falha ao ler config global: $conf_file"
            }
        else
            adm_log_warn "adm_read_kv_file não disponível; não foi possível processar $conf_file."
        fi
    else
        adm_log_debug "Config global não encontrada (ok): $conf_file"
    fi

    # Defaults seguros se não definidos em adm.conf
    : "${ADM_CONF_target:=}"       # pode ficar vazio, será inferido
    : "${ADM_CONF_host:=}"         # idem
    : "${ADM_CONF_build:=}"        # idem
    : "${ADM_CONF_libc_default:=auto}"  # auto, glibc, musl
    : "${ADM_CONF_jobs_default:=0}"     # 0 = auto (nproc)
    : "${ADM_CONF_cflags_default:=-O2 -pipe}"
    : "${ADM_CONF_cxxflags_default:=-O2 -pipe}"
    : "${ADM_CONF_ldflags_default:=}"
    : "${ADM_CONF_docs_default:=auto}"  # auto/yes/no
    : "${ADM_CONF_tests_default:=auto}" # auto/yes/no

    ADM_CONF_loaded=1
}

#==============================================================================
# PARTE 3 – Detecção de libc e triplets
#==============================================================================

# Detecta libc do sistema (glibc/musl/unknown)
adm_env_detect_system_libc() {
    # 1) tenta usar ldd
    if command -v ldd >/dev/null 2>&1; then
        # captura poucas linhas para evitar lentidão
        local out
        out="$(LC_ALL=C ldd --version 2>/dev/null | head -n 2 | tr '[:upper:]' '[:lower:]')" || out=""
        case "$out" in
            *musl*)
                printf 'musl\n'
                return 0
                ;;
            *glibc*|*gnu\ libc*)
                printf 'glibc\n'
                return 0
                ;;
        esac
    fi

    # 2) tenta detectar musl por arquivos de loader
    if find /lib /usr/lib /usr/local/lib -maxdepth 2 -type f -name 'ld-musl-*.so*' 2>/dev/null | grep -q .; then
        printf 'musl\n'
        return 0
    fi

    # 3) fallback
    printf 'unknown\n'
    return 0
}

# Inicializa ADM_TARGET, ADM_HOST, ADM_BUILD com base na config/global
adm_env_init_triplets() {
    adm_env_load_global_config

    # BUILD
    if [ -n "${ADM_CONF_build:-}" ]; then
        ADM_BUILD="$ADM_CONF_build"
    else
        # Tenta inferir a partir de gcc -dumpmachine
        if command -v gcc >/dev/null 2>&1; then
            ADM_BUILD="$(gcc -dumpmachine 2>/dev/null || printf 'unknown-build')"
        else
            ADM_BUILD="$(uname -m 2>/dev/null || printf 'unknown')-unknown-linux-gnu"
        fi
    fi

    # HOST
    if [ -n "${ADM_CONF_host:-}" ]; then
        ADM_HOST="$ADM_CONF_host"
    else
        ADM_HOST="$ADM_BUILD"
    fi

    # TARGET
    if [ -n "${ADM_CONF_target:-}" ]; then
        ADM_TARGET="$ADM_CONF_target"
    else
        ADM_TARGET="$ADM_HOST"
    fi

    export ADM_BUILD ADM_HOST ADM_TARGET
    adm_log_debug "Triplets: BUILD=$ADM_BUILD HOST=$ADM_HOST TARGET=$ADM_TARGET"
}

# Determina ADM_LIBC com base em config, profile e sistema
adm_env_determine_libc() {
    local requested="$1"  # pode ser "glibc", "musl" ou "auto" ou vazio

    adm_env_load_global_config

    local mode="${requested:-$ADM_CONF_libc_default}"

    case "$mode" in
        glibc|musl)
            printf '%s\n' "$mode"
            return 0
            ;;
        auto|"")
            local syslibc
            syslibc="$(adm_env_detect_system_libc)"
            case "$syslibc" in
                glibc|musl)
                    printf '%s\n' "$syslibc"
                    return 0
                    ;;
                *)
                    # fallback glibc se desconhecido
                    adm_log_warn "Libc do sistema desconhecida; assumindo glibc como padrão."
                    printf 'glibc\n'
                    return 0
                    ;;
            esac
            ;;
        *)
            adm_log_warn "Valor inválido de libc em profile/config: '$mode'; usando auto."
            syslibc="$(adm_env_detect_system_libc)"
            case "$syslibc" in
                glibc|musl) printf '%s\n' "$syslibc" ;;
                *) printf 'glibc\n' ;;
            esac
            return 0
            ;;
    esac
}

#==============================================================================
# PARTE 4 – Paths e arquivos de profile
#==============================================================================

# Retorna caminho do arquivo de profile para um nome
# Uso: adm_env_profile_file NOME
adm_env_profile_file() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_env_profile_file requer 1 argumento: NOME_PROFILE"
        return 1
    fi
    local name="$1"

    if [ -z "$name" ]; then
        adm_log_error "adm_env_profile_file: nome do profile não pode ser vazio."
        return 1
    fi

    local dir="${ADM_PROFILES_DIR:-${ADM_ROOT:-/usr/src/adm}/profiles}"
    printf '%s/%s.profile\n' "$dir" "$name"
    return 0
}

# Verifica se profile existe (arquivo)
adm_env_profile_exists() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_env_profile_exists requer 1 argumento: NOME_PROFILE"
        return 1
    fi
    local file
    file="$(adm_env_profile_file "$1")" || return 1
    [ -f "$file" ]
}

# Lista profiles disponíveis (apenas nomes, sem .profile)
adm_env_list_profiles() {
    local dir="${ADM_PROFILES_DIR:-${ADM_ROOT:-/usr/src/adm}/profiles}"

    if [ ! -d "$dir" ]; then
        adm_log_warn "Diretório de profiles não existe: $dir"
        return 0
    fi

    local f name found=0
    for f in "$dir"/*.profile; do
        [ -e "$f" ] || continue
        name="${f##*/}"
        name="${name%.profile}"
        printf '%s\n' "$name"
        found=1
    done

    if [ $found -eq 0 ]; then
        adm_log_warn "Nenhum profile encontrado em: $dir"
    fi
}

#==============================================================================
# PARTE 5 – Criação de profiles padrão
#==============================================================================

# Cria conteúdo default para um profile específico (minimal/normal/aggressive/outros)
adm_env_profile_write_default() {
    if [ $# -ne 2 ]; then
        adm_log_error "adm_env_profile_write_default requer 2 argumentos: NOME ARQUIVO"
        return 1
    fi
    local name="$1"
    local file="$2"

    # Determina tipo pela convenção do nome
    local kind
    case "$name" in
        minimal|minimal-*)
            kind="minimal"
            ;;
        aggressive|aggressive-*)
            kind="aggressive"
            ;;
        normal|default)
            kind="normal"
            ;;
        *)
            kind="custom"
            ;;
    esac

    adm_env_load_global_config

    # CFLAGS base para cada tipo
    local pf_cflags pf_cxxflags pf_ldflags pf_docs pf_tests pf_lto pf_debug pf_libc
    case "$kind" in
        minimal)
            pf_cflags="-O2 -pipe"
            pf_cxxflags="-O2 -pipe"
            pf_ldflags=""
            pf_docs="no"
            pf_tests="no"
            pf_lto="no"
            pf_debug="no"
            pf_libc="auto"
            ;;
        normal)
            pf_cflags="${ADM_CONF_cflags_default:- -O2 -pipe}"
            pf_cxxflags="${ADM_CONF_cxxflags_default:- -O2 -pipe}"
            pf_ldflags="${ADM_CONF_ldflags_default:-}"
            pf_docs="auto"
            pf_tests="auto"
            pf_lto="no"
            pf_debug="no"
            pf_libc="auto"
            ;;
        aggressive)
            pf_cflags="-O3 -pipe -march=native -mtune=native"
            pf_cxxflags="-O3 -pipe -march=native -mtune=native"
            pf_ldflags="-Wl,-O1"
            pf_docs="auto"
            pf_tests="auto"
            pf_lto="yes"
            pf_debug="no"
            pf_libc="auto"
            ;;
        custom|*)
            pf_cflags="${ADM_CONF_cflags_default:- -O2 -pipe}"
            pf_cxxflags="${ADM_CONF_cxxflags_default:- -O2 -pipe}"
            pf_ldflags="${ADM_CONF_ldflags_default:-}"
            pf_docs="auto"
            pf_tests="auto"
            pf_lto="no"
            pf_debug="no"
            pf_libc="auto"
            ;;
    esac

    {
        printf 'name=%s\n'        "$name"
        printf 'description=%s\n' "Profile %s do ADM" "$kind"
        printf 'libc=%s\n'        "$pf_libc"
        printf 'cflags=%s\n'      "$pf_cflags"
        printf 'cxxflags=%s\n'    "$pf_cxxflags"
        printf 'ldflags=%s\n'     "$pf_ldflags"
        printf 'docs=%s\n'        "$pf_docs"
        printf 'tests=%s\n'       "$pf_tests"
        printf 'lto=%s\n'         "$pf_lto"
        printf 'debug=%s\n'       "$pf_debug"
    } >"$file" 2>/dev/null || {
        adm_log_error "Falha ao escrever profile default em: $file"
        return 1
    }

    return 0
}

# Cria profile (arquivo) se não existir.
# Uso: adm_env_create_profile NOME [tipo]
adm_env_create_profile() {
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then
        adm_log_error "adm_env_create_profile requer 1 ou 2 argumentos: NOME [TIPO]"
        return 1
    fi
    local name="$1"
    local type="${2:-}"

    if [ -z "$name" ]; then
        adm_log_error "adm_env_create_profile: nome não pode ser vazio."
        return 1
    fi

    local file
    file="$(adm_env_profile_file "$name")" || return 1

    if [ -f "$file" ]; then
        adm_log_info "Profile '%s' já existe: %s" "$name" "$file"
        return 0
    fi

    # Garante diretório
    if ! adm_mkdir_p "$(dirname "$file")"; then
        adm_log_error "Não foi possível criar diretório do profile: $(dirname "$file")"
        return 1
    fi

    # Se type foi fornecido, podemos usar para o conteúdo; se não, usa heurística sobre name.
    if [ -n "$type" ]; then
        case "$type" in
            minimal|normal|aggressive|custom)
                # nada, usado em profile_write_default
                ;;
            *)
                adm_log_warn "Tipo de profile desconhecido: '%s'; usando 'custom'." "$type"
                type="custom"
                ;;
        esac
    fi

    adm_env_profile_write_default "$name" "$file" || return 1

    adm_log_info "Profile criado: %s (%s)" "$name" "$file"
    return 0
}

# Garante que pelo menos "minimal", "normal" e "aggressive" existam
adm_env_ensure_default_profiles() {
    adm_env_create_profile "minimal"    "minimal"    || :
    adm_env_create_profile "normal"     "normal"     || :
    adm_env_create_profile "aggressive" "aggressive" || :
}

#==============================================================================
# PARTE 6 – Current profile: leitura, escrita e exibição
#==============================================================================

# Caminho do arquivo current_profile
adm_env_current_profile_file() {
    printf '%s/current_profile\n' "${ADM_STATE_DIR:-${ADM_ROOT:-/usr/src/adm}/state}"
}

# Define current profile (grava em state/current_profile)
adm_env_set_current_profile() {
    if [ $# -ne 1 ]; then
        adm_log_error "adm_env_set_current_profile requer 1 argumento: NOME_PROFILE"
        return 1
    fi
    local name="$1"

    if [ -z "$name" ]; then
        adm_log_error "adm_env_set_current_profile: nome não pode ser vazio."
        return 1
    fi

    if ! adm_env_profile_exists "$name"; then
        adm_log_error "Profile '%s' não existe; não é possível setar como atual." "$name"
        return 1
    fi

    local file
    file="$(adm_env_current_profile_file)"
    if ! adm_mkdir_p "$(dirname "$file")"; then
        adm_log_error "Falha ao criar diretório do current_profile: $(dirname "$file")"
        return 1
    fi

    echo "$name" >"$file" 2>/dev/null || {
        adm_log_error "Não foi possível gravar current_profile em: $file"
        return 1
    }

    ADM_PROFILE_ACTIVE="$name"
    export ADM_PROFILE_ACTIVE
    adm_log_info "Profile atual definido para: %s" "$name"
    return 0
}

# Obtém profile atual (ou define um padrão, se necessário).
# Imprime o nome no stdout e também exporta ADM_PROFILE_ACTIVE.
adm_env_get_current_profile() {
    local file name

    file="$(adm_env_current_profile_file)"

    if [ -f "$file" ]; then
        name="$(cat "$file" 2>/dev/null | head -n1 | tr -d '[:space:]')" || name=""
    else
        name=""
    fi

    # Se não há current_profile, escolhe "normal" ou outro existente
    if [ -z "$name" ]; then
        adm_log_info "Nenhum profile atual definido; usando 'normal' como padrão."
        adm_env_ensure_default_profiles
        if adm_env_profile_exists "normal"; then
            name="normal"
            adm_env_set_current_profile "$name" || :
        else
            # fallback: tenta qualquer profile existente
            name="$(adm_env_list_profiles | head -n1)"
            if [ -n "$name" ]; then
                adm_env_set_current_profile "$name" || :
            else
                adm_log_error "Nenhum profile disponível; criando 'normal'."
                adm_env_create_profile "normal" "normal" || :
                name="normal"
                adm_env_set_current_profile "$name" || :
            fi
        fi
    else
        # current_profile file existe; checa se profile existe
        if ! adm_env_profile_exists "$name"; then
            adm_log_warn "Profile atual '%s' não existe mais; recriando 'normal'." "$name"
            adm_env_ensure_default_profiles
            name="normal"
            adm_env_set_current_profile "$name" || :
        fi
    fi

    ADM_PROFILE_ACTIVE="$name"
    export ADM_PROFILE_ACTIVE
    printf '%s\n' "$name"
    return 0
}

# Mostra conteúdo de um profile
adm_env_show_profile() {
    local name file

    if [ $# -eq 0 ]; then
        name="$(adm_env_get_current_profile)"
    elif [ $# -eq 1 ]; then
        name="$1"
    else
        adm_log_error "adm_env_show_profile requer 0 ou 1 argumento: [NOME_PROFILE]"
        return 1
    fi

    file="$(adm_env_profile_file "$name")" || return 1
    if [ ! -f "$file" ]; then
        adm_log_error "Profile '%s' não encontrado: %s" "$name" "$file"
        return 1
    fi

    adm_log_info "Profile: %s (%s)" "$name" "$file"
    cat "$file"
    return 0
}

#==============================================================================
# PARTE 7 – Aplicar profile ao ambiente de build
#==============================================================================

# Aplica profile ao ambiente.
# Uso: adm_env_apply_profile [NOME_PROFILE]
# Se NOME_PROFILE for omitido, usa o current_profile.
adm_env_apply_profile() {
    local name file
    if [ $# -eq 0 ]; then
        name="$(adm_env_get_current_profile)"
    elif [ $# -eq 1 ]; then
        name="$1"
        adm_env_set_current_profile "$name" || return 1
    else
        adm_log_error "adm_env_apply_profile requer 0 ou 1 argumento: [NOME_PROFILE]"
        return 1
    fi

    file="$(adm_env_profile_file "$name")" || return 1
    if [ ! -f "$file" ]; then
        adm_log_error "Profile '%s' não encontrado para aplicar: %s" "$name" "$file"
        return 1
    fi

    # Lê config global + triplets + libc default
    adm_env_load_global_config
    adm_env_init_triplets

    # Lê profile com prefixo
    if command -v adm_read_kv_file >/dev/null 2>&1; then
        adm_read_kv_file "$file" "ADM_PROFILE_RAW_" || {
            adm_log_error "Falha ao ler profile: %s" "$file"
            return 1
        }
    else
        adm_log_error "adm_read_kv_file não disponível; não foi possível processar profile: %s" "$file"
        return 1
    fi

    # Determina libc efetiva
    local libc_req libc_eff
    libc_req="${ADM_PROFILE_RAW_libc:-auto}"
    libc_eff="$(adm_env_determine_libc "$libc_req")"
    ADM_LIBC="$libc_eff"
    export ADM_LIBC

    # Determina CFLAGS/CXXFLAGS/LDFLAGS
    local pf_cflags pf_cxxflags pf_ldflags
    pf_cflags="${ADM_PROFILE_RAW_cflags:-$ADM_CONF_cflags_default}"
    pf_cxxflags="${ADM_PROFILE_RAW_cxxflags:-$ADM_CONF_cxxflags_default}"
    pf_ldflags="${ADM_PROFILE_RAW_ldflags:-$ADM_CONF_ldflags_default}"

    CFLAGS="$pf_cflags"
    CXXFLAGS="$pf_cxxflags"
    LDFLAGS="$pf_ldflags"

    # Makeflags (jobs)
    local jobs
    jobs="${ADM_CONF_jobs_default:-0}"
    if [ "$jobs" -le 0 ] 2>/dev/null; then
        if command -v nproc >/dev/null 2>&1; then
            jobs="$(nproc 2>/dev/null || echo 1)"
        else
            jobs=1
        fi
    fi
    MAKEFLAGS="-j${jobs}"

    # Flags adicionais: docs/tests/lto/debug
    ADM_PROFILE_DOCS="${ADM_PROFILE_RAW_docs:-$ADM_CONF_docs_default}"
    ADM_PROFILE_TESTS="${ADM_PROFILE_RAW_tests:-$ADM_CONF_tests_default}"
    ADM_PROFILE_LTO="${ADM_PROFILE_RAW_lto:-no}"
    ADM_PROFILE_DEBUG="${ADM_PROFILE_RAW_debug:-no}"

    # Exporta tudo
    export CFLAGS CXXFLAGS LDFLAGS MAKEFLAGS
    export ADM_PROFILE_DOCS ADM_PROFILE_TESTS ADM_PROFILE_LTO ADM_PROFILE_DEBUG
    export ADM_PROFILE_ACTIVE

    adm_log_info "Profile aplicado: %s (libc=%s, jobs=%s)" "$ADM_PROFILE_ACTIVE" "$ADM_LIBC" "$jobs"
    adm_log_debug "CFLAGS=\"$CFLAGS\""
    adm_log_debug "CXXFLAGS=\"$CXXFLAGS\""
    adm_log_debug "LDFLAGS=\"$LDFLAGS\""
    adm_log_debug "MAKEFLAGS=\"$MAKEFLAGS\""

    return 0
}

#==============================================================================
# PARTE 8 – Inicialização automática
#==============================================================================

adm_env_init() {
    adm_env_load_global_config
    adm_env_ensure_default_profiles
    # Não aplica profile automaticamente aqui; isso é feito quando necessário,
    # por exemplo, logo antes de um build (build.sh chama adm_env_apply_profile).
}

# Executa inicialização básica
adm_env_init
