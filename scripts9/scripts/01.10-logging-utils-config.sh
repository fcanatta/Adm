#!/usr/bin/env bash
# 01.10-logging-utils-config.sh
# Logging, utilidades gerais e configuração para o ADM.
# Local: /usr/src/adm/scripts/01.10-logging-utils-config.sh

###############################################################################
# Modo estrito + trap de erros (sem erros silenciosos)
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__adm_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] Falha: codigo=${code} linha=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __adm_err_trap ERR

###############################################################################
# Defaults e caminhos-base
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_LOG_DIR="${ADM_LOG_DIR:-${ADM_STATE_DIR}/logs}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"

# Fallbacks se 00.* não estiverem carregados
adm_is_cmd() { command -v "$1" >/dev/null 2>&1; }
__adm_ensure_dir() {
  local d="$1" mode="${2:-0755}" owner="${3:-root}" group="${4:-root}"
  if [[ ! -d "$d" ]]; then
    if adm_is_cmd install; then
      if [[ $EUID -ne 0 ]] && adm_is_cmd sudo; then
        sudo install -d -m "$mode" -o "$owner" -g "$group" "$d"
      else
        install -d -m "$mode" -o "$owner" -g "$group" "$d"
      fi
    else
      mkdir -p "$d"
      chmod "$mode" "$d"
      chown "$owner:$group" "$d" || true
    fi
  fi
}

__adm_ensure_dir "$ADM_STATE_DIR"
__adm_ensure_dir "$ADM_LOG_DIR"
__adm_ensure_dir "$ADM_TMPDIR"

###############################################################################
# Cores e TTY (compatível com ausência de 00.10)
###############################################################################
if [[ -t 1 ]] && adm_is_cmd tput && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  ADM_COLOR_RST="$(tput sgr0)"
  ADM_COLOR_BLD="$(tput bold)"
  ADM_COLOR_DIM="$(tput dim 2>/dev/null || echo)"
  ADM_COLOR_OK="$(tput setaf 2)"
  ADM_COLOR_WRN="$(tput setaf 3)"
  ADM_COLOR_ERR="$(tput setaf 1)"
  ADM_COLOR_INF="$(tput setaf 6)"
  ADM_COLOR_DBG="$(tput setaf 5)"
else
  ADM_COLOR_RST=""; ADM_COLOR_BLD=""; ADM_COLOR_DIM=""
  ADM_COLOR_OK="";  ADM_COLOR_WRN=""; ADM_COLOR_ERR=""
  ADM_COLOR_INF=""; ADM_COLOR_DBG=""
fi

###############################################################################
# Logging: níveis, formatação, arquivos, JSON, rotação
###############################################################################
# Níveis: 0=TRACE 1=DEBUG 2=INFO 3=WARN 4=ERROR 5=FATAL
declare -A __ADM_LOG_LEVELS=([TRACE]=0 [DEBUG]=1 [INFO]=2 [WARN]=3 [ERROR]=4 [FATAL]=5)
ADM_LOG_LEVEL_NAME="${ADM_LOG_LEVEL_NAME:-INFO}"
ADM_LOG_LEVEL="${ADM_LOG_LEVEL:-${__ADM_LOG_LEVELS[$ADM_LOG_LEVEL_NAME]:-2}}"

ADM_LOG_FILE="${ADM_LOG_FILE:-${ADM_LOG_DIR}/adm.log}"
ADM_LOG_MAX_SIZE="${ADM_LOG_MAX_SIZE:-5242880}" # 5 MiB
ADM_LOG_JSON="${ADM_LOG_JSON:-0}"               # 0=texto, 1=jsonl
ADM_LOG_TEE="${ADM_LOG_TEE:-1}"                 # 1=stdout+arquivo, 0=apenas arquivo

__adm_ts() { date -u +"%Y-%m-%dT%H:%M:%S%z"; } # ISO-like com timezone
__adm_prog() { printf "%s" "${ADM_PROG_CONTEXT:-adm}"; }

adm_log_set_level() {
  local name="${1^^}"
  if [[ -z "${__ADM_LOG_LEVELS[$name]+x}" ]]; then
    echo "[ERR] Nível inválido: $1" 1>&2
    return 1
  fi
  ADM_LOG_LEVEL="${__ADM_LOG_LEVELS[$name]}"
  ADM_LOG_LEVEL_NAME="$name"
}

__adm_log_level_enabled() {
  local name="${1^^}" lvl=${__ADM_LOG_LEVELS[$name]:-99}
  (( lvl >= ADM_LOG_LEVEL )) && return 0 || return 1
}

__adm_log_rotate_if_needed() {
  [[ -f "$ADM_LOG_FILE" ]] || return 0
  local size
  size=$(stat -c%s "$ADM_LOG_FILE" 2>/dev/null || echo 0)
  if [[ "$size" =~ ^[0-9]+$ ]] && (( size > ADM_LOG_MAX_SIZE )); then
    local ts suffix=1
    ts="$(date -u +%Y%m%d-%H%M%S)"
    while [[ -e "${ADM_LOG_FILE}.${ts}.${suffix}.gz" ]]; do ((suffix++)); done
    gzip -c "$ADM_LOG_FILE" > "${ADM_LOG_FILE}.${ts}.${suffix}.gz" || true
    : > "$ADM_LOG_FILE"
  fi
}

adm_log_init() {
  local file="$ADM_LOG_FILE" level="$ADM_LOG_LEVEL_NAME" json="$ADM_LOG_JSON"
  while (($#)); do
    case "$1" in
      --file)  file="${2:-}"; shift 2 ;;
      --level) level="${2:-}"; shift 2 ;;
      --json)  json="${2:-0}"; shift 2 ;;
      *) echo "[ERR] adm_log_init: opção inválida $1" 1>&2; return 2 ;;
    esac
  done
  [[ -n "$file" ]] || { echo "[ERR] log file vazio" 1>&2; return 3; }
  __adm_ensure_dir "$(dirname "$file")"
  : >"$file" || { echo "[ERR] não consigo abrir $file" 1>&2; return 4; }
  ADM_LOG_FILE="$file"
  ADM_LOG_JSON="$json"
  adm_log_set_level "$level"
  exec {ADM_LOG_FD}>>"$ADM_LOG_FILE"
  : "${ADM_LOG_FD:?Falha em abrir FD de log}"
  __adm_log_rotate_if_needed
  adm_info "Logging iniciado: file=$ADM_LOG_FILE level=$ADM_LOG_LEVEL_NAME json=$ADM_LOG_JSON"
}

__adm_log_emit_text() {
  local level="$1" msg="$2"
  local ts="$(__adm_ts)" prg="$(__adm_prog)"
  local tag color
  case "$level" in
    TRACE) tag="${ADM_COLOR_DBG}[TRC]${ADM_COLOR_RST}" ; color="$ADM_COLOR_DBG" ;;
    DEBUG) tag="${ADM_COLOR_DBG}[DBG]${ADM_COLOR_RST}" ; color="$ADM_COLOR_DBG" ;;
    INFO)  tag="${ADM_COLOR_INF}[INF]${ADM_COLOR_RST}" ; color="$ADM_COLOR_INF" ;;
    WARN)  tag="${ADM_COLOR_WRN}[WRN]${ADM_COLOR_RST}" ; color="$ADM_COLOR_WRN" ;;
    ERROR) tag="${ADM_COLOR_ERR}[ERR]${ADM_COLOR_RST}" ; color="$ADM_COLOR_ERR" ;;
    FATAL) tag="${ADM_COLOR_ERR}[FTL]${ADM_COLOR_RST}" ; color="$ADM_COLOR_ERR" ;;
    *)     tag="[LOG]" ; color="";;
  esac
  local line="${ts} ${prg} ${level} ${msg}"
  # Para terminal
  if (( ADM_LOG_TEE )); then
    if [[ "$level" =~ ^(WARN|ERROR|FATAL)$ ]]; then
      echo -e "${tag} ${ADM_COLOR_BLD}${msg}${ADM_COLOR_RST}" 1>&2
    else
      echo -e "${tag} ${msg}"
    fi
  fi
  # Para arquivo (sem cores)
  printf '%s\n' "${line}" >&"${ADM_LOG_FD}"
}

__adm_json_escape() {
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

__adm_log_emit_json() {
  local level="$1" msg="$2"
  local ts="$(__adm_ts)" prg="$(__adm_prog)"
  local json="{\"ts\":\"${ts}\",\"prog\":\"${prg}\",\"level\":\"${level}\",\"msg\":\"$(__adm_json_escape "$msg")\"}"
  if (( ADM_LOG_TEE )); then echo "$json"; fi
  printf '%s\n' "$json" >&"${ADM_LOG_FD}"
}

__adm_log_emit() {
  local level="$1"; shift
  local msg="$*"
  __adm_log_rotate_if_needed
  if (( ADM_LOG_JSON )); then
    __adm_log_emit_json "$level" "$msg"
  else
    __adm_log_emit_text "$level" "$msg"
  fi
}

adm_trace() { __adm_log_level_enabled TRACE && __adm_log_emit TRACE "$*"; true; }
adm_debug() { __adm_log_level_enabled DEBUG && __adm_log_emit DEBUG "$*"; true; }
adm_info()  { __adm_log_level_enabled INFO  && __adm_log_emit INFO  "$*"; true; }
adm_warn()  { __adm_log_level_enabled WARN  && __adm_log_emit WARN  "$*"; true; }
adm_error() { __adm_log_level_enabled ERROR && __adm_log_emit ERROR "$*"; true; }
adm_fatal() { __adm_log_emit FATAL "$*"; exit 1; }

adm_quote_cmd() {
  # Gera string segura para log a partir de argv
  local out=() s
  for s in "$@"; do
    if [[ "$s" =~ [[:space:]"'\\] ]]; then
      out+=("$(printf "%q" "$s")")
    else
      out+=("$s")
    fi
  done
  printf '%s ' "${out[@]}"
}

###############################################################################
# Utils: retry, spinner, run/capture, tmpfile
###############################################################################
adm_retry() {
  # uso: adm_retry <tentativas> <delay_inc_ms> -- comando args...
  local tries="${1:?tries}" inc_ms="${2:?inc-ms}"; shift 2
  [[ "$1" == "--" ]] && shift || { adm_error "adm_retry: falta --"; return 2; }
  local attempt=1 delay=0 rc
  while (( attempt <= tries )); do
    adm_info "Tentativa ${attempt}/${tries}: $(adm_quote_cmd "$@")"
    if "$@"; then
      adm_ok "Sucesso na tentativa ${attempt}"
      return 0
    fi
    rc=$?
    adm_warn "Falhou tentativa ${attempt} (rc=$rc)"
    if (( attempt == tries )); then
      adm_error "Esgotadas tentativas (rc=$rc)"
      return "$rc"
    fi
    delay=$((attempt * inc_ms))
    sleep "$(awk "BEGIN{printf \"%.3f\", $delay/1000}")"
    ((attempt++))
  done
}

adm_with_spinner() {
  # uso: adm_with_spinner "mensagem" -- comando args...
  local msg="${1:-processando}"; shift
  [[ "$1" == "--" ]] && shift || { adm_error "adm_with_spinner: falta --"; return 2; }
  local sp='|/-\' i=0 pid rc
  adm_info "$msg: $(adm_quote_cmd "$@")"
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) % 4 ))
    printf "\r[%c] %s" "${sp:$i:1}" "$msg"
    sleep 0.15
  done
  wait "$pid"; rc=$?
  printf "\r    \r"
  if (( rc == 0 )); then adm_info "$msg: concluído"; else adm_error "$msg: falhou (rc=$rc)"; fi
  return "$rc"
}

adm_run() {
  # uso: adm_run [-o out] [-e err] -- comando args...
  local outf="" errf=""
  while (($#)); do
    case "$1" in
      -o) outf="${2:-}"; shift 2 ;;
      -e) errf="${2:-}"; shift 2 ;;
      --) shift; break ;;
      *)  adm_error "adm_run: opção inválida $1"; return 2 ;;
    esac
  done
  [[ -n "$outf" ]] || outf="$(mktemp "${ADM_TMPDIR}/run.XXXXXX.out")"
  [[ -n "$errf" ]] || errf="$(mktemp "${ADM_TMPDIR}/run.XXXXXX.err")"
  adm_debug "run: $(adm_quote_cmd "$@")"
  if "$@" >"$outf" 2>"$errf"; then
    adm_trace "stdout: $(wc -c <"$outf") bytes, stderr: $(wc -c <"$errf") bytes"
    return 0
  else
    adm_error "comando falhou: $(adm_quote_cmd "$@")"
    adm_error "stderr (tail): $(tail -n 3 "$errf" | tr '\n' ' ')"
    return 1
  fi
}

adm_tmpfile() {
  local p="${1:-adm}"
  mktemp "${ADM_TMPDIR}/${p}.XXXXXX"
}
###############################################################################
# Utils: SHA256 e download resiliente (curl/wget, ETag, resume, hash)
###############################################################################
adm_sha256() {
  # uso: adm_sha256 <arquivo>
  local f="${1:?arquivo}"
  if ! [[ -r "$f" ]]; then
    adm_error "sha256: arquivo não legível: $f"
    return 2
  fi
  if adm_is_cmd sha256sum; then
    sha256sum "$f" | awk '{print $1}'
  elif adm_is_cmd shasum; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    adm_error "sha256: nenhuma ferramenta disponível"
    return 3
  fi
}

adm_sha256_verify() {
  # uso: adm_sha256_verify <arquivo> <soma_esperada>
  local f="${1:?arquivo}" want="${2:?sha}"
  local got
  got="$(adm_sha256 "$f")" || return $?
  if [[ "$got" == "$want" ]]; then
    adm_ok "sha256 OK para $(basename "$f")"
    return 0
  else
    adm_error "sha256 MISMATCH para $(basename "$f"): got=$got want=$want"
    return 1
  fi
}

__adm_dl_curl() {
  local url="$1" out="$2" hdr="$3"
  local args=( -L --fail --retry 3 --retry-delay 1 --connect-timeout 10 )
  [[ -f "$hdr" ]] && args+=( -z "$out" -D "$hdr.new" ) || args+=( -D "$hdr.new" )
  if [[ -f "$out" ]]; then args+=( -C - ); fi
  args+=( -o "$out" "$url" )
  adm_debug "curl ${args[*]}"
  curl "${args[@]}"
}

__adm_dl_wget() {
  local url="$1" out="$2" hdr="$3"
  local args=( -O "$out" --no-verbose --tries=3 --timeout=10 )
  [[ -f "$out" ]] && args+=( -c )
  # wget salva headers só com --server-response (stderr); contornamos com -S e parse posterior, opcional
  adm_debug "wget ${args[*]} $url"
  wget "${args[@]}" "$url"
  # cabeçalhos não padronizados; marcamos apenas timestamp de download
  printf 'Downloaded: %s\n' "$(__adm_ts)" > "$hdr.new"
}

adm_download() {
  # uso: adm_download <url> <outfile> [--sha256 SUM] [--retries N] [--etag HFILE]
  local url="${1:?url}" out="${2:?outfile}"; shift 2
  local sum="" retries=3 hdr="${out}.hdr"
  while (($#)); do
    case "$1" in
      --sha256) sum="${2:-}"; shift 2 ;;
      --retries) retries="${2:-3}"; shift 2 ;;
      --etag) hdr="${2:-${out}.hdr}"; shift 2 ;;
      *) adm_error "adm_download: opção inválida $1"; return 2 ;;
    esac
  done
  __adm_ensure_dir "$(dirname "$out")"
  local rc=0
  adm_retry "$retries" 400 -- bash -c '
    set -Eeuo pipefail
    url="$1"; out="$2"; hdr="$3"
    if command -v curl >/dev/null 2>&1; then
      __adm_dl_curl "$url" "$out" "$hdr"
    elif command -v wget >/dev/null 2>&1; then
      __adm_dl_wget "$url" "$out" "$hdr"
    else
      echo "[ERR] nem curl nem wget disponíveis" 1>&2; exit 7
    fi
    mv -f "$hdr.new" "$hdr" 2>/dev/null || true
  ' _ "$url" "$out" "$hdr" || rc=$?

  if (( rc != 0 )); then
    adm_error "download falhou para $url (rc=$rc)"
    return "$rc"
  fi

  if [[ -n "$sum" ]]; then
    adm_sha256_verify "$out" "$sum" || return 8
  fi
  adm_ok "download ok: $out"
}

###############################################################################
# Configuração: carregamento, merge, validação e acesso
###############################################################################
# Arquivos pesquisados (ordem de menor → maior precedência):
#  1) /etc/adm/adm.conf
#  2) ${ADM_ROOT}/adm.conf
#  3) ${HOME}/.config/adm/adm.conf
#  4) ${ADM_PROJECT_CONF:-/usr/src/adm/project/adm.conf} (se existir)
ADM_CONF_FILES_DEFAULT=(
  "/etc/adm/adm.conf"
  "${ADM_ROOT}/adm.conf"
  "${HOME:-/root}/.config/adm/adm.conf"
)

declare -A ADM_CFG

adm_bool() {
  # parse booleans: 1 true yes on → 1, 0 false no off → 0
  local v="${1:-}"
  shopt -s nocasematch
  case "$v" in
    1|true|yes|on|y) echo 1 ;;
    0|false|no|off|n|"") echo 0 ;;
    *) echo 0 ;;
  esac
  shopt -u nocasematch
}

adm_config_load_file() {
  local f="${1:?arquivo}"
  [[ -r "$f" ]] || { adm_warn "config: ignorando não legível: $f"; return 0; }
  adm_info "Carregando config: $f"
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    # strip comments
    line="${line%%#*}"
    # trim
    line="$(sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//' <<<"$line")"
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      key="${line%%=*}"
      val="${line#*=}"
      # remove aspas externas se houver
      if [[ "$val" =~ ^\".*\"$ || "$val" =~ ^\'.*\'$ ]]; then
        val="${val:1:-1}"
      fi
      ADM_CFG["$key"]="$val"
    else
      adm_warn "linha inválida em $f: $line"
    fi
  done <"$f"
}

adm_config_init() {
  local files=("${ADM_CONF_FILES_DEFAULT[@]}")
  [[ -n "${ADM_PROJECT_CONF:-}" ]] && files+=("$ADM_PROJECT_CONF")
  local f
  for f in "${files[@]}"; do
    [[ -n "$f" ]] && adm_config_load_file "$f"
  done
  # overrides por ENV (ADM_<KEY>)
  local k envk
  for k in "${!ADM_CFG[@]}"; do
    envk="ADM_${k}"
    if [[ -v $envk ]]; then
      ADM_CFG["$k"]="${!envk}"
      adm_info "override por env: ${k}=***"
    end
  done
}

adm_config_get() {
  # uso: adm_config_get <chave> [default]
  local k="${1:?chave}" def="${2:-}"
  if [[ -v ADM_CFG["$k"] ]]; then
    printf '%s' "${ADM_CFG[$k]}"
  else
    printf '%s' "$def"
  fi
}

adm_config_require() {
  local k="${1:?chave}"
  if [[ ! -v ADM_CFG["$k"] ]]; then
    adm_fatal "config requer chave ausente: $k"
  fi
}

adm_config_dump() {
  local k
  for k in "${!ADM_CFG[@]}"; do
    printf '%s=%q\n' "$k" "${ADM_CFG[$k]}"
  done
}

###############################################################################
# Auto-inicialização razoável: logging básico e config
###############################################################################
if [[ -z "${__ADM_LOG_INIT_DONE:-}" ]]; then
  # Tenta iniciar logging com defaults; não falha duro se não conseguir
  if adm_log_init --file "$ADM_LOG_FILE" --level "${ADM_LOG_LEVEL_NAME:-INFO}" --json "${ADM_LOG_JSON:-0}"; then
    __ADM_LOG_INIT_DONE=1
  else
    echo "[WAR] logging não inicializado, seguindo..." 1>&2
    __ADM_LOG_INIT_DONE=0
  fi
fi

# Inicializa config (não fatal)
adm_config_init || true

###############################################################################
# Self-test simples quando executado diretamente
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  adm_info "Self-test 01.10 iniciado."
  adm_trace "trace habilitado? nível atual: ${ADM_LOG_LEVEL_NAME}"
  adm_debug "debug habilitado."
  tmp="$(adm_tmpfile demo)"
  echo "hello" > "$tmp"
  sum="$(adm_sha256 "$tmp")"
  adm_info "sha256($tmp)=$sum"
  adm_run -o "${tmp}.out" -e "${tmp}.err" -- bash -lc 'echo OUT; echo ERR 1>&2'
  adm_with_spinner "aguarde 1s" -- sleep 1
  adm_info "Config dump:"
  adm_config_dump | sed 's/.*/  &/'
  adm_ok "Self-test concluído."
fi
