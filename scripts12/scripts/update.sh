#!/usr/bin/env bash
# update.sh – Atualizador EXTREMO de metafiles do ADM
#
# Funções principais:
#   adm_update_main               → CLI: atualiza 1 pacote (e deps) gerando novos metafiles
#   adm_update_package            → atualiza apenas o pacote alvo
#   adm_update_package_and_deps   → pacote + dependências diretas (run+build)
#
# Comportamento:
#   - Lê o metafile de /usr/src/adm/repo/<cat>/<name>/metafile
#   - Detecta versão estável mais recente no upstream:
#       * Git:   git ls-remote --tags
#       * HTTP:  parsing do índice do diretório com padrão baseado no URL atual
#   - Com a nova versão:
#       * Reescreve os sources usando a nova versão (substitui MF_VERSION)
#       * baixa os novos sources,
#       * calcula novos sha256sums ou md5sum (mantendo o tipo do metafile original),
#       * gera um **novo metafile** em:
#             /usr/src/adm/update/<name>/metafile
#   - Repete o processo para as dependências (run_deps + build_deps), se habilitado.
#
# NUNCA silencia erros: sempre loga com contexto preciso.

ADM_ROOT="/usr/src/adm"
ADM_REPO="$ADM_ROOT/repo"
ADM_UPDATE_ROOT="$ADM_ROOT/update"
ADM_UPDATE_CACHE="$ADM_UPDATE_ROOT/distfiles"

# Categorias válidas (para localizar metafiles sem usar find)
ADM_KNOWN_CATEGORIES=(apps libs sys dev x11 wayland)

# --------------------------------
# Integração opcional com ui.sh
# --------------------------------
_UPD_HAVE_UI=0

if declare -F adm_ui_log_info >/dev/null 2>&1; then
    _UPD_HAVE_UI=1
fi

_upd_log() {
    # $1 = nível (INFO|WARN|ERROR|DEBUG)
    # $2... = msg
    local lvl="$1"; shift || true
    local msg="$*"

    if [ "$_UPD_HAVE_UI" -eq 1 ]; then
        case "$lvl" in
            INFO)  adm_ui_log_info  "$msg" ;;
            WARN)  adm_ui_log_warn  "$msg" ;;
            ERROR) adm_ui_log_error "$msg" ;;
            DEBUG) adm_ui_log_info  "[DEBUG] $msg" ;;
            *)     adm_ui_log_info  "$msg" ;;
        esac
    else
        printf 'update[%s]: %s\n' "$lvl" "$msg" >&2
    fi
}

_upd_fail() {
    _upd_log ERROR "$*"
    return 1
}

_upd_trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# --------------------------------
# Carregar metafile.sh se preciso
# --------------------------------
_upd_ensure_metafile_lib() {
    if declare -F adm_meta_load >/dev/null 2>&1; then
        return 0
    fi
    local f="$ADM_ROOT/scripts/metafile.sh"
    if [ -r "$f" ]; then
        # shellcheck source=/usr/src/adm/scripts/metafile.sh
        . "$f" || return 1
        return 0
    fi
    _upd_fail "metafile.sh não encontrado em $f"
}

# --------------------------------
# HTTP/Git helpers locais
# --------------------------------
_upd_have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

_upd_choose_http_client() {
    if _upd_have_cmd curl; then
        echo "curl"
    elif _upd_have_cmd wget; then
        echo "wget"
    else
        echo ""
    fi
}

_upd_http_get() {
    # $1 = URL
    local url="$1"
    local client
    client="$(_upd_choose_http_client)"
    if [ -z "$client" ]; then
        _upd_fail "Nenhum cliente HTTP (curl/wget) disponível para $url"
        return 1
    fi

    case "$client" in
        curl)
            curl -L --fail --silent "$url"
            ;;
        wget)
            wget -q -O - "$url"
            ;;
    esac
}

_upd_http_download_to_file() {
    # $1 = URL, $2 = destino
    local url="$1"
    local dest="$2"
    local client
    client="$(_upd_choose_http_client)"
    if [ -z "$client" ]; then
        _upd_fail "Nenhum cliente HTTP (curl/wget) disponível para download: $url"
        return 1
    fi

    case "$client" in
        curl)
            curl -L --fail -o "$dest" "$url" || {
                _upd_fail "Falha ao baixar (curl): $url"
                rm -f "$dest" 2>/dev/null || true
                return 1
            }
            ;;
        wget)
            wget -O "$dest" "$url" || {
                _upd_fail "Falha ao baixar (wget): $url"
                rm -f "$dest" 2>/dev/null || true
                return 1
            }
            ;;
    esac

    return 0
}

_upd_download_to_cache() {
    # $1 = URL
    # stdout: caminho do arquivo em cache
    local url="$1"
    local base="${url##*/}"
    base="${base%%\?*}"
    [ -z "$base" ] && base="source_$(date +%s)_$$"

    if ! mkdir -p "$ADM_UPDATE_CACHE" 2>/dev/null; then
        _upd_fail "Não foi possível criar diretório de cache de update: $ADM_UPDATE_CACHE"
        return 1
    fi

    local dest="$ADM_UPDATE_CACHE/$base"
    # se já existir, reusa (útil em testes); mas poderíamos forçar re-download.
    if [ -f "$dest" ]; then
        printf '%s\n' "$dest"
        return 0
    fi

    if ! _upd_http_download_to_file "$url" "$dest"; then
        return 1
    fi

    printf '%s\n' "$dest"
    return 0
}

# --------------------------------
# Localizar metafile do pacote
# --------------------------------
_upd_find_metafile_for_pkg() {
    # $1 = nome do pacote (MF_NAME)
    local pkg="$1"
    local cat f

    if [ -z "$pkg" ]; then
        _upd_fail "_upd_find_metafile_for_pkg: nome de pacote vazio"
        return 1
    fi

    for cat in "${ADM_KNOWN_CATEGORIES[@]}"; do
        f="$ADM_REPO/$cat/$pkg/metafile"
        if [ -f "$f" ]; then
            printf '%s\n' "$f"
            return 0
        fi
    done

    _upd_fail "Metafile não encontrado para pacote '$pkg' em $ADM_REPO/{apps,libs,sys,dev,x11,wayland}/$pkg/metafile"
    return 1
}

_upd_load_meta_for_pkg() {
    # $1 = nome do pacote
    local pkg="$1"
    local mf

    _upd_ensure_metafile_lib || return 1

    mf="$(_upd_find_metafile_for_pkg "$pkg")" || return 1

    if ! adm_meta_load "$mf"; then
        _upd_fail "Falha ao carregar metafile de '$pkg': $mf"
        return 1
    fi

    # Sanidade: MF_NAME deve bater com pkg (se definido)
    if [ -n "${MF_NAME:-}" ] && [ "$MF_NAME" != "$pkg" ]; then
        _upd_fail "MF_NAME='$MF_NAME' diferente do pacote solicitado '$pkg' (metafile: $mf)"
        return 1
    fi

    return 0
}

# --------------------------------
# Comparação de versões (usando sort -V)
# --------------------------------
_upd_version_is_newer() {
    # Retorna 0 se $1 > $2 (versão nova > atual),
    #         1 caso contrário.
    local new="$1"
    local cur="$2"

    if [ -z "$new" ] || [ -z "$cur" ]; then
        return 1
    fi

    # sort -V: ordena versões "naturalmente"
    local top
    top="$(printf '%s\n%s\n' "$new" "$cur" | sort -V | tail -n1)"
    if [ "$top" = "$new" ] && [ "$new" != "$cur" ]; then
        return 0
    fi
    return 1
}

# --------------------------------
# Tipo de URL/source
# --------------------------------
_upd_is_git_url() {
    case "$1" in
        git+*|*.git|*://github.com/*|*://gitlab.com/*)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

_upd_is_http_like() {
    case "$1" in
        http://*|https://*|ftp://*)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

# --------------------------------
# Checksum helper
# --------------------------------
_upd_calc_checksum() {
    # $1 = tipo (sha256|md5)
    # $2 = arquivo
    local type="$1"
    local file="$2"

    if [ ! -f "$file" ]; then
        _upd_fail "Arquivo para checksum não encontrado: $file"
        return 1
    fi

    case "$type" in
        sha256)
            if ! _upd_have_cmd sha256sum; then
                _upd_fail "sha256sum não encontrado para gerar checksum de $file"
                return 1
            fi
            sha256sum "$file" 2>/dev/null | awk '{print $1}'
            ;;
        md5)
            if ! _upd_have_cmd md5sum; then
                _upd_fail "md5sum não encontrado para gerar checksum de $file"
                return 1
            fi
            md5sum "$file" 2>/dev/null | awk '{print $1}'
            ;;
        *)
            _upd_fail "Tipo de checksum desconhecido: $type"
            return 1
            ;;
    esac
}

# --------------------------------
# Estado temporário para construção
# de novo metafile
# --------------------------------
UPD_NEW_SOURCES=""
UPD_NEW_HASHES=""
UPD_HASH_FIELD=""   # "sha256sums" ou "md5sum"
UPD_HASH_TYPE=""    # "sha256" ou "md5"

_upd_reset_tmp_meta_state() {
    UPD_NEW_SOURCES=""
    UPD_NEW_HASHES=""
    UPD_HASH_FIELD=""
    UPD_HASH_TYPE=""
}
# --------------------------------
# Detectar versão estável mais nova
# --------------------------------

_upd_git_latest_stable_version() {
    # $1 = URL do repositório git
    # stdout: versão "normalizada" (sem 'v') ou vazio em falha
    local url="$1"

    if ! _upd_have_cmd git; then
        _upd_fail "git não disponível para detectar tags em $url"
        return 1
    fi

    local tags
    if ! tags="$(git ls-remote --tags --refs "$url" 2>/dev/null | awk '{print $2}' | sed 's@refs/tags/@@')"; then
        _upd_fail "git ls-remote falhou em $url"
        return 1
    fi

    if [ -z "$tags" ]; then
        _upd_log WARN "Nenhuma tag encontrada em $url"
        return 1
    fi

    local best=""
    local t v

    for t in $tags; do
        v="$t"
        v="${v#v}"  # tira prefixo 'v' comum

        # Ignora releases com sufixos -rc, -beta, etc
        if printf '%s\n' "$v" | grep -Eq -- '-(alpha|beta|rc|pre)'; then
            continue
        fi

        # Aceita apenas versões numéricas simples
        if ! printf '%s\n' "$v" | grep -Eq '^[0-9]+(\.[0-9]+)*$'; then
            continue
        fi

        if [ -z "$best" ]; then
            best="$v"
        else
            local top
            top="$(printf '%s\n%s\n' "$best" "$v" | sort -V | tail -n1)"
            if [ "$top" = "$v" ]; then
                best="$v"
            fi
        fi
    done

    if [ -z "$best" ]; then
        _upd_log WARN "Nenhuma tag estável numérica encontrada em $url"
        return 1
    fi

    printf '%s\n' "$best"
    return 0
}

_upd_http_latest_stable_version() {
    # $1 = URL do tarball atual (com versão)
    # $2 = versão atual (MF_VERSION)
    # stdout: nova versão ou vazio
    local url="$1"
    local cur_ver="$2"

    if ! _upd_is_http_like "$url"; then
        _upd_fail "_upd_http_latest_stable_version: URL não HTTP/FTP: $url"
        return 1
    fi

    local base_dir file_pat name_prefix suffix
    file_pat="${url##*/}"
    file_pat="${file_pat%%\?*}"

    if [ -z "$file_pat" ]; then
        _upd_fail "Não foi possível extrair nome de arquivo de $url"
        return 1
    fi

    # Usamos MF_VERSION (cur_ver) para identificar prefixo e sufixo
    if [ -z "$cur_ver" ]; then
        _upd_fail "Versão atual vazia para URL $url"
        return 1
    fi

    case "$file_pat" in
        *"$cur_ver"*)
            name_prefix="${file_pat%%$cur_ver*}"
            suffix="${file_pat#*$cur_ver}"
            ;;
        *)
            _upd_fail "Nome de arquivo '$file_pat' não contém a versão atual '$cur_ver'; não sei montar padrão"
            return 1
            ;;
    esac

    base_dir="${url%/*}/"

    _upd_log INFO "Buscando índice em $base_dir para detectar novas versões de padrão '$name_prefix<ver>$suffix'"

    local html
    if ! html="$(_upd_http_get "$base_dir")"; then
        _upd_fail "Falha ao obter índice de diretório: $base_dir"
        return 1
    fi

    # Padrão simplificado: name_prefix + versão numérica + suffix
    local regex
    regex="${name_prefix}[0-9][0-9.]*${suffix}"

    # shellcheck disable=SC2086
    local candidates
    candidates="$(printf '%s\n' "$html" | grep -Eo "$regex" | sort -u)" || true

    if [ -z "$candidates" ]; then
        _upd_log WARN "Nenhum arquivo candidato encontrado em $base_dir usando regex '$regex'"
        return 1
    fi

    local best_ver=""
    local fname ver

    for fname in $candidates; do
        ver="${fname#$name_prefix}"
        ver="${ver%$suffix}"

        # só versões numéricas simples
        if ! printf '%s\n' "$ver" | grep -Eq '^[0-9]+(\.[0-9]+)*$'; then
            continue
        fi

        if ! _upd_version_is_newer "$ver" "$cur_ver"; then
            continue
        fi

        if [ -z "$best_ver" ]; then
            best_ver="$ver"
        else
            local top
            top="$(printf '%s\n%s\n' "$best_ver" "$ver" | sort -V | tail -n1)"
            if [ "$top" = "$ver" ]; then
                best_ver="$ver"
            fi
        fi
    done

    if [ -z "$best_ver" ]; then
        _upd_log INFO "Nenhuma versão HTTP mais recente que $cur_ver foi encontrada em $base_dir"
        return 1
    fi

    printf '%s\n' "$best_ver"
    return 0
}

_upd_detect_latest_version_for_primary_source() {
    # Usa MF_SOURCES_ARR[0] como fonte "primária"
    # stdout: nova versão ou vazio se nenhuma atualização
    _upd_ensure_metafile_lib || return 1

    if [ "${#MF_SOURCES_ARR[@]}" -eq 0 ]; then
        _upd_fail "MF_SOURCES_ARR vazio; metafile não tem sources corretos"
        return 1
    fi

    local primary="${MF_SOURCES_ARR[0]}"
    local cur_ver="$MF_VERSION"
    local new_ver=""

    if _upd_is_git_url "$primary"; then
        _upd_log INFO "Detectando versão estável via GIT em $primary"
        if ! new_ver="$(_upd_git_latest_stable_version "$primary")"; then
            return 1
        fi
    elif _upd_is_http_like "$primary"; then
        _upd_log INFO "Detectando versão estável via HTTP em $primary"
        if ! new_ver="$(_upd_http_latest_stable_version "$primary" "$cur_ver")"; then
            return 1
        fi
    else
        _upd_fail "URL primária não suportada para detecção automática: $primary"
        return 1
    fi

    if [ -z "$new_ver" ]; then
        _upd_log INFO "Nenhuma nova versão estável encontrada (url primária: $primary)"
        return 1
    fi

    if ! _upd_version_is_newer "$new_ver" "$cur_ver"; then
        _upd_log INFO "Versão detectada ($new_ver) não é mais nova que a atual ($cur_ver)"
        return 1
    fi

    printf '%s\n' "$new_ver"
    return 0
}

# --------------------------------
# Construir nova lista de sources + checksums
# --------------------------------

_upd_build_new_sources_and_checksums() {
    # $1 = nova versão
    local new_ver="$1"

    if [ -z "$new_ver" ]; then
        _upd_fail "_upd_build_new_sources_and_checksums: nova versão vazia"
        return 1
    fi

    # Definir tipo de checksum conforme metafile original
    if [ -n "${MF_SHA256SUMS:-}" ]; then
        UPD_HASH_FIELD="sha256sums"
        UPD_HASH_TYPE="sha256"
    elif [ -n "${MF_MD5SUM:-}" ]; then
        UPD_HASH_FIELD="md5sum"
        UPD_HASH_TYPE="md5"
    else
        # fallback: usar sha256
        UPD_HASH_FIELD="sha256sums"
        UPD_HASH_TYPE="sha256"
        _upd_log WARN "Metafile sem sha256sums/md5sum definido; usando sha256 automaticamente"
    fi

    if [ "${#MF_SOURCES_ARR[@]}" -eq 0 ]; then
        _upd_fail "_upd_build_new_sources_and_checksums: MF_SOURCES_ARR vazio"
        return 1
    fi

    local i src new_src file sum
    local new_sources_list=()
    local new_hashes_list=()

    for i in "${!MF_SOURCES_ARR[@]}"; do
        src="${MF_SOURCES_ARR[$i]}"

        # tentativa simples: substituir MF_VERSION pela nova versão
        if printf '%s\n' "$src" | grep -q -- "$MF_VERSION"; then
            new_src="${src//$MF_VERSION/$new_ver}"
        else
            # fonte auxiliar (patch, asset extra) que não carrega a versão no nome
            new_src="$src"
        fi

        _upd_log INFO "Source [$i]: '$src' -> '$new_src'"

        # Download + checksum
        file="$(_upd_download_to_cache "$new_src")" || {
            _upd_fail "Falha ao baixar novo source: $new_src"
            return 1
        }

        if ! sum="$(_upd_calc_checksum "$UPD_HASH_TYPE" "$file")"; then
            _upd_fail "Falha ao calcular checksum do source: $file"
            return 1
        fi

        new_sources_list+=("$new_src")
        new_hashes_list+=("$sum")
    done

    # Monta strings CSV
    local IFS=','
    UPD_NEW_SOURCES="${new_sources_list[*]}"
    UPD_NEW_HASHES="${new_hashes_list[*]}"

    _upd_log INFO "Novos sources construídos: $UPD_NEW_SOURCES"
    _upd_log INFO "Novos checksums ($UPD_HASH_TYPE): $UPD_NEW_HASHES"
    return 0
}

# --------------------------------
# Atualizar um único pacote → gerar metafile novo em /usr/src/adm/update/<pkg>/metafile
# --------------------------------

adm_update_generate_metafile_for_current_pkg() {
    # Pré-condição: MF_* (do pacote desejado) já carregados
    # Pós-condição: se houver versão nova, gera /usr/src/adm/update/<MF_NAME>/metafile
    _upd_reset_tmp_meta_state

    if [ -z "${MF_NAME:-}" ] || [ -z "${MF_VERSION:-}" ]; then
        _upd_fail "adm_update_generate_metafile_for_current_pkg: MF_NAME/MF_VERSION vazios"
        return 1
    fi

    local pkg="$MF_NAME"
    local cur_ver="$MF_VERSION"
    local new_ver=""

    if ! new_ver="$(_upd_detect_latest_version_for_primary_source)"; then
        _upd_log WARN "Não foi possível detectar nova versão para '$pkg' (mantendo metafile atual)."
        return 1
    fi

    _upd_log INFO "Pacote '$pkg': versão atual=$cur_ver, nova versão detectada=$new_ver"

    if ! _upd_build_new_sources_and_checksums "$new_ver"; then
        _upd_fail "Falha ao construir novos sources/checksums para '$pkg'"
        return 1
    fi

    # Salvar estado antigo para restaurar em caso de erro
    local old_version="$MF_VERSION"
    local old_sources="$MF_SOURCES"
    local old_sha="$MF_SHA256SUMS"
    local old_md5="$MF_MD5SUM"
    local old_builds="$MF_NUM_BUILDS"

    # Atualiza MF_* em memória
    adm_meta_set_field version "$new_ver"
    adm_meta_set_field sources "$UPD_NEW_SOURCES"
    adm_meta_set_field num_builds "0"

    case "$UPD_HASH_FIELD" in
        sha256sums)
            adm_meta_set_field sha256sums "$UPD_NEW_HASHES"
            ;;
        md5sum)
            adm_meta_set_field md5sum "$UPD_NEW_HASHES"
            ;;
        *)
            _upd_fail "Campo de hash desconhecido ao atualizar '$pkg': $UPD_HASH_FIELD"
            # restaura
            MF_VERSION="$old_version"
            MF_SOURCES="$old_sources"
            MF_SHA256SUMS="$old_sha"
            MF_MD5SUM="$old_md5"
            MF_NUM_BUILDS="$old_builds"
            return 1
            ;;
    esac

    if ! adm_meta_validate; then
        _upd_fail "Metafile atualizado de '$pkg' é inválido; abortando update"
        # restaura
        MF_VERSION="$old_version"
        MF_SOURCES="$old_sources"
        MF_SHA256SUMS="$old_sha"
        MF_MD5SUM="$old_md5"
        MF_NUM_BUILDS="$old_builds"
        return 1
    fi

    local dest="$ADM_UPDATE_ROOT/$pkg/metafile"
    if ! adm_meta_write "$dest"; then
        _upd_fail "Falha ao escrever metafile de update para '$pkg' em $dest"
        # restaura
        MF_VERSION="$old_version"
        MF_SOURCES="$old_sources"
        MF_SHA256SUMS="$old_sha"
        MF_MD5SUM="$old_md5"
        MF_NUM_BUILDS="$old_builds"
        return 1
    fi

    _upd_log INFO "Novo metafile de '$pkg' escrito em $dest (versão=$new_ver)"
    return 0
}

adm_update_package() {
    # $1 = nome do pacote
    local pkg="$1"

    if [ -z "$pkg" ]; then
        _upd_fail "adm_update_package: nome de pacote não informado"
        return 1
    fi

    if ! _upd_load_meta_for_pkg "$pkg"; then
        return 1
    fi

    adm_update_generate_metafile_for_current_pkg
}

# --------------------------------
# Atualizar dependências diretas de um pacote
# --------------------------------

adm_update_deps_for_pkg() {
    # Pré-condição: MF_* (do pacote raiz) carregados
    local pkg="$MF_NAME"
    local dep
    local err=0
    local seen=()

    # Usa arrays que metafile.sh já preencheu
    #   MF_RUN_DEPS_ARR, MF_BUILD_DEPS_ARR
    if [ "${#MF_RUN_DEPS_ARR[@]}" -eq 0 ] && [ "${#MF_BUILD_DEPS_ARR[@]}" -eq 0 ]; then
        _upd_log INFO "Pacote '$pkg' não possui dependências diretas; nada a atualizar."
        return 0
    fi

    _upd_log INFO "Atualizando dependências diretas de '$pkg'..."

    # Construir lista única (run+build)
    for dep in "${MF_RUN_DEPS_ARR[@]}" "${MF_BUILD_DEPS_ARR[@]}"; do
        dep="$(_upd_trim "$dep")"
        [ -z "$dep" ] && continue
        # evita duplicatas
        if printf '%s\n' "${seen[@]}" | grep -qx -- "$dep"; then
            continue
        fi
        seen+=("$dep")
    done

    for dep in "${seen[@]}"; do
        _upd_log INFO "→ Dependência '$dep'"
        if ! _upd_load_meta_for_pkg "$dep"; then
            _upd_log WARN "  (dep '$dep') metafile não encontrado ou inválido; ignorando"
            err=1
            continue
        fi

        if ! adm_update_generate_metafile_for_current_pkg; then
            _upd_log WARN "  (dep '$dep') falha ao gerar novo metafile; ver logs acima"
            err=1
        fi
    done

    if [ "$err" -ne 0 ]; then
        _upd_log WARN "Uma ou mais dependências de '$pkg' falharam na atualização; veja mensagens acima."
        # não tratamos como erro fatal do pacote raiz, mas o caller pode decidir
    fi

    return 0
}

adm_update_package_and_deps() {
    # $1 = nome do pacote
    local pkg="$1"

    if [ -z "$pkg" ]; then
        _upd_fail "adm_update_package_and_deps: nome de pacote não informado"
        return 1
    fi

    if ! _upd_load_meta_for_pkg "$pkg"; then
        return 1
    fi

    # primeira: pacote raiz
    if ! adm_update_generate_metafile_for_current_pkg; then
        _upd_fail "Falha ao atualizar pacote '$pkg'"
        return 1
    fi

    # depois: deps diretas
    adm_update_deps_for_pkg || true

    return 0
}

# --------------------------------
# CLI: adm update [...]
# --------------------------------

adm_update_usage() {
    cat <<EOF
Uso: update.sh update [OPÇÕES] <pacote>

OPÇÕES:
  --no-deps   Não atualiza dependências, apenas o pacote alvo
  --with-deps Atualiza pacote alvo e dependências diretas (run+build) [padrão]

Exemplos:
  adm update bash
  adm update --no-deps bash
EOF
}

adm_update_main() {
    local cmd="$1"; shift || true

    case "$cmd" in
        update)
            local do_deps=1
            local pkg=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --no-deps)
                        do_deps=0
                        ;;
                    --with-deps)
                        do_deps=1
                        ;;
                    -h|--help)
                        adm_update_usage
                        return 0
                        ;;
                    -*)
                        _upd_fail "Opção desconhecida para update: $1"
                        return 1
                        ;;
                    *)
                        if [ -n "$pkg" ]; then
                            _upd_fail "Apenas um pacote pode ser especificado; já tenho '$pkg', recebido '$1'"
                            return 1
                        fi
                        pkg="$1"
                        ;;
                esac
                shift || true
            done

            if [ -z "$pkg" ]; then
                _upd_fail "Nenhum pacote informado para update"
                adm_update_usage
                return 1
            fi

            if [ "$do_deps" -eq 1 ]; then
                adm_update_package_and_deps "$pkg"
            else
                adm_update_package "$pkg"
            fi
            ;;
        ""|-h|--help)
            adm_update_usage
            ;;
        *)
            _upd_fail "Comando desconhecido para update.sh: '$cmd'"
            adm_update_usage
            return 1
            ;;
    esac
}

# Executado diretamente
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    adm_update_main "$@"
fi
