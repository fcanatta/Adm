#!/usr/bin/env bash
# metafile.sh - Leitura, validação e escrita de metafiles do adm
#
# Formato esperado do metafile (chave=valor, sem campos extras):
#
#   name=programa
#   version=1.2.3
#   category=apps|libs|sys|dev|x11|wayland|
#   run_deps=dep1,dep2
#   build_deps=depA,depB
#   opt_deps=depX,depY
#   num_builds=0
#   description=Descrição curta
#   homepage=https://...
#   maintainer=Nome <email>
#   sha256sums=sum1,sum2    # ou
#   md5sum=sum1,sum2
#   sources=url1,url2
#
# - Campos obrigatórios:
#     name, version, category, description, homepage, maintainer,
#     sources, (sha256sums ou md5sum, mas nunca ambos)
# - Campos opcionais podem ficar vazios, mas se existirem são validados.
#
# Uso típico em outros scripts:
#
#   . /usr/src/adm/scripts/ui.sh       # opcional
#   . /usr/src/adm/scripts/metafile.sh
#
#   adm_meta_load "/usr/src/adm/repo/apps/bash/metafile" || adm_ui_die "Metafile inválido"
#   echo "Nome: $MF_NAME"
#   echo "Versão: $MF_VERSION"
#   adm_meta_inc_builds
#   adm_meta_write "/usr/src/adm/repo/apps/bash/metafile"   # salva de volta
#
# Este script NUNCA usa set -e, para não quebrar scripts chamadores.
# ==========================
# Integração com ui.sh (opcional)
# ==========================
_META_HAVE_UI=0

if declare -F adm_ui_log_info >/dev/null 2>&1; then
    _META_HAVE_UI=1
fi

_meta_log() {
    # $1 = nível (INFO|WARN|ERROR|DEBUG)
    # $2... = mensagem
    local level="$1"; shift || true
    local msg="$*"

    if [ "$_META_HAVE_UI" -eq 1 ]; then
        case "$level" in
            INFO)  adm_ui_log_info  "$msg" ;;
            WARN)  adm_ui_log_warn  "$msg" ;;
            ERROR) adm_ui_log_error "$msg" ;;
            DEBUG) adm_ui_log_info  "[DEBUG] $msg" ;;
            *)     adm_ui_log_info  "$msg" ;;
        esac
    else
        # fallback para stderr, sem cores
        printf 'metafile[%s]: %s\n' "$level" "$msg" >&2
    fi
}

# ==========================
# Estado global do metafile
# ==========================

# Variáveis públicas (usadas por outros scripts)
MF_NAME=""
MF_VERSION=""
MF_CATEGORY=""
MF_RUN_DEPS=""
MF_BUILD_DEPS=""
MF_OPT_DEPS=""
MF_NUM_BUILDS=""
MF_DESCRIPTION=""
MF_HOMEPAGE=""
MF_MAINTAINER=""
MF_SHA256SUMS=""
MF_MD5SUM=""
MF_SOURCES=""

# Versões em array, convenientes
MF_RUN_DEPS_ARR=()
MF_BUILD_DEPS_ARR=()
MF_OPT_DEPS_ARR=()
MF_SOURCES_ARR=()
MF_SHA256SUMS_ARR=()
MF_MD5SUM_ARR=()

# Arquivo atualmente carregado
MF_FILE_PATH=""

# Flags internas para detectar duplicatas
_MF_SEEN_NAME=0
_MF_SEEN_VERSION=0
_MF_SEEN_CATEGORY=0
_MF_SEEN_RUN_DEPS=0
_MF_SEEN_BUILD_DEPS=0
_MF_SEEN_OPT_DEPS=0
_MF_SEEN_NUM_BUILDS=0
_MF_SEEN_DESCRIPTION=0
_MF_SEEN_HOMEPAGE=0
_MF_SEEN_MAINTAINER=0
_MF_SEEN_SHA256SUMS=0
_MF_SEEN_MD5SUM=0
_MF_SEEN_SOURCES=0

# ==========================
# Utilitários internos
# ==========================

_adm_meta_reset_state() {
    MF_NAME=""
    MF_VERSION=""
    MF_CATEGORY=""
    MF_RUN_DEPS=""
    MF_BUILD_DEPS=""
    MF_OPT_DEPS=""
    MF_NUM_BUILDS=""
    MF_DESCRIPTION=""
    MF_HOMEPAGE=""
    MF_MAINTAINER=""
    MF_SHA256SUMS=""
    MF_MD5SUM=""
    MF_SOURCES=""

    MF_RUN_DEPS_ARR=()
    MF_BUILD_DEPS_ARR=()
    MF_OPT_DEPS_ARR=()
    MF_SOURCES_ARR=()
    MF_SHA256SUMS_ARR=()
    MF_MD5SUM_ARR=()

    MF_FILE_PATH=""

    _MF_SEEN_NAME=0
    _MF_SEEN_VERSION=0
    _MF_SEEN_CATEGORY=0
    _MF_SEEN_RUN_DEPS=0
    _MF_SEEN_BUILD_DEPS=0
    _MF_SEEN_OPT_DEPS=0
    _MF_SEEN_NUM_BUILDS=0
    _MF_SEEN_DESCRIPTION=0
    _MF_SEEN_HOMEPAGE=0
    _MF_SEEN_MAINTAINER=0
    _MF_SEEN_SHA256SUMS=0
    _MF_SEEN_MD5SUM=0
    _MF_SEEN_SOURCES=0
}

_adm_meta_trim() {
    # Remove espaços em branco no início e fim da string.
    # Uso: local x; x="$(_adm_meta_trim "$valor")"
    local s="$*"

    # Remove espaços iniciais
    s="${s#"${s%%[![:space:]]*}"}"
    # Remove espaços finais
    s="${s%"${s##*[![:space:]]}"}"

    printf '%s' "$s"
}

_adm_meta_split_list() {
    # Divide uma lista separada por vírgulas em um array.
    # Uso:
    #   _adm_meta_split_list "MINHA_ARRAY" "$string"
    local var_name="$1"; shift || true
    local list="$*"
    local IFS=','

    # Limpa o array anterior
    eval "$var_name=()"

    # Se vazio, não faz nada
    if [ -z "$list" ]; then
        return 0
    fi

    # shellcheck disable=SC2206
    local parts=($list)
    local trimmed
    local new_arr=()
    local item

    for item in "${parts[@]}"; do
        trimmed="$(_adm_meta_trim "$item")"
        [ -n "$trimmed" ] && new_arr+=("$trimmed")
    done

    # Atribui ao array de destino
    eval "$var_name=(${new_arr[@]@Q})"
}

_adm_meta_is_number() {
    # Retorna 0 se for número inteiro não-negativo, 1 caso contrário.
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *)           return 0 ;;
    esac
}

_adm_meta_validate_category() {
    case "$MF_CATEGORY" in
        apps|libs|sys|dev|x11|wayland)
            return 0
            ;;
        *)
            _meta_log "ERROR" "Categoria inválida no metafile: '$MF_CATEGORY' (esperado: apps|libs|sys|dev|x11|wayland)"
            return 1
            ;;
    esac
}

# ==========================
# Validação completa do metafile
# ==========================

adm_meta_validate() {
    local ok=0

    # Campos obrigatórios
    if [ -z "$MF_NAME" ]; then
        _meta_log "ERROR" "Campo obrigatório 'name' ausente ou vazio"
        ok=1
    fi
    if [ -z "$MF_VERSION" ]; then
        _meta_log "ERROR" "Campo obrigatório 'version' ausente ou vazio"
        ok=1
    fi
    if [ -z "$MF_CATEGORY" ]; then
        _meta_log "ERROR" "Campo obrigatório 'category' ausente ou vazio"
        ok=1
    else
        _adm_meta_validate_category || ok=1
    fi
    if [ -z "$MF_DESCRIPTION" ]; then
        _meta_log "ERROR" "Campo obrigatório 'description' ausente ou vazio"
        ok=1
    fi
    if [ -z "$MF_HOMEPAGE" ]; then
        _meta_log "ERROR" "Campo obrigatório 'homepage' ausente ou vazio"
        ok=1
    fi
    if [ -z "$MF_MAINTAINER" ]; then
        _meta_log "ERROR" "Campo obrigatório 'maintainer' ausente ou vazio"
        ok=1
    fi

    # Sources obrigatórios
    if [ -z "$MF_SOURCES" ]; then
        _meta_log "ERROR" "Campo obrigatório 'sources' ausente ou vazio"
        ok=1
    fi

    # sha256sums / md5sum
    if [ -n "$MF_SHA256SUMS" ] && [ -n "$MF_MD5SUM" ]; then
        _meta_log "ERROR" "Use apenas 'sha256sums' OU 'md5sum' no metafile, não ambos"
        ok=1
    elif [ -z "$MF_SHA256SUMS" ] && [ -z "$MF_MD5SUM" ]; then
        _meta_log "ERROR" "É obrigatório definir 'sha256sums' OU 'md5sum' no metafile"
        ok=1
    fi

    # num_builds
    if [ -z "$MF_NUM_BUILDS" ]; then
        MF_NUM_BUILDS="0"
    fi
    if ! _adm_meta_is_number "$MF_NUM_BUILDS"; then
        _meta_log "ERROR" "Campo 'num_builds' deve ser inteiro não-negativo, valor encontrado: '$MF_NUM_BUILDS'"
        ok=1
    fi

    # Converter listas em arrays
    _adm_meta_split_list "MF_RUN_DEPS_ARR" "$MF_RUN_DEPS"
    _adm_meta_split_list "MF_BUILD_DEPS_ARR" "$MF_BUILD_DEPS"
    _adm_meta_split_list "MF_OPT_DEPS_ARR" "$MF_OPT_DEPS"
    _adm_meta_split_list "MF_SOURCES_ARR" "$MF_SOURCES"
    _adm_meta_split_list "MF_SHA256SUMS_ARR" "$MF_SHA256SUMS"
    _adm_meta_split_list "MF_MD5SUM_ARR" "$MF_MD5SUM"

    # Checar quantidades: número de checksums deve bater com sources
    local n_sources="${#MF_SOURCES_ARR[@]}"
    local n_sha="${#MF_SHA256SUMS_ARR[@]}"
    local n_md5="${#MF_MD5SUM_ARR[@]}"

    if [ "$n_sources" -eq 0 ]; then
        _meta_log "ERROR" "Campo 'sources' foi definido, mas resultou em lista vazia após parsing"
        ok=1
    fi

    if [ -n "$MF_SHA256SUMS" ]; then
        if [ "$n_sha" -ne "$n_sources" ]; then
            _meta_log "ERROR" "Quantidade de sha256sums ($n_sha) diferente da quantidade de sources ($n_sources)"
            ok=1
        fi
    fi
    if [ -n "$MF_MD5SUM" ]; then
        if [ "$n_md5" -ne "$n_sources" ]; then
            _meta_log "ERROR" "Quantidade de md5sum ($n_md5) diferente da quantidade de sources ($n_sources)"
            ok=1
        fi
    fi

    if [ "$ok" -ne 0 ]; then
        _meta_log "ERROR" "Metafile inválido${MF_FILE_PATH:+: $MF_FILE_PATH}"
        return 1
    fi

    return 0
}

# ==========================
# Leitura de metafile
# ==========================

adm_meta_load() {
    # Carrega e valida um metafile.
    # Uso:
    #   adm_meta_load "/caminho/para/metafile"
    #
    # Em caso de sucesso:
    #   - popula MF_* e arrays
    #   - retorna 0
    # Em caso de erro:
    #   - loga mensagens detalhadas
    #   - retorna !=0
    local file="$1"

    if [ -z "$file" ]; then
        _meta_log "ERROR" "adm_meta_load: caminho do metafile não informado"
        return 1
    fi

    if [ ! -f "$file" ]; then
        _meta_log "ERROR" "Metafile não encontrado: $file"
        return 1
    fi

    if [ ! -r "$file" ]; then
        _meta_log "ERROR" "Metafile não é legível: $file"
        return 1
    fi

    _adm_meta_reset_state
    MF_FILE_PATH="$file"

    local line
    local lineno=0
    local raw

    # Leitura linha a linha, preservando linhas sem newline final
    while IFS= read -r raw || [ -n "$raw" ]; do
        lineno=$((lineno + 1))
        line="$raw"

        # Remove CR no final (para arquivos CRLF)
        line="${line%$'\r'}"

        # Remove espaços laterais
        line="$(_adm_meta_trim "$line")"

        # Ignora vazias e comentários
        if [ -z "$line" ] || [[ "$line" == \#* ]]; then
            continue
        fi

        # Exige "chave=valor"
        case "$line" in
            *=*) ;;
            *)
                _meta_log "ERROR" "Linha $lineno inválida em $file (esperado chave=valor): '$line'"
                return 1
                ;;
        esac

        local key="${line%%=*}"
        local value="${line#*=}"

        key="$(_adm_meta_trim "$key")"
        value="$(_adm_meta_trim "$value")"

        if [ -z "$key" ]; then
            _meta_log "ERROR" "Linha $lineno em $file tem chave vazia"
            return 1
        fi

        case "$key" in
            name)
                if [ "$_MF_SEEN_NAME" -ne 0 ]; then
                    _meta_log "ERROR" "Campo duplicado 'name' na linha $lineno em $file"
                    return 1
                fi
                _MF_SEEN_NAME=1
                MF_NAME="$value"
                ;;
            version)
                if [ "$_MF_SEEN_VERSION" -ne 0 ]; then
                    _meta_log "ERROR" "Campo duplicado 'version' na linha $lineno em $file"
                    return 1
                fi
                _MF_SEEN_VERSION=1
                MF_VERSION="$value"
                ;;
            category)
                if [ "$_MF_SEEN_CATEGORY" -ne 0 ]; then
                    _meta_log "ERROR" "Campo duplicado 'category' na linha $lineno em $file"
                    return 1
                fi
                _MF_SEEN_CATEGORY=1
                MF_CATEGORY="$value"
                ;;
            run_deps)
                if [ "$_MF_SEEN_RUN_DEPS" -ne 0 ]; then
                    _meta_log "ERROR" "Campo duplicado 'run_deps' na linha $lineno em $file"
                    return 1
                fi
                _MF_SEEN_RUN_DEPS=1
                MF_RUN_DEPS="$value"
                ;;
            build_deps)
                if [ "$_MF_SEEN_BUILD_DEPS" -ne 0 ]; then
                    _meta_log "ERROR" "Campo duplicado 'build_deps' na linha $lineno em $file"
                    return 1
                fi
                _MF_SEEN_BUILD_DEPS=1
                MF_BUILD_DEPS="$value"
                ;;
            opt_deps)
                if [ "$_MF_SEEN_OPT_DEPS" -ne 0 ]; then
                    _meta_log "ERROR" "Campo duplicado 'opt_deps' na linha $lineno em $file"
                    return 1
                fi
                _MF_SEEN_OPT_DEPS=1
                MF_OPT_DEPS="$value"
                ;;
            num_builds)
                if [ "$_MF_SEEN_NUM_BUILDS" -ne 0 ]; then
                    _meta_log "ERROR" "Campo duplicado 'num_builds' na linha $lineno em $file"
                    return 1
                fi
                _MF_SEEN_NUM_BUILDS=1
                MF_NUM_BUILDS="$value"
                ;;
            description)
                if [ "$_MF_SEEN_DESCRIPTION" -ne 0 ]; then
                    _meta_log "ERROR" "Campo duplicado 'description' na linha $lineno em $file"
                    return 1
                fi
                _MF_SEEN_DESCRIPTION=1
                MF_DESCRIPTION="$value"
                ;;
            homepage)
                if [ "$_MF_SEEN_HOMEPAGE" -ne 0 ]; then
                    _meta_log "ERROR" "Campo duplicado 'homepage' na linha $lineno em $file"
                    return 1
                fi
                _MF_SEEN_HOMEPAGE=1
                MF_HOMEPAGE="$value"
                ;;
            maintainer)
                if [ "$_MF_SEEN_MAINTAINER" -ne 0 ]; then
                    _meta_log "ERROR" "Campo duplicado 'maintainer' na linha $lineno em $file"
                    return 1
                fi
                _MF_SEEN_MAINTAINER=1
                MF_MAINTAINER="$value"
                ;;
            sha256sums)
                if [ "$_MF_SEEN_SHA256SUMS" -ne 0 ]; then
                    _meta_log "ERROR" "Campo duplicado 'sha256sums' na linha $lineno em $file"
                    return 1
                fi
                _MF_SEEN_SHA256SUMS=1
                MF_SHA256SUMS="$value"
                ;;
            md5sum)
                if [ "$_MF_SEEN_MD5SUM" -ne 0 ]; then
                    _meta_log "ERROR" "Campo duplicado 'md5sum' na linha $lineno em $file"
                    return 1
                fi
                _MF_SEEN_MD5SUM=1
                MF_MD5SUM="$value"
                ;;
            sources)
                if [ "$_MF_SEEN_SOURCES" -ne 0 ]; then
                    _meta_log "ERROR" "Campo duplicado 'sources' na linha $lineno em $file"
                    return 1
                fi
                _MF_SEEN_SOURCES=1
                MF_SOURCES="$value"
                ;;
            *)
                _meta_log "WARN" "Chave desconhecida '$key' ignorada (linha $lineno em $file)"
                ;;
        esac
    done < "$file"

    # Validação final
    adm_meta_validate || return 1

    _meta_log "INFO" "Metafile carregado com sucesso: $file (name=$MF_NAME, version=$MF_VERSION)"
    return 0
}

# ==========================
# Escrita de metafile
# ==========================

adm_meta_write() {
    # Escreve o estado atual MF_* em um arquivo, sobrescrevendo-o.
    #
    # Uso:
    #   adm_meta_write "/caminho/para/metafile"
    #
    # Antes de gravar, roda adm_meta_validate. Se inválido, não escreve.
    local file="$1"

    if [ -z "$file" ]; then
        _meta_log "ERROR" "adm_meta_write: caminho do metafile não informado"
        return 1
    fi

    if ! adm_meta_validate; then
        _meta_log "ERROR" "adm_meta_write: não escrevendo metafile inválido ($file)"
        return 1
    fi

    local dir
    dir="$(dirname -- "$file")"

    if ! mkdir -p "$dir" 2>/dev/null; then
        _meta_log "ERROR" "adm_meta_write: não foi possível criar diretório: $dir"
        return 1
    fi

    # Escreve em arquivo temporário e depois faz mv atômico
    local tmp="${file}.tmp.$$"

    {
        printf 'name=%s\n'        "$MF_NAME"
        printf 'version=%s\n'     "$MF_VERSION"
        printf 'category=%s\n'    "$MF_CATEGORY"
        printf 'run_deps=%s\n'    "$MF_RUN_DEPS"
        printf 'build_deps=%s\n'  "$MF_BUILD_DEPS"
        printf 'opt_deps=%s\n'    "$MF_OPT_DEPS"
        printf 'num_builds=%s\n'  "$MF_NUM_BUILDS"
        printf 'description=%s\n' "$MF_DESCRIPTION"
        printf 'homepage=%s\n'    "$MF_HOMEPAGE"
        printf 'maintainer=%s\n'  "$MF_MAINTAINER"

        if [ -n "$MF_SHA256SUMS" ]; then
            printf 'sha256sums=%s\n' "$MF_SHA256SUMS"
        elif [ -n "$MF_MD5SUM" ]; then
            printf 'md5sum=%s\n'     "$MF_MD5SUM"
        else
            # Isso não deveria acontecer porque adm_meta_validate garante um deles
            _meta_log "ERROR" "adm_meta_write: nem sha256sums nem md5sum definidos após validação"
            rm -f "$tmp" 2>/dev/null || true
            return 1
        fi

        printf 'sources=%s\n' "$MF_SOURCES"
    } > "$tmp" || {
        _meta_log "ERROR" "adm_meta_write: falha ao escrever temporário: $tmp"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    }

    if ! mv -f "$tmp" "$file" 2>/dev/null; then
        _meta_log "ERROR" "adm_meta_write: falha ao mover temporário para destino: $file"
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi

    MF_FILE_PATH="$file"
    _meta_log "INFO" "Metafile escrito com sucesso em: $file"
    return 0
}

# ==========================
# Funções auxiliares extras
# ==========================

adm_meta_inc_builds() {
    # Incrementa num_builds (em memória).
    # Não grava no arquivo automaticamente; chame adm_meta_write para persistir.
    if ! _adm_meta_is_number "$MF_NUM_BUILDS"; then
        _meta_log "ERROR" "adm_meta_inc_builds: num_builds atual não é número: '$MF_NUM_BUILDS'"
        return 1
    fi
    MF_NUM_BUILDS=$((MF_NUM_BUILDS + 1))
    _meta_log "INFO" "num_builds incrementado para $MF_NUM_BUILDS (name=$MF_NAME)"
    return 0
}

adm_meta_get_field() {
    # Imprime o valor bruto de um campo.
    # Uso:
    #   adm_meta_get_field name
    #   adm_meta_get_field version
    #
    # Retorna 0 se campo conhecido, 1 se desconhecido.
    local key="$1"
    case "$key" in
        name)        printf '%s\n' "$MF_NAME" ;;
        version)     printf '%s\n' "$MF_VERSION" ;;
        category)    printf '%s\n' "$MF_CATEGORY" ;;
        run_deps)    printf '%s\n' "$MF_RUN_DEPS" ;;
        build_deps)  printf '%s\n' "$MF_BUILD_DEPS" ;;
        opt_deps)    printf '%s\n' "$MF_OPT_DEPS" ;;
        num_builds)  printf '%s\n' "$MF_NUM_BUILDS" ;;
        description) printf '%s\n' "$MF_DESCRIPTION" ;;
        homepage)    printf '%s\n' "$MF_HOMEPAGE" ;;
        maintainer)  printf '%s\n' "$MF_MAINTAINER" ;;
        sha256sums)  printf '%s\n' "$MF_SHA256SUMS" ;;
        md5sum)      printf '%s\n' "$MF_MD5SUM" ;;
        sources)     printf '%s\n' "$MF_SOURCES" ;;
        *)
            _meta_log "ERROR" "adm_meta_get_field: campo desconhecido '$key'"
            return 1
            ;;
    esac
    return 0
}

adm_meta_set_field() {
    # Define um campo em memória (não grava no arquivo).
    # Uso:
    #   adm_meta_set_field version "1.2.4"
    #
    # Validação completa só acontece em adm_meta_validate/adm_meta_write.
    local key="$1"; shift || true
    local value="$*"

    case "$key" in
        name)        MF_NAME="$value" ;;
        version)     MF_VERSION="$value" ;;
        category)    MF_CATEGORY="$value" ;;
        run_deps)    MF_RUN_DEPS="$value" ;;
        build_deps)  MF_BUILD_DEPS="$value" ;;
        opt_deps)    MF_OPT_DEPS="$value" ;;
        num_builds)  MF_NUM_BUILDS="$value" ;;
        description) MF_DESCRIPTION="$value" ;;
        homepage)    MF_HOMEPAGE="$value" ;;
        maintainer)  MF_MAINTAINER="$value" ;;
        sha256sums)  MF_SHA256SUMS="$value"; MF_MD5SUM=""; ;;
        md5sum)      MF_MD5SUM="$value"; MF_SHA256SUMS=""; ;;
        sources)     MF_SOURCES="$value" ;;
        *)
            _meta_log "ERROR" "adm_meta_set_field: campo desconhecido '$key'"
            return 1
            ;;
    esac
    _meta_log "INFO" "Campo '$key' atualizado para '$value'"
    return 0
}

adm_meta_debug_dump() {
    # Imprime todo o estado do metafile (útil para debug)
    _meta_log "INFO" "Dump do metafile carregado:"
    printf '  MF_FILE_PATH   = %s\n' "$MF_FILE_PATH"
    printf '  name           = %s\n' "$MF_NAME"
    printf '  version        = %s\n' "$MF_VERSION"
    printf '  category       = %s\n' "$MF_CATEGORY"
    printf '  run_deps       = %s\n' "$MF_RUN_DEPS"
    printf '  build_deps     = %s\n' "$MF_BUILD_DEPS"
    printf '  opt_deps       = %s\n' "$MF_OPT_DEPS"
    printf '  num_builds     = %s\n' "$MF_NUM_BUILDS"
    printf '  description    = %s\n' "$MF_DESCRIPTION"
    printf '  homepage       = %s\n' "$MF_HOMEPAGE"
    printf '  maintainer     = %s\n' "$MF_MAINTAINER"
    printf '  sha256sums     = %s\n' "$MF_SHA256SUMS"
    printf '  md5sum         = %s\n' "$MF_MD5SUM"
    printf '  sources        = %s\n' "$MF_SOURCES"

    printf '  RUN_DEPS_ARR   ='; printf ' %s' "${MF_RUN_DEPS_ARR[@]}"; echo
    printf '  BUILD_DEPS_ARR ='; printf ' %s' "${MF_BUILD_DEPS_ARR[@]}"; echo
    printf '  OPT_DEPS_ARR   ='; printf ' %s' "${MF_OPT_DEPS_ARR[@]}"; echo
    printf '  SOURCES_ARR    ='; printf ' %s' "${MF_SOURCES_ARR[@]}"; echo
    printf '  SHA256SUMS_ARR ='; printf ' %s' "${MF_SHA256SUMS_ARR[@]}"; echo
    printf '  MD5SUM_ARR     ='; printf ' %s' "${MF_MD5SUM_ARR[@]}"; echo
}

# ==========================
# Modo de teste direto
# ==========================

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Teste simples se chamado diretamente: 
    #   ./metafile.sh /caminho/para/metafile
    if [ "$#" -ne 1 ]; then
        echo "Uso: $0 /caminho/para/metafile" >&2
        exit 1
    fi

    if ! adm_meta_load "$1"; then
        echo "Metafile inválido." >&2
        exit 1
    fi

    adm_meta_debug_dump
fi
