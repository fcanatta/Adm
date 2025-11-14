#!/usr/bin/env bash
# 13-binary-cache.sh
# Gerenciamento de cache de binários do ADM.
#
# Layout do cache:
#   $ADM_CACHE_BIN/<categoria>/<programa>/<versao>/<libc>/<target>/<profile>/<arch>/
#       pkg.tar.<ext>      (tarball com o conteúdo do DESTDIR)
#       manifest           (metadados do pacote em cache)
#
# Este script:
#   - cria diretórios de cache
#   - salva pacotes compilados no cache a partir de um DESTDIR
#   - verifica se há binário em cache válido
#   - extrai binário em cache para um DESTDIR
#   - invalida (remove) entradas de cache
#
# Não existem erros silenciosos: qualquer falha relevante é logada e aborta,
# exceto quando explicitamente documentado como comportamento esperado.
# ----------------------------------------------------------------------
# Requisitos e modo seguro
# ----------------------------------------------------------------------
if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERRO: 13-binary-cache.sh requer bash." >&2
    exit 1
fi

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "ERRO: 13-binary-cache.sh requer bash >= 4." >&2
    exit 1
fi

set -euo pipefail
IFS=$'\n\t'
# ----------------------------------------------------------------------
# Integração com ambiente e logging
# ----------------------------------------------------------------------
ADM_ROOT_DEFAULT="/usr/src/adm"
ADM_ROOT="${ADM_ROOT:-$ADM_ROOT_DEFAULT}"
ADM_CACHE="${ADM_CACHE:-$ADM_ROOT/cache}"
ADM_CACHE_BIN="${ADM_CACHE_BIN:-$ADM_CACHE/bin}"

# Vars que vêm do sistema de profiles (00-env-profiles.sh), se disponíveis
ADM_PROFILE="${ADM_PROFILE:-normal}"
ADM_TARGET="${ADM_TARGET:-$(uname -m 2>/dev/null || echo unknown)-unknown-linux-gnu}"
ADM_LIBC="${ADM_LIBC:-glibc}"

# Logging: usa 01-log-ui.sh se disponível; senão, fallback simples
if ! declare -F adm_info >/dev/null 2>&1; then
    adm_log_ts() { date +"%Y-%m-%d %H:%M:%S"; }
    adm_info()   { printf '[%s] [INFO] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_warn()   { printf '[%s] [WARN] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_error()  { printf '[%s] [ERRO] %s\n'  "$(adm_log_ts)" "$*" >&2; }
    adm_die()    { adm_error "$*"; exit 1; }
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

# Reuso dos sanitizadores do repo, se existirem; senão, definimos aqui
if ! declare -F adm_repo_sanitize_name >/dev/null 2>&1; then
    adm_repo_sanitize_name() {
        local n="${1:-}"
        if [ -z "$n" ]; then
            adm_die "Nome vazio não é permitido"
        fi
        if [[ ! "$n" =~ ^[A-Za-z0-9._+-]+$ ]]; then
            adm_die "Nome inválido '$n'. Use apenas [A-Za-z0-9._+-]."
        fi
        printf '%s' "$n"
    }
fi

if ! declare -F adm_repo_sanitize_category >/dev/null 2>&1; then
    adm_repo_sanitize_category() {
        local c="${1:-}"
        if [ -z "$c" ]; then
            adm_die "Categoria vazia não é permitida"
        fi
        if [[ ! "$c" =~ ^[A-Za-z0-9._+-]+$ ]]; then
            adm_die "Categoria inválida '$c'. Use apenas [A-Za-z0-9._+-]."
        fi
        printf '%s' "$c"
    }
fi

# ----------------------------------------------------------------------
# Inicialização do cache
# ----------------------------------------------------------------------

adm_cache_init() {
    adm_ensure_dir "$ADM_CACHE_BIN"
}

adm_cache_detect_arch() {
    local arch
    arch="$(uname -m 2>/dev/null || echo unknown)"
    printf '%s' "$arch"
}

adm_cache_detect_compressor() {
    # Define compressor e extensão de tarball.
    # Ordem de preferência: zstd, xz, gzip.
    # Retorna dois campos: "cmd ext"
    local cmd ext

    if command -v zstd >/dev/null 2>&1; then
        cmd="zstd"
        ext="tar.zst"
    elif command -v xz >/dev/null 2>&1; then
        cmd="xz"
        ext="tar.xz"
    else
        cmd="gzip"
        ext="tar.gz"
    fi

    printf '%s %s' "$cmd" "$ext"
}

# ----------------------------------------------------------------------
# Construção de paths dentro do cache
# ----------------------------------------------------------------------

adm_cache_pkg_dir() {
    # Retorna diretório base do cache para um pacote/versão/profile/target/libc/arch.
    # Uso:
    #   adm_cache_pkg_dir categoria nome versao [profile] [target] [libc] [arch]
    local category_raw="${1:-}"
    local name_raw="${2:-}"
    local version="${3:-}"
    local profile="${4:-$ADM_PROFILE}"
    local target="${5:-$ADM_TARGET}"
    local libc="${6:-$ADM_LIBC}"
    local arch="${7:-$(adm_cache_detect_arch)}"

    [ -z "$category_raw" ] && adm_die "adm_cache_pkg_dir requer categoria"
    [ -z "$name_raw" ]     && adm_die "adm_cache_pkg_dir requer nome"
    [ -z "$version" ]      && adm_die "adm_cache_pkg_dir requer versao"

    local category name
    category="$(adm_repo_sanitize_category "$category_raw")"
    name="$(adm_repo_sanitize_name "$name_raw")"

    printf '%s/%s/%s/%s/%s/%s/%s/%s' \
        "$ADM_CACHE_BIN" \
        "$category" \
        "$name" \
        "$version" \
        "$libc" \
        "$target" \
        "$profile" \
        "$arch"
}

adm_cache_tarball_path() {
    # Retorna caminho do tarball no cache.
    local category="${1:-}"
    local name="${2:-}"
    local version="${3:-}"
    local profile="${4:-$ADM_PROFILE}"
    local target="${5:-$ADM_TARGET}"
    local libc="${6:-$ADM_LIBC}"
    local arch="${7:-$(adm_cache_detect_arch)}"
    local cache_dir
    cache_dir="$(adm_cache_pkg_dir "$category" "$name" "$version" "$profile" "$target" "$libc" "$arch")"

    # Extensão depende do compressor escolhido (mas usamos padrão .tar.ext)
    local _cmd _ext
    read -r _cmd _ext < <(adm_cache_detect_compressor)

    printf '%s/%s-%s-%s-%s-%s.%s' \
        "$cache_dir" \
        "$name" \
        "$version" \
        "$arch" \
        "$libc" \
        "$profile" \
        "$_ext"
}

adm_cache_manifest_path() {
    local category="${1:-}"
    local name="${2:-}"
    local version="${3:-}"
    local profile="${4:-$ADM_PROFILE}"
    local target="${5:-$ADM_TARGET}"
    local libc="${6:-$ADM_LIBC}"
    local arch="${7:-$(adm_cache_detect_arch)}"
    local cache_dir
    cache_dir="$(adm_cache_pkg_dir "$category" "$name" "$version" "$profile" "$target" "$libc" "$arch")"
    printf '%s/manifest' "$cache_dir"
}

adm_cache_files_list_path() {
    local category="${1:-}"
    local name="${2:-}"
    local version="${3:-}"
    local profile="${4:-$ADM_PROFILE}"
    local target="${5:-$ADM_TARGET}"
    local libc="${6:-$ADM_LIBC}"
    local arch="${7:-$(adm_cache_detect_arch)}"
    local cache_dir
    cache_dir="$(adm_cache_pkg_dir "$category" "$name" "$version" "$profile" "$target" "$libc" "$arch")"
    printf '%s/files.list' "$cache_dir"
}

# ----------------------------------------------------------------------
# Verificação de integridade do tarball
# ----------------------------------------------------------------------

adm_cache_sha256() {
    local file="${1:-}"
    if [ -z "$file" ]; then
        adm_die "adm_cache_sha256 requer caminho do arquivo"
    fi
    if [ ! -f "$file" ]; then
        adm_die "Arquivo inexistente para sha256: $file"
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        adm_die "Nenhuma ferramenta sha256 disponível (sha256sum/shasum)"
    fi
}

# ----------------------------------------------------------------------
# Criação de cache a partir de DESTDIR
# ----------------------------------------------------------------------

adm_cache_store_from_destdir() {
    # Cria entrada de cache para um pacote recém-compilado, a partir de um DESTDIR.
    #
    # Uso:
    #   adm_cache_store_from_destdir categoria nome versao destdir [profile] [target] [libc]
    #
    local category="${1:-}"
    local name="${2:-}"
    local version="${3:-}"
    local destdir="${4:-}"
    local profile="${5:-$ADM_PROFILE}"
    local target="${6:-$ADM_TARGET}"
    local libc="${7:-$ADM_LIBC}"
    local arch
    arch="$(adm_cache_detect_arch)"

    [ -z "$category" ] && adm_die "adm_cache_store_from_destdir requer categoria"
    [ -z "$name" ]     && adm_die "adm_cache_store_from_destdir requer nome"
    [ -z "$version" ]  && adm_die "adm_cache_store_from_destdir requer versao"
    [ -z "$destdir" ]  && adm_die "adm_cache_store_from_destdir requer destdir"

    if [ ! -d "$destdir" ]; then
        adm_die "DESTDIR inválido para cache: $destdir"
    fi

    # Verifica se DESTDIR não está vazio (sugestão forte, mas não infalível)
    if ! find "$destdir" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
        adm_die "DESTDIR está vazio, não faz sentido criar cache: $destdir"
    fi

    adm_cache_init

    local cache_dir tarball manifest fileslist
    cache_dir="$(adm_cache_pkg_dir "$category" "$name" "$version" "$profile" "$target" "$libc" "$arch")"
    tarball="$(adm_cache_tarball_path "$category" "$name" "$version" "$profile" "$target" "$libc" "$arch")"
    manifest="$(adm_cache_manifest_path "$category" "$name" "$version" "$profile" "$target" "$libc" "$arch")"
    fileslist="$(adm_cache_files_list_path "$category" "$name" "$version" "$profile" "$target" "$libc" "$arch")"

    adm_ensure_dir "$cache_dir"

    adm_info "Criando cache para $category/$name-$version (profile=$profile, target=$target, libc=$libc, arch=$arch)"
    adm_info "DESTDIR: $destdir"
    adm_info "Cache dir: $cache_dir"

    # Captura lista de arquivos (relativa ao DESTDIR)
    # Se isso falhar, abortar; é essencial.
    if ! (cd "$destdir" && find . -type f | sort >"$fileslist.tmp"); then
        rm -f "$fileslist.tmp" || true
        adm_die "Falha ao gerar lista de arquivos em $destdir"
    fi

    mv -f "$fileslist.tmp" "$fileslist"

    local compressor ext
    read -r compressor ext < <(adm_cache_detect_compressor)

    local tar_tmp
    tar_tmp="${tarball}.tmp.$$"

    adm_info "Compactando arquivos do DESTDIR em tarball ($compressor, ext=$ext)..."

    # Cria tarball temporário
    (
        cd "$destdir" || exit 1
        # Tar + compressor em pipeline
        if [ "$compressor" = "zstd" ]; then
            tar -cf - . | zstd -q -o "$tar_tmp"
        elif [ "$compressor" = "xz" ]; then
            tar -cf - . | xz -z -c >"$tar_tmp"
        else
            # gzip
            tar -cf - . | gzip -c >"$tar_tmp"
        fi
    ) || {
        rm -f "$tar_tmp" || true
        adm_die "Falha ao criar tarball temporário para $category/$name-$version"
    }

    if [ ! -f "$tar_tmp" ]; then
        adm_die "Tarball temporário não foi criado: $tar_tmp"
    fi

    # Calcula sha256 e tamanho
    local sha size_bytes file_count created_at
    sha="$(adm_cache_sha256 "$tar_tmp")"
    size_bytes="$(stat -c '%s' "$tar_tmp" 2>/dev/null || stat -f '%z' "$tar_tmp" 2>/dev/null || echo 0)"
    file_count="$(wc -l <"$fileslist" 2>/dev/null || echo 0)"
    created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    # Manifest temporário
    local manifest_tmp
    manifest_tmp="${manifest}.tmp.$$"

    {
        printf 'name=%s\n' "$name"
        printf 'version=%s\n' "$version"
        printf 'category=%s\n' "$category"
        printf 'profile=%s\n' "$profile"
        printf 'target=%s\n' "$target"
        printf 'libc=%s\n' "$libc"
        printf 'arch=%s\n' "$arch"
        printf 'tarball=%s\n' "$(basename "$tarball")"
        printf 'size_bytes=%s\n' "$size_bytes"
        printf 'sha256=%s\n' "$sha"
        printf 'file_count=%s\n' "$file_count"
        printf 'created_at=%s\n' "$created_at"
        printf 'adm_cache_version=%s\n' "1"
    } >"$manifest_tmp"

    # Move atomically manifest + tarball
    if ! mv -f "$tar_tmp" "$tarball"; then
        rm -f "$tar_tmp" "$manifest_tmp" "$fileslist" || true
        adm_die "Falha ao mover tarball para '$tarball'"
    fi

    if ! mv -f "$manifest_tmp" "$manifest"; then
        rm -f "$manifest_tmp" "$tarball" "$fileslist" || true
        adm_die "Falha ao salvar manifest em '$manifest'"
    fi

    adm_info "Cache criado com sucesso: $tarball"
    adm_info "Manifest: $manifest"
    adm_info "Lista de arquivos: $fileslist"
}

# ----------------------------------------------------------------------
# Verificação e leitura de manifest
# ----------------------------------------------------------------------

adm_cache_exists() {
    # Verifica se existe um binário em cache (tarball + manifest).
    #
    # Uso:
    #   adm_cache_exists categoria nome versao [profile] [target] [libc]
    #
    local category="${1:-}"
    local name="${2:-}"
    local version="${3:-}"
    local profile="${4:-$ADM_PROFILE}"
    local target="${5:-$ADM_TARGET}"
    local libc="${6:-$ADM_LIBC}"
    local arch
    arch="$(adm_cache_detect_arch)"

    local tarball manifest
    tarball="$(adm_cache_tarball_path "$category" "$name" "$version" "$profile" "$target" "$libc" "$arch")"
    manifest="$(adm_cache_manifest_path "$category" "$name" "$version" "$profile" "$target" "$libc" "$arch")"

    [ -f "$tarball" ] && [ -f "$manifest" ]
}

adm_cache_manifest_get_field() {
    # Lê um campo do manifest.
    # Uso: adm_cache_manifest_get_field manifest_path campo
    local manifest="${1:-}"
    local field="${2:-}"
    [ -z "$manifest" ] && adm_die "adm_cache_manifest_get_field requer caminho de manifest"
    [ -z "$field" ]    && adm_die "adm_cache_manifest_get_field requer campo"
    [ -f "$manifest" ] || adm_die "Manifest não encontrado: $manifest"

    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        if [[ "$line" == "$field="* ]]; then
            value="${line#*=}"
            printf '%s\n' "$value"
            return 0
        fi
    done <"$manifest"

    adm_die "Campo '$field' não encontrado no manifest '$manifest'"
}

adm_cache_validate() {
    # Valida um entry de cache: confere sha256 do tarball com o manifest.
    #
    # Uso:
    #   adm_cache_validate categoria nome versao [profile] [target] [libc]
    #
    local category="${1:-}"
    local name="${2:-}"
    local version="${3:-}"
    local profile="${4:-$ADM_PROFILE}"
    local target="${5:-$ADM_TARGET}"
    local libc="${6:-$ADM_LIBC}"
    local arch
    arch="$(adm_cache_detect_arch)"

    local tarball manifest
    tarball="$(adm_cache_tarball_path "$category" "$name" "$version" "$profile" "$target" "$libc" "$arch")"
    manifest="$(adm_cache_manifest_path "$category" "$name" "$version" "$profile" "$target" "$libc" "$arch")"

    if [ ! -f "$tarball" ] || [ ! -f "$manifest" ]; then
        adm_warn "Cache incompleto para $category/$name-$version (profile=$profile, target=$target, libc=$libc, arch=$arch)"
        return 1
    fi

    local expected_sha actual_sha
    expected_sha="$(adm_cache_manifest_get_field "$manifest" "sha256")"

    adm_info "Validando cache: $tarball"
    actual_sha="$(adm_cache_sha256 "$tarball")"

    if [ "$expected_sha" != "$actual_sha" ]; then
        adm_warn "sha256 do tarball não confere: manifest=$expected_sha, calculado=$actual_sha"
        return 1
    fi

    adm_info "Cache válido para $category/$name-$version (profile=$profile, target=$target, libc=$libc, arch=$arch)"
    return 0
}

# ----------------------------------------------------------------------
# Extração de cache para DESTDIR
# ----------------------------------------------------------------------

adm_cache_extract_to_destdir() {
    # Extrai o tarball em cache para um DESTDIR.
    #
    # Uso:
    #   adm_cache_extract_to_destdir categoria nome versao destdir [profile] [target] [libc]
    #
    local category="${1:-}"
    local name="${2:-}"
    local version="${3:-}"
    local destdir="${4:-}"
    local profile="${5:-$ADM_PROFILE}"
    local target="${6:-$ADM_TARGET}"
    local libc="${7:-$ADM_LIBC}"
    local arch
    arch="$(adm_cache_detect_arch)"

    [ -z "$category" ] && adm_die "adm_cache_extract_to_destdir requer categoria"
    [ -z "$name" ]     && adm_die "adm_cache_extract_to_destdir requer nome"
    [ -z "$version" ]  && adm_die "adm_cache_extract_to_destdir requer versao"
    [ -z "$destdir" ]  && adm_die "adm_cache_extract_to_destdir requer destdir"

    adm_cache_init

    local tarball manifest
    tarball="$(adm_cache_tarball_path "$category" "$name" "$version" "$profile" "$target" "$libc" "$arch")"
    manifest="$(adm_cache_manifest_path "$category" "$name" "$version" "$profile" "$target" "$libc" "$arch")"

    if [ ! -f "$tarball" ] || [ ! -f "$manifest" ]; then
        adm_die "Não há cache disponível para $category/$name-$version (profile=$profile, target=$target, libc=$libc, arch=$arch)"
    fi

    if ! adm_cache_validate "$category" "$name" "$version" "$profile" "$target" "$libc"; then
        adm_die "Cache inválido para $category/$name-$version; não será extraído"
    fi

    adm_ensure_dir "$destdir"

    adm_info "Extraindo cache para DESTDIR: $destdir"

    # Detecta compressor pela extensão
    case "$tarball" in
        *.tar.zst)
            if ! command -v zstd >/dev/null 2>&1; then
                adm_die "Tarball é .tar.zst mas 'zstd' não está disponível"
            fi
            ( cd "$destdir" && zstd -q -d -c "$tarball" | tar -xf - ) \
                || adm_die "Falha ao extrair tarball .tar.zst para $destdir"
            ;;
        *.tar.xz)
            if ! command -v xz >/dev/null 2>&1; then
                adm_die "Tarball é .tar.xz mas 'xz' não está disponível"
            fi
            ( cd "$destdir" && xz -d -c "$tarball" | tar -xf - ) \
                || adm_die "Falha ao extrair tarball .tar.xz para $destdir"
            ;;
        *.tar.gz|*.tgz)
            ( cd "$destdir" && gzip -d -c "$tarball" | tar -xf - ) \
                || adm_die "Falha ao extrair tarball .tar.gz para $destdir"
            ;;
        *)
            adm_die "Extensão de tarball desconhecida: $tarball"
            ;;
    esac

    adm_info "Cache extraído com sucesso para $destdir"
}

# ----------------------------------------------------------------------
# Invalidação (remoção) de cache
# ----------------------------------------------------------------------

adm_cache_invalidate() {
    # Remove completamente o cache de um pacote/versão/profile/target/libc/arch.
    #
    # Uso:
    #   adm_cache_invalidate categoria nome versao [profile] [target] [libc]
    #
    local category="${1:-}"
    local name="${2:-}"
    local version="${3:-}"
    local profile="${4:-$ADM_PROFILE}"
    local target="${5:-$ADM_TARGET}"
    local libc="${6:-$ADM_LIBC}"
    local arch
    arch="$(adm_cache_detect_arch)"

    [ -z "$category" ] && adm_die "adm_cache_invalidate requer categoria"
    [ -z "$name" ]     && adm_die "adm_cache_invalidate requer nome"
    [ -z "$version" ]  && adm_die "adm_cache_invalidate requer versao"

    local cache_dir
    cache_dir="$(adm_cache_pkg_dir "$category" "$name" "$version" "$profile" "$target" "$libc" "$arch")"

    if [ ! -d "$cache_dir" ]; then
        adm_warn "Cache para $category/$name-$version (profile=$profile, target=$target, libc=$libc, arch=$arch) já não existe."
        return 0
    fi

    adm_info "Removendo cache em $cache_dir"
    if ! rm -rf --one-file-system "$cache_dir"; then
        adm_die "Falha ao remover cache: $cache_dir"
    fi

    adm_info "Cache removido com sucesso: $cache_dir"
}

# ----------------------------------------------------------------------
# Utilitários de listagem
# ----------------------------------------------------------------------

adm_cache_list_versions() {
    # Lista versões em cache para um pacote.
    #
    # Uso:
    #   adm_cache_list_versions categoria nome
    #
    local category="${1:-}"
    local name="${2:-}"

    [ -z "$category" ] && adm_die "adm_cache_list_versions requer categoria"
    [ -z "$name" ]     && adm_die "adm_cache_list_versions requer nome"

    local c n base
    c="$(adm_repo_sanitize_category "$category")"
    n="$(adm_repo_sanitize_name "$name")"

    base="$ADM_CACHE_BIN/$c/$n"
    [ -d "$base" ] || return 0

    local d
    for d in "$base"/*; do
        [ -d "$d" ] || continue
        basename "$d"
    done | sort
}

# ----------------------------------------------------------------------
# Comportamento ao ser executado diretamente (demo)
# ----------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    adm_info "13-binary-cache.sh executado diretamente (modo demonstração)."
    adm_cache_init
    echo
    echo "Funções principais:"
    echo "  adm_cache_store_from_destdir categoria nome versao destdir [profile] [target] [libc]"
    echo "  adm_cache_exists categoria nome versao [profile] [target] [libc]"
    echo "  adm_cache_validate categoria nome versao [profile] [target] [libc]"
    echo "  adm_cache_extract_to_destdir categoria nome versao destdir [profile] [target] [libc]"
    echo "  adm_cache_invalidate categoria nome versao [profile] [target] [libc]"
    echo "  adm_cache_list_versions categoria nome"
fi
