#!/usr/bin/env bash
# Simple LFS package manager / build system

set -euo pipefail

# =========================
# Configuração geral
# =========================
: "${LFS_PKG_ROOT:=/var/lib/adm}"                 # raiz do sistema de pacotes (lado host)
: "${CHROOT_DIR:=$LFS_PKG_ROOT/chroot}"           # raiz chroot onde o build roda
: "${LFS:=$CHROOT_DIR}"                           # alias, se você quiser usar LFS em metadatas
: "${META_DIR:=$LFS_PKG_ROOT/metadata}"           # metadatas ficam fora do chroot
: "${CACHE_DIR:=$LFS_PKG_ROOT/cache}"             # cache de downloads / git (host)
: "${BUILD_ROOT:=$CHROOT_DIR/build}"              # área de build DENTRO do chroot
: "${PKG_DIR:=$LFS_PKG_ROOT/packages}"            # pacotes .tar.zst / .tar.xz (host)
: "${DB_DIR:=$LFS_PKG_ROOT/db}"                   # info de instalados (host)
: "${STATE_DIR:=$LFS_PKG_ROOT/state}"             # estado de construção (retomada) (host)
: "${LOG_DIR:=$LFS_PKG_ROOT/log}"                 # logs (host)
: "${LOG_FILE:=$LOG_DIR/lfs-pkg.log}"             # log sem cores
: "${PARALLEL_JOBS:=4}"                           # downloads paralelos

# Garante toda a hierarquia necessária
mkdir -p "$META_DIR" "$CACHE_DIR" "$BUILD_ROOT" "$PKG_DIR" "$DB_DIR" "$STATE_DIR" "$LOG_DIR" "$CHROOT_DIR"

# =========================
# Cores para saída na tela
# =========================
if [[ -t 1 ]]; then
    C_RESET=$'\e[0m'
    C_INFO=$'\e[32m'   # verde
    C_WARN=$'\e[33m'   # amarelo
    C_ERR=$'\e[31m'    # vermelho
    C_DEBUG=$'\e[36m'  # ciano
else
    C_RESET=; C_INFO=; C_WARN=; C_ERR=; C_DEBUG=
fi

log_ts() { date +"%Y-%m-%d %H:%M:%S"; }

log_to_file() {
    local level="$1"; shift
    printf "[%s] [%s] %s\n" "$(log_ts)" "$level" "$*" >>"$LOG_FILE"
}

log_info() {
    log_to_file INFO "$*"
    printf "%s[INFO ]%s %s\n" "$C_INFO" "$C_RESET" "$*"
}

log_warn() {
    log_to_file WARN "$*"
    printf "%s[WARN ]%s %s\n" "$C_WARN" "$C_RESET" "$*"
}

log_error() {
    log_to_file ERROR "$*"
    printf "%s[ERROR]%s %s\n" "$C_ERR" "$C_RESET" "$*" >&2
}

log_debug() {
    log_to_file DEBUG "$*"
    printf "%s[DEBUG]%s %s\n" "$C_DEBUG" "$C_RESET" "$*"
}

# Lista de variáveis de metadata (PKG_*) a exportar para o ambiente de build/chroot
ADM_META_VARS=()

metadata_export_snippet() {
    # Gera declarações 'declare ...' para todas as variáveis PKG_*
    if [[ ${#ADM_META_VARS[@]:-0} -eq 0 ]]; then
        return
    fi
    # declare -p imprime algo como: declare -- PKG_FOO="bar"
    # Isso é seguro de ser avaliado numa shell bash.
    declare -p "${ADM_META_VARS[@]}" 2>/dev/null || true
}

validate_source_arrays() {
    local nsources=${#PKG_SOURCE_URLS[@]}

    # sha256, se usado, tem que ter mesmo tamanho que SOURCES
    if [[ ${#PKG_SHA256S[@]:-0} -gt 0 && ${#PKG_SHA256S[@]} -ne $nsources ]]; then
        die "[$PKG_NAME] PKG_SHA256S precisa ter o mesmo número de elementos que PKG_SOURCE_URLS (ou ser vazio)."
    fi

    # md5, se usado, tem que ter mesmo tamanho que SOURCES
    if [[ ${#PKG_MD5S[@]:-0} -gt 0 && ${#PKG_MD5S[@]} -ne $nsources ]]; then
        die "[$PKG_NAME] PKG_MD5S precisa ter o mesmo número de elementos que PKG_SOURCE_URLS (ou ser vazio)."
    fi
}

# =========================
# Utilidades gerais
# =========================

die() {
    log_error "$*"
    exit 1
}

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "Comando obrigatório não encontrado: $c"
    done
}

# Checamos alguns comandos base
# (file e tac são usados mais à frente; unzip é usado se você tiver fontes .zip)
require_cmd tar gzip xz zstd sha256sum md5sum sed awk sort grep file tac

# =========================
# Carregar metadata
# =========================

meta_path_for_pkg() {
    local pkg="$1"
    local path=""

    # Caso 1: o nome do pacote já veio no formato "grupo/programa"
    if [[ "$pkg" == */* ]]; then
        local group="${pkg%/*}"
        local name="${pkg##*/}"

        # Novo layout preferido: $META_DIR/grupo/programa/programa.meta
        if [[ -f "$META_DIR/$group/$name/$name.meta" ]]; then
            echo "$META_DIR/$group/$name/$name.meta"
            return
        fi

        # Layout antigo: $META_DIR/grupo/programa.meta
        if [[ -f "$META_DIR/$group/$name.meta" ]]; then
            echo "$META_DIR/$group/$name.meta"
            return
        fi

        # Fallback genérico: $META_DIR/$pkg.meta
        path="$META_DIR/$pkg.meta"
        echo "$path"
        return
    fi

    # Caso 2: nome simples ("programa")
    # Primeiro tentamos o layout de subdiretório padrão: $META_DIR/core/programa/programa.meta, etc.
    # Ou qualquer $META_DIR/*/programa/programa.meta
    path=$(find "$META_DIR" -mindepth 2 -maxdepth 3 -type f -name "$pkg.meta" -print -quit 2>/dev/null || true)
    if [[ -n "$path" ]]; then
        echo "$path"
        return
    fi

    # Fallback: procurar em qualquer lugar (como antes)
    path=$(find "$META_DIR" -type f -name "$pkg.meta" -print -quit 2>/dev/null || true)
    if [[ -n "$path" ]]; then
        echo "$path"
    else
        # Último fallback: raiz direta
        echo "$META_DIR/$pkg.meta"
    fi
}

ensure_metadata_exists() {
    local pkg="$1"
    local path
    path="$(meta_path_for_pkg "$pkg")"
    [[ -f "$path" ]] || die "Metadata não encontrado: $path"
}

load_metadata() {
    local pkg="$1"
    ensure_metadata_exists "$pkg"
    # Limpar variáveis de metadata anteriores (evitar vazamento)
    unset PKG_NAME PKG_VERSION PKG_RELEASE PKG_SOURCE_URLS PKG_SHA256S PKG_MD5S PKG_DEPENDS \
          PKG_BUILD PKG_INSTALL PKG_UPSTREAM_URL PKG_UPSTREAM_REGEX PKG_GROUPS
    # shellcheck source=/dev/null
    source "$(meta_path_for_pkg "$pkg")"

    : "${PKG_NAME:=$pkg}"
    : "${PKG_VERSION:?PKG_VERSION não definido em metadata de $pkg}"
    : "${PKG_RELEASE:=1}"
    : "${PKG_SOURCE_URLS:?PKG_SOURCE_URLS não definido em metadata de $pkg}"
    : "${PKG_DEPENDS:=()}"
    : "${PKG_GROUPS:=()}"

    # Registrar todas as variáveis PKG_* conhecidas para exportar no ambiente de build/chroot
    ADM_META_VARS=()
    while IFS= read -r varname; do
        ADM_META_VARS+=("$varname")
    done < <(compgen -v PKG_ || true)
}

# =========================
# Hooks locais por pacote
# =========================

# Diretório onde ficam os hooks de um pacote (normalmente o mesmo da .meta)
hook_dir_for_pkg() {
    local pkg="$1"
    local meta_path

    meta_path="$(meta_path_for_pkg "$pkg" 2>/dev/null || true)"
    if [[ -n "$meta_path" && -f "$meta_path" ]]; then
        dirname "$meta_path"
    else
        # Fallback razoável se o metadata ainda não existir
        echo "$META_DIR/$pkg"
    fi
}

# Executa um hook de tipo (pre_install, post_install, pre_uninstall, post_uninstall)
# dentro da pasta do programa, se existir e for executável.
run_pkg_hook() {
    local hook_type="$1"
    local pkg="$2"
    local hook_dir hook_file prog

    hook_dir="$(hook_dir_for_pkg "$pkg")"
    prog="${pkg##*/}"  # nome curto do programa, sem o grupo (core/shadow -> shadow)

    hook_file="${hook_dir}/${prog}.${hook_type}"

    if [[ -x "$hook_file" ]]; then
        log_info "[$pkg] Executando hook ${hook_type}: $hook_file"
        if ! /bin/bash "$hook_file" "$pkg" "$hook_type"; then
            die "[$pkg] Hook ${hook_type} falhou: $hook_file"
        fi
    else
        log_debug "[$pkg] Nenhum hook ${hook_type} encontrado em ${hook_dir}"
    fi
}

# Gera uma estrutura padrão de hooks para um pacote
generate_hooks_for_pkg() {
    local pkg="$1"

    if [[ -z "$pkg" ]]; then
        die "generate_hooks_for_pkg: pacote não informado."
    fi

    # Garante que o metadata exista (para sabermos o diretório real)
    ensure_metadata_exists "$pkg"
    local meta_dir prog
    meta_dir="$(dirname "$(meta_path_for_pkg "$pkg")")"
    prog="${pkg##*/}"

    mkdir -p "$meta_dir"

    local t hook
    for t in pre_install post_install pre_uninstall post_uninstall; do
        hook="${meta_dir}/${prog}.${t}"
        if [[ -e "$hook" ]]; then
            log_warn "[$pkg] Hook já existe, não sobrescrevendo: $hook"
            continue
        fi

        cat >"$hook" <<'EOF'
#!/bin/bash
# Hook gerado automaticamente pelo adm.sh
# Argumentos: $1 = nome do pacote lógico, $2 = tipo de hook
set -euo pipefail
pkg="${1:-<desconhecido>}"
phase="${2:-<fase>}"

# TODO: personalize este hook.
# Exemplo:
# echo "[$pkg] Executando hook ${phase} em $(basename "$0")"
EOF
        chmod +x "$hook"
        log_info "[$pkg] Hook criado: $hook"
    done
}

# =========================
# Estado de construção (retomada)
# =========================

# stage: 0=novo, 1=baixado, 2=extraído, 3=build, 4=empacotado, 5=instalado
get_pkg_stage() {
    local pkg="$1"
    local f="$STATE_DIR/$pkg.stage"
    if [[ -f "$f" ]]; then
        cat "$f"
    else
        echo 0
    fi
}

set_pkg_stage() {
    local pkg="$1" stage="$2"
    local f="$STATE_DIR/$pkg.stage"
    mkdir -p "$(dirname "$f")"
    echo "$stage" >"$f"
}

clear_pkg_stage() {
    local pkg="$1"
    rm -f "$STATE_DIR/$pkg.stage"
}

# =========================
# Download com cache + checksum
# =========================
download_one_source() {
    local pkg="$1" idx="$2" urlspec="$3" out="$4" sha256_spec="$5" md5_spec="$6"

    # urlspec pode ter múltiplos espelhos separados por '|'
    local -a mirrors=()
    IFS='|' read -r -a mirrors <<<"$urlspec"
    if ((${#mirrors[@]} == 0)); then
        die "[$pkg] Nenhuma URL válida em PKG_SOURCE_URLS[$idx]"
    fi

    # hashes esperados: aceitamos múltiplos separados por '|' ou espaço
    local -a sha256_list=() md5_list=()
    if [[ -n "$sha256_spec" ]]; then
        IFS='| ' read -r -a sha256_list <<<"$sha256_spec"
    fi
    if [[ -n "$md5_spec" ]]; then
        IFS='| ' read -r -a md5_list <<<"$md5_spec"
    fi

    local have_checksum=0
    if ((${#sha256_list[@]} > 0 || ${#md5_list[@]} > 0)); then
        have_checksum=1
    fi

    local attempts_per_mirror=3

    # ---------- Validação de checksums (AGORA CORRETA) ----------
    _check_file_checksums() {
        local file="$1"
        local failed=0

        if ((${#sha256_list[@]} > 0)); then
            local expected_s got_s
            got_s=$(sha256sum "$file" | awk '{print $1}')
            local match=0
            for expected_s in "${sha256_list[@]}"; do
                [[ -z "$expected_s" ]] && continue
                if [[ "$got_s" == "$expected_s" ]]; then
                    match=1
                    break
                fi
            done
            if (( match == 0 )); then
                log_warn "[$pkg] sha256 não confere para $file (obtido=$got_s)"
                failed=1
            fi
        fi

        if ((${#md5_list[@]} > 0)); then
            local expected_m got_m
            got_m=$(md5sum "$file" | awk '{print $1}')
            local match=0
            for expected_m in "${md5_list[@]}"; do
                [[ -z "$expected_m" ]] && continue
                if [[ "$got_m" == "$expected_m" ]]; then
                    match=1
                    break
                fi
            done
            if (( match == 0 )); then
                log_warn "[$pkg] md5 não confere para $file (obtido=$got_m)"
                failed=1
            fi
        fi

        return "$failed"   # 0 = OK, 1 = FALHOU
    }

    mkdir -p "$(dirname "$out")"

    # Se já existe no cache, verifica checksum ANTES de qualquer coisa
    if [[ -f "$out" && $have_checksum -eq 1 ]]; then
        log_info "[$pkg] Source já no cache: $out, verificando checksums..."
        if _check_file_checksums "$out"; then
            log_info "[$pkg] Arquivo em cache válido, reaproveitando."
            return 0
        else
            log_warn "[$pkg] Arquivo em cache com checksum inválido, removendo: $out"
            rm -f "$out"
        fi
    elif [[ -f "$out" && $have_checksum -eq 0 ]]; then
        log_info "[$pkg] Source já no cache: $out (sem checksums definidos)."
        return 0
    fi

    # ---------- Download de uma única URL para tmpout ----------
    _do_download_url() {
        local url="$1" tmpout="$2"

        if [[ "$url" == git://* || "$url" == *.git || "$url" == git+* ]]; then
            require_cmd git
            local tmpdir
            tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/adm-git-XXXXXX")"
            log_info "[$pkg] Clonando repositório git: $url"
            if git clone --depth=1 "${url#git+}" "$tmpdir" >>"$LOG_FILE" 2>&1; then
                ( cd "$tmpdir" && tar -cf "$tmpout" . ) >>"$LOG_FILE" 2>&1
                rm -rf "$tmpdir"
                return 0
            else
                log_warn "[$pkg] Falha ao clonar git: $url"
                rm -rf "$tmpdir"
                return 1
            fi

        elif [[ "$url" == rsync://* ]]; then
            require_cmd rsync
            log_info "[$pkg] Baixando via rsync: $url"
            if rsync -av "$url" "$tmpout" >>"$LOG_FILE" 2>&1; then
                return 0
            else
                log_warn "[$pkg] Falha no rsync: $url"
                return 1
            fi

        else
            # HTTP/HTTPS/FTP etc
            if command -v curl >/dev/null 2>&1; then
                log_info "[$pkg] Baixando via curl: $url"
                if curl -L --fail --connect-timeout 15 --max-time 0 -o "$tmpout" "$url" 2>&1 | tee -a "$LOG_FILE"; then
                    return 0
                else
                    log_warn "[$pkg] Falha no download via curl: $url"
                    return 1
                fi
            elif command -v wget >/dev/null 2>&1; then
                log_info "[$pkg] Baixando via wget: $url"
                if wget -O "$tmpout" "$url" >>"$LOG_FILE" 2>&1; then
                    return 0
                else
                    log_warn "[$pkg] Falha no download via wget: $url"
                    return 1
                fi
            else
                die "[$pkg] Nem curl nem wget encontrados para download HTTP/FTP."
            fi
        fi
    }

    # ---------- Tenta cada mirror com algumas tentativas ----------
    local mirror
    for mirror in "${mirrors[@]}"; do
        [[ -z "$mirror" ]] && continue
        log_info "[$pkg] Usando mirror: $mirror -> $out"

        local attempt
        for (( attempt=1; attempt<=attempts_per_mirror; attempt++ )); do
            log_info "[$pkg] Download tentativa $attempt/$attempts_per_mirror: $mirror"

            local tmpout="${out}.part"
            rm -f "$tmpout"

            if _do_download_url "$mirror" "$tmpout"; then
                # Se temos checksums, valida ANTES de mover
                if (( have_checksum == 1 )); then
                    if _check_file_checksums "$tmpout"; then
                        mv -f "$tmpout" "$out"
                        log_info "[$pkg] Download concluído e checksum OK: $out"
                        return 0
                    else
                        log_warn "[$pkg] Checksum inválido para arquivo baixado de $mirror (tentativa $attempt)."
                        rm -f "$tmpout"
                        continue
                    fi
                else
                    mv -f "$tmpout" "$out"
                    log_info "[$pkg] Download concluído (sem checksum): $out"
                    return 0
                fi
            else
                log_warn "[$pkg] Falha na tentativa $attempt de $mirror"
            fi
        done
    done

    die "[$pkg] Falha ao baixar source (todas URLs/tentativas esgotadas) para índice $idx -> $out"
}

    mkdir -p "$(dirname "$out")"

    # Se já existe no cache, verifica checksum ANTES de qualquer coisa
    if [[ -f "$out" && $have_checksum -eq 1 ]]; then
        log_info "[$pkg] Source já no cache: $out, verificando checksums..."
        if _check_file_checksums "$out"; then
            log_info "[$pkg] Arquivo em cache válido, reaproveitando."
            return 0
        else
            log_warn "[$pkg] Arquivo em cache com checksum inválido, removendo: $out"
            rm -f "$out"
        fi
    elif [[ -f "$out" && $have_checksum -eq 0 ]]; then
        log_info "[$pkg] Source já no cache: $out (sem checksums definidos)."
        return 0
    fi

    # Helper para download de uma única URL em tmpout
    _do_download_url() {
        local url="$1" tmpout="$2"

        if [[ "$url" == git://* || "$url" == *.git || "$url" == git+* ]]; then
            require_cmd git
            local tmpdir
            tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/adm-git-XXXXXX")"
            log_info "[$pkg] Clonando repositório git: $url"
            if git clone --depth=1 "${url#git+}" "$tmpdir" >>"$LOG_FILE" 2>&1; then
                ( cd "$tmpdir" && tar -cf "$tmpout" . ) >>"$LOG_FILE" 2>&1
                rm -rf "$tmpdir"
                return 0
            else
                log_warn "[$pkg] Falha ao clonar git: $url"
                rm -rf "$tmpdir"
                return 1
            fi

        elif [[ "$url" == rsync://* ]]; then
            require_cmd rsync
            log_info "[$pkg] Baixando via rsync: $url"
            if rsync -av "$url" "$tmpout" >>"$LOG_FILE" 2>&1; then
                return 0
            else
                log_warn "[$pkg] Falha no rsync: $url"
                return 1
            fi

        else
            # HTTP/HTTPS/FTP etc
            if command -v curl >/dev/null 2>&1; then
                log_info "[$pkg] Baixando via curl: $url"
                if curl -L --fail --connect-timeout 15 --max-time 0 -o "$tmpout" "$url" 2>&1 | tee -a "$LOG_FILE"; then
                    return 0
                else
                    log_warn "[$pkg] Falha no download via curl: $url"
                    return 1
                fi
            elif command -v wget >/dev/null 2>&1; then
                log_info "[$pkg] Baixando via wget: $url"
                if wget -O "$tmpout" "$url" >>"$LOG_FILE" 2>&1; then
                    return 0
                else
                    log_warn "[$pkg] Falha no download via wget: $url"
                    return 1
                fi
            else
                die "[$pkg] Nem curl nem wget encontrados para download HTTP/FTP."
            fi
        fi
    }

    local mirror
    for mirror in "${mirrors[@]}"; do
        [[ -z "$mirror" ]] && continue
        log_info "[$pkg] Usando mirror: $mirror -> $out"

        local attempt
        for (( attempt=1; attempt<=attempts_per_mirror; attempt++ )); do
            log_info "[$pkg] Download tentativa $attempt/$attempts_per_mirror: $mirror"

            local tmpout="${out}.part"
            rm -f "$tmpout"

            if ! _do_download_url "$mirror" "$tmpout"; then
                log_warn "[$pkg] Falha ao baixar de $mirror (tentativa $attempt)"
                continue
            fi

            if [[ ! -e "$tmpout" ]]; then
                log_warn "[$pkg] Download não produziu arquivo: $tmpout"
                continue
            fi

            if (( have_checksum == 1 )); then
                if _check_file_checksums "$tmpout"; then
                    mv "$tmpout" "$out"
                    log_info "[$pkg] Download concluído e válido: $out"
                    return 0
                else
                    rm -f "$tmpout"
                    continue
                fi
            else
                mv "$tmpout" "$out"
                log_info "[$pkg] Download concluído (sem checksums definidos): $out"
                return 0
            fi
        done
    done

    die "[$pkg] Falha ao baixar/verificar source $idx depois de tentar todos os mirrors."
}        
            
download_sources_parallel() {
    local pkg="$1"

    load_metadata "$pkg"
    validate_source_arrays

    mkdir -p "$CACHE_DIR"

    local -a urls=("${PKG_SOURCE_URLS[@]}")
    local -a sha256s=()
    local -a md5s=()

    if [[ ${#PKG_SHA256S[@]:-0} -gt 0 ]]; then
        sha256s=("${PKG_SHA256S[@]}")
    fi
    if [[ ${#PKG_MD5S[@]:-0} -gt 0 ]]; then
        md5s=("${PKG_MD5S[@]}")
    fi

    local -a pids=()
    local i=0
    local urlspec
    local fail=0

    for urlspec in "${urls[@]}"; do
        # Usamos a PRIMEIRA URL (antes do '|') só para nomear o arquivo
        local first_url="${urlspec%%|*}"
        local base
        base="$(basename "${first_url%%\?*}")"
        [[ -n "$base" ]] || base="${PKG_NAME}-${PKG_VERSION}-src-$i.tar"

        local out="$CACHE_DIR/${PKG_NAME}-${PKG_VERSION}-$i-$base"
        local sha="${sha256s[$i]:-}"
        local md="${md5s[$i]:-}"

        (
            download_one_source "$PKG_NAME" "$i" "$urlspec" "$out" "$sha" "$md"
        ) &
        pids+=("$!")
        (( i++ ))

        # limitar paralelismo só com os PIDs que a gente mesmo criou
        while ((${#pids[@]} >= PARALLEL_JOBS)); do
            if ! wait "${pids[0]}"; then
                fail=1
            fi
            pids=("${pids[@]:1}")
        done
    done

    local pid
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            fail=1
        fi
    done

    (( fail == 0 )) || die "[$PKG_NAME] Falha em algum download (um ou mais sources não foram baixados corretamente)."
}

# =========================
# Extração de fontes
# =========================
extract_sources() {
    local pkg="$1"
    load_metadata "$pkg"
    local builddir="$BUILD_ROOT/$PKG_NAME-$PKG_VERSION"
    rm -rf "$builddir"
    mkdir -p "$builddir"

    log_info "[$pkg] Extraindo fontes para $builddir"

    local i=0
    local urlspec
    for urlspec in "${PKG_SOURCE_URLS[@]}"; do
        # Usa apenas a primeira URL (antes do '|') para nomear o arquivo no cache,
        # igual na função download_sources_parallel
        local first_url="${urlspec%%|*}"
        local base
        base="$(basename "${first_url%%\?*}")"
        [[ -n "$base" ]] || base="${PKG_NAME}-${PKG_VERSION}-$i.src"
        local src="$CACHE_DIR/${PKG_NAME}-${PKG_VERSION}-$i-$base"

        if [[ ! -e "$src" ]]; then
            die "[$pkg] Arquivo de fonte não encontrado: $src"
        fi

        if [[ -d "$src" ]]; then
            log_info "[$pkg] Copiando diretório fonte $src"
            cp -a "$src"/. "$builddir/"
        else
            # tentar reconhecer formato pelo file ou extensão
            local mime
            mime=$(file -b --mime-type "$src" || echo "")

            case "$src" in
                *.tar|*.tar.gz|*.tgz|*.tar.bz2|*.tbz2|*.tar.xz|*.txz|*.tar.zst|*.tzst)
                    log_info "[$pkg] Extraindo tar: $src"
                    tar -xf "$src" -C "$builddir"
                    ;;
                *.zip)
                    require_cmd unzip
                    log_info "[$pkg] Extraindo zip: $src"
                    unzip -q "$src" -d "$builddir"
                    ;;
                *)
                    if [[ "$mime" == application/x-tar* || "$mime" == application/x-xz* || "$mime" == application/zstd* ]]; then
                        log_info "[$pkg] Extraindo via tar (mime: $mime): $src"
                        tar -xf "$src" -C "$builddir"
                    else
                        log_warn "[$pkg] Formato desconhecido, copiando bruto: $src"
                        cp "$src" "$builddir/"
                    fi
                    ;;
            esac
        fi
        (( i++ ))
    done

    echo "$builddir"
}

# =========================
# Chroot / execução de build
# =========================

# Flag para saber se já montamos o ambiente do chroot nesta execução
CHROOT_MOUNTED=0

chroot_setup_mounts() {
    [[ -z "$CHROOT_DIR" ]] && return 0

    require_cmd mount umount mountpoint

    # Garante diretórios básicos dentro do chroot
    mkdir -p "$CHROOT_DIR"/{dev,dev/pts,proc,sys,run,etc}
    mkdir -p "$CHROOT_DIR/tmp"
    chmod 1777 "$CHROOT_DIR/tmp" 2>/dev/null || true

    # /etc/resolv.conf para DNS
    if [[ -f /etc/resolv.conf ]]; then
        if [[ ! -e "$CHROOT_DIR/etc/resolv.conf" ]]; then
            touch "$CHROOT_DIR/etc/resolv.conf"
        fi
        if ! mountpoint -q "$CHROOT_DIR/etc/resolv.conf"; then
            if ! mount --bind /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf"; then
                log_warn "[chroot] Falha ao bind /etc/resolv.conf em $CHROOT_DIR/etc/resolv.conf"
            fi
        fi
    fi

    # /dev
    if ! mountpoint -q "$CHROOT_DIR/dev"; then
        if ! mount --bind /dev "$CHROOT_DIR/dev"; then
            log_warn "[chroot] Falha ao bind /dev em $CHROOT_DIR/dev"
        fi
    fi

    # /dev/pts
    if ! mountpoint -q "$CHROOT_DIR/dev/pts"; then
        if ! mount --bind /dev/pts "$CHROOT_DIR/dev/pts"; then
            log_warn "[chroot] Falha ao bind /dev/pts em $CHROOT_DIR/dev/pts"
        fi
    fi

    # /proc
    if ! mountpoint -q "$CHROOT_DIR/proc"; then
        if ! mount -t proc proc "$CHROOT_DIR/proc"; then
            log_warn "[chroot] Falha ao montar proc em $CHROOT_DIR/proc"
        fi
    fi

    # /sys
    if ! mountpoint -q "$CHROOT_DIR/sys"; then
        if ! mount -t sysfs sysfs "$CHROOT_DIR/sys"; then
            log_warn "[chroot] Falha ao montar sysfs em $CHROOT_DIR/sys"
        fi
    fi

    # /run (opcional)
    if [[ -d /run ]]; then
        if ! mountpoint -q "$CHROOT_DIR/run"; then
            if ! mount --bind /run "$CHROOT_DIR/run"; then
                log_warn "[chroot] Falha ao bind /run em $CHROOT_DIR/run"
            fi
        fi
    fi

    CHROOT_MOUNTED=1
}

chroot_teardown_mounts() {
    [[ -z "$CHROOT_DIR" ]] && return 0
    [[ "${CHROOT_MOUNTED:-0}" -eq 0 ]] && return 0

    # Desmonta em ordem reversa
    local targets=(
        "$CHROOT_DIR/run"
        "$CHROOT_DIR/sys"
        "$CHROOT_DIR/proc"
        "$CHROOT_DIR/dev/pts"
        "$CHROOT_DIR/dev"
        "$CHROOT_DIR/etc/resolv.conf"
    )

    local t
    for t in "${targets[@]}"; do
        if mountpoint -q "$t"; then
            if ! umount "$t"; then
                log_warn "[chroot] Falha ao desmontar $t (pode estar em uso)."
            fi
        fi
    done

    CHROOT_MOUNTED=0
}

ensure_chroot_ready() {
    [[ -z "$CHROOT_DIR" ]] && return 0

    # Garante existência do diretório do chroot
    if [[ ! -d "$CHROOT_DIR" ]]; then
        log_info "[chroot] Criando CHROOT_DIR em '$CHROOT_DIR'"
        if ! mkdir -p "$CHROOT_DIR"; then
            die "[chroot] Falha ao criar CHROOT_DIR em '$CHROOT_DIR'"
        fi
    fi

    # Aqui apenas avisamos, não derrubamos tudo – quem cria /bin/bash é você.
    # Se quiser copiar /bin/bash do host, essa lógica poderia ser ampliada, mas
    # é mais seguro manter separado como no LFS.
    if [[ ! -x "$CHROOT_DIR/bin/bash" ]]; then
        log_warn "[chroot] $CHROOT_DIR não tem /bin/bash executável ainda. Algumas builds podem falhar."
    fi

    if [[ "${CHROOT_MOUNTED:-0}" -eq 0 ]]; then
        chroot_setup_mounts
        # Garante desmontagem na saída do script inteiro
        trap chroot_teardown_mounts EXIT
    fi
}

run_in_chroot() {
    local workdir="$1"; shift
    local cmd="$*"

    if [[ -n "$CHROOT_DIR" ]]; then
        require_cmd chroot
        ensure_chroot_ready

        # Garantir que workdir está dentro do chroot
        case "$workdir" in
            "$CHROOT_DIR"/*)
                # converte /host/path -> /path dentro do chroot
                local inner_dir="${workdir#"$CHROOT_DIR"}"
                [[ -z "$inner_dir" ]] && inner_dir="/"
                ;;
            *)
                die "[chroot] workdir '$workdir' não está dentro de CHROOT_DIR='$CHROOT_DIR'. Ajuste BUILD_ROOT ou CHROOT_DIR."
                ;;
        esac

        log_info "[chroot] Executando em $CHROOT_DIR (dir: $inner_dir): $cmd"
        chroot "$CHROOT_DIR" /bin/bash -lc "cd \"$inner_dir\" && $cmd"
    else
        log_info "[host] Executando (dir: $workdir): $cmd"
        ( cd "$workdir" && /bin/bash -lc "$cmd" )
    fi
}

# =========================
# Registro de instalação
# =========================

db_pkg_dir() {
    local pkg="$1"
    echo "$DB_DIR/$pkg"
}

db_files_list() {
    local pkg="$1"
    echo "$(db_pkg_dir "$pkg")/files.list"
}

db_manifest() {
    local pkg="$1"
    echo "$(db_pkg_dir "$pkg")/manifest.sha256"
}

db_meta_copy() {
    local pkg="$1"
    echo "$(db_pkg_dir "$pkg")/metadata.meta"
}

is_installed() {
    local pkg="$1"
    [[ -d "$(db_pkg_dir "$pkg")" ]]
}

register_install() {
    local pkg="$1" destdir="$2"

    # Segurança extra com DESTDIR
    if [[ -z "${destdir:-}" || "$destdir" == "/" ]]; then
        die "[$pkg] DESTDIR inválido em register_install: '$destdir'"
    fi
    if [[ ! -d "$destdir" ]]; then
        die "[$pkg] DESTDIR não encontrado em register_install: $destdir"
    fi

    mkdir -p "$(db_pkg_dir "$pkg")"
    local listfile
    listfile="$(db_files_list "$pkg")"
    local manifest
    manifest="$(db_manifest "$pkg")"

    : >"$listfile"
    : >"$manifest"

    log_info "[$pkg] Registrando arquivos instalados a partir de $destdir"
    (
        cd "$destdir" || die "[$pkg] Falha ao entrar em DESTDIR: $destdir"
        find . -type f -o -type l -o -type d | sed 's|^\./||' | while read -r path; do
            echo "/$path" >>"$listfile"
            if [[ -f "$path" ]]; then
                sha256sum "$path" | sed "s|  $path|  /$path|" >>"$manifest"
            fi
        done
    )

    # copia metadata para referência futura (depende de PKG_DEPENDS etc)
    cp "$(meta_path_for_pkg "$pkg")" "$(db_meta_copy "$pkg")"

    log_info "[$pkg] Registro de instalação concluído"
}

# =========================
# Dependências / topological sort
# =========================

get_pkg_depends() {
    local pkg="$1"
    load_metadata "$pkg"
    # Garante que PKG_DEPENDS existe como array, mesmo se vazio
    if [[ ${#PKG_DEPENDS[@]:-0} -eq 0 ]]; then
        return 0
    fi
    printf "%s\n" "${PKG_DEPENDS[@]}"
}

# Construímos o grafo lendo os metadatas que forem necessários
resolve_deps_recursive() {
    local pkg="$1"
    local -n outlist="$2"
    local -n visiting="$3"
    local -n visited="$4"

    if [[ "${visited[$pkg]:-}" == "1" ]]; then
        return
    fi
    if [[ "${visiting[$pkg]:-}" == "1" ]]; then
        die "Ciclo de dependências detectado envolvendo '$pkg'. Verifique PKG_DEPENDS dos pacotes envolvidos."
    fi

    # Garante que há metadata pro pacote
    ensure_metadata_exists "$pkg" || die "Metadata não encontrado para dependência '$pkg'."

    visiting["$pkg"]=1

    local dep
    while read -r dep; do
        [[ -z "$dep" ]] && continue
        resolve_deps_recursive "$dep" outlist visiting visited
    done < <(get_pkg_depends "$pkg")

    visiting["$pkg"]=0
    visited["$pkg"]=1
    outlist+=("$pkg")
}

resolve_deps_order() {
    # Retorna ordem topológica das dependências + o próprio pacote
    local root="$1"
    declare -A visiting visited
    local outlist=()
    resolve_deps_recursive "$root" outlist visiting visited
    printf "%s\n" "${outlist[@]}"
}

# Reverse deps para uninstall / órfãos
reverse_deps_of() {
    local target="$1"
    local pkg pkgpath

    while IFS= read -r -d '' pkgpath; do
        [[ -d "$pkgpath" ]] || continue
        if [[ ! -f "$pkgpath/metadata.meta" ]]; then
            continue
        fi
        pkg="$(basename "$pkgpath")"
        # carrega metadata salvo na instalação
        unset PKG_NAME PKG_DEPENDS
        # shellcheck source=/dev/null
        source "$pkgpath/metadata.meta"
        local d
        for d in "${PKG_DEPENDS[@]:-}"; do
            if [[ "$d" == "$target" ]]; then
                echo "$pkg"
            fi
        done
    done < <(find "$DB_DIR" -mindepth 1 -type d -print0 2>/dev/null)
}

# Detectar órfãos: pacotes que ninguém depende (e que não são base listados)
list_orphans() {
    local base_pkgs=() # você pode adicionar base aqui se quiser preservar
    declare -A has_revdep
    local pkg pkgpath

    # Inicializa todos como sem reverse deps
    while IFS= read -r -d '' pkgpath; do
        [[ -d "$pkgpath" ]] || continue
        if [[ ! -f "$pkgpath/metadata.meta" ]]; then
            continue
        fi
        pkg="$(basename "$pkgpath")"
        has_revdep["$pkg"]=0
    done < <(find "$DB_DIR" -mindepth 1 -type d -print0 2>/dev/null)

    # Marca quem possui reverse deps
    while IFS= read -r -d '' pkgpath; do
        [[ -d "$pkgpath" ]] || continue
        if [[ ! -f "$pkgpath/metadata.meta" ]]; then
            continue
        fi
        pkg="$(basename "$pkgpath")"
        unset PKG_DEPENDS
        # shellcheck source=/dev/null
        source "$pkgpath/metadata.meta"
        local d
        for d in "${PKG_DEPENDS[@]:-}"; do
            has_revdep["$d"]=1
        done
    done < <(find "$DB_DIR" -mindepth 1 -type d -print0 2>/dev/null)

    for pkg in "${!has_revdep[@]}"; do
        local keep=0
        local b
        for b in "${base_pkgs[@]}"; do
            [[ "$pkg" == "$b" ]] && keep=1 && break
        done
        if (( has_revdep["$pkg"] == 0 && keep == 0 )); then
            echo "$pkg"
        fi
    done
}

# =========================
# Build + Package + Install
# =========================

build_package() {
    local pkg="$1"
    load_metadata "$pkg"

    local stage
    stage="$(get_pkg_stage "$pkg")"

    if (( stage < 1 )); then
        download_sources_parallel "$pkg"
        set_pkg_stage "$pkg" 1
    else
        log_info "[$pkg] Retomando: etapa de download já concluída (stage>=1)"
    fi

    local builddir
    if (( stage < 2 )); then
        builddir="$(extract_sources "$pkg")"
        local builddir_state="$STATE_DIR/$pkg.builddir"
        mkdir -p "$(dirname "$builddir_state")"
        echo "$builddir" >"$builddir_state"
        set_pkg_stage "$pkg" 2
    else
        log_info "[$pkg] Retomando: extração já feita (stage>=2)"
        if [[ -f "$STATE_DIR/$pkg.builddir" ]]; then
            builddir=$(<"$STATE_DIR/$pkg.builddir")
        else
            builddir="$BUILD_ROOT/$PKG_NAME-$PKG_VERSION"
        fi
    fi

    # Normalmente, as fontes extraídas criam um subdiretório; se só houver um, entramos nele
    local subdirs
    subdirs=$(find "$builddir" -mindepth 1 -maxdepth 1 -type d | wc -l)
    if (( subdirs == 1 )); then
        builddir="$(find "$builddir" -mindepth 1 -maxdepth 1 -type d)"
    fi

    if (( stage < 3 )); then
        log_info "[$pkg] Iniciando build"
        if declare -F PKG_BUILD >/dev/null 2>&1; then
            # Exporta variáveis PKG_* do metadata e executa a função de build
            run_in_chroot "$builddir" "$(metadata_export_snippet); PKG_NAME='$PKG_NAME'; PKG_VERSION='$PKG_VERSION'; DESTDIR=''; $(declare -f PKG_BUILD); PKG_BUILD"
        else
            log_warn "[$pkg] PKG_BUILD não definido, pulando build (assumindo build manual no metadata)"
        fi
        set_pkg_stage "$pkg" 3
    else
        log_info "[$pkg] Retomando: build já concluída (stage>=3)"
    fi

    # DESTDIR para instalação temporária (lado host)
    local destdir="$BUILD_ROOT/${PKG_NAME}-${PKG_VERSION}-destdir"

    # Caminho equivalente visto de dentro do chroot (se houver)
    local destdir_chroot="$destdir"
    if [[ -n "$CHROOT_DIR" ]]; then
        destdir_chroot="${destdir#"$CHROOT_DIR"}"
        [[ -z "$destdir_chroot" ]] && destdir_chroot="/"
    fi

    if (( stage < 4 )); then
        rm -rf "$destdir"
        mkdir -p "$destdir"

        log_info "[$pkg] Instalando em DESTDIR: $destdir"
        if declare -F PKG_INSTALL >/dev/null 2>&1; then
            # Exporta variáveis PKG_* do metadata e executa a função de instalação
            run_in_chroot "$builddir" "$(metadata_export_snippet); PKG_NAME='$PKG_NAME'; PKG_VERSION='$PKG_VERSION'; DESTDIR='$destdir_chroot'; $(declare -f PKG_INSTALL); PKG_INSTALL"
        else
            log_warn "[$pkg] PKG_INSTALL não definido, nenhum arquivo instalado em DESTDIR"
        fi

        mkdir -p "$PKG_DIR"
        local pkgfile_zst="$PKG_DIR/${PKG_NAME}-${PKG_VERSION}-${PKG_RELEASE}.tar.zst"
        local pkgfile_xz="$PKG_DIR/${PKG_NAME}-${PKG_VERSION}-${PKG_RELEASE}.tar.xz"
        log_info "[$pkg] Empacotando em $pkgfile_zst (fallback xz)"
        if tar --help 2>/dev/null | grep -q -- '--zstd'; then
            ( cd "$destdir" && tar --zstd -cf "$pkgfile_zst" . )
        else
            # fallback manual
            ( cd "$destdir" && tar -cf - . | zstd -19 -o "$pkgfile_zst" )
        fi
        if [[ ! -f "$pkgfile_zst" ]]; then
            log_warn "[$pkg] Falha ao criar .tar.zst, tentando .tar.xz"
            ( cd "$destdir" && tar -cJf "$pkgfile_xz" . )
        fi
        set_pkg_stage "$pkg" 4
    else
        log_info "[$pkg] Retomando: empacotamento já concluído (stage>=4)"
    fi

    log_info "[$pkg] Build e empacotamento finalizados."
}

install_package_root() {
    local pkg="$1"
    load_metadata "$pkg"
    local destdir="$BUILD_ROOT/${PKG_NAME}-${PKG_VERSION}-destdir"
    [[ -d "$destdir" ]] || die "[$pkg] DESTDIR não encontrado para instalação: $destdir"

    # Hook de pré-instalação (roda no sistema real, antes de copiar arquivos)
    run_pkg_hook "pre_install" "$pkg"

    log_info "[$pkg] Instalando em / a partir de $destdir"
    # Cópia preservando atributos
    ( cd "$destdir" && cp -a . / )

    register_install "$pkg" "$destdir"

    set_pkg_stage "$pkg" 5

    # Hook de pós-instalação (após registrar o pacote)
    run_pkg_hook "post_install" "$pkg"

    log_info "[$pkg] Instalação em / concluída."
}

build_and_install_with_deps() {
    local pkg="$1"
    log_info "Resolvendo dependências de $pkg"
    local order
    order=$(resolve_deps_order "$pkg")

    log_info "Ordem de build: $order"

    local dep
    for dep in $order; do
        if ! is_installed "$dep"; then
            log_info "[DEP] Construindo e instalando dependência: $dep"
            build_package "$dep"
            install_package_root "$dep"
        fi
    done
}

packages_in_group() {
    local group="$1"
    local meta
    while IFS= read -r -d '' meta; do
        (
            unset PKG_NAME PKG_GROUPS
            # shellcheck source=/dev/null
            source "$meta"
            : "${PKG_NAME:=$(basename "$meta" .meta)}"
            : "${PKG_GROUPS:=()}"
            local g
            for g in "${PKG_GROUPS[@]}"; do
                if [[ "$g" == "$group" ]]; then
                    printf '%s\n' "$PKG_NAME"
                    break
                fi
            done
        )
    done < <(find "$META_DIR" -type f -name '*.meta' -print0 2>/dev/null)
}

install_group() {
    local group="$1"

    log_info "Procurando pacotes do grupo '$group' em $META_DIR"
    local pkgs=()
    mapfile -t pkgs < <(packages_in_group "$group" | sort -u)

    if [[ ${#pkgs[@]} -eq 0 ]]; then
        die "Nenhum pacote encontrado com grupo '$group'."
    fi

    log_info "Pacotes no grupo '$group': ${pkgs[*]}"

    local pkg
    for pkg in "${pkgs[@]}"; do
        log_info "[grupo:$group] Instalando pacote '$pkg'"
        build_and_install_with_deps "$pkg"
    done
}

# =========================
# Uninstall + órfãos
# =========================

uninstall_package() {
    local pkg="$1"

    if [[ -z "$pkg" ]]; then
        die "uninstall_package: pacote não informado."
    fi

    if ! is_installed "$pkg"; then
        log_warn "[$pkg] Não está instalado."
        return 0
    fi

    local revdeps
    revdeps=$(reverse_deps_of "$pkg" || true)
    if [[ -n "$revdeps" ]]; then
        log_error "[$pkg] Possui reverse dependencies (alguns pacotes dependem dele):"
        echo "$revdeps"
        die "Não é seguro remover '$pkg' automaticamente."
    fi

     # Hook de pré-desinstalação (antes de remover arquivos do sistema)
    run_pkg_hook "pre_uninstall" "$pkg"

    local listfile
    listfile="$(db_files_list "$pkg")"
    [[ -f "$listfile" ]] || die "[$pkg] Lista de arquivos não encontrada: $listfile"

    log_info "[$pkg] Removendo arquivos instalados."

    tac "$listfile" | while IFS= read -r f; do
        [[ -z "$f" ]] && continue

        # Segurança extra: só aceita caminhos absolutos
        if [[ "$f" != /* ]]; then
            log_warn "[$pkg] Ignorando caminho não absoluto em files.list: $f"
            continue
        fi

        # Nunca remova a raiz por engano
        if [[ "$f" == "/" ]]; then
            log_warn "[$pkg] Ignorando entrada '/' em files.list."
            continue
        fi

        if [[ -d "$f" && ! -L "$f" ]]; then
            # Diretório: tenta remover se estiver vazio
            if ! rmdir "$f" 2>/dev/null; then
                log_debug "[$pkg] Diretório não removido (provavelmente não vazio): $f"
            fi
        else
            if [[ -e "$f" || -L "$f" ]]; then
                if ! rm -f "$f" 2>/dev/null; then
                    log_warn "[$pkg] Falha ao remover arquivo: $f"
                fi
            fi
        fi
    done

    rm -rf "$(db_pkg_dir "$pkg")"
    clear_pkg_stage "$pkg"
    rm -rf "$BUILD_ROOT/${pkg}-"* "$STATE_DIR/$pkg.builddir" 2>/dev/null || true

     # Hook de pós-desinstalação (após limpar DB e estado)
    run_pkg_hook "post_uninstall" "$pkg"

    log_info "[$pkg] Desinstalação concluída."
}

remove_orphans() {
    log_info "Localizando órfãos..."
    local orf
    orf=$(list_orphans || true)
    if [[ -z "$orf" ]]; then
        log_info "Nenhum pacote órfão encontrado."
        return 0
    fi

    log_info "Órfãos detectados: $orf"

    local failed=()
    local p
    for p in $orf; do
        log_info "Removendo órfão: $p"
        if ! uninstall_package "$p"; then
            log_error "[$p] Falha ao remover órfão."
            failed+=("$p")
        fi
    done

    if ((${#failed[@]} > 0)); then
        log_error "Remoção de órfãos concluída com falhas nos pacotes: ${failed[*]}"
        return 1
    fi

    log_info "Remoção de órfãos concluída com sucesso."
}

# =========================
# Verificação de integridade
# =========================

verify_package_integrity() {
    local pkg="$1"
    if [[ -z "$pkg" ]]; then
        die "verify_package_integrity: pacote não informado."
    fi
    if ! is_installed "$pkg"; then
        die "[$pkg] Não está instalado."
    fi

    local manifest
    manifest="$(db_manifest "$pkg")"
    [[ -f "$manifest" ]] || die "[$pkg] Manifesto de integridade não encontrado."

    log_info "[$pkg] Verificando integridade de arquivos..."
    local broken=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

          # Espera formato: 64 hex, dois espaços, caminho
        if [[ ! "$line" =~ ^[0-9a-fA-F]{64}[[:space:]][[:space:]]/ ]]; then
            log_warn "[$pkg] Linha em formato inesperado no manifesto (ignorando): $line"
            broken=1
            continue
        fi

        local sum file
        sum="${line%% *}"
        file="${line##*  }"

        if [[ -z "$sum" || -z "$file" ]]; then
            log_warn "[$pkg] Linha inválida no manifesto: $line"
            broken=1
            continue
        fi

        if [[ ! -f "$file" ]]; then
            log_error "[$pkg] Arquivo ausente: $file"
            broken=1
            continue
        fi

        local current
        current=$(sha256sum "$file" | awk '{print $1}')
        if [[ "$current" != "$sum" ]]; then
            log_error "[$pkg] Checksum incorreto: $file"
            broken=1
        fi
    done <"$manifest"

    if (( broken == 0 )); then
        log_info "[$pkg] Integridade OK."
        return 0
    else
        die "[$pkg] Integridade comprometida."
    fi
}

verify_all() {
    local pkg pkgdir
    local failed=()

    while IFS= read -r -d '' pkgdir; do
        [[ -d "$pkgdir" ]] || continue
        if [[ ! -f "$pkgdir/metadata.meta" && ! -f "$pkgdir/files.list" ]]; then
            continue
        fi
        pkg="$(basename "$pkgdir")"
        if ! verify_package_integrity "$pkg"; then
            failed+=("$pkg")
        fi
    done < <(find "$DB_DIR" -mindepth 1 -type d -print0 2>/dev/null)

    if ((${#failed[@]} > 0)); then
        log_error "Pacotes com integridade comprometida: ${failed[*]}"
        return 1
    fi

    log_info "Todos os pacotes instalados passaram na verificação de integridade."
}

# =========================
# Update / upgrade
# =========================

check_upstream_version() {
    local pkg="$1"
    load_metadata "$pkg"

    if [[ -z "${PKG_UPSTREAM_URL:-}" || -z "${PKG_UPSTREAM_REGEX:-}" ]]; then
        die "[$pkg] PKG_UPSTREAM_URL/PKG_UPSTREAM_REGEX não definidos no metadata."
    fi
    require_cmd curl

    log_info "[$pkg] Consultando upstream: $PKG_UPSTREAM_URL"
    local html
    if ! html=$(curl -L --fail --connect-timeout 15 --max-time 60 -s "$PKG_UPSTREAM_URL"); then
        die "[$pkg] Falha ao baixar página de upstream."
    fi

    # extrair versões pelo regex; o regex deve ter grupo de captura com a versão
    local versions
    versions=$(printf "%s" "$html" \
        | grep -Eo "$PKG_UPSTREAM_REGEX" \
        | sed -E "s/$PKG_UPSTREAM_REGEX/\\1/g" \
        | sort -Vu || true)

    if [[ -z "$versions" ]]; then
        die "[$pkg] Não foi possível extrair versões do upstream (verifique PKG_UPSTREAM_REGEX)."
    fi

    local newest
    newest=$(printf "%s\n" "$versions" | tail -n1)

    log_info "[$pkg] Versão local   : $PKG_VERSION"
    log_info "[$pkg] Versão upstream: $newest"

    if [[ "$newest" == "$PKG_VERSION" ]]; then
        log_info "[$pkg] Já está na versão mais recente."
        # não imprime nada → upgrade_package interpreta como "sem upgrade"
        return 0
    fi

    local oldmeta
    oldmeta="$(meta_path_for_pkg "$pkg")"
    local newmeta="${oldmeta%.meta}-${newest}.meta"

    sed -E "s/^(PKG_VERSION=).*$/\1\"$newest\"/" "$oldmeta" >"$newmeta"

    # zera hashes no metadata novo, para você preencher depois manualmente
    {
        echo ""
        echo "# ATENÇÃO: checksums resetados automaticamente pelo adm upgrade."
        echo "# Preencha PKG_SHA256S e/ou PKG_MD5S com os hashes corretos da versão $newest."
        echo "PKG_SHA256S=()"
        echo "PKG_MD5S=()"
    } >>"$newmeta"

    log_info "[$pkg] Novo metadata criado: $newmeta"
    echo "$newmeta"
}

upgrade_package() {
    local pkg="$1"

    if [[ -z "$pkg" ]]; then
        die "upgrade_package: pacote não informado."
    fi

    local newmeta
    newmeta=$(check_upstream_version "$pkg")
    if [[ -z "$newmeta" ]]; then
        log_info "[$pkg] Nenhum upgrade necessário."
        return 0
    fi

    if [[ ! -f "$newmeta" ]]; then
        die "[$pkg] Arquivo de novo metadata não encontrado: $newmeta"
    fi

    # Usar o novo metadata temporariamente, mas manter o nome do pacote
    local tmpmeta="$META_DIR/$pkg.upgrade.meta"
    cp "$newmeta" "$tmpmeta"

    log_info "[$pkg] Fazendo upgrade usando metadata: $tmpmeta"

    # backup do original
    local original
    original="$(meta_path_for_pkg "$pkg")"
    cp "$original" "$original.bak"

    mv "$tmpmeta" "$original"

    # construir e instalar nova versão, com rollback em caso de falha
    if ! build_package "$pkg"; then
        log_error "[$pkg] Falha durante build no upgrade; restaurando metadata original."
        mv "$original.bak" "$original"
        return 1
    fi

    if ! install_package_root "$pkg"; then
        log_error "[$pkg] Falha durante instalação no upgrade; restaurando metadata original."
        mv "$original.bak" "$original"
        return 1
    fi

    rm -f "$original.bak"

    load_metadata "$pkg"
    log_info "[$pkg] Upgrade concluído para versão $PKG_VERSION"
}

# =========================
# Rebuild
# =========================

rebuild_one() {
    local pkg="$1"

    if [[ -z "$pkg" ]]; then
        die "rebuild_one: pacote não informado."
    fi

    if ! is_installed "$pkg"; then
        die "[$pkg] Não está instalado; não há o que rebuildar."
    fi

    log_info "Rebuild do pacote: $pkg"
    clear_pkg_stage "$pkg"
    rm -rf "$BUILD_ROOT/${pkg}-"* "$STATE_DIR/$pkg.builddir" 2>/dev/null || true
    build_package "$pkg"
    install_package_root "$pkg"
}

rebuild_all() {
    declare -A seen
    local ordered=()

    log_info "Calculando ordem de rebuild global com base nas dependências..."

    local pkg pkgdir

    # Para cada pacote instalado (diretório com metadata.meta)
    while IFS= read -r -d '' pkgdir; do
        [[ -d "$pkgdir" ]] || continue
        if [[ ! -f "$pkgdir/metadata.meta" ]]; then
            continue
        fi
        pkg="$(basename "$pkgdir")"

        local order
        order=$(resolve_deps_order "$pkg")
        local p
        for p in $order; do
            if [[ -d "$(db_pkg_dir "$p")" && -z "${seen[$p]:-}" ]]; then
                ordered+=("$p")
                seen["$p"]=1
            fi
        done
    done < <(find "$DB_DIR" -mindepth 1 -type d -print0 2>/dev/null)

    if ((${#ordered[@]} == 0)); then
        log_info "Nenhum pacote instalado encontrado para rebuild."
        return 0
    fi

    log_info "Ordem final de rebuild: ${ordered[*]}"

    local failed=()
    local p
    for p in "${ordered[@]}"; do
        if ! rebuild_one "$p"; then
            failed+=("$p")
        fi
    done

    if ((${#failed[@]} > 0)); then
        log_error "Rebuild concluído com falhas nos pacotes: ${failed[*]}"
        return 1
    fi

    log_info "Rebuild de todos os pacotes concluído com sucesso."
}

# =========================
# CLI
# =========================

usage() {
    cat <<EOF
Uso: $0 [opções_globais] <comando> [args]

Opções globais:
  --no-chroot         - força build fora de qualquer chroot (ignora \$CHROOT_DIR do ambiente)

Comandos principais:
  build <pkg>         - Construir pacote (com retomada)
  install <pkg>       - Construir + instalar com dependências
  install-group <grupo> - Instalar todos os pacotes marcados com esse grupo (core, x11, etc.)
  uninstall <pkg>     - Desinstalar pacote (se não tiver reverse deps)
  remove-orphans      - Remover pacotes órfãos
  verify <pkg>        - Verificar integridade de um pacote instalado
  verify-all          - Verificar integridade de todos
  update <pkg>        - Buscar versão maior no upstream e gerar novo metadata
  upgrade <pkg>       - Upgrade automático (usa update + rebuild+install)
  rebuild <pkg>       - Rebuild completo de um pacote
  rebuild-all         - Rebuild de todos os pacotes instalados
  list-installed      - Listar pacotes instalados
  info <pkg>          - Mostrar info básica do pacote
  gen-hooks <pkg>     - Gerar estrutura padrão de hooks locais para o pacote
EOF
}

list_installed() {
    local pkg
    while IFS= read -r -d '' pkgdir; do
        [[ -d "$pkgdir" ]] || continue
        if [[ ! -f "$pkgdir/metadata.meta" && ! -f "$pkgdir/files.list" ]]; then
            continue
        fi
        pkg="$(basename "$pkgdir")"

        # Tentar ler metadata salvo no DB primeiro, sem abortar o script inteiro
        unset PKG_NAME PKG_VERSION PKG_RELEASE PKG_DEPENDS
        local meta_db
        meta_db="$pkgdir/metadata.meta"
        if [[ -f "$meta_db" ]]; then
            # shellcheck source=/dev/null
            source "$meta_db"
        elif [[ -f "$(meta_path_for_pkg "$pkg")" ]]; then
            # shellcheck source=/dev/null
            source "$(meta_path_for_pkg "$pkg")"
        else
            PKG_VERSION="?"
            PKG_RELEASE="?"
        fi

        printf "%-20s %s-%s\n" "$pkg" "${PKG_VERSION:-?}" "${PKG_RELEASE:-?}"
    done < <(find "$DB_DIR" -mindepth 1 -type d -print0 2>/dev/null)
}

info_pkg() {
    local pkg="$1"
    if is_installed "$pkg"; then
        # tentar carregar do DB primeiro
        if [[ -f "$(db_meta_copy "$pkg")" ]]; then
            # shellcheck source=/dev/null
            source "$(db_meta_copy "$pkg")"
        else
            load_metadata "$pkg"
        fi
        echo "Pacote:   $PKG_NAME"
        echo "Versão:   $PKG_VERSION"
        echo "Release:  ${PKG_RELEASE:-1}"
        echo "Depende:  ${PKG_DEPENDS[*]:-(nenhuma)}"
        echo "Instalado: SIM"
    else
        # não instalado, mas pode ter metadata
        if [[ -f "$(meta_path_for_pkg "$pkg")" ]]; then
            load_metadata "$pkg"
            echo "Pacote:   $PKG_NAME"
            echo "Versão:   $PKG_VERSION"
            echo "Release:  ${PKG_RELEASE:-1}"
            echo "Depende:  ${PKG_DEPENDS[*]:-(nenhuma)}"
            echo "Instalado: NÃO"
        else
            die "Pacote ou metadata não encontrado: $pkg"
        fi
    fi
}

# Parseia opções globais antes do comando
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-chroot)
            # Força build fora de chroot para esta execução
            CHROOT_DIR=""
            shift
            ;;
        --|-h|--help|help)
            # Deixa o comando / ajuda serem tratados normalmente abaixo
            break
            ;;
        -*)
            log_error "Opção global desconhecida: $1"
            usage
            exit 1
            ;;
        *)
            # Primeiro argumento que não é opção => comando
            break
            ;;
    esac
done

# Se CHROOT_DIR foi esvaziado (ex: --no-chroot), ajusta BUILD_ROOT para ficar fora do chroot
if [[ -z "${CHROOT_DIR:-}" ]]; then
    : "${LFS_PKG_ROOT:=/var/lib/adm}"
    BUILD_ROOT="${LFS_PKG_ROOT}/build"
    mkdir -p "$BUILD_ROOT"
fi

cmd="${1:-}"
case "$cmd" in
    build)
        shift || true
        [[ $# -ge 1 ]] || { usage; exit 1; }
        build_package "$1"
        ;;
    install)
        shift || true
        [[ $# -ge 1 ]] || { usage; exit 1; }
        build_and_install_with_deps "$1"
        ;;
    install-group)
        shift || true
        [[ $# -ge 1 ]] || { usage; exit 1; }
        install_group "$1"
        ;;
    uninstall)
        shift || true
        [[ $# -ge 1 ]] || { usage; exit 1; }
        uninstall_package "$1"
        ;;
    remove-orphans)
        remove_orphans
        ;;
    verify)
        shift || true
        [[ $# -ge 1 ]] || { usage; exit 1; }
        verify_package_integrity "$1"
        ;;
    verify-all)
        verify_all
        ;;
    update)
        shift || true
        [[ $# -ge 1 ]] || { usage; exit 1; }
        check_upstream_version "$1" || true
        ;;
    upgrade)
        shift || true
        [[ $# -ge 1 ]] || { usage; exit 1; }
        upgrade_package "$1"
        ;;
    rebuild)
        shift || true
        [[ $# -ge 1 ]] || { usage; exit 1; }
        rebuild_one "$1"
        ;;
    rebuild-all)
        rebuild_all
        ;;
    list-installed)
        list_installed
        ;;
    info)
        shift || true
        [[ $# -ge 1 ]] || { usage; exit 1; }
        info_pkg "$1"
        ;;
    gen-hooks)
        shift || true
        [[ $# -ge 1 ]] || { usage; exit 1; }
        generate_hooks_for_pkg "$1"
        ;;
    ""|-h|--help|help)
        usage
        ;;
    *)
        log_error "Comando desconhecido: $cmd"
        usage
        exit 1
        ;;
esac
