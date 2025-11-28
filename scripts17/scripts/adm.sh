#!/usr/bin/env bash
# Simple LFS package manager / build system

set -euo pipefail

# =========================
# Configuração geral
# =========================
: "${LFS_PKG_ROOT:=/var/lib/lfs-pkg}"          # raiz do sistema de pacotes
: "${META_DIR:=$LFS_PKG_ROOT/metadata}"       # onde ficam os metadatas
: "${CACHE_DIR:=$LFS_PKG_ROOT/cache}"         # cache de downloads / git
: "${BUILD_ROOT:=$LFS_PKG_ROOT/build}"        # área de build
: "${PKG_DIR:=$LFS_PKG_ROOT/packages}"        # pacotes .tar.zst / .tar.xz
: "${DB_DIR:=$LFS_PKG_ROOT/db}"               # info de instalados
: "${STATE_DIR:=$LFS_PKG_ROOT/state}"         # estado de construção (retomada)
: "${LOG_DIR:=$LFS_PKG_ROOT/log}"             # logs
: "${LOG_FILE:=$LOG_DIR/lfs-pkg.log}"         # log sem cores
: "${CHROOT_DIR:=}"                           # se definido, builds em chroot
: "${PARALLEL_JOBS:=4}"                       # downloads paralelos

mkdir -p "$META_DIR" "$CACHE_DIR" "$BUILD_ROOT" "$PKG_DIR" "$DB_DIR" "$STATE_DIR" "$LOG_DIR"

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
require_cmd tar gzip xz zstd sha256sum md5sum sed awk sort grep

# =========================
# Carregar metadata
# =========================

meta_path_for_pkg() {
    local pkg="$1"
    echo "$META_DIR/$pkg.meta"
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
          PKG_BUILD PKG_INSTALL PKG_UPSTREAM_URL PKG_UPSTREAM_REGEX
    # shellcheck source=/dev/null
    source "$(meta_path_for_pkg "$pkg")"

    : "${PKG_NAME:=$pkg}"
    : "${PKG_VERSION:?PKG_VERSION não definido em metadata de $pkg}"
    : "${PKG_RELEASE:=1}"
    : "${PKG_SOURCE_URLS:?PKG_SOURCE_URLS não definido em metadata de $pkg}"
    : "${PKG_DEPENDS:=()}"
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
    echo "$stage" >"$STATE_DIR/$pkg.stage"
}

clear_pkg_stage() {
    local pkg="$1"
    rm -f "$STATE_DIR/$pkg.stage"
}

# =========================
# Download com cache + checksum
# =========================

download_one_source() {
    local pkg="$1" idx="$2" urlspec="$3" out="$4" sha256="$5" md5="$6"

    # urlspec pode ter múltiplos espelhos separados por '|'
    local -a mirrors=()
    IFS='|' read -r -a mirrors <<<"$urlspec"
    if ((${#mirrors[@]} == 0)); then
        die "[$pkg] Nenhuma URL válida em PKG_SOURCE_URLS[$idx]"
    fi

    local attempts_per_mirror=3
    local have_checksum=0
    [[ -n "$sha256" ]] && have_checksum=1
    [[ -n "$md5" ]] && have_checksum=1

    # Se já existe no cache, verifica checksum ANTES de qualquer coisa
    if [[ -f "$out" && $have_checksum -eq 1 ]]; then
        local ok=1
        if [[ -n "$sha256" ]]; then
            if ! echo "$sha256  $out" | sha256sum -c - >/dev/null 2>&1; then
                ok=0
            fi
        fi
        if [[ -n "$md5" ]]; then
            if ! echo "$md5  $out" | md5sum -c - >/dev/null 2>&1; then
                ok=0
            fi
        fi
        if (( ok == 1 )); then
            log_info "[$pkg] Cache OK (checksums) para $out"
            return 0
        else
            log_warn "[$pkg] Cache inválido para $out, removendo"
            rm -f "$out"
        fi
    fi

    # Função interna para fazer download de UMA url
    _do_download_url() {
        local url="$1" tmpout="$2"

        if [[ "$url" == git://* || "$url" == *.git || "$url" == git+* ]]; then
            require_cmd git
            local tmpdir="${tmpout}.gitclone"
            rm -rf "$tmpdir"
            mkdir -p "$tmpdir"
            log_info "[$pkg] Clonando repositório git: $url"
            if git clone --depth=1 "${url#git+}" "$tmpdir" >>"$LOG_FILE" 2>&1; then
                tar -cf "$tmpout" -C "$tmpdir" . >>"$LOG_FILE" 2>&1
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
                if curl -L --fail --progress-bar -o "$tmpout" "$url" >>"$LOG_FILE" 2>&1; then
                    return 0
                else
                    log_warn "[$pkg] Falha no curl: $url"
                    return 1
                fi
            elif command -v wget >/dev/null 2>&1; then
                log_info "[$pkg] Baixando via wget: $url"
                if wget --progress=bar:force -O "$tmpout" "$url" >>"$LOG_FILE" 2>&1; then
                    return 0
                else
                    log_warn "[$pkg] Falha no wget: $url"
                    return 1
                fi
            else
                die "Nem curl nem wget encontrados para download."
            fi
        fi
    }

    local mirror
    for mirror in "${mirrors[@]}"; do
        mirror="${mirror//[[:space:]]/}"  # tira espaços acidentais
        [[ -z "$mirror" ]] && continue

        log_info "[$pkg] Usando mirror: $mirror -> $out"
        local attempt
        for (( attempt=1; attempt<=attempts_per_mirror; attempt++ )); do
            log_info "[$pkg] Download tentativa $attempt/$attempts_per_mirror: $mirror"

            local tmpout="${out}.part"
            rm -f "$tmpout"

            if !_do_download_url "$mirror" "$tmpout"; then
                log_warn "[$pkg] Falha ao baixar de $mirror (tentativa $attempt)"
                continue
            fi

            if [[ ! -f "$tmpout" ]]; then
                log_warn "[$pkg] Download não produziu arquivo: $tmpout"
                continue
            fi

            # Verificar checksums se fornecidos
            local ok=1
            if [[ -n "$sha256" ]]; then
                if ! echo "$sha256  $tmpout" | sha256sum -c - >/dev/null 2>&1; then
                    log_warn "[$pkg] sha256 inválido para arquivo baixado de $mirror"
                    ok=0
                fi
            fi
            if [[ -n "$md5" ]]; then
                if ! echo "$md5  $tmpout" | md5sum -c - >/dev/null 2>&1; then
                    log_warn "[$pkg] md5 inválido para arquivo baixado de $mirror"
                    ok=0
                fi
            fi

            if (( ok == 1 || have_checksum == 0 )); then
                mv "$tmpout" "$out"
                log_info "[$pkg] Download concluído e válido: $out"
                return 0
            else
                rm -f "$tmpout"
            fi
        done
    done

    die "[$pkg] Falha ao baixar/verificar source $idx depois de tentar todos os mirrors."
}

download_sources_parallel() {
    local pkg="$1"
    load_metadata "$pkg"
    validate_source_arrays   # <<< usa a função nova

    local urls=("${PKG_SOURCE_URLS[@]}")
    local sha256s=()
    local md5s=()

    if [[ ${#PKG_SHA256S[@]:-0} -gt 0 ]]; then
        sha256s=("${PKG_SHA256S[@]}")
    fi
    if [[ ${#PKG_MD5S[@]:-0} -gt 0 ]]; then
        md5s=("${PKG_MD5S[@]}")
    fi

    mkdir -p "$CACHE_DIR"

    local pids=()
    local i=0
    local urlspec
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
        pids+=($!)
        (( i++ ))

        # limitar paralelismo
        while (( $(jobs -rp | wc -l) >= PARALLEL_JOBS )); do
            sleep 0.2
        done
    done

    local fail=0
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
    for url in "${PKG_SOURCE_URLS[@]}"; do
        local base
        base="$(basename "${url%%\?*}")"
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

run_in_chroot() {
    local workdir="$1"; shift
    local cmd="$*"

    if [[ -n "$CHROOT_DIR" ]]; then
        require_cmd chroot

        if [[ ! -x "$CHROOT_DIR/bin/bash" ]]; then
            die "[chroot] $CHROOT_DIR não parece um chroot válido (faltando /bin/bash executável)."
        fi

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
    mkdir -p "$(db_pkg_dir "$pkg")"
    local listfile
    listfile="$(db_files_list "$pkg")"
    local manifest
    manifest="$(db_manifest "$pkg")"

    : >"$listfile"
    : >"$manifest"

    log_info "[$pkg] Registrando arquivos instalados"
    (
        cd "$destdir"
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
    local pkg
    for pkgpath in "$DB_DIR"/*; do
        [[ -d "$pkgpath" ]] || continue
        pkg="$(basename "$pkgpath")"
        # carrega metadata salvo na instalação
        unset PKG_NAME PKG_DEPENDS
        # shellcheck source=/dev/null
        if [[ -f "$pkgpath/metadata.meta" ]]; then
            source "$pkgpath/metadata.meta"
            for d in "${PKG_DEPENDS[@]:-}"; do
                if [[ "$d" == "$target" ]]; then
                    echo "$pkg"
                fi
            done
        fi
    done
}

# Detectar órfãos: pacotes que ninguém depende (e que não são base listados)
list_orphans() {
    local base_pkgs=() # você pode adicionar base aqui se quiser preservar
    declare -A has_revdep
    local pkg

    for pkgpath in "$DB_DIR"/*; do
        [[ -d "$pkgpath" ]] || continue
        pkg="$(basename "$pkgpath")"
        has_revdep["$pkg"]=0
    done

    for pkgpath in "$DB_DIR"/*; do
        [[ -d "$pkgpath" ]] || continue
        pkg="$(basename "$pkgpath")"
        unset PKG_DEPENDS
        # shellcheck source=/dev/null
        if [[ -f "$pkgpath/metadata.meta" ]]; then
            source "$pkgpath/metadata.meta"
            for d in "${PKG_DEPENDS[@]:-}"; do
                has_revdep["$d"]=1
            done
        fi
    done

    for pkg in "${!has_revdep[@]}"; do
        local keep=0
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
        echo "$builddir" >"$STATE_DIR/$pkg.builddir"
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
            run_in_chroot "$builddir" "PKG_NAME='$PKG_NAME'; PKG_VERSION='$PKG_VERSION'; DESTDIR=''; $(declare -f PKG_BUILD); PKG_BUILD"
        else
            log_warn "[$pkg] PKG_BUILD não definido, pulando build (assumindo build manual no metadata)"
        fi
        set_pkg_stage "$pkg" 3
    else
        log_info "[$pkg] Retomando: build já concluída (stage>=3)"
    fi

    # DESTDIR para instalação temporária
    local destdir="$BUILD_ROOT/${PKG_NAME}-${PKG_VERSION}-destdir"
    rm -rf "$destdir"
    mkdir -p "$destdir"

    if (( stage < 4 )); then
        log_info "[$pkg] Instalando em DESTDIR: $destdir"
        if declare -F PKG_INSTALL >/dev/null 2>&1; then
            run_in_chroot "$builddir" "PKG_NAME='$PKG_NAME'; PKG_VERSION='$PKG_VERSION'; DESTDIR='$destdir'; $(declare -f PKG_INSTALL); PKG_INSTALL"
        else
            log_warn "[$pkg] PKG_INSTALL não definido, nenhum arquivo instalado em DESTDIR"
        fi

        # Empacotar DESTDIR
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

    log_info "[$pkg] Instalando em / a partir de $destdir"
    # Cópia preservando atributos
    ( cd "$destdir" && cp -a . / )

    register_install "$pkg" "$destdir"

    set_pkg_stage "$pkg" 5
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

# =========================
# Uninstall + órfãos
# =========================

uninstall_package() {
    local pkg="$1"
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

    local listfile
    listfile="$(db_files_list "$pkg")"
    [[ -f "$listfile" ]] || die "[$pkg] Lista de arquivos não encontrada: $listfile"

    log_info "[$pkg] Removendo arquivos instalados."
    tac "$listfile" | while read -r f; do
        if [[ -d "$f" && ! -L "$f" ]]; then
            # remove diretório se vazio
            rmdir "$f" 2>/dev/null || true
        else
            rm -f "$f" 2>/dev/null || true
        fi
    done

    rm -rf "$(db_pkg_dir "$pkg")"
    clear_pkg_stage "$pkg"
    rm -rf "$BUILD_ROOT/${pkg}-"* "$STATE_DIR/$pkg.builddir" 2>/dev/null || true
    log_info "[$pkg] Desinstalação concluída."
}

remove_orphans() {
    log_info "Localizando órfãos..."
    local orf
    orf=$(list_orphans || true)
    if [[ -z "$orf" ]]; then
        log_info "Nenhum órfão encontrado."
        return 0
    fi
    log_info "Órfãos detectados: $orf"
    local p
    for p in $orf; do
        log_info "Removendo órfão: $p"
        uninstall_package "$p"
    done
}

# =========================
# Verificação de integridade
# =========================

verify_package_integrity() {
    local pkg="$1"
    if ! is_installed "$pkg"; then
        die "[$pkg] Não está instalado."
    fi
    local manifest
    manifest="$(db_manifest "$pkg")"
    [[ -f "$manifest" ]] || die "[$pkg] Manifesto de integridade não encontrado."

    log_info "[$pkg] Verificando integridade de arquivos..."
    local broken=0
    while read -r line; do
        local sum file
        sum="${line%% *}"
        file="${line##*  }"
        if [[ ! -f "$file" ]]; then
            log_error "Arquivo ausente: $file"
            broken=1
        else
            local current
            current=$(sha256sum "$file" | awk '{print $1}')
            if [[ "$current" != "$sum" ]]; then
                log_error "Checksum incorreto: $file"
                broken=1
            fi
        fi
    done <"$manifest"

    if (( broken == 0 )); then
        log_info "[$pkg] Integridade OK."
    else
        die "[$pkg] Integridade comprometida."
    fi
}

verify_all() {
    local pkg
    for pkgdir in "$DB_DIR"/*; do
        [[ -d "$pkgdir" ]] || continue
        pkg="$(basename "$pkgdir")"
        verify_package_integrity "$pkg" || true
    done
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
    html=$(curl -L --fail -s "$PKG_UPSTREAM_URL")

    # extrair versões pelo regex
    local versions
    versions=$(printf "%s" "$html" | grep -Eo "$PKG_UPSTREAM_REGEX" | sed -E "s/$PKG_UPSTREAM_REGEX/\\1/g" | sort -Vu || true)

    if [[ -z "$versions" ]]; then
        die "[$pkg] Não foi possível extrair versões do upstream."
    fi

    local newest
    newest=$(printf "%s\n" "$versions" | tail -n1)

    log_info "[$pkg] Version local : $PKG_VERSION"
    log_info "[$pkg] Version upstream: $newest"

    if [[ "$newest" == "$PKG_VERSION" ]]; then
        log_info "[$pkg] Já está na versão mais recente."
        return 1
    fi

    # criar metadata novo ao lado do antigo
    local oldmeta
    oldmeta="$(meta_path_for_pkg "$pkg")"
    local newmeta="${oldmeta%.meta}-${newest}.meta"

    sed -E "s/^(PKG_VERSION=).*$/\1\"$newest\"/" "$oldmeta" >"$newmeta"

    log_info "[$pkg] Novo metadata criado: $newmeta"
    echo "$newmeta"
}

upgrade_package() {
    local pkg="$1"
    local newmeta
    newmeta=$(check_upstream_version "$pkg" || true)
    if [[ -z "$newmeta" ]]; then
        log_info "[$pkg] Nenhum upgrade necessário."
        return 0
    fi

    # Usar o novo metadata temporariamente, mas manter o nome do pacote
    local tmpmeta="$META_DIR/$pkg.upgrade.meta"
    cp "$newmeta" "$tmpmeta"

    log_info "[$pkg] Fazendo upgrade usando metadata: $tmpmeta"

    # backup do original
    local original
    original="$(meta_path_for_pkg "$pkg")"
    mv "$original" "$original.bak"
    mv "$tmpmeta" "$original"

    # construir e instalar nova versão
    build_package "$pkg"
    install_package_root "$pkg"

    log_info "[$pkg] Upgrade concluído para versão $(load_metadata "$pkg"; echo "$PKG_VERSION")"
}

# =========================
# Rebuild
# =========================

rebuild_one() {
    local pkg="$1"
    log_info "Rebuild do pacote: $pkg"
    clear_pkg_stage "$pkg"
    rm -rf "$BUILD_ROOT/${pkg}-"* "$STATE_DIR/$pkg.builddir" 2>/dev/null || true
    build_package "$pkg"
    install_package_root "$pkg"
}

rebuild_all() {
    local pkg
    for pkgdir in "$DB_DIR"/*; do
        [[ -d "$pkgdir" ]] || continue
        pkg="$(basename "$pkgdir")"
        rebuild_one "$pkg"
    done
}

# =========================
# CLI
# =========================

usage() {
    cat <<EOF
Uso: $0 <comando> [args]

Comandos principais:
  build <pkg>         - Construir pacote (com retomada)
  install <pkg>       - Construir + instalar com dependências
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
EOF
}

list_installed() {
    local pkg
    for pkgdir in "$DB_DIR"/*; do
        [[ -d "$pkgdir" ]] || continue
        pkg="$(basename "$pkgdir")"
        load_metadata "$pkg" || true
        printf "%-20s %s-%s\n" "$pkg" "${PKG_VERSION:-?}" "${PKG_RELEASE:-?}"
    done
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
    ""|-h|--help|help)
        usage
        ;;
    *)
        log_error "Comando desconhecido: $cmd"
        usage
        exit 1
        ;;
esac
