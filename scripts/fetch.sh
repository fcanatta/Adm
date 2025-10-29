#!/usr/bin/env bash
# /usr/src/adm/scripts/fetch.sh
# ADM Build System - fetch & prepare sources
# Version: 1.0
# Purpose: download/clone/prepare sources based on build.conf
set -o errexit
set -o nounset
set -o pipefail

# ------------------------
# Defaults & environment
# ------------------------
ADM_BASE="${ADM_BASE:-/usr/src/adm}"
ADM_SCRIPTS="${ADM_SCRIPTS:-${ADM_BASE}/scripts}"
ADM_REPO="${ADM_REPO:-${ADM_BASE}/repo}"
ADM_SOURCES="${ADM_SOURCES:-${ADM_REPO}/sources}"
ADM_TMP="${ADM_TMP:-${ADM_BASE}/tmp/fetch}"
ADM_LOGS="${ADM_LOGS:-${ADM_BASE}/logs}"
ADM_DB="${ADM_DB:-${ADM_BASE}/db}"
FETCH_VERSION="1.0"

# CLI defaults
PKG_DIR=""
CONF_FILE=""
FORCE=0
VERIFY_ONLY=0
NO_CACHE=0
DEBUG=0
AUTO_YES=0
VERBOSE=0

TS="$(date '+%Y%m%d_%H%M%S')"
LOGFILE="${ADM_LOGS}/fetch-${TS}.log"
mkdir -p "${ADM_LOGS}" "${ADM_SOURCES}" "${ADM_TMP}" 2>/dev/null || true
touch "${LOGFILE}" 2>/dev/null || true

# Try to source helpers (non-fatal)
if [[ -r "${ADM_SCRIPTS}/env.sh" ]]; then
  # shellcheck disable=SC1091
  source "${ADM_SCRIPTS}/env.sh" || true
fi
_LOG_PRESENT=no
_UI_PRESENT=no
if [[ -r "${ADM_SCRIPTS}/log.sh" ]]; then
  # shellcheck disable=SC1091
  source "${ADM_SCRIPTS}/log.sh" || true
  _LOG_PRESENT=yes
fi
if [[ -r "${ADM_SCRIPTS}/ui.sh" ]]; then
  # shellcheck disable=SC1091
  source "${ADM_SCRIPTS}/ui.sh" || true
  _UI_PRESENT=yes
fi

# ------------------------
# Logging wrappers
# ------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
_log() {
  local lvl="$1"; shift
  local msg="$*"
  printf "%s [%s] %s\n" "$(_ts)" "$lvl" "$msg" >>"${LOGFILE}"
  if [[ "${_LOG_PRESENT}" == "yes" && "$(type -t log_${lvl} 2>/dev/null)" == "function" ]]; then
    # call corresponding log function if exists
    log_"${lvl}" "$msg" || true
  else
    if [[ "${VERBOSE:-0}" -eq 1 ]]; then
      printf "[%s] %s\n" "$lvl" "$msg"
    fi
  fi
}
log_info(){ _log info "$*"; }
log_warn(){ _log warn "$*"; }
log_error(){ _log error "$*"; }

# UI wrappers
ui_section_start() {
  local t="$1"
  if [[ "${_UI_PRESENT}" == "yes" && "$(type -t ui_section 2>/dev/null)" == "function" ]]; then
    ui_section "$t"
  else
    printf "[  ] %s\n" "$t"
  fi
}
ui_section_end_ok() {
  local t="$1"
  if [[ "${_UI_PRESENT}" == "yes" && "$(type -t ui_end_section 2>/dev/null)" == "function" ]]; then
    ui_end_section 0 "$t"
  else
    printf "[✔️] %s... concluído\n" "$t"
  fi
}
ui_section_end_fail() {
  local t="$1"
  if [[ "${_UI_PRESENT}" == "yes" && "$(type -t ui_end_section 2>/dev/null)" == "function" ]]; then
    ui_end_section 1 "$t"
  else
    printf "[✖] %s... falhou\n" "$t"
  fi
}

# ------------------------
# Helpers
# ------------------------
safe_mkdir() { mkdir -p "$1"; chmod 0755 "$1" 2>/dev/null || true; }

confirm() {
  if [[ "${AUTO_YES}" -eq 1 ]]; then return 0; fi
  printf "%s [y/N]: " "$1"
  read -r ans
  case "$ans" in y|Y) return 0 ;; *) return 1 ;; esac
}

sha256_of() {
  if [[ -f "$1" ]]; then sha256sum "$1" 2>/dev/null | awk '{print $1}'; fi
}

# Parse build.conf safely (only KEY=VALUE lines)
# prints KEY=VALUE pairs to stdout
parse_build_conf() {
  local f="$1"
  if [[ ! -r "$f" ]]; then return 1; fi
  awk -F= '
    /^[[:space:]]*#/ {next}
    NF>=2 {
      key=$1; sub(/^[[:space:]]*/,"",key); sub(/[[:space:]]*$/,"",key);
      $1=""; sub(/^=/,"",$0);
      val=$0; gsub(/^[[:space:]]*/,"",val); gsub(/[[:space:]]*$/,"",val);
      print key"="val
    }' "$f"
}

# expand simple variables $NAME and $VERSION in string
expand_vars() {
  local s="$1" name="$2" version="$3"
  s="${s//\$NAME/$name}"
  s="${s//\$VERSION/$version}"
  printf "%s" "$s"
}

# ensure required commands exist
require_cmds() {
  local miss=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || miss+=("$c"); done
  if (( ${#miss[@]} )); then
    log_error "Dependências ausentes: ${miss[*]}"
    return 1
  fi
  return 0
}

# atomic download via curl/wget
http_download() {
  local url="$1" out="$2"
  # prefer curl then wget
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 --create-dirs -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -c -O "$out" "$url"
  else
    return 2
  fi
}

# git shallow clone safe
git_clone_shallow() {
  local url="$1" outdir="$2"
  git clone --depth=1 "$url" "$outdir"
}

# unpack common formats into dest
unpack_archive() {
  local f="$1" dest="$2"
  safe_mkdir "$dest"
  case "$f" in
    *.tar.gz|*.tgz) tar xzf "$f" -C "$dest" ;;
    *.tar.xz) tar xJf "$f" -C "$dest" ;;
    *.tar.bz2) tar xjf "$f" -C "$dest" ;;
    *.tar) tar xf "$f" -C "$dest" ;;
    *.zip) unzip -q "$f" -d "$dest" ;;
    *.tar.lz4) lz4 -dc "$f" | tar xf - -C "$dest" ;;
    *) return 2 ;;
  esac
}

# ------------------------
# Phase: init
# ------------------------
fetch_init() {
  ui_section_start "Inicializando fetch"
  safe_mkdir "${ADM_SOURCES}"
  safe_mkdir "${ADM_TMP}"
  safe_mkdir "${ADM_LOGS}"
  touch "${LOGFILE}" 2>/dev/null || true
  log_info "Fetch init: sources=${ADM_SOURCES} tmp=${ADM_TMP}"
  ui_section_end_ok "Inicialização"
}

# ------------------------
# Phase: parse package conf
# Input: --conf <file> or --pkg <pkg_dir>
# Sets: NAME VERSION SOURCE CHECKSUM SRC_TYPE PKG_CACHE_FILE PKG_TMP_DIR
# ------------------------
fetch_parse_conf() {
  ui_section_start "Lendo build.conf"
  if [[ -n "${CONF_FILE}" ]]; then
    local conf="${CONF_FILE}"
  elif [[ -n "${PKG_DIR}" ]]; then
    local conf="${PKG_DIR}/build.conf"
  else
    log_error "Nenhum pacote especificado (--pkg dir) ou --conf arquivo"
    ui_section_end_fail "Ler build.conf"
    return 2
  fi

  if [[ ! -r "${conf}" ]]; then
    log_error "build.conf não encontrado ou não legível: ${conf}"
    ui_section_end_fail "Ler build.conf"
    return 2
  fi

  # default values
  NAME=""; VERSION=""; SOURCE=""; CHECKSUM=""; DESC=""
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue
    case "$line" in
      NAME=*) NAME="${line#NAME=}"; NAME="${NAME%\"}"; NAME="${NAME#\"}";;
      VERSION=*) VERSION="${line#VERSION=}"; VERSION="${VERSION%\"}"; VERSION="${VERSION#\"}";;
      SOURCE=*) SOURCE="${line#SOURCE=}"; SOURCE="${SOURCE%\"}"; SOURCE="${SOURCE#\"}";;
      URL=*) SOURCE="${line#URL=}"; SOURCE="${SOURCE%\"}"; SOURCE="${SOURCE#\"}";; # support older field
      CHECKSUM=*) CHECKSUM="${line#CHECKSUM=}"; CHECKSUM="${CHECKSUM%\"}"; CHECKSUM="${CHECKSUM#\"}";;
      DESC=*) DESC="${line#DESC=}"; DESC="${DESC%\"}"; DESC="${DESC#\"}";;
    esac
  done <"${conf}"

  # fallback inference
  if [[ -z "${NAME}" && -n "${PKG_DIR}" ]]; then NAME="$(basename "${PKG_DIR}")"; fi
  if [[ -z "${VERSION}" ]]; then VERSION="unknown"; fi
  if [[ -z "${SOURCE}" ]]; then
    log_error "build.conf sem campo SOURCE/URL: ${conf}"
    ui_section_end_fail "Ler build.conf"
    return 2
  fi

  # expand $NAME and $VERSION in SOURCE
  SOURCE="$(expand_vars "${SOURCE}" "${NAME}" "${VERSION}")"

  PKG_LABEL="${NAME}-${VERSION}"
  PKG_TMP_DIR="${ADM_TMP}/${PKG_LABEL}-${TS}"
  PKG_CACHE_FILE="${ADM_SOURCES}/${PKG_LABEL}"

  log_info "Parsed build.conf: name=${NAME} version=${VERSION} source=${SOURCE} checksum=${CHECKSUM}"
  ui_section_end_ok "build.conf lido"
  return 0
}

# ------------------------
# Phase: detect source type
# ------------------------
fetch_detect_type() {
  ui_section_start "Detectando tipo de origem"
  SRC_TYPE="unknown"
  case "${SOURCE}" in
    http://*|https://*|ftp://*) SRC_TYPE="http" ;;
    git://*|*git@*:*|*github.com*|*.git) SRC_TYPE="git" ;;
    file:///*) SRC_TYPE="local"; SOURCE="${SOURCE#file://}" ;;
    /*) SRC_TYPE="local" ;;
    *) 
      # try to detect simple patterns
      if [[ "${SOURCE}" =~ \.git$ ]]; then SRC_TYPE="git"; else SRC_TYPE="http"; fi
      ;;
  esac
  log_info "Tipo detectado: ${SRC_TYPE}"
  ui_section_end_ok "Tipo detectado"
}

# ------------------------
# Phase: check cache
# ------------------------
fetch_check_cache() {
  ui_section_start "Verificando cache local"
  # prefer full file name with extension; allow exact match or any file beginning with label
  local cached=""
  if [[ -f "${PKG_CACHE_FILE}" ]]; then cached="${PKG_CACHE_FILE}"; fi
  if [[ -z "${cached}" ]]; then
    # try any matching file
    cached="$(ls -1 "${ADM_SOURCES}/${NAME}-${VERSION}"* 2>/dev/null | head -n1 || true)"
  fi
  if [[ -n "${cached}" && -f "${cached}" && "${FORCE}" -eq 0 && "${NO_CACHE}" -eq 0 ]]; then
    # if checksum available, verify
    if [[ -n "${CHECKSUM}" ]]; then
      local actual
      actual="$(sha256_of "${cached}" || true)"
      if [[ "${actual}" == "${CHECKSUM}" ]]; then
        FOUND_CACHE="${cached}"
        log_info "Cache válido encontrado: ${FOUND_CACHE}"
        ui_section_end_ok "Cache válido"
        return 0
      else
        log_warn "Cache encontrado, checksum diferente: ${cached}"
      fi
    else
      FOUND_CACHE="${cached}"
      log_info "Cache (sem checksum) encontrado: ${FOUND_CACHE}"
      ui_section_end_ok "Cache (sem checksum)"
      return 0
    fi
  fi
  FOUND_CACHE=""
  ui_section_end_ok "Cache verificado"
  return 1
}

# ------------------------
# Phase: download / clone / copy
# ------------------------
fetch_download_or_clone() {
  ui_section_start "Executando fetch (${SRC_TYPE})"
  safe_mkdir "${PKG_TMP_DIR}"
  case "${SRC_TYPE}" in
    http)
      # build filename from URL basename
      local fname
      fname="$(basename "${SOURCE%%\?*}")"
      local out="${PKG_TMP_DIR}/${fname}"
      if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "DRY-RUN: download ${SOURCE} -> ${out}"
      else
        log_info "Baixando ${SOURCE}"
        if ! http_download "${SOURCE}" "${out}"; then
          log_error "Falha ao baixar ${SOURCE}"
          ui_section_end_fail "Download"
          return 2
        fi
      fi
      FETCHED_PATH="${out}"
      ;;
    git)
      # support git+https:// or ssh forms; clone into PKG_TMP_DIR/repo
      local repo_dir="${PKG_TMP_DIR}/repo"
      if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "DRY-RUN: git clone ${SOURCE} -> ${repo_dir}"
      else
        log_info "Clonando ${SOURCE}"
        if ! git_clone_shallow "${SOURCE}" "${repo_dir}"; then
          log_error "Falha ao clonar ${SOURCE}"
          ui_section_end_fail "Git clone"
          return 2
        fi
      fi
      FETCHED_PATH="${repo_dir}"
      ;;
    local)
      # copy file or directory
      if [[ -f "${SOURCE}" ]]; then
        local dest="${PKG_TMP_DIR}/$(basename "${SOURCE}")"
        if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
          log_info "DRY-RUN: cp ${SOURCE} -> ${dest}"
        else
          cp -a "${SOURCE}" "${dest}"
        fi
        FETCHED_PATH="${dest}"
      elif [[ -d "${SOURCE}" ]]; then
        local dest="${PKG_TMP_DIR}/source"
        if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
          log_info "DRY-RUN: cp -r ${SOURCE} -> ${dest}"
        else
          cp -a "${SOURCE}" "${dest}"
        fi
        FETCHED_PATH="${dest}"
      else
        log_error "Fonte local inexistente: ${SOURCE}"
        ui_section_end_fail "Fonte local"
        return 2
      fi
      ;;
    *)
      log_error "Tipo de origem não suportado: ${SRC_TYPE}"
      ui_section_end_fail "Fetch"
      return 2
      ;;
  esac

  log_info "Fetch realizado: ${FETCHED_PATH:-none}"
  ui_section_end_ok "Fetch"
  return 0
}

# ------------------------
# Phase: verify checksum or signature
# ------------------------
fetch_verify() {
  ui_section_start "Verificando integridade"
  if [[ -z "${CHECKSUM}" ]]; then
    log_info "Nenhum checksum fornecido; calculando sha256 para registro"
    local sha
    sha="$(sha256_of "${FETCHED_PATH}" || true)"
    if [[ -n "$sha" ]]; then
      log_info "SHA256: ${sha}"
      ui_section_end_ok "Verificação (registrado)"
      return 0
    else
      log_warn "Falha ao calcular SHA para ${FETCHED_PATH}"
      ui_section_end_fail "Verificação"
      return 2
    fi
  else
    # CHECKSUM provided -> compare
    local actual
    actual="$(sha256_of "${FETCHED_PATH}" || true)"
    if [[ "${actual}" == "${CHECKSUM}" ]]; then
      log_info "Checksum verificado OK"
      ui_section_end_ok "Verificação checksum"
      return 0
    else
      log_warn "Checksum mismatch: expected=${CHECKSUM} actual=${actual}"
      ui_section_end_fail "Verificação checksum"
      return 2
    fi
  fi
}

# ------------------------
# Phase: unpack / prepare source directory
# ------------------------
fetch_unpack() {
  ui_section_start "Desempacotando/preparando fontes"
  local destdir="${PKG_TMP_DIR}/src"
  safe_mkdir "${destdir}"
  if [[ -d "${FETCHED_PATH}" && -f "${FETCHED_PATH}/.git" ]] || [[ -d "${FETCHED_PATH}/.git" ]]; then
    # git repo: move or copy
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
      log_info "DRY-RUN: preparar repo em ${destdir}"
    else
      cp -a "${FETCHED_PATH}/." "${destdir}/"
    fi
    log_info "Repositório preparado em ${destdir}"
  elif [[ -f "${FETCHED_PATH}" ]]; then
    # archive: unpack
    if ! unpack_archive "${FETCHED_PATH}" "${destdir}"; then
      # might be plain directory archived without known ext; try tar xf
      if ! tar xf "${FETCHED_PATH}" -C "${destdir}" 2>/dev/null; then
        log_warn "Formato desconhecido ou falha ao desempacotar: ${FETCHED_PATH}"
        ui_section_end_fail "Desempacotar"
        return 2
      fi
    fi
    log_info "Archive extraído para ${destdir}"
  else
    # maybe a copied dir
    if [[ -d "${FETCHED_PATH}" ]]; then
      cp -a "${FETCHED_PATH}/." "${destdir}/"
      log_info "Conteúdo copiado para ${destdir}"
    else
      log_error "Nenhum conteúdo para preparar em ${FETCHED_PATH}"
      ui_section_end_fail "Preparar fontes"
      return 2
    fi
  fi
  FETCHED_SRC_DIR="${destdir}"
  ui_section_end_ok "Fontes prontas"
  return 0
}

# ------------------------
# Phase: cache update
# ------------------------
fetch_cache_update() {
  ui_section_start "Atualizando cache local"
  # choose stable cache filename: name-version.ext if possible; else fallback to label + timestamp
  if [[ "${SRC_TYPE}" == "http" && -f "${FETCHED_PATH}" ]]; then
    local base="$(basename "${FETCHED_PATH}")"
    local dest="${ADM_SOURCES}/${NAME}-${VERSION}-${base}"
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
      log_info "DRY-RUN: copiar ${FETCHED_PATH} -> ${dest}"
    else
      cp -a "${FETCHED_PATH}" "${dest}"
      log_info "Cache atualizado: ${dest}"
    fi
    PKG_CACHE_FILE="${dest}"
  elif [[ "${SRC_TYPE}" == "git" ]]; then
    # store a tarball snapshot of commit (if git available)
    local out="${ADM_SOURCES}/${NAME}-${VERSION}-git-${TS}.tar.gz"
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
      log_info "DRY-RUN: criar tarball do repo -> ${out}"
    else
      (cd "${FETCHED_PATH}" && git rev-parse --short HEAD >/dev/null 2>&1) && \
        (cd "${FETCHED_PATH}" && git archive --format=tar.gz -o "${out}" HEAD) || \
        tar czf "${out}" -C "${FETCHED_PATH}" .
      log_info "Cache git salvo em ${out}"
      PKG_CACHE_FILE="${out}"
    fi
  else
    # local or unpacked directory: create tarball
    local out="${ADM_SOURCES}/${NAME}-${VERSION}-snapshot-${TS}.tar.gz"
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
      log_info "DRY-RUN: criar snapshot ${out}"
    else
      tar czf "${out}" -C "${FETCHED_SRC_DIR}" .
      log_info "Snapshot salvo em ${out}"
      PKG_CACHE_FILE="${out}"
    fi
  fi

  # update DB record (simple append)
  if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
    safe_mkdir "${ADM_DB}"
    local dbfile="${ADM_DB}/fetch.db"
    local now
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf "%s|%s|%s|%s|%s\n" "${NAME}" "${VERSION}" "${SOURCE}" "${PKG_CACHE_FILE:-none}" "${now}" >>"${dbfile}"
    log_info "DB atualizado: ${dbfile}"
  fi

  ui_section_end_ok "Cache atualizado"
}

# ------------------------
# Phase: cleanup
# ------------------------
fetch_cleanup() {
  ui_section_start "Limpando temporários"
  if [[ "${DEBUG}" -eq 1 ]]; then
    log_info "DEBUG=1: mantendo temporários em ${PKG_TMP_DIR}"
  else
    rm -rf "${PKG_TMP_DIR}" 2>/dev/null || true
    log_info "Removidos temporários: ${PKG_TMP_DIR}"
  fi
  ui_section_end_ok "Cleanup"
}

# ------------------------
# Main dispatcher
# ------------------------
_print_usage() {
  cat <<EOF
fetch.sh - fetch and prepare package sources (ADM)
Usage:
  fetch.sh --pkg <pkg_dir> [--conf <build.conf>] [options]
Options:
  --pkg <pkg_dir>       Directory containing build.conf
  --conf <build.conf>   Path to build.conf file
  --force               Force re-fetch even if cache exists
  --verify-only         Only verify cache/checksum (no download)
  --no-cache            Do not update/read cache
  --debug               Keep temporary files for inspection
  --yes                 Assume yes for confirmations
  --verbose             Verbose output to stdout
  --help
EOF
}

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pkg) PKG_DIR="${2:-}"; shift 2 ;;
    --conf) CONF_FILE="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --verify-only) VERIFY_ONLY=1; shift ;;
    --no-cache) NO_CACHE=1; shift ;;
    --debug) DEBUG=1; shift ;;
    --yes) AUTO_YES=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --help|-h) _print_usage; exit 0 ;;
    *) echo "Unknown arg: $1"; _print_usage; exit 2 ;;
  esac
done

# run
fetch_init

# parse conf
if ! fetch_parse_conf; then
  log_error "Falha ao parsear build.conf"
  exit 2
fi

# detect type
fetch_detect_type

# check prerequisites for network/git when needed
case "${SRC_TYPE}" in
  http)
    if ! require_cmds curl sha256sum >/dev/null 2>&1; then
      log_error "curl ou sha256sum ausente"
      exit 2
    fi
    ;;
  git)
    if ! require_cmds git tar sha256sum >/dev/null 2>&1; then
      log_error "git/tar/sha256sum ausente"
      exit 2
    fi
    ;;
  local)
    # no external required
    ;;
esac

# check cache
FOUND_CACHE=""
if [[ "${NO_CACHE}" -eq 0 ]]; then
  fetch_check_cache || true
fi

# if verify-only requested, just verify cache or fail
if [[ "${VERIFY_ONLY}" -eq 1 ]]; then
  if [[ -n "${FOUND_CACHE}" ]]; then
    if [[ -n "${CHECKSUM}" ]]; then
      local actual; actual="$(sha256_of "${FOUND_CACHE}" || true)"
      if [[ "${actual}" == "${CHECKSUM}" ]]; then
        log_info "VERIFY-ONLY: cache OK"
        echo "OK: ${FOUND_CACHE}"
        exit 0
      else
        log_error "VERIFY-ONLY: checksum mismatch for ${FOUND_CACHE}"
        exit 2
      fi
    else
      log_info "VERIFY-ONLY: cache present (no checksum supplied): ${FOUND_CACHE}"
      exit 0
    fi
  else
    log_error "VERIFY-ONLY: no cached file found"
    exit 2
  fi
fi

# if cache valid and not forced, use it
if [[ -n "${FOUND_CACHE}" && "${FORCE}" -eq 0 && "${NO_CACHE}" -eq 0 ]]; then
  log_info "Usando cache: ${FOUND_CACHE}"
  # still prepare FETCHED_PATH and SRC_DIR
  FETCHED_PATH="${FOUND_CACHE}"
  # prepare unpack only if needed
  if ! fetch_unpack; then
    log_error "Falha ao preparar fontes a partir do cache"
    exit 2
  fi
  if [[ "${NO_CACHE}" -eq 0 ]]; then
    # we still may want to update DB (already present) - skip
    :
  fi
else
  # perform fetch
  if ! fetch_download_or_clone; then
    log_error "Falha no fetch"
    exit 2
  fi

  # verify fetched
  if ! fetch_verify; then
    # attempt one retry for HTTP
    if [[ "${SRC_TYPE}" == "http" && "${FORCE}" -eq 0 ]]; then
      log_warn "Tentando novo download (retry)..."
      sleep 1
      if ! fetch_download_or_clone; then
        log_error "Retry failed"
        exit 2
      fi
      if ! fetch_verify; then
        log_error "Checksum ainda inválido após retry"
        exit 2
      fi
    else
      log_error "Verificação falhou"
      exit 2
    fi
  fi

  # unpack/prep
  if ! fetch_unpack; then
    log_error "Falha ao desempacotar"
    exit 2
  fi

  # update cache unless disabled
  if [[ "${NO_CACHE}" -eq 0 ]]; then
    fetch_cache_update || log_warn "Falha ao atualizar cache (não fatal)"
  fi
fi

# cleanup unless debug
fetch_cleanup

# final summary
ui_section_start "Resumo"
log_info "Fetch concluído: ${NAME}-${VERSION}"
printf "Package: %s\nVersion: %s\nSource: %s\nCached: %s\nLog: %s\n" "${NAME}" "${VERSION}" "${SOURCE}" "${PKG_CACHE_FILE:-none}" "${LOGFILE}"
ui_section_end_ok "Resumo"

exit 0
