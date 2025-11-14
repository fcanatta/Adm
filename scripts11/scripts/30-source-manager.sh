#!/usr/bin/env bash
# 30-source-manager.sh
# Gerenciamento avançado de fontes do ADM:
#
# - Downloads:
#     * http/https (curl ou wget)
#     * ftp (curl/wget/lftp)
#     * rsync
#     * git (git://, ssh://, https://... .git, git+https://)
#     * github/gitlab/sourceforge (tratados como http/git conforme padrão da URL)
#     * file://
#     * diretórios locais
# - Verificação de integridade:
#     * sha256sums (via metafile, se disponível)
# - Extração:
#     * .tar.gz .tgz .tar.bz2 .tar.xz .tar.zst
#     * .tar
#     * .zip
#     * .7z
#     * .gz .bz2 .xz simples (1 arquivo)
# - Detecção de projeto:
#     * build system (autotools, cmake, meson, waf, scons, qmake, etc.)
#     * linguagens principais (C, C++, Fortran, Rust, Go, Python, etc.)
#     * kernel/toolchain (Kconfig, arch/*, etc.)
#     * docs (texinfo, man, sphinx)
#     * hints de deps (pkg-config, CMake find_package, etc.)
#
# Integra com:
#   - 10-repo-metafile.sh (adm_meta_*) para ler sources/sha256sums
#   - 01-log-ui.sh (adm_info/adm_warn/adm_error/adm_run_with_spinner)
#
# Não há erros silenciosos. Se algo crítico falhar, vai logar e dar adm_die.

# ----------------------------------------------------------------------
# Requisitos e modo seguro
# ----------------------------------------------------------------------

if [ -z "${BASH_VERSION:-}" ]; then
    echo "ERRO: 30-source-manager.sh requer bash." >&2
    exit 1
fi

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "ERRO: 30-source-manager.sh requer bash >= 4." >&2
    exit 1
fi

set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------
# Integração com ambiente e logging
# ----------------------------------------------------------------------

ADM_ROOT_DEFAULT="/usr/src/adm"
ADM_ROOT="${ADM_ROOT:-$ADM_ROOT_DEFAULT}"

ADM_SCRIPTS="${ADM_SCRIPTS:-$ADM_ROOT/scripts}"
ADM_SOURCES="${ADM_SOURCES:-$ADM_ROOT/sources}"
ADM_WORK="${ADM_WORK:-$ADM_ROOT/work}"

# Paralelismo opcional de downloads
ADM_SRC_JOBS_DEFAULT=4
ADM_SRC_JOBS="${ADM_SRC_JOBS:-$ADM_SRC_JOBS_DEFAULT}"

# Logging: se 01-log-ui.sh já foi carregado, usamos; senão, fallback simples.
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

if ! declare -F adm_run_with_spinner >/dev/null 2>&1; then
    adm_run_with_spinner() {
        # fallback sem spinner
        local msg="$1"; shift
        adm_info "$msg"
        "$@"
    }
fi

# Integração com 10-repo-metafile.sh (se houver)
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
# Helpers gerais
# ----------------------------------------------------------------------

adm_src_init_paths() {
    adm_ensure_dir "$ADM_SOURCES"
    adm_ensure_dir "$ADM_WORK"
}

adm_src_sha256() {
    local file="${1:-}"
    if [ -z "$file" ]; then
        adm_die "adm_src_sha256 requer arquivo"
    fi
    if [ ! -f "$file" ]; then
        adm_die "Arquivo inexistente para sha256: $file"
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        adm_die "Nenhuma ferramenta sha256 encontrada (sha256sum/shasum)."
    fi
}

adm_src_basename_from_url() {
    # Tenta extrair um nome de arquivo razoável a partir da URL.
    local url="${1:-}"
    if [ -z "$url" ]; then
        adm_die "adm_src_basename_from_url requer url"
    fi

    local base
    base="${url##*/}"
    # Se terminar com / ou ficar vazio, gera um nome fallback
    if [ -z "$base" ] || [ "$base" = "$url" ] && [[ "$base" != *.* ]]; then
        base="source-$(echo "$url" | tr '/:' '_')"
    fi
    printf '%s' "$base"
}

adm_src_detect_scheme() {
    # Retorna o "tipo" principal da URL: http, https, ftp, rsync, git, file, dir, local
    local url="${1:-}"
    [ -z "$url" ] && adm_die "adm_src_detect_scheme requer url"

    # Diretório local (relativo ou absoluto)
    if [ -d "$url" ]; then
        printf '%s' "dir"
        return 0
    fi

    # Arquivo local
    if [ -f "$url" ]; then
        printf '%s' "local"
        return 0
    fi

    case "$url" in
        git+http://*|git+https://*|git+ssh://*)
            printf '%s' "git"
            ;;
        git://*|ssh://*|*.git)
            printf '%s' "git"
            ;;
        http://*)
            printf '%s' "http"
            ;;
        https://*)
            # Pode ser git ou http, mas tratamos como http se não tiver .git/explicit git+
            if [[ "$url" == *.git ]] || [[ "$url" == git+https://* ]]; then
                printf '%s' "git"
            else
                printf '%s' "https"
            fi
            ;;
        ftp://*)
            printf '%s' "ftp"
            ;;
        rsync://*)
            printf '%s' "rsync"
            ;;
        file://*)
            printf '%s' "file"
            ;;
        *)
            adm_warn "Esquema de URL desconhecido: $url (tratando como http genérico)"
            printf '%s' "http"
            ;;
    esac
}

# ----------------------------------------------------------------------
# Download de um único source
# ----------------------------------------------------------------------

adm_src_download_http_generic() {
    local url="${1:-}"
    local dest="${2:-}"

    [ -z "$url" ]  && adm_die "adm_src_download_http_generic requer url"
    [ -z "$dest" ] && adm_die "adm_src_download_http_generic requer dest"

    adm_info "Baixando (HTTP/HTTPS): $url -> $dest"

    if command -v curl >/dev/null 2>&1; then
        if ! curl -L --fail --retry 3 -o "$dest" "$url"; then
            adm_die "Falha ao baixar via curl: $url"
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -O "$dest" "$url"; then
            adm_die "Falha ao baixar via wget: $url"
        fi
    else
        adm_die "Nem curl nem wget disponíveis para baixar URL: $url"
    fi
}

adm_src_download_ftp() {
    local url="${1:-}"
    local dest="${2:-}"

    [ -z "$url" ]  && adm_die "adm_src_download_ftp requer url"
    [ -z "$dest" ] && adm_die "adm_src_download_ftp requer dest"

    adm_info "Baixando (FTP): $url -> $dest"

    if command -v curl >/dev/null 2>&1; then
        if ! curl --fail --retry 3 -o "$dest" "$url"; then
            adm_die "Falha ao baixar via curl (ftp): $url"
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -O "$dest" "$url"; then
            adm_die "Falha ao baixar via wget (ftp): $url"
        fi
    elif command -v lftp >/dev/null 2>&1; then
        if ! lftp -c "get -O $(dirname "$dest") $url"; then
            adm_die "Falha ao baixar via lftp: $url"
        fi
    else
        adm_die "Nenhuma ferramenta FTP (curl/wget/lftp) disponível para: $url"
    fi
}

adm_src_download_rsync() {
    local url="${1:-}"
    local dest_dir="${2:-}"

    [ -z "$url" ]      && adm_die "adm_src_download_rsync requer url"
    [ -z "$dest_dir" ] && adm_die "adm_src_download_rsync requer dest_dir"

    if ! command -v rsync >/dev/null 2>&1; then
        adm_die "rsync não disponível, mas a URL é rsync: $url"
    fi

    adm_ensure_dir "$dest_dir"

    adm_info "Baixando (rsync): $url -> $dest_dir"
    if ! rsync -av --delete "$url" "$dest_dir/"; then
        adm_die "Falha ao sincronizar via rsync: $url"
    fi
}

adm_src_download_git() {
    local url="${1:-}"
    local dest_dir="${2:-}"

    [ -z "$url" ]      && adm_die "adm_src_download_git requer url"
    [ -z "$dest_dir" ] && adm_die "adm_src_download_git requer dest_dir"

    if ! command -v git >/dev/null 2>&1; then
        adm_die "git não disponível, mas a URL é git: $url"
    fi

    local git_url="$url"

    # Normalizar git+https://, git+ssh:// etc.
    case "$git_url" in
        git+https://*|git+http://*|git+ssh://*)
            git_url="${git_url#git+}"
            ;;
    esac

    adm_ensure_dir "$(dirname "$dest_dir")"

    if [ -d "$dest_dir/.git" ]; then
        adm_info "Repositório git já existe em $dest_dir; fazendo fetch/checkout."
        (
            cd "$dest_dir" || exit 1
            git fetch --all --prune || exit 1
        ) || adm_die "Falha ao atualizar repositório git em $dest_dir"
    else
        adm_info "Clonando git: $git_url -> $dest_dir"
        if ! git clone --depth 1 "$git_url" "$dest_dir"; then
            adm_die "Falha ao clonar repositório git: $git_url"
        fi
    fi
}

adm_src_copy_local_file() {
    local src="${1:-}"
    local dest="${2:-}"

    [ -z "$src" ]  && adm_die "adm_src_copy_local_file requer src"
    [ -z "$dest" ] && adm_die "adm_src_copy_local_file requer dest"

    if [ ! -f "$src" ]; then
        adm_die "Arquivo local não encontrado: $src"
    fi

    adm_info "Copiando arquivo local: $src -> $dest"
    if ! cp -f "$src" "$dest"; then
        adm_die "Falha ao copiar $src -> $dest"
    fi
}

adm_src_copy_local_dir() {
    local src="${1:-}"
    local dest="${2:-}"

    [ -z "$src" ]  && adm_die "adm_src_copy_local_dir requer src"
    [ -z "$dest" ] && adm_die "adm_src_copy_local_dir requer dest"

    if [ ! -d "$src" ]; then
        adm_die "Diretório local não encontrado: $src"
    fi

    adm_info "Copiando diretório local: $src -> $dest"
    adm_ensure_dir "$(dirname "$dest")"

    if [ -e "$dest" ]; then
        adm_warn "Destino $dest já existe; removendo para cópia limpa."
        rm -rf --one-file-system "$dest" || adm_die "Falha ao limpar $dest"
    fi

    if ! cp -a "$src" "$dest"; then
        adm_die "Falha ao copiar diretório $src -> $dest"
    fi
}

adm_src_download_one() {
    # Baixa um único "source" dentro de uma pasta de destino.
    #
    # Uso:
    #   adm_src_download_one url destdir destname
    #
    # Retorna caminho do resultado (arquivo ou diretório) via stdout.
    local url="${1:-}"
    local destdir="${2:-}"
    local destname="${3:-}"

    [ -z "$url" ]     && adm_die "adm_src_download_one requer url"
    [ -z "$destdir" ] && adm_die "adm_src_download_one requer destdir"

    adm_ensure_dir "$destdir"

    local scheme
    scheme="$(adm_src_detect_scheme "$url")"

    local target_path

    case "$scheme" in
        http|https)
            if [ -z "$destname" ]; then
                destname="$(adm_src_basename_from_url "$url")"
            fi
            target_path="$destdir/$destname"
            adm_src_download_http_generic "$url" "$target_path"
            ;;
        ftp)
            if [ -z "$destname" ]; then
                destname="$(adm_src_basename_from_url "$url")"
            fi
            target_path="$destdir/$destname"
            adm_src_download_ftp "$url" "$target_path"
            ;;
        rsync)
            if [ -z "$destname" ]; then
                destname="$(adm_src_basename_from_url "$url")"
            fi
            target_path="$destdir/$destname"
            adm_src_download_rsync "$url" "$target_path"
            ;;
        git)
            if [ -z "$destname" ]; then
                destname="$(adm_src_basename_from_url "$url")"
            fi
            target_path="$destdir/$destname"
            adm_src_download_git "$url" "$target_path"
            ;;
        file)
            local path="${url#file://}"
            if [ -z "$destname" ]; then
                destname="$(basename "$path")"
            fi
            target_path="$destdir/$destname"
            adm_src_copy_local_file "$path" "$target_path"
            ;;
        dir)
            # url é um diretório local
            if [ -z "$destname" ]; then
                destname="$(basename "$url")"
            fi
            target_path="$destdir/$destname"
            adm_src_copy_local_dir "$url" "$target_path"
            ;;
        local)
            # arquivo local
            if [ -z "$destname" ]; then
                destname="$(basename "$url")"
            fi
            target_path="$destdir/$destname"
            adm_src_copy_local_file "$url" "$target_path"
            ;;
        *)
            adm_die "Esquema de URL não suportado: $scheme ($url)"
            ;;
    esac

    printf '%s\n' "$target_path"
}

# ----------------------------------------------------------------------
# Downloads múltiplos (com paralelismo opcional)
# ----------------------------------------------------------------------

adm_src_download_many() {
    # Baixa vários sources em um destdir, com sha256 opcional por índice.
    #
    # Uso:
    #   adm_src_download_many destdir "url1,url2,..." "sha1,sha2,..."
    #
    # Retorna lista de caminhos baixados (um por linha) em stdout.
    local destdir="${1:-}"
    local sources_csv="${2:-}"
    local sha_csv="${3:-}"

    [ -z "$destdir" ] && adm_die "adm_src_download_many requer destdir"
    [ -z "$sources_csv" ] && adm_die "adm_src_download_many requer lista de sources"

    adm_ensure_dir "$destdir"

    local -a urls shas
    IFS=',' read -r -a urls <<< "$sources_csv"
    IFS=',' read -r -a shas <<< "${sha_csv:-}"

    local n="${#urls[@]}"
    local n_sha="${#shas[@]}"

    if [ "$n" -eq 0 ]; then
        adm_die "Lista de sources vazia em adm_src_download_many"
    fi

    # Ajusta shas para ter pelo menos n entradas (vazias se não tiver)
    if [ "$n_sha" -lt "$n" ]; then
        local i
        for ((i=n_sha; i<n; i++)); do
            shas[i]=""
        done
    fi

    local -a results
    results=()

    # Se ADM_SRC_JOBS>1, faz downloads em paralelo simples (background)
    local jobs="$ADM_SRC_JOBS"
    local active=0
    local -a pids paths idxs

    adm_info "Iniciando downloads de $n source(s) (jobs=$jobs)."

    local i url sha
    for ((i=0; i<n; i++)); do
        url="${urls[i]}"
        sha="${shas[i]}"

        # Remove espaços
        url="${url#"${url%%[![:space:]]*}"}"
        url="${url%"${url##*[![:space:]]}"}"
        sha="${sha#"${sha%%[![:space:]]*}"}"
        sha="${sha%"${sha##*[![:space:]]}"}"

        [ -z "$url" ] && adm_die "Entrada de source vazia na posição $i"

        # Nome default
        local base destpath
        base="$(adm_src_basename_from_url "$url")"
        destpath="$destdir/$base"

        if [ "$jobs" -gt 1 ]; then
            # Paralelo (background)
            (
                set -euo pipefail
                p="$(adm_src_download_one "$url" "$destdir" "$base")"
                printf '%s\n' "$p"
            ) >"$destpath.__tmp_path" 2>"$destpath.__tmp_err" &
            pids[i]=$!
            paths[i]="$destpath"
            idxs[i]="$i"
            active=$((active+1))

            # Limita número de jobs simultâneos
            if [ "$active" -ge "$jobs" ]; then
                # Espera pelo menos um
                wait -n || true
                active=$((active-1))
            fi
        else
            # Sequencial
            destpath="$(adm_src_download_one "$url" "$destdir" "$base")"
            results+=("$destpath")
        fi
    done

    # Espera todos se esteve em paralelo
    if [ "$jobs" -gt 1 ]; then
        local any_fail=0
        for pid in "${pids[@]:-}"; do
            [ -z "${pid:-}" ] && continue
            if ! wait "$pid"; then
                any_fail=1
            fi
        done

        # Coleta paths ou erros
        local j
        for ((j=0; j<${#paths[@]}; j++)); do
            local tmp_path tmp_err
            tmp_path="${paths[j]}.__tmp_path"
            tmp_err="${paths[j]}.__tmp_err"
            if [ -f "$tmp_path" ]; then
                local real_path
                real_path="$(cat "$tmp_path")"
                results+=("$real_path")
                rm -f "$tmp_path" "$tmp_err" || true
            else
                any_fail=1
                if [ -f "$tmp_err" ]; then
                    adm_error "Erro no download (paralelo) de ${paths[j]}:"
                    sed 's/^/  /' "$tmp_err" >&2
                    rm -f "$tmp_err" || true
                else
                    adm_error "Erro desconhecido no download (paralelo) de ${paths[j]}"
                fi
            fi
        done

        if [ "$any_fail" -ne 0 ]; then
            adm_die "Um ou mais downloads falharam em modo paralelo."
        fi
    fi

    # Checagem de sha256sums (apenas para arquivos normais, não dirs)
    local count="${#results[@]}"
    if [ "$count" -ne "$n" ]; then
        adm_die "Número de resultados ($count) difere do número de sources ($n)."
    fi

    local k file expected_sha actual_sha
    for ((k=0; k<count; k++)); do
        file="${results[k]}"
        expected_sha="${shas[k]:-}"

        if [ -z "$expected_sha" ]; then
            adm_info "Sem sha256 esperado para '${urls[k]}'; pulando verificação."
            continue
        fi

        if [ -d "$file" ]; then
            adm_warn "sha256 fornecido para '${urls[k]}', mas resultado é diretório ($file). Pulando verificação."
            continue
        fi

        actual_sha="$(adm_src_sha256 "$file")"
        if [ "$actual_sha" != "$expected_sha" ]; then
            adm_die "sha256 não confere para '$file': esperado=$expected_sha, calculado=$actual_sha"
        fi

        adm_info "sha256 OK para '$file'"
    done

    # Retorna lista de caminhos
    for file in "${results[@]}"; do
        printf '%s\n' "$file"
    done
}

# ----------------------------------------------------------------------
# Extração de arquivos em workdir
# ----------------------------------------------------------------------

adm_src_workdir_for_pkg() {
    local category="${1:-}"
    local name="${2:-}"
    local version="${3:-}"

    [ -z "$category" ] && adm_die "adm_src_workdir_for_pkg requer categoria"
    [ -z "$name" ]     && adm_die "adm_src_workdir_for_pkg requer nome"
    [ -z "$version" ]  && adm_die "adm_src_workdir_for_pkg requer versao"

    local c n
    c="$(adm_repo_sanitize_category "$category")"
    n="$(adm_repo_sanitize_name "$name")"

    printf '%s/%s-%s' "$ADM_WORK" "$n" "$version"
}

adm_src_extract_one() {
    # Extrai um arquivo ou trata diretório/checkout git.
    #
    # Uso:
    #   adm_src_extract_one src_path workdir
    #
    local src="${1:-}"
    local workdir="${2:-}"

    [ -z "$src" ]     && adm_die "adm_src_extract_one requer src"
    [ -z "$workdir" ] && adm_die "adm_src_extract_one requer workdir"

    adm_ensure_dir "$workdir"

    if [ -d "$src" ]; then
        # Se for diretório (git clone, rsync, diretório local copiado)
        adm_info "Source é diretório; copiando/merge para $workdir: $src"
        # Copiamos conteúdo pra dentro do workdir (pode haver múltiplos sources)
        if ! cp -a "$src"/. "$workdir"/; then
            adm_die "Falha ao copiar diretório $src -> $workdir"
        fi
        return 0
    fi

    if [ ! -f "$src" ]; then
        adm_die "Source para extração não existe: $src"
    fi

    adm_info "Extraindo arquivo $src em $workdir"

    case "$src" in
        *.tar.gz|*.tgz)
            tar -xzf "$src" -C "$ADM_WORK" || adm_die "Falha ao extrair $src"
            ;;
        *.tar.bz2)
            tar -xjf "$src" -C "$ADM_WORK" || adm_die "Falha ao extrair $src"
            ;;
        *.tar.xz)
            tar -xJf "$src" -C "$ADM_WORK" || adm_die "Falha ao extrair $src"
            ;;
        *.tar.zst)
            if ! command -v zstd >/dev/null 2>&1; then
                adm_die "Arquivo $src é .tar.zst mas zstd não está disponível"
            fi
            zstd -d -c "$src" | tar -xf - -C "$ADM_WORK" || adm_die "Falha ao extrair $src"
            ;;
        *.tar)
            tar -xf "$src" -C "$ADM_WORK" || adm_die "Falha ao extrair $src"
            ;;
        *.zip)
            if ! command -v unzip >/dev/null 2>&1; then
                adm_die "unzip não disponível para extrair $src"
            fi
            unzip -q "$src" -d "$ADM_WORK" || adm_die "Falha ao extrair $src"
            ;;
        *.7z)
            if ! command -v 7z >/dev/null 2>&1; then
                adm_die "7z não disponível para extrair $src"
            fi
            ( cd "$ADM_WORK" && 7z x -y "$src" ) || adm_die "Falha ao extrair $src"
            ;;
        *.gz)
            # .gz simples (um arquivo); extraímos para workdir
            local base
            base="$(basename "$src" .gz)"
            gunzip -c "$src" >"$workdir/$base" || adm_die "Falha ao descomprimir $src"
            ;;
        *.bz2)
            local baseb
            baseb="$(basename "$src" .bz2)"
            bunzip2 -c "$src" >"$workdir/$baseb" || adm_die "Falha ao descomprimir $src"
            ;;
        *.xz)
            local basex
            basex="$(basename "$src" .xz)"
            unxz -c "$src" >"$workdir/$basex" || adm_die "Falha ao descomprimir $src"
            ;;
        *)
            # Não reconhecido como arquivo comprimido -> copiamos pro workdir
            adm_warn "Extensão de source não reconhecida para extração: $src (apenas copiando para workdir)."
            cp -f "$src" "$workdir"/ || adm_die "Falha ao copiar $src -> $workdir"
            ;;
    esac

    # Tentar identificar se criou diretório principal; se sim e for diferente de workdir, podemos mover.
    # Isso é heurístico; preferimos não apagar nada se não tiver certeza.
    :
}

adm_src_extract_all_to_workdir() {
    # Extrai todos os arquivos/diretórios de uma lista em um workdir.
    #
    # Uso:
    #   adm_src_extract_all_to_workdir "file1\nfile2\n..." workdir
    #
    local list="${1:-}"
    local workdir="${2:-}"

    [ -z "$workdir" ] && adm_die "adm_src_extract_all_to_workdir requer workdir"

    adm_ensure_dir "$workdir"

    local src
    while IFS= read -r src || [ -n "$src" ]; do
        [ -z "$src" ] && continue
        adm_src_extract_one "$src" "$workdir"
    done <<< "$list"

    adm_info "Extração completa para workdir: $workdir"
}

# ----------------------------------------------------------------------
# Detecção de projeto (scan do workdir)
# ----------------------------------------------------------------------
# Resultado em variáveis:
#   ADM_SRC_DETECTED_BUILDSYS   : lista com espaços (autotools cmake meson ...)
#   ADM_SRC_DETECTED_LANGS      : lista (c c++ fortran rust go python ...)
#   ADM_SRC_DETECTED_DOCS       : lista (texinfo man sphinx ...)
#   ADM_SRC_DETECTED_KERNEL     : 0 ou 1
#   ADM_SRC_DETECTED_PKGS       : hints (nomes de pkg-config, etc.)

adm_src_detect_project() {
    local workdir="${1:-}"
    [ -z "$workdir" ] && adm_die "adm_src_detect_project requer workdir"
    [ -d "$workdir" ] || adm_die "Workdir não existe: $workdir"

    local builds langs docs kernel pkgs
    builds=()
    langs=()
    docs=()
    kernel=0
    pkgs=()

    # Autotools
    if find "$workdir" -maxdepth 1 -name configure -type f -print | grep -q . 2>/dev/null; then
        builds+=("autotools")
    fi

    # CMake
    if find "$workdir" -name CMakeLists.txt -type f -print | grep -q . 2>/dev/null; then
        builds+=("cmake")
    fi

    # Meson
    if find "$workdir" -name meson.build -type f -print | grep -q . 2>/dev/null; then
        builds+=("meson")
    fi

    # Waf
    if find "$workdir" -name wscript -type f -print | grep -q . 2>/dev/null; then
        builds+=("waf")
    fi

    # SCons
    if find "$workdir" -name SConstruct -o -name SConscript -type f -print | grep -q . 2>/dev/null; then
        builds+=("scons")
    fi

    # QMake
    if find "$workdir" -name '*.pro' -type f -print | grep -q . 2>/dev/null; then
        builds+=("qmake")
    fi

    # Linguagens (heurístico simples por extensão)
    if find "$workdir" -name '*.c' -type f -print | grep -q . 2>/dev/null; then
        langs+=("c")
    fi
    if find "$workdir" -name '*.cc' -o -name '*.cpp' -o -name '*.cxx' -type f -print | grep -q . 2>/dev/null; then
        langs+=("c++")
    fi
    if find "$workdir" -name '*.f' -o -name '*.f90' -o -name '*.F90' -type f -print | grep -q . 2>/dev/null; then
        langs+=("fortran")
    fi
    if find "$workdir" -name '*.rs' -type f -print | grep -q . 2>/dev/null; then
        langs+=("rust")
    fi
    if find "$workdir" -name '*.go' -type f -print | grep -q . 2>/dev/null; then
        langs+=("go")
    fi
    if find "$workdir" -name '*.py' -type f -print | grep -q . 2>/dev/null; then
        langs+=("python")
    fi
    if find "$workdir" -name '*.java' -type f -print | grep -q . 2>/dev/null; then
        langs+=("java")
    fi

    # Docs
    if find "$workdir" -name '*.texi' -o -name '*.texinfo' -type f -print | grep -q . 2>/dev/null; then
        docs+=("texinfo")
    fi
    if find "$workdir" -path '*/man/*' -o -name '*.1' -o -name '*.2' -o -name '*.3' -type f -print | grep -q . 2>/dev/null; then
        docs+=("man")
    fi
    if find "$workdir" -name conf.py -path '*/docs/*' -type f -print | grep -q . 2>/dev/null; then
        docs+=("sphinx")
    fi

    # Kernel / toolchain (heurísticos)
    if find "$workdir" -name Kconfig -o -path "$workdir/arch/*" -type f -print | grep -q . 2>/dev/null; then
        kernel=1
    fi

    # Hints de deps:
    #  - pkg-config: procura pkg-config nome.pc
    if grep -R --include='*.[ch]' -e 'pkg-config' "$workdir" 2>/dev/null | grep -q .; then
        # Tentativa de extrair nomes de .pc
        local line
        while IFS= read -r line; do
            # pega tokens que terminam com .pc
            for tok in $line; do
                case "$tok" in
                    *.pc)
                        tok="${tok##*/}"
                        tok="${tok%.pc}"
                        pkgs+=("$tok")
                        ;;
                esac
            done
        done < <(grep -R --include='*.[ch]' -e 'pkg-config' "$workdir" 2>/dev/null || true)
    fi

    # CMake find_package
    if grep -R --include='CMakeLists.txt' -e 'find_package(' "$workdir" 2>/dev/null | grep -q .; then
        while IFS= read -r line; do
            local name
            name="$(echo "$line" | sed -n 's/.*find_package([[:space:]]*\([^ )]*\).*/\1/p')"
            [ -n "$name" ] && pkgs+=("$name")
        done < <(grep -R --include='CMakeLists.txt' -e 'find_package(' "$workdir" 2>/dev/null || true)
    fi

    # Remover duplicatas
    local uniq_builds uniq_langs uniq_docs uniq_pkgs
    uniq_builds="$(printf '%s\n' "${builds[@]}" | awk 'NF && !seen[$0]++')"
    uniq_langs="$(printf '%s\n' "${langs[@]}" | awk 'NF && !seen[$0]++')"
    uniq_docs="$(printf '%s\n' "${docs[@]}" | awk 'NF && !seen[$0]++')"
    uniq_pkgs="$(printf '%s\n' "${pkgs[@]}" | awk 'NF && !seen[$0]++')"

    ADM_SRC_DETECTED_BUILDSYS="$uniq_builds"
    ADM_SRC_DETECTED_LANGS="$uniq_langs"
    ADM_SRC_DETECTED_DOCS="$uniq_docs"
    ADM_SRC_DETECTED_KERNEL="$kernel"
    ADM_SRC_DETECTED_PKGS="$uniq_pkgs"

    export ADM_SRC_DETECTED_BUILDSYS ADM_SRC_DETECTED_LANGS ADM_SRC_DETECTED_DOCS \
           ADM_SRC_DETECTED_KERNEL ADM_SRC_DETECTED_PKGS

    adm_info "Detecção de projeto em $workdir:"
    adm_info "  Build systems: ${ADM_SRC_DETECTED_BUILDSYS:-<nenhum>}"
    adm_info "  Linguagens:    ${ADM_SRC_DETECTED_LANGS:-<nenhuma>}"
    adm_info "  Docs:          ${ADM_SRC_DETECTED_DOCS:-<nenhum>}"
    adm_info "  Kernel?        ${ADM_SRC_DETECTED_KERNEL:-0}"
    adm_info "  Hints deps:    ${ADM_SRC_DETECTED_PKGS:-<nenhum>}"
}

# ----------------------------------------------------------------------
# Integração com metafile (10-repo-metafile.sh)
# ----------------------------------------------------------------------

adm_src_get_meta_sources_and_sums() {
    # Pega sources e sha256sums do metafile já carregado em ADM_META_*.
    # Requer adm_meta_get_var; senão, aborta.
    if ! declare -F adm_meta_get_var >/dev/null 2>&1; then
        adm_die "adm_meta_get_var não disponível; carregue 10-repo-metafile.sh antes."
    fi

    local sources sums
    sources="$(adm_meta_get_var "sources")"
    sums="$(adm_meta_get_var "sha256sums")"

    printf '%s\n' "$sources"
    printf '%s\n' "$sums"
}

adm_src_fetch_for_pkg() {
    # Faz:
    #   - carregar metafile de categoria/nome (se adm_meta_load existir)
    #   - baixar sources
    #   - extrair para workdir
    #   - detectar projeto
    #
    # Uso:
    #   adm_src_fetch_for_pkg categoria nome
    #
    local category="${1:-}"
    local name="${2:-}"

    [ -z "$category" ] && adm_die "adm_src_fetch_for_pkg requer categoria"
    [ -z "$name" ]     && adm_die "adm_src_fetch_for_pkg requer nome"

    local c n
    c="$(adm_repo_sanitize_category "$category")"
    n="$(adm_repo_sanitize_name "$name")"

    if ! declare -F adm_meta_load >/dev/null 2>&1; then
        adm_die "adm_meta_load não disponível; carregue 10-repo-metafile.sh antes de usar adm_src_fetch_for_pkg."
    fi

    adm_src_init_paths

    adm_info "Carregando metafile para $c/$n"
    adm_meta_load "$c" "$n"

    local sources sums version
    sources="$(adm_meta_get_var "sources")"
    sums="$(adm_meta_get_var "sha256sums")"
    version="$(adm_meta_get_var "version")"

    if [ -z "$version" ]; then
        adm_warn "Metafile sem versão definida; usando 'unknown' para workdir."
        version="unknown"
    fi

    local srcdir workdir
    srcdir="$ADM_SOURCES/$c/$n/$version"
    workdir="$(adm_src_workdir_for_pkg "$c" "$n" "$version")"

    adm_info "Source dir: $srcdir"
    adm_info "Workdir:    $workdir"

    # Limpa workdir antigo
    if [ -d "$workdir" ]; then
        adm_warn "Workdir existente para $c/$n-$version; removendo."
        rm -rf --one-file-system "$workdir" || adm_die "Falha ao limpar $workdir"
    fi

    adm_ensure_dir "$srcdir"
    adm_ensure_dir "$workdir"

    local downloaded
    downloaded="$(adm_src_download_many "$srcdir" "$sources" "$sums")"

    adm_src_extract_all_to_workdir "$downloaded" "$workdir"
    adm_src_detect_project "$workdir"

    # Exporta para uso posterior (build-engine)
    ADM_SRC_CURRENT_CATEGORY="$c"
    ADM_SRC_CURRENT_NAME="$n"
    ADM_SRC_CURRENT_VERSION="$version"
    ADM_SRC_CURRENT_SRCDIR="$srcdir"
    ADM_SRC_CURRENT_WORKDIR="$workdir"
    export ADM_SRC_CURRENT_CATEGORY ADM_SRC_CURRENT_NAME ADM_SRC_CURRENT_VERSION \
           ADM_SRC_CURRENT_SRCDIR ADM_SRC_CURRENT_WORKDIR

    adm_info "Sources preparados para $c/$n-$version."
}

# ----------------------------------------------------------------------
# CLI de demonstração
# ----------------------------------------------------------------------

adm_src_usage() {
    cat <<EOF
Uso: $(basename "$0") <comando> [args...]

Comandos:
  fetch-meta <categoria> <nome>
      - Carrega metafile (via 10-repo-metafile.sh), baixa sources, extrai e detecta projeto.

  detect <workdir>
      - Apenas roda a detecção de projeto em um workdir já existente.

  help
      - Mostra esta ajuda.

Exemplos:
  $(basename "$0") fetch-meta apps bash
  $(basename "$0") detect /usr/src/adm/work/bash-5.2
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cmd="${1:-help}"
    case "$cmd" in
        fetch-meta)
            [ "$#" -eq 3 ] || { adm_error "Uso: $0 fetch-meta <categoria> <nome>"; exit 1; }
            adm_src_fetch_for_pkg "$2" "$3"
            ;;
        detect)
            [ "$#" -eq 2 ] || { adm_error "Uso: $0 detect <workdir>"; exit 1; }
            adm_src_detect_project "$2"
            ;;
        help|-h|--help)
            adm_src_usage
            ;;
        *)
            adm_error "Comando desconhecido: $cmd"
            adm_src_usage
            exit 1
            ;;
    esac
fi
