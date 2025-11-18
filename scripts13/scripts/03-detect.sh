#!/usr/bin/env bash
# 03-detect.sh - Download, verificação e preparação de sources
# Pode ser chamado como script (CLI) ou 'sourced' para usar as funções.

###############################################################################
# Proteção contra execução direta sem env/lib
###############################################################################

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Chamado diretamente: modo CLI
    CLI_MODE=1
else
    CLI_MODE=0
fi

# Carrega env/lib se ainda não foram carregados
if [[ -z "${ADM_ENV_LOADED:-}" ]]; then
    if [[ -f /usr/src/adm/scripts/01-env.sh ]]; then
        # shellcheck disable=SC1091
        . /usr/src/adm/scripts/01-env.sh
    else
        echo "ERRO: 01-env.sh não encontrado em /usr/src/adm/scripts." >&2
        exit 1
    fi
fi

if [[ -z "${ADM_LIB_LOADED:-}" ]]; then
    if [[ -f /usr/src/adm/scripts/02-lib.sh ]]; then
        # shellcheck disable=SC1091
        . /usr/src/adm/scripts/02-lib.sh
    else
        echo "ERRO: 02-lib.sh não encontrado em /usr/src/adm/scripts." >&2
        exit 1
    fi
fi

###############################################################################
# 1. Variáveis internas de detect
###############################################################################

declare -a ADM_DETECT_SOURCES
declare -a ADM_DETECT_SHA256
declare -a ADM_DETECT_MD5
declare -a ADM_DETECT_LOCALPATHS
declare -a ADM_DETECT_TYPES

ADM_DETECT_BUILDROOT=""
ADM_DETECT_WORKDIR=""
ADM_DETECT_MANIFEST=""

###############################################################################
# 2. Helpers de busca de metafile
###############################################################################

adm_detect_find_metafile_for_pkg() {
    # Uso: adm_detect_find_metafile_for_pkg <nome>
    local name="$1"
    local f

    # repo/<categoria>/<nome>/metafile
    while IFS= read -r -d '' f; do
        if [[ "$(basename "$(dirname "$f")")" == "$name" ]]; then
            echo "$f"
            return 0
        fi
    done < <(find "${ADM_REPO}" -maxdepth 3 -type f -name "metafile" -print0 2>/dev/null || true)

    return 1
}

###############################################################################
# 3. Parse de sources e checksums do metafile
###############################################################################

adm_detect_load_sources_from_meta() {
    ADM_DETECT_SOURCES=()
    ADM_DETECT_SHA256=()
    ADM_DETECT_MD5=()
    ADM_DETECT_LOCALPATHS=()
    ADM_DETECT_TYPES=()

    local -a srcs sha md5
    adm_meta_get_sources_array srcs

    # sha256sums e md5sum podem ter menos entradas que sources
    adm_split_csv_to_array "${ADM_META_sha256sums}" sha
    adm_split_csv_to_array "${ADM_META_md5sum}" md5

    local i
    for (( i=0; i<${#srcs[@]}; i++ )); do
        ADM_DETECT_SOURCES[i]="${srcs[i]}"
        ADM_DETECT_SHA256[i]="${sha[i]:-}"
        ADM_DETECT_MD5[i]="${md5[i]:-}"
        ADM_DETECT_LOCALPATHS[i]=""
        ADM_DETECT_TYPES[i]=""
    done
}

###############################################################################
# 4. Classificação do tipo de source
###############################################################################

adm_detect_classify_source() {
    # Uso: adm_detect_classify_source <url|path>
    local src="$1"

    # Diretório ou arquivo local
    if [[ -d "$src" || -f "$src" ]]; then
        if [[ -d "$src" ]]; then
            echo "local-dir"
        else
            echo "local-file"
        fi
        return 0
    fi

    # Padrões de URL
    if [[ "$src" =~ ^git:// ]] || [[ "$src" =~ ^git@ ]] || [[ "$src" =~ ^ssh://git@ ]] || [[ "$src" =~ \.git(/)?$ ]]; then
        echo "git"
        return 0
    fi

    if [[ "$src" =~ ^rsync:// ]]; then
        echo "rsync"
        return 0
    fi

    if [[ "$src" =~ ^https?:// ]] || [[ "$src" =~ ^ftp:// ]]; then
        # github / gitlab / sourceforge ainda são "file" (tarball, etc)
        echo "remote-file"
        return 0
    fi

    # Fallback: tratar como remoto via HTTP/HTTPS? Não, melhor considerar erro
    echo "unknown"
    return 0
}

###############################################################################
# 5. Download dos sources em paralelo
###############################################################################

adm_detect_download_one() {
    local idx="$1"
    local src="${ADM_DETECT_SOURCES[idx]}"
    local t="${ADM_DETECT_TYPES[idx]}"

    local dest=""

    case "$t" in
        local-dir)
            # Apenas registra o path local
            ADM_DETECT_LOCALPATHS[idx]="$(readlink -f "$src" 2>/dev/null || echo "$src")"
            return 0
            ;;
        local-file)
            ADM_DETECT_LOCALPATHS[idx]="$(readlink -f "$src" 2>/dev/null || echo "$src")"
            return 0
            ;;
        git)
            dest="${ADM_SOURCES}/${ADM_META_name}-${ADM_META_version}-git-${idx}"
            rm -rf "$dest" 2>/dev/null || true
            if ! command -v git >/dev/null 2>&1; then
                adm_error "git não encontrado para clonar '$src'."
                return 1
            fi
            adm_debug "Clonando git '$src' em '$dest'."
            git clone --depth=1 "$src" "$dest" >/dev/null 2>&1
            ADM_DETECT_LOCALPATHS[idx]="$dest"
            return 0
            ;;
        rsync)
            dest="${ADM_SOURCES}/${ADM_META_name}-${ADM_META_version}-rsync-${idx}"
            rm -rf "$dest" 2>/dev/null || true
            if ! command -v rsync >/dev/null 2>&1; then
                adm_error "rsync não encontrado para '$src'."
                return 1
            fi
            adm_debug "Sincronizando rsync '$src' em '$dest'."
            rsync -a "$src" "$dest" >/dev/null 2>&1
            ADM_DETECT_LOCALPATHS[idx]="$dest"
            return 0
            ;;
        remote-file)
            local base
            base="$(basename "$src")"
            [[ -z "$base" || "$base" == "/" ]] && base="source-${idx}"
            dest="${ADM_SOURCES}/${base}"

            # Evita sobrescrever algo que não seja nosso
            if [[ -f "$dest" ]]; then
                adm_debug "Arquivo '$dest' já existe, reutilizando."
                ADM_DETECT_LOCALPATHS[idx]="$dest"
                return 0
            fi

            if command -v curl >/dev/null 2>&1; then
                curl -L -o "$dest" "$src" >/dev/null 2>&1 || {
                    adm_error "Falha ao baixar '$src' com curl."
                    return 1
                }
            elif command -v wget >/dev/null 2>&1; then
                wget -O "$dest" "$src" >/dev/null 2>&1 || {
                    adm_error "Falha ao baixar '$src' com wget."
                    return 1
                }
            else
                adm_error "Nem curl nem wget disponíveis para baixar '$src'."
                return 1
            fi

            ADM_DETECT_LOCALPATHS[idx]="$dest"
            return 0
            ;;
        *)
            adm_error "Tipo de source desconhecido para '$src' (tipo='$t')."
            return 1
            ;;
    esac
}

adm_detect_download_all() {
    local i p
    local -a pids
    pids=()

    for (( i=0; i<${#ADM_DETECT_SOURCES[@]}; i++ )); do
        ADM_DETECT_TYPES[i]="$(adm_detect_classify_source "${ADM_DETECT_SOURCES[i]}")"
        if [[ "${ADM_DETECT_TYPES[i]}" == "unknown" ]]; then
            adm_error "Não sei como lidar com source: '${ADM_DETECT_SOURCES[i]}'"
            return 1
        fi
    done

    adm_info "Iniciando download/preparo de ${#ADM_DETECT_SOURCES[@]} source(s)..."

    for (( i=0; i<${#ADM_DETECT_SOURCES[@]}; i++ )); do
        # local-dir e local-file não precisam spawn separado
        case "${ADM_DETECT_TYPES[i]}" in
            local-dir|local-file)
                adm_detect_download_one "$i" || return 1
                ;;
            *)
                (
                    adm_detect_download_one "$i"
                ) &
                pids+=("$!")
                ;;
        esac
    done

    # Espera pelos paralelos
    for p in "${pids[@]}"; do
        if ! wait "$p"; then
            adm_error "Um dos downloads falhou (PID=$p)."
            return 1
        end
    done

    adm_info "Downloads/preparo de sources concluídos."
    return 0
}

###############################################################################
# 6. Verificação de checksums
###############################################################################

adm_detect_verify_checksums() {
    local i path sum expected_sha expected_md5 ok
    ok=1

    for (( i=0; i<${#ADM_DETECT_SOURCES[@]}; i++ )); do
        path="${ADM_DETECT_LOCALPATHS[i]}"
        expected_sha="${ADM_DETECT_SHA256[i]}"
        expected_md5="${ADM_DETECT_MD5[i]}"

        # Diretórios (local-dir, git, rsync) não verificam checksum aqui
        if [[ -d "$path" ]]; then
            continue
        fi

        if [[ ! -f "$path" ]]; then
            adm_error "Arquivo para verificação não encontrado: '$path'"
            ok=0
            continue
        fi

        if [[ -n "$expected_sha" ]]; then
            if ! command -v sha256sum >/dev/null 2>&1; then
                adm_warn "sha256sum não disponível; pulando verificação SHA256 de '$path'."
            else
                local got_sha
                got_sha="$(sha256sum "$path" 2>/dev/null | awk '{print $1}')"
                if [[ "$got_sha" != "$expected_sha" ]]; then
                    adm_error "SHA256 inválido para '$path'. Esperado='$expected_sha', obtido='$got_sha'."
                    ok=0
                else
                    adm_info "SHA256 OK para '$path'."
                fi
            fi
        fi

        if [[ -n "$expected_md5" ]]; then
            if ! command -v md5sum >/dev/null 2>&1; then
                adm_warn "md5sum não disponível; pulando verificação MD5 de '$path'."
            else
                local got_md5
                got_md5="$(md5sum "$path" 2>/dev/null | awk '{print $1}')"
                if [[ "$got_md5" != "$expected_md5" ]]; then
                    adm_error "MD5 inválido para '$path'. Esperado='$expected_md5', obtido='$got_md5'."
                    ok=0
                else
                    adm_info "MD5 OK para '$path'."
                fi
            fi
        fi
    done

    if [[ "$ok" -ne 1 ]]; then
        adm_error "Falha na verificação de checksums."
        return 1
    fi
    return 0
}
###############################################################################
# 7. Preparação do diretório de build e extração
###############################################################################

adm_detect_prepare_build_root() {
    ADM_DETECT_BUILDROOT="${ADM_BUILD}/${ADM_META_name}-${ADM_META_version}"

    if [[ -d "$ADM_DETECT_BUILDROOT" ]]; then
        adm_warn "Build root '${ADM_DETECT_BUILDROOT}' já existe; será limpo."
        rm -rf "${ADM_DETECT_BUILDROOT}"/* 2>/dev/null || true
    else
        mkdir -p "$ADM_DETECT_BUILDROOT" || {
            adm_error "Não foi possível criar build root '${ADM_DETECT_BUILDROOT}'."
            return 1
        }
    fi
}

adm_detect_extract_one() {
    local idx="$1"
    local path="${ADM_DETECT_LOCALPATHS[idx]}"
    local t="${ADM_DETECT_TYPES[idx]}"

    if [[ -z "$path" ]]; then
        adm_error "Source local path vazio para índice ${idx}."
        return 1
    fi

    case "$t" in
        local-dir|git|rsync)
            # Copia/consolida dentro de BUILDROOT
            adm_debug "Copiando diretório '$path' para build root."
            cp -a "$path" "${ADM_DETECT_BUILDROOT}/" || {
                adm_error "Falha ao copiar '$path' para '${ADM_DETECT_BUILDROOT}'."
                return 1
            }
            ;;
        local-file|remote-file)
            # Extrai arquivo
            local ext
            ext="${path##*.}"

            if [[ "$path" =~ \.tar\.gz$ || "$path" =~ \.tgz$ ]]; then
                tar -xzf "$path" -C "$ADM_DETECT_BUILDROOT" || return 1
            elif [[ "$path" =~ \.tar\.bz2$ || "$path" =~ \.tbz2$ ]]; then
                tar -xjf "$path" -C "$ADM_DETECT_BUILDROOT" || return 1
            elif [[ "$path" =~ \.tar\.xz$ || "$path" =~ \.txz$ ]]; then
                tar -xJf "$path" -C "$ADM_DETECT_BUILDROOT" || return 1
            elif [[ "$path" =~ \.tar\.zst$ || "$path" =~ \.tzst$ ]]; then
                if ! command -v zstd >/dev/null 2>&1; then
                    adm_error "zstd não disponível para extrair '$path'."
                    return 1
                fi
                # extrai manualmente
                local tmp="${path%.zst}"
                zstd -d -c "$path" > "$tmp" || return 1
                tar -xf "$tmp" -C "$ADM_DETECT_BUILDROOT" || return 1
                rm -f "$tmp" || true
            elif [[ "$path" =~ \.tar$ ]]; then
                tar -xf "$path" -C "$ADM_DETECT_BUILDROOT" || return 1
            elif [[ "$path" =~ \.zip$ ]]; then
                if ! command -v unzip >/dev/null 2>&1; then
                    adm_error "unzip não disponível para extrair '$path'."
                    return 1
                fi
                unzip -q "$path" -d "$ADM_DETECT_BUILDROOT" || return 1
            elif [[ "$path" =~ \.7z$ ]]; then
                if ! command -v 7z >/dev/null 2>&1; then
                    adm_error "7z não disponível para extrair '$path'."
                    return 1
                fi
                7z x "$path" -o"$ADM_DETECT_BUILDROOT" >/dev/null || return 1
            else
                adm_warn "Extensão desconhecida para '$path'; copiando sem extrair."
                cp -a "$path" "${ADM_DETECT_BUILDROOT}/" || return 1
            fi
            ;;
        *)
            adm_error "Tipo de source não suportado na extração: '$t'."
            return 1
            ;;
    esac
}

adm_detect_extract_all() {
    local i
    for (( i=0; i<${#ADM_DETECT_SOURCES[@]}; i++ )); do
        adm_info "Preparando source ${i}/${#ADM_DETECT_SOURCES[@]}: ${ADM_DETECT_SOURCES[i]}"
        adm_detect_extract_one "$i" || return 1
    done
    return 0
}

###############################################################################
# 8. Detecção do diretório de trabalho principal
###############################################################################

adm_detect_primary_workdir() {
    local root="$ADM_DETECT_BUILDROOT"
    local -a entries
    local d count=0 last=""

    # Considera apenas diretórios
    while IFS= read -r -d '' d; do
        entries+=("$d")
        last="$d"
        count=$((count + 1))
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)

    if (( count == 0 )); then
        # Sem diretórios, usa root
        ADM_DETECT_WORKDIR="$root"
        return 0
    elif (( count == 1 )); then
        ADM_DETECT_WORKDIR="$last"
        return 0
    else
        # Vários diretórios; tenta achar algo com nome parecido com name-version
        local pattern="${ADM_META_name}-${ADM_META_version}"
        for d in "${entries[@]}"; do
            if [[ "$(basename "$d")" == "$pattern" ]]; then
                ADM_DETECT_WORKDIR="$d"
                return 0
            fi
        done
        # fallback: usa root
        ADM_DETECT_WORKDIR="$root"
        return 0
    fi
}

###############################################################################
# 9. Detecção do sistema de build
###############################################################################

adm_detect_build_system() {
    local wd="$ADM_DETECT_WORKDIR"

    # Se o metafile já definir build_type no futuro, aqui poderia respeitar.
    local build_type="custom"

    if [[ -f "${wd}/configure.ac" || -f "${wd}/configure.in" || -f "${wd}/configure" ]]; then
        build_type="autotools"
    elif [[ -f "${wd}/CMakeLists.txt" ]]; then
        build_type="cmake"
    elif [[ -f "${wd}/meson.build" ]]; then
        build_type="meson"
    elif [[ -f "${wd}/Cargo.toml" ]]; then
        build_type="cargo"
    elif [[ -f "${wd}/package.json" ]]; then
        build_type="node"
    elif [[ -f "${wd}/pyproject.toml" || -f "${wd}/setup.py" ]]; then
        build_type="python"
    elif [[ -f "${wd}/Makefile" || -f "${wd}/makefile" ]]; then
        build_type="make"
    fi

    echo "$build_type"
}

###############################################################################
# 10. Escrita do manifesto de source (.adm-source-manifest)
###############################################################################

adm_detect_write_manifest() {
    local build_system="$1"

    ADM_DETECT_MANIFEST="${ADM_DETECT_BUILDROOT}/.adm-source-manifest"

    cat > "${ADM_DETECT_MANIFEST}" <<EOF
name=${ADM_META_name}
version=${ADM_META_version}
category=${ADM_META_category}
build_root=${ADM_DETECT_BUILDROOT}
workdir=${ADM_DETECT_WORKDIR}
build_system=${build_system}
sources=${ADM_META_sources}
sha256sums=${ADM_META_sha256sums}
md5sum=${ADM_META_md5sum}
EOF

    adm_info "Manifesto de source criado em: ${ADM_DETECT_MANIFEST}"
}

###############################################################################
# 11. Pipeline principal de detecção
###############################################################################

adm_detect_pipeline() {
    local metafile="$1"

    adm_init_log "detect-$(basename "$metafile")"
    adm_info "Iniciando 03-detect para metafile: ${metafile}"

    adm_meta_load "$metafile" || return 1
    adm_detect_load_sources_from_meta

    adm_run_with_spinner "Baixando/preparando sources..." adm_detect_download_all || return 1
    adm_run_with_spinner "Verificando checksums..." adm_detect_verify_checksums || return 1
    adm_run_with_spinner "Preparando diretório de build..." adm_detect_prepare_build_root || return 1
    adm_run_with_spinner "Extraindo todos os sources..." adm_detect_extract_all || return 1
    adm_run_with_spinner "Detectando diretório de trabalho..." adm_detect_primary_workdir || return 1

    local build_system
    build_system="$(adm_detect_build_system)"
    adm_info "Sistema de build detectado: ${build_system}"

    adm_detect_write_manifest "$build_system"

    adm_info "03-detect concluído com sucesso para ${ADM_META_name}-${ADM_META_version}."
}

###############################################################################
# 12. CLI (se executado diretamente)
###############################################################################

adm_detect_usage() {
    cat <<EOF
Uso: 03-detect.sh <pacote|caminho_metafile>

- Se for nome de pacote, procura em: ${ADM_REPO}/<categoria>/<pacote>/metafile
- Se for caminho para arquivo ou diretório, usa o 'metafile' ali.

Exemplos:
  03-detect.sh bash
  03-detect.sh ${ADM_REPO}/sys/bash/metafile
EOF
}

adm_detect_main() {
    adm_enable_strict_mode

    if [[ $# -lt 1 ]]; then
        adm_detect_usage
        exit 1
    fi

    local arg="$1"
    local metafile=""

    if [[ -f "$arg" || -d "$arg" ]]; then
        if [[ -d "$arg" ]]; then
            metafile="${arg%/}/metafile"
        else
            metafile="$arg"
        fi
    else
        # Trata como nome de pacote
        metafile="$(adm_detect_find_metafile_for_pkg "$arg" || true)"
        if [[ -z "$metafile" ]]; then
            adm_error "Metafile não encontrado para pacote '$arg'."
            exit 1
        fi
    fi

    adm_detect_pipeline "$metafile"
}

if [[ "$CLI_MODE" -eq 1 ]]; then
    adm_detect_main "$@"
fi
