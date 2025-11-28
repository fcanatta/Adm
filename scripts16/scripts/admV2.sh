#!/usr/bin/env bash
# adm - Simple package manager for Linux From Scratch style systems
# Features:
#  - Build/install/remove packages defined as shell recipes
#  - Binary cache (.tar.zst and .tar.xz)
#  - Source cache and parallel downloads
#  - Dependency resolution with Kahn-style topological sort and cycle detection
#  - DESTDIR support and manifest-based uninstall
#  - Simple upgrade mechanism based on recipe-provided upstream version
#
# NOTE:
#  Este script é um framework genérico. Cada pacote precisa de um "recipe"
#  em shell que define como baixar, compilar e instalar o programa.
#  Ver comentários em ADM_RECIPES_DIR mais abaixo.

set -euo pipefail

ADM_VERSION="0.2.0"   # versão do framework (v2: upgrade aprimorado, fixes)

# -------------------------------------------------------------
# Configuração básica (pode ser sobrescrita por variáveis de ambiente)
# -------------------------------------------------------------
ADM_PREFIX="${ADM_PREFIX:-/usr}"
ADM_STATE_DIR="${ADM_STATE_DIR:-/var/lib/adm}"
ADM_CACHE_DIR="${ADM_CACHE_DIR:-$ADM_STATE_DIR/cache}"
ADM_SRC_CACHE="${ADM_SRC_CACHE:-$ADM_CACHE_DIR/src}"
ADM_BIN_CACHE="${ADM_BIN_CACHE:-$ADM_CACHE_DIR/bin}"
ADM_BUILD_ROOT="${ADM_BUILD_ROOT:-/var/tmp/adm/build}"
ADM_LOG_DIR="${ADM_LOG_DIR:-/var/log/adm}"
ADM_DB_DIR="${ADM_DB_DIR:-$ADM_STATE_DIR/db}"
ADM_MANIFEST_DIR="${ADM_MANIFEST_DIR:-$ADM_DB_DIR/manifests}"
ADM_META_DIR="${ADM_META_DIR:-$ADM_DB_DIR/meta}"
ADM_RECIPES_DIR="${ADM_RECIPES_DIR:-$ADM_STATE_DIR/recipes}"
ADM_DL_JOBS="${ADM_DL_JOBS:-4}"
ADM_CHROOT_DIR="${ADM_CHROOT_DIR:-}"   # opcional, para builds em chroot
ADM_DEFAULT_COMPRESS="${ADM_DEFAULT_COMPRESS:-zst}" # zst ou xz

umask 022

# -------------------------------------------------------------
# Cores
# -------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_MAGENTA=$'\033[35m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
fi

log_ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

log_info()  { printf '%s[%s] [INFO]%s %s\n'  "$C_GREEN"  "$(log_ts)" "$C_RESET" "$*" >&2; }
log_warn()  { printf '%s[%s] [WARN]%s %s\n'  "$C_YELLOW" "$(log_ts)" "$C_RESET" "$*" >&2; }
log_error() { printf '%s[%s] [ERRO]%s %s\n'  "$C_RED"    "$(log_ts)" "$C_RESET" "$*" >&2; }
log_debug() { [[ -n "${ADM_DEBUG:-}" ]] && printf '%s[%s] [DBG ]%s %s\n' "$C_CYAN" "$(log_ts)" "$C_RESET" "$*" >&2 || true; }

die() {
  log_error "$*"
  exit 1
}

dry_run_enabled() {
  case "${ADM_DRY_RUN:-0}" in
    1|true|yes|on|ON|TRUE)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# -------------------------------------------------------------
# Inicialização de diretórios
# -------------------------------------------------------------
init_dirs() {
  for d in \
    "$ADM_STATE_DIR" "$ADM_CACHE_DIR" "$ADM_SRC_CACHE" "$ADM_BIN_CACHE" \
    "$ADM_BUILD_ROOT" "$ADM_LOG_DIR" "$ADM_DB_DIR" \
    "$ADM_MANIFEST_DIR" "$ADM_META_DIR" "$ADM_RECIPES_DIR"; do
    if [[ ! -d "$d" ]]; then
      mkdir -p "$d" || die "Não foi possível criar diretório: $d"
    fi
  done
}

# -------------------------------------------------------------
# Tratamento de erros
# -------------------------------------------------------------
cleanup_build() {
  local builddir="${ADM_CURRENT_BUILD_DIR:-}"
  if [[ -n "$builddir" && -d "$builddir" ]]; then
    log_debug "Limpando diretório de build temporário: $builddir"
    rm -rf "$builddir" || log_warn "Falha ao remover $builddir"
  fi
}

on_err() {
  local exit_code=$?
  log_error "Erro inesperado (code=$exit_code). Veja logs em $ADM_LOG_DIR."
  cleanup_build
  exit "$exit_code"
}

trap on_err ERR
trap cleanup_build EXIT

# -------------------------------------------------------------
# Utilidades gerais
# -------------------------------------------------------------
ensure_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Comando obrigatório não encontrado: $cmd"
}

check_runtime_deps() {
  # Comandos essenciais para o funcionamento do adm
  local cmds=(
    tee tar find xargs sort tac
    sha256sum
  )

  # Comandos muito recomendados (mas não fatais se não existirem em todos os fluxos)
  local optional_cmds=(
    md5sum
    make
    curl wget
    unzip bunzip2 gunzip 7z
    git rsync
    zstd xz lzip
  )

  local c
  for c in "${cmds[@]}"; do
    ensure_cmd "$c"
  done

  # Optional: só loga aviso se faltar
  for c in "${optional_cmds[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      log_warn "Comando opcional não encontrado: $c (algumas operações/recipes podem falhar)"
    fi
  done
}

# Comparação de versões usando sort -V
ver_gt() {
  local a="$1"; local b="$2"
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" == "$a" && "$a" != "$b" ]]
}

ver_ge() {
  local a="$1"; local b="$2"
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" == "$a" ]]
}

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

# -------------------------------------------------------------
# Localizar arquivo de recipe de um pacote em qualquer subdiretório
# Nome do pacote == nome do arquivo .sh (ex: man-pages -> man-pages.sh)
# -------------------------------------------------------------
find_recipe_file() {
  local pkg="$1"
  local recipe

  # Se ainda não existe recipes dir, evita erro de find
  if [[ ! -d "$ADM_RECIPES_DIR" ]]; then
    return 1
  fi

  # Procura a primeira ocorrência de <pkg>.sh em qualquer subdiretório
  recipe="$(find "$ADM_RECIPES_DIR" -type f -name "$pkg.sh" -print | head -n1)"

  if [[ -z "$recipe" ]]; then
    return 1
  fi

  printf '%s\n' "$recipe"
}

# -------------------------------------------------------------
# Carregar recipe de pacote
ADM_LAST_RECIPE_PATH=""
# -------------------------------------------------------------
load_recipe() {
  local pkg="$1"
  local recipe

  recipe="$(find_recipe_file "$pkg")" || die "Recipe não encontrado para pacote '$pkg' em $ADM_RECIPES_DIR"
  ADM_LAST_RECIPE_PATH="$recipe"

  unset PKG_NAME PKG_VERSION PKG_RELEASE PKG_DESC PKG_DEPENDS PKG_SOURCES \
        PKG_BUILD_DIR PKG_LICENSE PKG_URL PKG_SHA256S PKG_MD5S PKG_GROUPS

  # Limpa funções de recipes anteriores (se existirem)
  unset -f pkg_prepare pkg_build pkg_check pkg_install pkg_upstream_version 2>/dev/null || true

  # shellcheck source=/dev/null
  . "$recipe"

  [[ -n "${PKG_NAME:-}" ]] || die "Recipe $recipe não define PKG_NAME"
  [[ -n "${PKG_VERSION:-}" ]] || die "Recipe $recipe não define PKG_VERSION"

  if [[ "$(basename "$PKG_NAME")" != "$pkg" ]]; then
    log_warn "PKG_NAME='$PKG_NAME' difere do nome solicitado '$pkg' em '$recipe'"
  fi
}

load_recipe_soft() {
  local pkg="$1"
  local recipe

  if ! recipe="$(find_recipe_file "$pkg")"; then
    log_warn "Recipe não encontrado para pacote '$pkg' em $ADM_RECIPES_DIR"
    return 1
  fi

  ADM_LAST_RECIPE_PATH="$recipe"

  unset PKG_NAME PKG_VERSION PKG_RELEASE PKG_DESC PKG_DEPENDS PKG_SOURCES \
        PKG_BUILD_DIR PKG_LICENSE PKG_URL PKG_SHA256S PKG_MD5S PKG_GROUPS
  unset -f pkg_prepare pkg_build pkg_check pkg_install pkg_upstream_version 2>/dev/null || true

  # Desliga -e temporariamente para evitar acionar o trap ERR aqui
  local old_opts="$-"
  if [[ "$old_opts" == *e* ]]; then
    set +e
  fi

  # shellcheck source=/dev/null
  . "$recipe"
  local status=$?

  # Restaura -e se estava ligado
  if [[ "$old_opts" == *e* ]]; then
    set -e
  fi

  if (( status != 0 )); then
    log_warn "Falha ao carregar recipe '$recipe' para pacote '$pkg' (status=$status)"
    return 1
  fi

  if [[ -z "${PKG_NAME:-}" || -z "${PKG_VERSION:-}" ]]; then
    log_warn "Recipe '$recipe' inválido (PKG_NAME/PKG_VERSION ausentes)"
    return 1
  fi

  if [[ "$(basename "$PKG_NAME")" != "$pkg" ]]; then
    log_warn "PKG_NAME='$PKG_NAME' difere do nome solicitado '$pkg' em '$recipe'"
  fi

  return 0
}

# -------------------------------------------------------------
# Banco de dados / metadados
# -------------------------------------------------------------
meta_file_for() {
  local pkg="$1"
  printf '%s/%s.meta' "$ADM_META_DIR" "$pkg"
}

is_installed() {
  local pkg="$1"
  [[ -f "$(meta_file_for "$pkg")" ]]
}

get_installed_version() {
  local pkg="$1"
  local meta
  meta="$(meta_file_for "$pkg")"
  [[ -f "$meta" ]] || return 1
  awk -F= '$1=="version"{print $2}' "$meta"
}

write_meta() {
  local pkg="$1" version="$2" release="$3" deps="$4"
  local meta
  meta="$(meta_file_for "$pkg")"
  {
    printf 'name=%s\n' "$pkg"
    printf 'version=%s\n' "$version"
    printf 'release=%s\n' "$release"
    printf 'depends=%s\n' "$deps"
    printf 'installed_at=%s\n' "$(timestamp)"
  } >"$meta.tmp"
  mv "$meta.tmp" "$meta"
}

manifest_file_for() {
  local pkg="$1"
  printf '%s/%s.manifest' "$ADM_MANIFEST_DIR" "$pkg"
}

list_installed() {
  if [[ ! -d "$ADM_META_DIR" ]]; then
    return 0
  fi
  for f in "$ADM_META_DIR"/*.meta; do
    [[ -e "$f" ]] || continue
    basename "${f%.meta}"
  done | sort
}

# -------------------------------------------------------------
# Download de fontes (com cache e paralelismo)
# -------------------------------------------------------------
download_one() {
  local url="$1"
  local dest="$2"
  local sha256="$3"
  local md5="$4"

  # Tenta no máximo duas vezes: download + (se necessário) redownload
  local attempt
  for attempt in 1 2; do
    if (( attempt == 2 )); then
      log_warn "Nova tentativa de download para $(basename "$dest")..."
    fi

    if [[ -f "$dest" ]]; then
      log_debug "Fonte já em cache: $dest"
    else
      log_info "Baixando fonte: $url -> $dest"

      case "$url" in
        git+*|git://*|*.git)
          ensure_cmd git
          local tmp_dir="${dest}.git-tmp"
          rm -rf "$tmp_dir"
          git clone --depth 1 "${url#git+}" "$tmp_dir"
          ( cd "$tmp_dir" && git archive --format=tar --output="$dest" HEAD )
          rm -rf "$tmp_dir"
          ;;
        http://*|https://*|ftp://*)
          if command -v curl >/dev/null 2>&1; then
            curl -L --fail --retry 3 -o "$dest" "$url"
          elif command -v wget >/dev/null 2>&1; then
            wget -O "$dest" "$url"
          else
            die "Nem curl nem wget encontrados para baixar: $url"
          fi
          ;;
        rsync://*)
          ensure_cmd rsync
          rsync -av "$url" "$dest"
          ;;
        *)
          die "Esquema de URL não suportado: $url"
          ;;
      esac
    fi

    # Verificação de SHA256, se fornecido
    if [[ -n "$sha256" ]]; then
      log_info "Verificando SHA256 de $(basename "$dest")"
      local calc_sha
      calc_sha="$(sha256sum "$dest" | awk '{print $1}')"

      if [[ "$calc_sha" != "$sha256" ]]; then
        log_warn "SHA256 incorreto para $(basename "$dest"). Esperado: $sha256 Obtido: $calc_sha"
        log_warn "Removendo para tentar baixar novamente..."
        rm -f "$dest"
        continue
      fi
    fi

    # Verificação de MD5, se fornecido (só se md5sum existir)
    if [[ -n "$md5" ]]; then
      if ! command -v md5sum >/dev/null 2>&1; then
        log_warn "MD5 fornecido mas md5sum não está disponível; pulando verificação MD5 de $(basename "$dest")"
      else
        log_info "Verificando MD5 de $(basename "$dest")"
        local calc_md5
        calc_md5="$(md5sum "$dest" | awk '{print $1}')"

        if [[ "$calc_md5" != "$md5" ]]; then
          log_warn "MD5 incorreto para $(basename "$dest"). Esperado: $md5 Obtido: $calc_md5"
          log_warn "Removendo para tentar baixar novamente..."
          rm -f "$dest"
          continue
        fi
      fi
    fi

    # Se chegou aqui, passou em todas as checagens
    return 0
  done

  die "Falha ao baixar/verificar $(basename "$dest") após duas tentativas."
}

download_sources_parallel() {
  local -a urls=("$@")
  local -a sha256s md5s
  local -a pids=()
  local -i running=0
  local -i idx=0

  mkdir -p "$ADM_SRC_CACHE"

  # Transforma PKG_SHA256S / PKG_MD5S (string) em arrays alinhados
  IFS=' ' read -r -a sha256s <<< "${PKG_SHA256S:-}"
  IFS=' ' read -r -a md5s    <<< "${PKG_MD5S:-}"

  for url in "${urls[@]}"; do
    [[ -n "$url" ]] || { ((idx++)); continue; }

    local filename dest sha md5
    filename="$(basename "${url%%\?*}")"
    dest="$ADM_SRC_CACHE/$filename"
    sha="${sha256s[$idx]:-}"
    md5="${md5s[$idx]:-}"

    (
      set -e
      download_one "$url" "$dest" "$sha" "$md5"
    ) &
    pids+=("$!")
    ((running++))

    if (( running >= ADM_DL_JOBS )); then
      local pid failed=0
      for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
          failed=1
        fi
      done
      pids=()
      running=0
      (( failed == 0 )) || die "Falha em pelo menos um download de fonte."
    fi

    ((idx++))
  done

  # Espera os últimos downloads
  if (( running > 0 )); then
    local pid failed=0
    for pid in "${pids[@]}"; do
      if ! wait "$pid"; then
        failed=1
      fi
    done
    (( failed == 0 )) || die "Falha em pelo menos um download de fonte."
  fi
}

# -------------------------------------------------------------
# Extração de fontes
# -------------------------------------------------------------
extract_src() {
  local archive="$1"
  local dest_dir="$2"

  [[ -f "$archive" ]] || die "Arquivo de fonte não encontrado: $archive"

  mkdir -p "$dest_dir"

  log_info "Extraindo $archive em $dest_dir"

  case "$archive" in
    *.tar.gz|*.tgz)    tar -xzf "$archive" -C "$dest_dir" ;;
    *.tar.bz2|*.tbz2)  tar -xjf "$archive" -C "$dest_dir" ;;
    *.tar.xz)          tar -xJf "$archive" -C "$dest_dir" ;;
    *.tar.zst|*.tzst)  ensure_cmd zstd; tar --zstd -xf "$archive" -C "$dest_dir" ;;
    *.tar.lz)          ensure_cmd lzip; tar --lzip -xf "$archive" -C "$dest_dir" ;;
    *.zip)             ensure_cmd unzip; unzip -q "$archive" -d "$dest_dir" ;;
    *.gz)              gunzip -c "$archive" | tar -xf - -C "$dest_dir" ;;
    *.bz2)             bunzip2 -c "$archive" | tar -xf - -C "$dest_dir" ;;
    *.xz)              xz -dc "$archive" | tar -xf - -C "$dest_dir" ;;
    *.7z)              ensure_cmd 7z; 7z x "$archive" -o"$dest_dir" ;;
    *)
      die "Formato de arquivo não suportado: $archive"
      ;;
  esac
}
# -------------------------------------------------------------
# Construção do pacote
# -------------------------------------------------------------
build_pkg() {
  local pkg="$1"
  load_recipe "$pkg"

  local builddir destdir
  builddir="$ADM_BUILD_ROOT/$pkg-$$"
  destdir="$builddir/dest"
  ADM_CURRENT_BUILD_DIR="$builddir"

  mkdir -p "$builddir" "$destdir"

  log_info "Construindo pacote $pkg (versão $PKG_VERSION)"

  # 1) Baixar fontes
  IFS=' ' read -r -a srcs <<< "${PKG_SOURCES:-}"
  if (( ${#srcs[@]} > 0 )); then
    download_sources_parallel "${srcs[@]}"
  else
    log_warn "Recipe $pkg não define PKG_SOURCES; assumindo fonte já disponível."
  fi

  # 2) Extração (assume primeiro arquivo como principal)
  local src_main src_archive
  if (( ${#srcs[@]} > 0 )); then
    src_main="${srcs[0]}"
    src_archive="$ADM_SRC_CACHE/$(basename "${src_main%%\?*}")"
    extract_src "$src_archive" "$builddir"
  fi

  # 3) Encontrar diretório de build (primeiro subdir criado)
  local srcdir
  srcdir="$(find "$builddir" -mindepth 1 -maxdepth 1 -type d ! -name dest | head -n1 || true)"
  [[ -n "$srcdir" ]] || srcdir="$builddir"

  # 4) Executar etapas de build definidas pela recipe
  (
    cd "$srcdir"

    if declare -f pkg_prepare >/dev/null 2>&1; then
      log_info "Etapa: prepare()"
      pkg_prepare
    fi

    if declare -f pkg_build >/dev/null 2>&1; then
      log_info "Etapa: build()"

      # Se ADM_JOBS estiver definido (ex: 8), usa make -j8 via MAKEFLAGS
      if [[ -n "${ADM_JOBS:-}" ]]; then
        export MAKEFLAGS="-j${ADM_JOBS}"
        log_info "Usando MAKEFLAGS=$MAKEFLAGS"
      fi

      PKG_DESTDIR="$destdir" PKG_PREFIX="$ADM_PREFIX" pkg_build
    else
      die "Recipe $pkg não define função pkg_build()"
    fi

    if declare -f pkg_check >/dev/null 2>&1; then
      log_info "Etapa: check()"
      pkg_check
    fi

    if declare -f pkg_install >/dev/null 2>&1; then
      log_info "Etapa: install() para DESTDIR=$destdir"
      PKG_DESTDIR="$destdir" PKG_PREFIX="$ADM_PREFIX" pkg_install
    else
      # fallback genérico: tentar "make install"
      if [[ -f Makefile || -f makefile ]]; then
        log_warn "pkg_install() não definido; tentando 'make DESTDIR=$destdir install'"
        make DESTDIR="$destdir" install
      else
        die "Sem pkg_install() e sem Makefile para instalar $pkg"
      fi
    fi
  )

  # 5) Criar pacote binário e manifest
  package_from_destdir "$pkg" "$PKG_VERSION" "${PKG_RELEASE:-1}" "$destdir"

  # 6) Instalar imediatamente (exceto se DRY-RUN)
  if dry_run_enabled; then
    log_info "DRY-RUN: pacote $pkg-$PKG_VERSION-${PKG_RELEASE:-1} foi construído, mas NÃO será instalado."
  else
    install_from_cache "$pkg" "$PKG_VERSION" "${PKG_RELEASE:-1}"
  fi

  cleanup_build
  ADM_CURRENT_BUILD_DIR=""
}

# -------------------------------------------------------------
# Empacotamento e cache binário
# -------------------------------------------------------------
bin_pkg_filename() {
  local pkg="$1" version="$2" release="$3" ext="$4"
  local arch
  arch="$(uname -m)"
  printf '%s-%s-%s-%s.tar.%s' "$pkg" "$version" "$release" "$arch" "$ext"
}

package_from_destdir() {
  local pkg="$1" version="$2" release="$3" destdir="$4"
  [[ -d "$destdir" ]] || die "DESTDIR não existe: $destdir"

  mkdir -p "$ADM_BIN_CACHE"

  ensure_cmd zstd
  ensure_cmd xz

  local fname_zst fname_xz
  fname_zst="$(bin_pkg_filename "$pkg" "$version" "$release" "zst")"
  fname_xz="$(bin_pkg_filename "$pkg" "$version" "$release" "xz")"

  ( cd "$destdir" && tar -cf - . ) | zstd -19 -T0 -o "$ADM_BIN_CACHE/$fname_zst"
  ( cd "$destdir" && tar -cf - . ) | xz -T0 -9 -c > "$ADM_BIN_CACHE/$fname_xz"

  log_info "Pacotes criados:"
  log_info "  $ADM_BIN_CACHE/$fname_zst"
  log_info "  $ADM_BIN_CACHE/$fname_xz"

  # Gera manifesto com SHA256 (se sha256sum estiver disponível)
  local manifest
  manifest="$(manifest_file_for "$pkg")"

  if command -v sha256sum >/dev/null 2>&1; then
    log_info "Gerando manifesto com SHA256 em $manifest"
    (
      cd "$destdir" || exit 1
      # Apenas arquivos regulares e links simbólicos; diretórios serão tratados via dirname
      find . -mindepth 1 \( -type f -o -type l \) -print0 \
        | sort -z \
        | xargs -0 -r sha256sum \
        | sed 's#  \./#  /#' >"$manifest"
    )
  else
    log_warn "sha256sum não encontrado; gerando manifesto sem hashes."
    ( cd "$destdir" && find . -mindepth 1 -printf '/%P\n' | sort ) >"$manifest"
  fi
}

# -------------------------------------------------------------
# Instalação a partir do cache binário
# -------------------------------------------------------------
install_from_cache() {
  local pkg="$1" version="$2" release="$3"
  local arch
  arch="$(uname -m)"

  local fname_zst fname_xz
  fname_zst="$ADM_BIN_CACHE/$(bin_pkg_filename "$pkg" "$version" "$release" "zst")"
  fname_xz="$ADM_BIN_CACHE/$(bin_pkg_filename "$pkg" "$version" "$release" "xz")"

  local chosen=""
  case "$ADM_DEFAULT_COMPRESS" in
    zst) [[ -f "$fname_zst" ]] && chosen="$fname_zst" || chosen="$fname_xz" ;;
    xz)  [[ -f "$fname_xz" ]] && chosen="$fname_xz" || chosen="$fname_zst" ;;
    *)   chosen="$fname_zst" ;;
  esac

  [[ -f "$chosen" ]] || die "Pacote binário não encontrado para $pkg versão $version-$release"

  if dry_run_enabled; then
    log_info "DRY-RUN: instalaria $pkg-$version-$release a partir de $chosen"
    return 0
  fi

  log_info "Instalando $pkg-$version-$release a partir de $chosen"

  case "$chosen" in
    *.tar.zst|*.tzst) tar --zstd -xf "$chosen" -C / ;;
    *.tar.xz)         tar -xJf "$chosen" -C / ;;
    *)                die "Formato de pacote binário desconhecido: $chosen" ;;
  esac

  write_meta "$pkg" "$version" "$release" "${PKG_DEPENDS:-}"
}

reverse_deps() {
  local target="$1"
  local meta name depends dep

  # Lista pacotes que dependem de $target, lendo todos os .meta
  for meta in "$ADM_META_DIR"/*.meta; do
    [[ -e "$meta" ]] || continue

    name=""
    depends=""

    while IFS='=' read -r key value; do
      case "$key" in
        name)    name="$value" ;;
        depends) depends="$value" ;;
      esac
    done < "$meta"

    # pula o próprio pacote
    [[ "$name" == "$target" ]] && continue

    # vê se $target está na lista de depends
    for dep in $depends; do
      if [[ "$dep" == "$target" ]]; then
        echo "$name"
        break
      fi
    done
  done
}

# -------------------------------------------------------------
# Remoção via manifesto
# -------------------------------------------------------------
remove_pkg() {
  local pkg="$1"
  local manifest
  manifest="$(manifest_file_for "$pkg")"

  [[ -f "$manifest" ]] || die "Manifesto não encontrado para $pkg"

  # Segurança: não remover se outros pacotes dependem dele (a menos que ADM_REMOVE_FORCE=1)
  if [[ "${ADM_REMOVE_FORCE:-0}" != "1" ]]; then
    local users
    users="$(reverse_deps "$pkg" || true)"
    if [[ -n "$users" ]]; then
      log_error "Não é seguro remover $pkg; outros pacotes dependem dele:"
      printf '  - %s\n' $users >&2
      die "Use ADM_REMOVE_FORCE=1 adm remove $pkg para forçar, se tiver certeza."
    fi
  fi

  if dry_run_enabled; then
    log_info "DRY-RUN: removeria pacote $pkg"
    log_info "DRY-RUN: arquivos que seriam removidos (manifesto: $manifest):"
    sed 's/^/  - /' "$manifest"
    return 0
  fi

  log_info "Removendo arquivos de $pkg usando manifesto $manifest"

  # Remove arquivos
  local line path
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue

    # Manifesto pode ter formato:
    #   /caminho
    #   SHA256  /caminho
    if [[ "$line" == /* ]]; then
      # Manifesto sem hash
      path="$line"
    elif [[ "$line" =~ ^[0-9a-fA-F]{64}[[:space:]][[:space:]]/ ]]; then
      # Manifesto com hash (sha256sum usa "HASH␣␣/caminho")
      path="${line#*  }"
    else
      # Formato inesperado; melhor tentar a linha inteira
      path="$line"
    fi

    # Sanity extra: nunca remover raiz, diretório atual ou caminho vazio
    if [[ -z "$path" || "$path" == "/" || "$path" == "." ]]; then
      log_warn "Entrada de manifesto suspeita para $pkg: '$line' (ignorando)"
      continue
    fi

    if [[ -e "$path" || -L "$path" ]]; then
      rm -f -- "$path"
    fi
  done <"$manifest"

  # Tenta remover diretórios vazios residuais
  log_info "Removendo diretórios vazios residuais"
  tac "$manifest" | while IFS= read -r line; do
    [[ -n "$line" ]] || continue

    if [[ "$line" == /* ]]; then
      path="$line"
    elif [[ "$line" =~ ^[0-9a-fA-F]{64}[[:space:]][[:space:]]/ ]]; then
      path="${line#*  }"
    else
      path="$line"
    fi

    local dir
    dir="$(dirname "$path")"
    [[ "$dir" == "/" || "$dir" == "." ]] && continue
    if [[ -d "$dir" ]]; then
      rmdir "$dir" 2>/dev/null || true
    fi
  done

  rm -f "$manifest"
  rm -f "$(meta_file_for "$pkg")"

  log_info "Pacote $pkg removido."
}

cmd_verify() {
  local pkg="$1"
  local manifest
  manifest="$(manifest_file_for "$pkg")"
  local meta
  meta="$(meta_file_for "$pkg")"

  if [[ ! -f "$manifest" ]]; then
    die "Manifesto não encontrado para $pkg em $manifest"
  fi

  if [[ ! -f "$meta" ]]; then
    log_warn "Meta de instalação não encontrada para $pkg em $meta"
  fi

  log_info "Verificando arquivos do pacote $pkg (manifesto: $manifest)"

  local missing=0 mismatched=0
  local line path hash

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue

    # Linha pode ser:
    #   /caminho
    #   SHA256  /caminho
    hash=""
    if [[ "$line" == /* ]]; then
      # Manifesto sem hash
      path="$line"
    elif [[ "$line" =~ ^([0-9a-fA-F]{64})[[:space:]][[:space:]](/.*)$ ]]; then
      # Manifesto com hash (captura hash e caminho completo, inclusive com espaços)
      hash="${BASH_REMATCH[1]}"
      path="${BASH_REMATCH[2]}"
    else
      # formato inesperado; assume linha inteira como caminho
      path="$line"
    fi

    if [[ ! -e "$path" && ! -L "$path" ]]; then
      log_warn "Arquivo ausente: $path"
      missing=1
      continue
    fi

    if [[ -n "$hash" ]] && command -v sha256sum >/dev/null 2>&1; then
      local calc
      calc="$(sha256sum "$path" | awk '{print $1}')"
      if [[ "$calc" != "$hash" ]]; then
        log_warn "SHA256 divergente para $path (esperado=$hash, calculado=$calc)"
        mismatched=1
      else
        log_debug "OK (hash): $path"
      fi
    else
      log_debug "OK (existência): $path"
    fi
  done <"$manifest"

  if (( missing == 0 && mismatched == 0 )); then
    log_info "Verificação concluída: todos os arquivos de $pkg existem e (quando disponível) SHA256 confere."
    return 0
  else
    log_warn "Verificação concluída: problemas detectados em $pkg (missing=$missing, mismatched=$mismatched)"
    return 1
  fi
}

cmd_verify_all() {
  log_info "Verificando todos os pacotes instalados..."

  local -a pkgs=()
  mapfile -t pkgs < <(list_installed)

  if (( ${#pkgs[@]} == 0 )); then
    log_info "Nenhum pacote instalado para verificar."
    return 0
  fi

  local pkg failed=0
  for pkg in "${pkgs[@]}"; do
    [[ -n "$pkg" ]] || continue
    log_info "=== $pkg ==="
    if ! cmd_verify "$pkg"; then
      failed=1
    fi
  done

  if (( failed == 0 )); then
    log_info "Verificação geral concluída: todos os pacotes passaram."
  else
    log_warn "Verificação geral concluída: existem pacotes com problemas."
  fi

  return $failed
}

# -------------------------------------------------------------
# Resolução de dependências e ordenação (Kahn-like)
# -------------------------------------------------------------
pkg_deps() {
  local pkg="$1"
  load_recipe "$pkg"
  printf '%s\n' "${PKG_DEPENDS:-}" | tr ' ' '\n' | sed '/^$/d' | sort -u
}

# Listar pacotes que pertencem a um grupo/categoria (usa PKG_GROUPS em cada recipe)
pkgs_in_group() {
  local group="$1"
  local f

  local needle=" $group "

  # Procura todas as recipes .sh em qualquer subdiretório
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue

    (
      unset PKG_NAME PKG_GROUPS
      # shellcheck source=/dev/null
      . "$f"
      local name="${PKG_NAME:-}"
      local groups=" ${PKG_GROUPS:-} "
      if [[ -n "$name" && "$groups" == *"$needle"* ]]; then
        printf '%s\n' "$name"
      fi
    )
  done < <(find "$ADM_RECIPES_DIR" -type f -name '*.sh' 2>/dev/null | sort) | sort -u
}

# Gera ordem topológica de uma lista de pacotes
topo_sort_pkgs() {
  local -a input_pkgs=("$@")
  local -a all_pkgs=()
  local -A want
  local p

  # normalizar e único
  for p in "${input_pkgs[@]}"; do
    want["$p"]=1
  done

  # inclui dependências recursivamente
  local changed=1
  while (( changed )); do
    changed=0
    for p in "${!want[@]}"; do
      local d
      while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        if [[ -z "${want[$d]:-}" ]]; then
          want["$d"]=1
          changed=1
        fi
      done < <(pkg_deps "$p")
    done
  done

  for p in "${!want[@]}"; do
    all_pkgs+=("$p")
  done

  local -a sorted=()
  local -A done
  local progress

  while (( ${#sorted[@]} < ${#all_pkgs[@]} )); do
    progress=0
    for p in "${all_pkgs[@]}"; do
      [[ -n "$p" ]] || continue
      if [[ -n "${done[$p]:-}" ]]; then
        continue
      fi
      local ok=1
      local d
      while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        if [[ -n "${want[$d]:-}" && -z "${done[$d]:-}" ]]; then
          ok=0
          break
        fi
      done < <(pkg_deps "$p")
      if (( ok )); then
        sorted+=("$p")
        done["$p"]=1
        progress=1
      fi
    done

    if (( ! progress )); then
      log_error "Detecção de ciclo de dependências entre pacotes:"
      log_error "Conjunto envolvido:"
      for p in "${all_pkgs[@]}"; do
        [[ -z "${done[$p]:-}" ]] && printf '  %s\n' "$p" >&2
      done
      die "Não foi possível resolver dependências (ciclo detectado)."
    fi
  done

  printf '%s\n' "${sorted[@]}"
}

# -------------------------------------------------------------
# Função genérica para descobrir versão upstream a partir de PKG_SOURCES
# -------------------------------------------------------------
adm_generic_upstream_version() {
  if [[ -z "${PKG_VERSION:-}" || -z "${PKG_SOURCES:-}" ]]; then
    die "adm_generic_upstream_version() requer PKG_VERSION e PKG_SOURCES definidos."
  fi

  local first_url filename base_url prefix suffix ver_pattern
  first_url="${PKG_SOURCES%% *}"
  filename="$(basename "${first_url%%\?*}")"

  if [[ "$filename" == *"$PKG_VERSION"* ]]; then
    prefix="${filename%%$PKG_VERSION*}"
    suffix="${filename#*$PKG_VERSION}"
  else
    prefix="${filename%%-[0-9]*}"
    suffix="${filename#$prefix}"
    suffix="${suffix#*-}"
    suffix="${suffix#*$PKG_VERSION}"
  fi

  if [[ -z "$prefix" || -z "$suffix" ]]; then
    log_warn "Não foi possível inferir prefix/suffix de '$filename'; usando padrão simples."
    prefix="${filename%%-[0-9]*}-"
    suffix=".tar.gz"
  fi

  base_url="${first_url%/*}/"

  log_info "Verificando versões upstream em: $base_url (prefix='$prefix', suffix='$suffix')"

  local index
  if command -v curl >/dev/null 2>&1; then
    index="$(curl -fsSL "$base_url" || true)"
  elif command -v wget >/dev/null 2>&1; then
    index="$(wget -qO- "$base_url" || true)"
  else
    die "Nem curl nem wget disponíveis para adm_generic_upstream_version()."
  fi

  if [[ -z "$index" ]]; then
    die "Não foi possível baixar índice de $base_url"
  fi

  local candidates
  candidates=$(grep -Eo "${prefix}[0-9][0-9A-Za-z\.\-_]*${suffix}" <<<"$index" | sort -u) || true

  if [[ -z "$candidates" ]]; then
    die "Nenhum candidato encontrado em $base_url para padrão ${prefix}*${suffix}"
  fi

  local v name versions=()
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    v="${name#$prefix}"
    v="${v%$suffix}"
    versions+=("$v")
  done <<<"$candidates"

  if (( ${#versions[@]} == 0 )); then
    die "Nenhuma versão extraída a partir dos candidatos em $base_url"
  fi

  printf '%s\n' "${versions[@]}" | sort -V | tail -n1
}

# -------------------------------------------------------------
# Funções de upgrade (baseadas em pkg_upstream_version() das recipes)
# -------------------------------------------------------------
pkg_upstream_version_or_generic() {
  if declare -f pkg_upstream_version >/dev/null 2>&1; then
    pkg_upstream_version
  else
    adm_generic_upstream_version
  fi
}

cmd_upgrade_check_pkg() {
  local pkg="$1"

  if ! load_recipe_soft "$pkg"; then
    die "Não foi possível carregar recipe de $pkg para upgrade-check."
  fi

  if ! is_installed "$pkg"; then
    log_info "$pkg não está instalado; nada para comparar."
    return 0
  fi

  local cur ver_up
  cur="$(get_installed_version "$pkg")" || {
    die "Não foi possível obter versão instalada de $pkg"
  }

  ver_up="$(pkg_upstream_version_or_generic)" || {
    die "Falha ao descobrir versão upstream de $pkg"
  }

  if ver_gt "$ver_up" "$cur"; then
    printf '%s %s -> %s\n' "$pkg" "$cur" "$ver_up"
    return 0
  else
    log_info "$pkg está atualizado ($cur). Upstream: $ver_up"
    return 0
  fi
}

cmd_upgrade_check_all() {
  log_info "Verificando pacotes com novas versões upstream..."
  local pkgs
  pkgs="$(list_installed)"

  if [[ -z "$pkgs" ]]; then
    log_info "Nenhum pacote instalado."
    return 0
  fi

  local pkg
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    cmd_upgrade_check_pkg "$pkg" || true
  done <<<"$pkgs"
}

cmd_upgrade_pkg() {
  local pkg="$1"

  if [[ -z "$pkg" ]]; then
    die "Use: adm upgrade <pkg>"
  fi

  if ! is_installed "$pkg"; then
    log_info "$pkg não está instalado; chamando install em vez de upgrade."
    cmd_install "$pkg"
    return
  fi

  if ! load_recipe_soft "$pkg"; then
    die "Não foi possível carregar recipe de $pkg para upgrade."
  fi

  local cur ver_up
  cur="$(get_installed_version "$pkg")" || {
    die "Não foi possível obter versão instalada de $pkg"
  }

  ver_up="$(pkg_upstream_version_or_generic)" || {
    die "Falha ao descobrir versão upstream de $pkg"
  }

  if ! ver_gt "$ver_up" "$cur"; then
    log_info "$pkg já está atualizado ($cur). Upstream: $ver_up"
    return 0
  fi

  if [[ -z "${PKG_VERSION:-}" ]]; then
    die "Recipe carregada para $pkg não define PKG_VERSION; não é possível prosseguir com upgrade automático."
  fi

  if [[ "$PKG_VERSION" != "$ver_up" ]]; then
    log_warn "Há uma nova versão upstream ($ver_up) para $pkg, mas a recipe em '$ADM_LAST_RECIPE_PATH' ainda declara PKG_VERSION=$PKG_VERSION."
    log_warn "Atualize a recipe para refletir a nova versão antes de rodar 'adm upgrade $pkg'."
    return 1
  fi

  log_info "Atualizando $pkg de $cur para $ver_up"
  build_pkg "$pkg"
}

cmd_upgrade_all() {
  log_info "Atualizando todos os pacotes com novas versões upstream (quando recipe estiver em dia)..."

  local pkgs
  pkgs="$(list_installed)"

  if [[ -z "$pkgs" ]]; then
    log_info "Nenhum pacote instalado."
    return 0
  fi

  local pkg
  local failed=0

  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    if ! cmd_upgrade_pkg "$pkg"; then
      failed=1
    fi
  done <<<"$pkgs"

  if (( failed == 0 )); then
    log_info "Upgrade concluído: todos os pacotes estão atualizados."
  else
    log_warn "Upgrade concluído com erros em alguns pacotes; verifique os logs acima."
  fi

  return $failed
}

# -------------------------------------------------------------
# CLI de alto nível
# -------------------------------------------------------------
usage() {
  cat <<EOF
adm $ADM_VERSION - Package manager para sistemas estilo LFS

Uso:
  adm list
  adm files <pkg>
  adm info <pkg>
  adm deps <pkg>
  adm group <grupo>
  adm install <pkg>...
  adm install-order <pkg>...
  adm remove <pkg>
  adm verify <pkg>
  adm verify-all
  adm upgrade-check <pkg>
  adm upgrade-check-all
  adm upgrade <pkg>
  adm upgrade-all

Variáveis de ambiente:
  ADM_PREFIX=/usr           Prefix de instalação padrão das recipes
  ADM_STATE_DIR=/var/lib/adm
  ADM_DRY_RUN=1             Mostra o que faria sem alterar o sistema
  ADM_DL_JOBS=4             Paralelismo nos downloads
  ADM_DEFAULT_COMPRESS=zst  zst ou xz

Exemplos:
  adm list
  adm install zlib
  ADM_DRY_RUN=1 adm remove zlib
  adm install-order bash coreutils grep
  adm upgrade-check bash
  adm upgrade bash
EOF
}

cmd_list() {
  list_installed
}

cmd_files() {
  local pkg="$1"
  local manifest
  manifest="$(manifest_file_for "$pkg")"
  [[ -f "$manifest" ]] || die "Manifesto não encontrado para $pkg"
  cat "$manifest"
}

cmd_info() {
  local pkg="$1"
  local meta recipe
  meta="$(meta_file_for "$pkg")"
  recipe="$(find_recipe_file "$pkg" || true)"

  echo "Pacote: $pkg"
  if [[ -f "$meta" ]]; then
    echo "== Meta =="
    cat "$meta"
  else
    echo "Meta: (não instalado)"
  fi

  if [[ -n "$recipe" ]]; then
    echo
    echo "Recipe: $recipe"
    unset PKG_NAME PKG_DESC PKG_VERSION PKG_RELEASE PKG_DEPENDS PKG_GROUPS
    # shellcheck source=/dev/null
    . "$recipe"
    echo "== Recipe =="
    echo "  PKG_NAME    = ${PKG_NAME:-}"
    echo "  PKG_VERSION = ${PKG_VERSION:-}"
    echo "  PKG_RELEASE = ${PKG_RELEASE:-}"
    echo "  PKG_DESC    = ${PKG_DESC:-}"
    echo "  PKG_DEPENDS = ${PKG_DEPENDS:-}"
    echo "  PKG_GROUPS  = ${PKG_GROUPS:-}"
  else
    echo "Recipe: não encontrado em $ADM_RECIPES_DIR"
  fi
}

cmd_deps() {
  local pkg="$1"
  pkg_deps "$pkg"
}

cmd_group() {
  local group="$1"
  pkgs_in_group "$group"
}

cmd_install() {
  local pkgs=("$@")
  if (( ${#pkgs[@]} == 0 )); then
    die "Use: adm install <pkg>..."
  fi

  local -a ordered
  mapfile -t ordered < <(topo_sort_pkgs "${pkgs[@]}")

  log_info "Ordem de instalação (com dependências):"
  printf '  %s\n' "${ordered[@]}"

  local p
  for p in "${ordered[@]}"; do
    if is_installed "$p"; then
      log_info "Pulando $p (já instalado)."
      continue
    fi
    log_info "Instalando pacote: $p"
    build_pkg "$p"
  done
}

cmd_install_order() {
  local pkgs=("$@")
  if (( ${#pkgs[@]} == 0 )); then
    die "Use: adm install-order <pkg>..."
  fi
  topo_sort_pkgs "${pkgs[@]}"
}

cmd_remove_wrap() {
  local pkg="$1"
  remove_pkg "$pkg"
}

# -------------------------------------------------------------
# Main
# -------------------------------------------------------------
main() {
  local cmd="${1:-}"

  if [[ -z "$cmd" ]]; then
    usage
    exit 1
  fi

  init_dirs
  check_runtime_deps

  case "$cmd" in
    list)
      cmd_list
      ;;
    files)
      [[ $# -ge 2 ]] || die "Use: adm files <pkg>"
      cmd_files "$2"
      ;;
    info)
      [[ $# -ge 2 ]] || die "Use: adm info <pkg>"
      cmd_info "$2"
      ;;
    deps)
      [[ $# -ge 2 ]] || die "Use: adm deps <pkg>"
      cmd_deps "$2"
      ;;
    group)
      [[ $# -ge 2 ]] || die "Use: adm group <grupo>"
      cmd_group "$2"
      ;;
    install)
      shift
      cmd_install "$@"
      ;;
    install-order)
      shift
      cmd_install_order "$@"
      ;;
    remove)
      [[ $# -ge 2 ]] || die "Use: adm remove <pkg>"
      cmd_remove_wrap "$2"
      ;;
    verify)
      [[ $# -ge 2 ]] || die "Use: adm verify <pkg>"
      cmd_verify "$2"
      ;;
    verify-all)
      cmd_verify_all
      ;;
    upgrade-check)
      [[ $# -ge 2 ]] || die "Use: adm upgrade-check <pkg>"
      cmd_upgrade_check_pkg "$2"
      ;;
    upgrade-check-all)
      cmd_upgrade_check_all
      ;;
    upgrade)
      [[ $# -ge 2 ]] || die "Use: adm upgrade <pkg>"
      cmd_upgrade_pkg "$2"
      ;;
    upgrade-all)
      cmd_upgrade_all
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      log_error "Comando desconhecido: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
