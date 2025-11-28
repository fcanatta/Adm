#!/usr/bin/env bash
# adm-lib.sh - núcleo do gerenciador de pacotes "adm"

set -euo pipefail
set -E  # garante que trap ERR funcione também em funções

#######################################
# CONFIGURAÇÃO
#######################################

# Raiz do chroot (LFS). Se não existir, cai para "/".
ADM_CHROOT_DIR="${ADM_CHROOT_DIR:-/mnt/lfs}"
if [[ -d "$ADM_CHROOT_DIR" ]]; then
  ADM_ROOT="$ADM_CHROOT_DIR"
else
  ADM_ROOT="/"
fi

ADM_STATE_DIR="${ADM_STATE_DIR:-/var/lib/adm}"
ADM_CACHE_DIR="${ADM_CACHE_DIR:-/var/cache/adm}"
ADM_SRC_CACHE="${ADM_SRC_CACHE:-$ADM_CACHE_DIR/src}"
ADM_BIN_CACHE="${ADM_BIN_CACHE:-$ADM_CACHE_DIR/pkg}"
ADM_BUILD_ROOT="${ADM_BUILD_ROOT:-/var/tmp/adm/build}"
ADM_LOG_DIR="${ADM_LOG_DIR:-/var/log/adm}"
ADM_DB_DIR="${ADM_DB_DIR:-$ADM_STATE_DIR/db}"
ADM_MANIFEST_DIR="${ADM_MANIFEST_DIR:-$ADM_STATE_DIR/manifest}"
ADM_META_DIR="${ADM_META_DIR:-$ADM_STATE_DIR/meta}"
ADM_RECIPES_DIR="${ADM_RECIPES_DIR:-/usr/share/adm/recipes}"

ADM_DEFAULT_COMPRESS="${ADM_DEFAULT_COMPRESS:-zstd}"   # zstd|xz
ADM_DL_JOBS="${ADM_DL_JOBS:-4}"

ADM_DRY_RUN="${ADM_DRY_RUN:-0}"
ADM_FORCE_REINSTALL="${ADM_FORCE_REINSTALL:-0}"  # usado em reinstall / rebuild-system

ADM_CURRENT_BUILD_DIR=""

#######################################
# LOG / ERROS
#######################################

_color() {
  local code="$1"; shift
  printf "\033[%sm%s\033[0m" "$code" "$*"
}

log_ts() { date +"%Y-%m-%d %H:%M:%S"; }

log_info()  { echo "[$(log_ts)] $(_color '32;1' INFO)  $*"; }
log_warn()  { echo "[$(log_ts)] $(_color '33;1' WARN)  $*" >&2; }
log_error() { echo "[$(log_ts)] $(_color '31;1' ERROR) $*" >&2; }
log_debug() {
  if [[ "${ADM_DEBUG:-0}" -eq 1 ]]; then
    echo "[$(log_ts)] $(_color '36;1' DEBUG) $*" >&2
  fi
}

die() {
  log_error "$*"
  exit 1
}

on_err() {
  local status="$?"
  log_error "Erro inesperado (exit=$status). Veja logs em: $ADM_LOG_DIR"
  exit "$status"
}
trap on_err ERR

cleanup_build() {
  local d="$ADM_CURRENT_BUILD_DIR"
  if [[ -n "${d:-}" && -d "$d" ]]; then
    log_debug "Removendo diretório de build temporário: $d"
    rm -rf -- "$d"
  fi
}
trap cleanup_build EXIT

#######################################
# UTILITÁRIOS / PATH ROOT DO CHROOT
#######################################

# Converte um caminho absoluto /foo/bar para o caminho físico dentro do ADM_ROOT
root_path() {
  local p="$1"
  [[ "$p" == /* ]] || die "root_path requer caminho absoluto: $p"
  if [[ "$ADM_ROOT" == "/" ]]; then
    printf "%s\n" "$p"
  else
    printf "%s%s\n" "$ADM_ROOT" "$p"
  fi
}

ensure_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Requer comando: $cmd"
}

init_dirs() {
  local d
  for d in \
    "$ADM_STATE_DIR" "$ADM_CACHE_DIR" "$ADM_SRC_CACHE" "$ADM_BIN_CACHE" \
    "$ADM_BUILD_ROOT" "$ADM_LOG_DIR" "$ADM_DB_DIR" \
    "$ADM_MANIFEST_DIR" "$ADM_META_DIR" "$ADM_RECIPES_DIR"
  do
    mkdir -p -m 0755 "$d"
  done
}

check_runtime_deps() {
  local required_cmds=(
    bash find sort tac sha256sum tar
  )
  local optional_cmds=(
    md5sum
    make
    curl
    wget
    unzip
    bzip2
    gunzip
    7z
    git
    rsync
    zstd
    xz
    lzip
  )

  local c
  for c in "${required_cmds[@]}"; do
    command -v "$c" >/dev/null 2>&1 || die "Comando obrigatório não encontrado: $c"
  done

  for c in "${optional_cmds[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      log_warn "Comando opcional ausente: $c"
    fi
  done
}

#######################################
# RECIPE LOADING
#######################################

unset_recipe_symbols() {
  unset PKG_NAME PKG_VERSION PKG_RELEASE PKG_DESC PKG_URL
  unset PKG_LICENSE PKG_DEPENDS PKG_GROUPS PKG_SOURCES
  unset PKG_SHA256S PKG_MD5S PKG_BUILD_DIR PKG_PREFIX
  unset PKG_HOST PKG_BUILD PKG_TARGET
  unset -f pkg_prepare pkg_build pkg_check pkg_install pkg_upstream_version || true
}

find_recipe_file() {
  local name="$1"
  find "$ADM_RECIPES_DIR" -maxdepth 5 -type f -name "${name}.sh" | head -n1
}

load_recipe() {
  local pkg="$1"
  unset_recipe_symbols
  local f
  f="$(find_recipe_file "$pkg")" || true
  [[ -n "$f" ]] || die "Recipe para pacote '$pkg' não encontrada em $ADM_RECIPES_DIR"
  # shellcheck source=/dev/null
  source "$f"
  [[ -n "${PKG_NAME:-}" && -n "${PKG_VERSION:-}" ]] || die "Recipe $f inválida (PKG_NAME/PKG_VERSION ausentes)"
  PKG_RELEASE="${PKG_RELEASE:-1}"
  PKG_PREFIX="${PKG_PREFIX:-/usr}"
}

load_recipe_soft() {
  local pkg="$1"
  unset_recipe_symbols
  local f
  f="$(find_recipe_file "$pkg")" || true
  [[ -n "$f" ]] || return 1
  # shellcheck source=/dev/null
  if ! source "$f"; then
    log_warn "Falha ao carregar recipe para '$pkg': $f"
    return 1
  fi
  [[ -n "${PKG_NAME:-}" && -n "${PKG_VERSION:-}" ]] || return 1
  PKG_RELEASE="${PKG_RELEASE:-1}"
  PKG_PREFIX="${PKG_PREFIX:-/usr}"
  return 0
}

#######################################
# DB / META / MANIFEST
#######################################

meta_file_for() { printf "%s/%s.meta\n" "$ADM_META_DIR" "$1"; }
manifest_file_for() { printf "%s/%s.manifest\n" "$ADM_MANIFEST_DIR" "$1"; }

is_installed() {
  local pkg="$1"
  [[ -f "$(meta_file_for "$pkg")" ]]
}

get_installed_version() {
  local pkg="$1"
  local mf
  mf="$(meta_file_for "$pkg")"
  [[ -f "$mf" ]] || return 1
  awk -F= '$1=="version"{print $2}' "$mf"
}

write_meta() {
  local pkg="$1" ver="$2" rel="$3" deps="$4"
  local mf
  mf="$(meta_file_for "$pkg")"
  {
    echo "name=$pkg"
    echo "version=$ver"
    echo "release=$rel"
    echo "depends=$deps"
    echo "installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "root=$ADM_ROOT"
  } >"$mf"
}

list_installed() {
  local f
  for f in "$ADM_META_DIR"/*.meta; do
    [[ -e "$f" ]] || continue
    basename "$f" .meta
  done | sort
}

reverse_deps() {
  local target="$1"
  local f deps pkg
  for f in "$ADM_META_DIR"/*.meta; do
    [[ -e "$f" ]] || continue
    pkg="$(basename "$f" .meta)"
    deps="$(awk -F= '$1=="depends"{print $2}' "$f")"
    for d in $deps; do
      if [[ "$d" == "$target" ]]; then
        echo "$pkg"
        break
      fi
    done
  done
}

#######################################
# DOWNLOAD
#######################################

download_one() {
  local url="$1" dest="$2" sha="$3" md5="$4"
  local tmp="${dest}.part"
  local tries=0 max_tries=2

  while (( tries < max_tries )); do
    ((tries++))
    log_info "Baixando $url (tentativa $tries/$max_tries)"

    rm -f -- "$tmp"
    if [[ "$url" == git+* || "$url" == *.git ]]; then
      ensure_cmd git
      rm -rf -- "$tmp"
      git clone --depth 1 "$url" "$tmp"
      tar -C "$tmp" -cf "$tmp.tar" .
      mv "$tmp.tar" "$tmp"
      rm -rf -- "$tmp.gitdir" || true
    elif [[ "$url" == http://* || "$url" == https://* || "$url" == ftp://* ]]; then
      if command -v curl >/dev/null 2>&1; then
        curl -L --fail -o "$tmp" "$url"
      elif command -v wget >/dev/null 2>&1; then
        wget -O "$tmp" "$url"
      else
        die "Nenhum downloader disponível (curl ou wget)"
      fi
    elif [[ "$url" == rsync://* ]]; then
      ensure_cmd rsync
      rsync -av "$url" "$tmp"
    else
      die "URL de fonte não suportada: $url"
    fi

    if [[ -n "$sha" ]]; then
      if ! echo "$sha  $tmp" | sha256sum -c -; then
        log_warn "SHA256 incorreta para $url"
        rm -f -- "$tmp"
        continue
      fi
    fi

    if [[ -n "$md5" && "$(command -v md5sum || true)" != "" ]]; then
      if ! echo "$md5  $tmp" | md5sum -c -; then
        log_warn "MD5 incorreta para $url"
        rm -f -- "$tmp"
        continue
      fi
    fi

    mv "$tmp" "$dest"
    return 0
  done

  die "Falha ao baixar $url após $max_tries tentativas"
}

download_sources_parallel() {
  local -n _urls="$1"
  local -n _sha="$2"
  local -n _md5="$3"

  mkdir -p "$ADM_SRC_CACHE"

  local i url dest s m pids=()
  for i in "${!_urls[@]}"; do
    url="${!_urls[$i]}"
    [[ -n "$url" ]] || continue
    s="${_sha[$i]:-}"
    m="${_md5[$i]:-}"
    dest="$ADM_SRC_CACHE/$(basename "$url")"
    if [[ -f "$dest" ]]; then
      log_info "Usando fonte em cache: $dest"
      continue
    fi
    (
      download_one "$url" "$dest" "$s" "$m"
    ) &
    pids+=("$!")
    # Limita jobs simultâneos
    if (( ${#pids[@]} >= ADM_DL_JOBS )); then
      wait -n || die "Download falhou"
      # remove um PID da lista (não precisamos dos específicos)
      pids=("${pids[@]:1}")
    fi
  done

  # espera o resto
  if ((${#pids[@]} > 0)); then
    wait "${pids[@]}" || die "Download falhou"
  fi
}

#######################################
# EXTRAÇÃO
#######################################

extract_src() {
  local archive="$1" dest="$2"
  mkdir -p "$dest"

  case "$archive" in
    *.tar.gz|*.tgz)    tar -C "$dest" -xzf "$archive" ;;
    *.tar.bz2|*.tbz2)  tar -C "$dest" -xjf "$archive" ;;
    *.tar.xz)          tar -C "$dest" -xJf "$archive" ;;
    *.tar.zst)         ensure_cmd zstd; tar -C "$dest" --zstd -xf "$archive" ;;
    *.tar.lz)          ensure_cmd lzip; lzip -dc "$archive" | tar -C "$dest" -xf - ;;
    *.zip)             ensure_cmd unzip; unzip -d "$dest" "$archive" ;;
    *.7z)              ensure_cmd 7z; 7z x "$archive" -o"$dest" ;;
    *.gz)              gunzip -c "$archive" | tar -C "$dest" -xf - ;;
    *.bz2)             bzip2 -dc "$archive" | tar -C "$dest" -xf - ;;
    *.xz)              xz -dc "$archive" | tar -C "$dest" -xf - ;;
    *)                 die "Formato de arquivo não suportado: $archive" ;;
  esac
}

#######################################
# PACKAGING / INSTALL
#######################################

package_from_destdir() {
  local pkg="$1" ver="$2" rel="$3" destdir="$4"
  local arch
  arch="$(uname -m)"

  mkdir -p "$ADM_BIN_CACHE" "$ADM_MANIFEST_DIR"

  local base="${pkg}-${ver}-${rel}-${arch}"
  local tarfile_zst="$ADM_BIN_CACHE/${base}.tar.zst"
  local tarfile_xz="$ADM_BIN_CACHE/${base}.tar.xz"

  pushd "$destdir" >/dev/null

  # Manifesto
  local manifest
  manifest="$(manifest_file_for "$pkg")"
  : >"$manifest"

  find . -mindepth 1 -print0 | sort -z | while IFS= read -r -d '' f; do
    local rp="/${f#./}"
    if [[ -f "$f" || -L "$f" ]]; then
      local hash
      hash="$(sha256sum "$f" | awk '{print $1}')"
      printf "SHA256 %s %s\n" "$hash" "$rp" >>"$manifest"
    elif [[ -d "$f" ]]; then
      printf "%s\n" "$rp" >>"$manifest"
    fi
  done

  # pacotes binários
  case "$ADM_DEFAULT_COMPRESS" in
    zstd)
      ensure_cmd zstd
      tar --zstd -cf "$tarfile_zst" .
      if command -v xz >/dev/null 2>&1; then
        tar -cJf "$tarfile_xz" .
      fi
      ;;
    xz)
      ensure_cmd xz
      tar -cJf "$tarfile_xz" .
      if command -v zstd >/dev/null 2>&1; then
        tar --zstd -cf "$tarfile_zst" .
      fi
      ;;
    *)
      die "ADM_DEFAULT_COMPRESS deve ser 'zstd' ou 'xz'"
      ;;
  esac

  popd >/dev/null

  log_info "Pacotes gerados em: $ADM_BIN_CACHE"
}

install_from_cache() {
  local pkg="$1" ver="$2" rel="$3"
  local arch
  arch="$(uname -m)"

  local base="${pkg}-${ver}-${rel}-${arch}"
  local tarfile

  if [[ "$ADM_DEFAULT_COMPRESS" == "zstd" ]]; then
    tarfile="$ADM_BIN_CACHE/${base}.tar.zst"
    if [[ ! -f "$tarfile" ]]; then
      tarfile="$ADM_BIN_CACHE/${base}.tar.xz"
    fi
  else
    tarfile="$ADM_BIN_CACHE/${base}.tar.xz"
    if [[ ! -f "$tarfile" ]]; then
      tarfile="$ADM_BIN_CACHE/${base}.tar.zst"
    fi
  fi

  [[ -f "$tarfile" ]] || die "Pacote binário não encontrado: $tarfile"

  if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
    log_info "[DRY-RUN] Instalaria pacote $pkg a partir de $tarfile em $ADM_ROOT"
    return 0
  fi

  log_info "Instalando $pkg em $ADM_ROOT a partir de $tarfile"
  case "$tarfile" in
    *.tar.zst) tar --zstd -C "$ADM_ROOT" -xf "$tarfile" ;;
    *.tar.xz)  tar -C "$ADM_ROOT" -xJf "$tarfile" ;;
    *)         die "Formato de pacote inesperado: $tarfile" ;;
  esac

  local deps="${PKG_DEPENDS:-}"
  write_meta "$pkg" "$ver" "$rel" "$deps"
}

#######################################
# BUILD
#######################################

find_build_srcdir() {
  local builddir="$1"
  local candidate
  candidate="$(find "$builddir" -mindepth 1 -maxdepth 1 -type d ! -name dest | sort | head -n1 || true)"
  [[ -n "$candidate" ]] || candidate="$builddir"
  printf "%s\n" "$candidate"
}

build_pkg_internal() {
  local pkg="$1" do_install="$2" # 1 instala, 0 só gera pacote (ou só compila)
  load_recipe "$pkg"

  log_info "Iniciando build de $PKG_NAME-$PKG_VERSION-$PKG_RELEASE"

  local builddir="$ADM_BUILD_ROOT/${pkg}-$$"
  ADM_CURRENT_BUILD_DIR="$builddir"
  mkdir -p "$builddir"
  mkdir -p "$builddir/dest"

  # Arrays de fontes/hashes se existirem
  local -a urls sha md5
  if [[ -n "${PKG_SOURCES:-}" ]]; then
    read -r -a urls <<<"$PKG_SOURCES"
  fi
  if [[ -n "${PKG_SHA256S:-}" ]]; then
    read -r -a sha <<<"$PKG_SHA256S"
  fi
  if [[ -n "${PKG_MD5S:-}" ]]; then
    read -r -a md5 <<<"$PKG_MD5S"
  fi

  if ((${#urls[@]} > 0)); then
    download_sources_parallel urls sha md5
  fi

  local srcdir="$builddir"
  if ((${#urls[@]} > 0)); then
    local first="$ADM_SRC_CACHE/$(basename "${urls[0]}")"
    [[ -f "$first" ]] || die "Fonte principal não encontrada: $first"
    extract_src "$first" "$builddir"
    srcdir="$(find_build_srcdir "$builddir")"
  fi

  log_debug "Diretório de build: $srcdir"

  local destdir="$builddir/dest"
  local prefix="$PKG_PREFIX"

  (
    cd "$srcdir"

    export PKG_DESTDIR="$destdir"
    export PKG_PREFIX="$prefix"
    export PKG_HOST="${PKG_HOST:-}"
    export PKG_BUILD="${PKG_BUILD:-}"
    export PKG_TARGET="${PKG_TARGET:-}"

    if declare -F pkg_prepare >/dev/null 2>&1; then
      log_info "Executando pkg_prepare para $pkg"
      pkg_prepare
    fi

    if ! declare -F pkg_build >/dev/null 2>&1; then
      die "Recipe de $pkg não implementa pkg_build"
    fi
    log_info "Executando pkg_build para $pkg"
    pkg_build

    if declare -F pkg_check >/dev/null 2>&1; then
      log_info "Executando pkg_check para $pkg"
      pkg_check
    fi

    if (( do_install )); then
      if declare -F pkg_install >/dev/null 2>&1; then
        log_info "Executando pkg_install para $pkg"
        pkg_install
      else
        if command -v make >/dev/null 2>&1; then
          log_info "Executando 'make DESTDIR=$destdir install'"
          make DESTDIR="$destdir" install
        else
          die "pkg_install não definido e 'make' não disponível"
        fi
      fi
    fi
  )

  if (( do_install )); then
    package_from_destdir "$PKG_NAME" "$PKG_VERSION" "$PKG_RELEASE" "$destdir"
    install_from_cache "$PKG_NAME" "$PKG_VERSION" "$PKG_RELEASE"
  else
    # modo "build" apenas: gera pacote, mas não instala
    package_from_destdir "$PKG_NAME" "$PKG_VERSION" "$PKG_RELEASE" "$destdir"
    log_info "Build de teste concluído (pacote em cache, não instalado)."
  fi

  ADM_CURRENT_BUILD_DIR=""
  rm -rf -- "$builddir"
}

build_pkg() { build_pkg_internal "$1" 1; }
build_pkg_noinstall() { build_pkg_internal "$1" 0; }

#######################################
# REMOVE
#######################################

remove_pkg() {
  local pkg="$1"

  if ! is_installed "$pkg"; then
    log_warn "Pacote $pkg não está instalado"
    return 0
  fi

  # checa dependentes reversos
  local rdeps
  rdeps="$(reverse_deps "$pkg" | xargs || true)"
  if [[ -n "$rdeps" && "${ADM_REMOVE_FORCE:-0}" -ne 1 ]]; then
    die "Não é possível remover $pkg: outros pacotes dependem dele: $rdeps"
  fi

  local manifest
  manifest="$(manifest_file_for "$pkg")"
  [[ -f "$manifest" ]] || die "Manifesto para $pkg não encontrado: $manifest"

  log_info "Removendo arquivos de $pkg em $ADM_ROOT"

  local line type hash path real
  # Remoção em ordem inversa para diretórios
  tac "$manifest" | while read -r line; do
    [[ -z "$line" ]] && continue
    set +u
    type="${line%% *}"
    set -u
    if [[ "$type" == SHA256 ]]; then
      # linha: SHA256 hash /caminho
      hash="${line#SHA256 }"
      hash="${hash%% *}"
      path="${line##* }"
    else
      # diretório: /caminho
      path="$line"
    fi
    real="$(root_path "$path")"

    if [[ "$type" == SHA256 ]]; then
      if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] Removeria arquivo $real"
      else
        rm -f -- "$real" || true
      fi
    else
      if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
        log_info "[DRY-RUN] Tentaria remover diretório $real (se vazio)"
      else
        rmdir --ignore-fail-on-non-empty "$real" 2>/dev/null || true
      fi
    fi
  done

  if [[ "$ADM_DRY_RUN" -eq 1 ]]; then
    log_info "[DRY-RUN] Não apagará manifest/meta de $pkg"
  else
    rm -f -- "$manifest" "$(meta_file_for "$pkg")"
  fi
}

#######################################
# VERIFY
#######################################

verify_pkg() {
  local pkg="$1"
  if ! is_installed "$pkg"; then
    log_warn "Pacote $pkg não está instalado"
    return 1
  fi
  local manifest
  manifest="$(manifest_file_for "$pkg")"
  [[ -f "$manifest" ]] || die "Manifesto não encontrado: $manifest"

  local has_err=0 line type hash path real
  while read -r line; do
    [[ -z "$line" ]] && continue
    set +u
    type="${line%% *}"
    set -u
    if [[ "$type" == SHA256 ]]; then
      hash="${line#SHA256 }"
      hash="${hash%% *}"
      path="${line##* }"
      real="$(root_path "$path")"
      if [[ ! -e "$real" ]]; then
        log_error "$pkg: arquivo ausente: $path"
        has_err=1
        continue
      fi
      local cur
      cur="$(sha256sum "$real" | awk '{print $1}')"
      if [[ "$cur" != "$hash" ]]; then
        log_error "$pkg: hash incorreta: $path"
        has_err=1
      fi
    else
      path="$line"
      real="$(root_path "$path")"
      if [[ ! -e "$real" ]]; then
        log_warn "$pkg: diretório ausente: $path"
      fi
    fi
  done <"$manifest"

  if ((has_err)); then
    log_error "Verificação de $pkg falhou"
    return 1
  fi

  log_info "Verificação de $pkg OK"
  return 0
}

verify_all() {
  local pkg
  local rc=0
  for pkg in $(list_installed); do
    if ! verify_pkg "$pkg"; then
      rc=1
    fi
  done
  return "$rc"
}

#######################################
# DEPENDÊNCIAS / GRUPOS / TOPOLOGIA
#######################################

pkg_deps() {
  local pkg="$1"
  load_recipe "$pkg"
  for d in ${PKG_DEPENDS:-}; do
    [[ -n "$d" ]] && echo "$d"
  done
}

pkgs_in_group() {
  local group="$1"
  local f pkg
  for f in "$ADM_RECIPES_DIR"/*.sh "$ADM_RECIPES_DIR"/*/*.sh "$ADM_RECIPES_DIR"/*/*/*.sh; do
    [[ -e "$f" ]] || continue
    unset_recipe_symbols
    # shellcheck source=/dev/null
    source "$f" || continue
    pkg="${PKG_NAME:-}"
    [[ -n "$pkg" ]] || pkg="$(basename "$f" .sh)"
    for g in ${PKG_GROUPS:-}; do
      if [[ "$g" == "$group" ]]; then
        echo "$pkg"
        break
      fi
    done
  done | sort -u
}

topo_sort_pkgs() {
  # entrada: lista de pacotes
  local input_pkgs=("$@")

  # fecha dependências
  local queue=("${input_pkgs[@]}")
  local all=()
  local seen=()

  contains() {
    local x="$1"; shift
    local i
    for i in "$@"; do [[ "$i" == "$x" ]] && return 0; done
    return 0  # bug proposital? não, isso está errado, arrumar já
  }

  contains_strict() {
    local x="$1"; shift
    local i
    for i in "$@"; do [[ "$i" == "$x" ]] && return 0; done
    return 1
  }

  local q
  while ((${#queue[@]} > 0)); do
    q="${queue[0]}"
    queue=("${queue[@]:1}")
    if contains_strict "$q" "${seen[@]}"; then
      continue
    fi
    seen+=("$q")
    all+=("$q")
    local d
    while read -r d; do
      [[ -n "$d" ]] || continue
      if ! contains_strict "$d" "${seen[@]}"; then
        queue+=("$d")
      fi
    done < <(pkg_deps "$q")
  done

  # ordenação topológica
  local done=()
  local result=()
  local changed
  while ((${#all[@]} > 0)); do
    changed=0
    local next=()
    local p
    for p in "${all[@]}"; do
      local ok=1 d
      while read -r d; do
        [[ -n "$d" ]] || continue
        # só consideramos dependências que fazem parte do conjunto "all+done"
        if contains_strict "$d" "${all[@]}" && ! contains_strict "$d" "${done[@]}"; then
          ok=0
          break
        fi
      done < <(pkg_deps "$p")
      if ((ok)); then
        result+=("$p")
        done+=("$p")
        changed=1
      else
        next+=("$p")
      fi
    done
    all=("${next[@]}")
    if (( !changed )) && ((${#all[@]} > 0)); then
      die "Ciclo de dependências detectado: ${all[*]}"
    fi
  done

  printf "%s\n" "${result[@]}"
}

#######################################
# UPGRADE CHECK (melhorado)
#######################################

escape_regex() {
  # escapa caracteres especiais de regex básica
  sed -e 's/[.[\*^$()+?{}|]/\\&/g'
}

adm_generic_upstream_version() {
  # Usa o primeiro item de PKG_SOURCES; tenta descobrir versão mais nova a partir de listing de diretório
  local url
  read -r url _ <<<"$PKG_SOURCES"
  [[ -n "$url" ]] || return 1
  [[ "$url" == http://* || "$url" == https://* || "$url" == ftp://* ]] || return 1

  local base
  base="$(basename "$url")"
  # tenta achar prefixo/sufixo em torno de PKG_VERSION
  local ver="$PKG_VERSION"
  local pre="${base%%$ver*}"
  local suf="${base#*${ver}}"

  # escapa para regex
  local pre_re suf_re
  pre_re="$(printf "%s" "$pre" | escape_regex)"
  suf_re="$(printf "%s" "$suf" | escape_regex)"

  local listing
  if command -v curl >/dev/null 2>&1; then
    listing="$(curl -fsSL "${url%/*}/" || true)"
  elif command -v wget >/dev/null 2>&1; then
    listing="$(wget -qO- "${url%/*}/" || true)"
  fi

  [[ -n "$listing" ]] || return 1

  local versions
  versions="$(printf "%s\n" "$listing" | \
    grep -Eo "${pre_re}[0-9A-Za-z._-]+${suf_re}" | \
    sed -e "s/^${pre_re}//" -e "s/${suf_re}$//" | sort -V | uniq)"

  [[ -n "$versions" ]] || return 1
  echo "$versions" | tail -n1
}

pkg_upstream_version_or_generic() {
  if declare -F pkg_upstream_version >/dev/null 2>&1; then
    pkg_upstream_version
  else
    adm_generic_upstream_version || return 1
  fi
}

upgrade_check_pkg() {
  local pkg="$1"
  if ! is_installed "$pkg"; then
    log_warn "$pkg não está instalado"
    return 1
  fi
  load_recipe_soft "$pkg" || { log_warn "Não foi possível carregar recipe de $pkg para upgrade-check"; return 1; }

  local cur upstream
  cur="$(get_installed_version "$pkg" || true)"
  [[ -n "$cur" ]] || return 1

  upstream="$(pkg_upstream_version_or_generic || true)"
  [[ -n "$upstream" ]] || return 1

  if [[ "$upstream" != "$cur" ]]; then
    printf "%s %s -> %s\n" "$pkg" "$cur" "$upstream"
  fi
}

upgrade_check_all() {
  local p
  for p in $(list_installed); do
    upgrade_check_pkg "$p" || true
  done
}

#######################################
# REINSTALL / REBUILD-SYSTEM / BUILD
#######################################

install_pkgs_ordered() {
  # recebe lista de pacotes alvo
  local targets=("$@")
  local pkgs
  mapfile -t pkgs < <(topo_sort_pkgs "${targets[@]}")

  local p
  for p in "${pkgs[@]}"; do
    if is_installed "$p" && [[ "$ADM_FORCE_REINSTALL" -ne 1 ]]; then
      log_info "Pacote $p já instalado, pulando"
      continue
    fi
    build_pkg "$p"
  done
}

build_pkgs_noinstall_ordered() {
  local targets=("$@")
  local pkgs
  mapfile -t pkgs < <(topo_sort_pkgs "${targets[@]}")

  local p
  for p in "${pkgs[@]}"; do
    log_info "Build (teste) de $p"
    build_pkg_noinstall "$p"
  done
}

reinstall_pkg_and_deps() {
  local pkg="$1"
  ADM_FORCE_REINSTALL=1 install_pkgs_ordered "$pkg"
}

rebuild_system() {
  local all
  mapfile -t all < <(list_installed)
  [[ ${#all[@]} -gt 0 ]] || { log_warn "Nenhum pacote instalado para rebuild"; return 0; }
  ADM_FORCE_REINSTALL=1 install_pkgs_ordered "${all[@]}"
}

#######################################
# COMANDOS DE ALTO NÍVEL / CLI
#######################################

usage() {
  cat <<EOF
adm - gerenciador de pacotes simples

Uso:
  adm list
  adm files <pkg>
  adm info <pkg>
  adm deps <pkg>
  adm group <nome-grupo>

  adm install <pkg...>
  adm install-order <pkg...>
  adm build <pkg...>           # só compila e gera pacote, não instala
  adm reinstall <pkg>          # rebuild + reinstall de pkg e deps
  adm rebuild-system           # rebuild de todos os pacotes instalados

  adm remove <pkg>
  adm verify <pkg>
  adm verify-all

  adm upgrade-check <pkg>
  adm upgrade-check-all

Variáveis úteis:
  ADM_CHROOT_DIR   raiz do "sistema" (default: /mnt/lfs se existir)
  ADM_DRY_RUN=1    mostra o que faria sem modificar nada
EOF
}

cmd_list() { list_installed; }

cmd_files() {
  local pkg="$1"
  local mf
  mf="$(manifest_file_for "$pkg")"
  [[ -f "$mf" ]] || die "Manifesto de $pkg não encontrado"
  awk '{print $NF}' "$mf"
}

cmd_info() {
  local pkg="$1"
  local mf
  mf="$(meta_file_for "$pkg")"
  [[ -f "$mf" ]] || die "Meta de $pkg não encontrada"
  cat "$mf"
  echo
  echo "Arquivos:"
  cmd_files "$pkg"
}

cmd_deps() {
  local pkg="$1"
  load_recipe "$pkg"
  for d in ${PKG_DEPENDS:-}; do
    echo "$d"
  done
}

cmd_group() {
  local g="$1"
  pkgs_in_group "$g"
}

cmd_install() {
  local pkgs=("$@")
  install_pkgs_ordered "${pkgs[@]}"
}

cmd_install_order() {
  local pkgs=("$@")
  topo_sort_pkgs "${pkgs[@]}"
}

cmd_build() {
  local pkgs=("$@")
  build_pkgs_noinstall_ordered "${pkgs[@]}"
}

cmd_reinstall() {
  local pkg="$1"
  reinstall_pkg_and_deps "$pkg"
}

cmd_rebuild_system() {
  rebuild_system
}

cmd_remove() {
  local pkg="$1"
  remove_pkg "$pkg"
}

cmd_verify() {
  local pkg="$1"
  verify_pkg "$pkg"
}

cmd_verify_all() {
  verify_all
}

cmd_upgrade_check() {
  local pkg="$1"
  upgrade_check_pkg "$pkg"
}

cmd_upgrade_check_all() {
  upgrade_check_all
}

adm_main() {
  init_dirs
  check_runtime_deps

  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    list)             cmd_list "$@" ;;
    files)            cmd_files "$@" ;;
    info)             cmd_info "$@" ;;
    deps)             cmd_deps "$@" ;;
    group)            cmd_group "$@" ;;
    install)          cmd_install "$@" ;;
    install-order)    cmd_install_order "$@" ;;
    build)            cmd_build "$@" ;;
    reinstall)        cmd_reinstall "$@" ;;
    rebuild-system)   cmd_rebuild_system "$@" ;;
    remove)           cmd_remove "$@" ;;
    verify)           cmd_verify "$@" ;;
    verify-all)       cmd_verify_all "$@" ;;
    upgrade-check)    cmd_upgrade_check "$@" ;;
    upgrade-check-all) cmd_upgrade_check_all "$@" ;;
    ""|-h|--help|help) usage ;;
    *) die "Comando inválido: $cmd" ;;
  esac
}
