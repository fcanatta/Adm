#!/usr/bin/env bash
# 01-adm-lib.part1.sh
# Biblioteca utilitária do ADM: logging, spinner, execução, locks, fs helpers,
# checksum, validações, ambiente, erros e traps.
#
# Requer: 00-adm-config.sh já carregado (source).

###############################################################################
# Guardas e pré-requisitos
###############################################################################
if [[ -n "${ADM_LIB_LOADED_PART1:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_LIB_LOADED_PART1=1

# Verifica presença do config
if [[ -z "${ADM_CONF_LOADED:-}" ]]; then
  echo "ERRO: 01-adm-lib requer 00-adm-config.sh carregado antes." >&2
  return 2 2>/dev/null || exit 2
fi

# Bash 4+
if [[ -z "${BASH_VERSINFO:-}" || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "ERRO: Bash >= 4 é requerido pelo 01-adm-lib (associativos, etc.)." >&2
  return 2 2>/dev/null || exit 2
fi

###############################################################################
# Cores e estilo (baseado em ADM_COLOR_MODE do config)
###############################################################################
# 0 = sem cor, 1 = com cor
: "${ADM_COLOR_MODE:=0}"

_adm_csi=$'\033['
if [[ "${ADM_COLOR_MODE}" -eq 1 ]]; then
  ADM_CLR_RESET="${_adm_csi}0m"
  ADM_CLR_BOLD="${_adm_csi}1m"
  ADM_CLR_DIM="${_adm_csi}2m"
  ADM_CLR_RED="${_adm_csi}31m"
  ADM_CLR_GREEN="${_adm_csi}32m"
  ADM_CLR_YELLOW="${_adm_csi}33m"
  ADM_CLR_BLUE="${_adm_csi}34m"
  ADM_CLR_MAGENTA="${_adm_csi}35m"
  ADM_CLR_PINK="${_adm_csi}95m"     # para deps (rosa)
else
  ADM_CLR_RESET=""
  ADM_CLR_BOLD=""
  ADM_CLR_DIM=""
  ADM_CLR_RED=""
  ADM_CLR_GREEN=""
  ADM_CLR_YELLOW=""
  ADM_CLR_BLUE=""
  ADM_CLR_MAGENTA=""
  ADM_CLR_PINK=""
fi

# Símbolos
ADM_SYM_OK="✔️"
ADM_SYM_ERR="✖"
ADM_SYM_INFO="•"
ADM_SYM_RETRY="↻"

###############################################################################
# Estado global de log/spinner/locks
###############################################################################
ADM_LOG_CURRENT=""          # caminho do arquivo de log atual
ADM_LOG_PKG=""              # nome do pacote (exibição padronizada)
ADM_LOG_CAT=""
ADM_LOG_VER=""
ADM_LOG_ACTION=""
ADM_SPINNER_PID=""
ADM_SPINNER_ACTIVE=0

# Locks: nome → fd (via assoc)
declare -A __ADM_LOCK_FD

###############################################################################
# Utilitários internos (sem saída colorida silenciosa)
###############################################################################
_adm_now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

_adm_escape_pkg_tag() {
  # Gera tag padronizada [cat/pkg ver] ou [pkg ver] caso cat esteja vazio
  local pkg="${1:-}" cat="${2:-}" ver="${3:-}"
  local head=""
  if [[ -n "$pkg" && -n "$ver" && -n "$cat" ]]; then
    head="[$cat/$pkg $ver]"
  elif [[ -n "$pkg" && -n "$ver" ]]; then
    head="[$pkg $ver]"
  elif [[ -n "$pkg" ]]; then
    head="[$pkg]"
  else
    head=""
  fi
  printf "%s" "$head"
}

_adm_logfile_path() {
  # Gera nome de log: <cat>-<name>-<ver>-<timestamp>.log (faltantes viram 'na')
  local cat="${1:-na}" name="${2:-na}" ver="${3:-na}"
  local ts; ts=$(date +"%Y%m%d-%H%M%S")
  printf "%s/%s-%s-%s-%s.log" "$ADM_LOG_ROOT" "$cat" "$name" "$ver" "$ts"
}

_adm_ensure_dir() {
  local d="$1"
  [[ -z "$d" ]] && { echo "ERRO: diretório vazio em _adm_ensure_dir" >&2; return 3; }
  if [[ ! -d "$d" ]]; then
    mkdir -p -- "$d" 2>/dev/null || { mkdir -p -- "$d" || return 3; }
  fi
}

###############################################################################
# Logging estruturado + saída na tela
###############################################################################
# Níveis: INFO | WARN | ERROR | DEP | STEP | OK

adm_log_open() {
  # adm_log_open <pkg> <category> <version> <action>
  local pkg="${1:-}"; local cat="${2:-}"; local ver="${3:-}"; local action="${4:-}"
  _adm_ensure_dir "$ADM_LOG_ROOT" || { echo "ERRO: não foi possível criar LOG_ROOT: $ADM_LOG_ROOT" >&2; return 2; }
  ADM_LOG_PKG="$pkg"; ADM_LOG_CAT="$cat"; ADM_LOG_VER="$ver"; ADM_LOG_ACTION="$action"
  local lf; lf="$(_adm_logfile_path "$cat" "$pkg" "$ver")" || return 2
  : > "$lf" 2>/dev/null || { echo "ERRO: não foi possível criar arquivo de log: $lf" >&2; return 2; }
  ADM_LOG_CURRENT="$lf"
  # Cabeçalho
  {
    echo "# ADM LOG"
    echo "# package=$pkg category=$cat version=$ver action=$action"
    echo "# started=$(_adm_now_iso)"
  } >> "$ADM_LOG_CURRENT"
  return 0
}

adm__logfile_assert() {
  if [[ -z "$ADM_LOG_CURRENT" ]]; then
    # cria efêmero no TMP
    _adm_ensure_dir "$ADM_TMP_ROOT" || return 2
    local lf="${ADM_TMP_ROOT}/adm-ephemeral-$(date +%s)-$$.log"
    : > "$lf" || { echo "ERRO: não foi possível criar log efêmero: $lf" >&2; return 2; }
    ADM_LOG_CURRENT="$lf"
  fi
}

adm_log() {
  # adm_log <LEVEL> <PKG(optional or use current)> <ACTION(optional)> <message...>
  local level="$1"; shift || true
  local pkg="${1:-$ADM_LOG_PKG}"; shift || true
  local action="${1:-$ADM_LOG_ACTION}"; shift || true
  local msg="$*"
  adm__logfile_assert || return 2
  local ts="$(_adm_now_iso)"
  printf "%s | %s | %s/%s %s | %s\n" "$ts" "$level" "${ADM_LOG_CAT:-na}" "${pkg:-na}" "${ADM_LOG_VER:-na}" "${action:--}" >> "$ADM_LOG_CURRENT" 2>/dev/null || {
    echo "ERRO: falha ao escrever no log ($ADM_LOG_CURRENT)" >&2
    return 3
  }

  # Saída na tela formatada
  local head; head="$(_adm_escape_pkg_tag "$pkg" "$ADM_LOG_CAT" "$ADM_LOG_VER")"
  case "$level" in
    INFO)  printf "%b%s%b %b%s%b\n" "$ADM_CLR_BOLD" "$head" "$ADM_CLR_RESET" "$ADM_CLR_YELLOW" "• $msg" "$ADM_CLR_RESET" ;;
    WARN)  printf "%b%s%b %b%s%b\n" "$ADM_CLR_BOLD" "$head" "$ADM_CLR_RESET" "$ADM_CLR_YELLOW" "AVISO: $msg" "$ADM_CLR_RESET" ;;
    ERROR) printf "%b%s%b %b%s%b\n" "$ADM_CLR_BOLD" "$head" "$ADM_CLR_RESET" "$ADM_CLR_RED"   "ERRO: $msg" "$ADM_CLR_RESET" ;;
    DEP)   printf "%b%s%b %b%s%b\n" "$ADM_CLR_BOLD" "$head" "$ADM_CLR_RESET" "$ADM_CLR_PINK"  "DEPEND: $msg" "$ADM_CLR_RESET" ;;
    STEP)  printf "%b%s%b %b%s%b\n" "$ADM_CLR_BOLD" "$head" "$ADM_CLR_RESET" "$ADM_CLR_BLUE"  "Etapa: $msg" "$ADM_CLR_RESET" ;;
    OK)    printf "%b%s%b %b%s%b\n" "$ADM_CLR_BOLD" "$head" "$ADM_CLR_RESET" "$ADM_CLR_GREEN" "${ADM_SYM_OK} $msg" "$ADM_CLR_RESET" ;;
    *)     printf "%b%s%b %s\n"      "$ADM_CLR_BOLD" "$head" "$ADM_CLR_RESET" "$msg" ;;
  esac
}

adm_step() {
  # adm_step <pkg> <version> <title>
  local pkg="${1:-$ADM_LOG_PKG}"; local ver="${2:-$ADM_LOG_VER}"; local title="${3:-}"
  [[ -z "$title" ]] && title="(sem título)"
  adm_log "STEP" "$pkg" "step" "$title"
}

adm_dep() {
  # adm_dep <name> <status: satisfied|missing|optional>
  local name="${1:-}"; local st="${2:-}"
  case "$st" in
    satisfied) adm_log "DEP" "$ADM_LOG_PKG" "dep" "$name    ${ADM_SYM_OK}";;
    optional)  adm_log "DEP" "$ADM_LOG_PKG" "dep" "$name    (opcional)";;
    missing)   adm_log "DEP" "$ADM_LOG_PKG" "dep" "$name    (faltando)";;
    *)         adm_log "DEP" "$ADM_LOG_PKG" "dep" "$name    (estado=$st)";;
  esac
}

adm_ok()   { adm_log "OK"    "$ADM_LOG_PKG" "ok"   "$*"; }
adm_warn() { adm_log "WARN"  "$ADM_LOG_PKG" "warn" "$*"; }
adm_err()  { adm_log "ERROR" "$ADM_LOG_PKG" "err"  "$*"; }

###############################################################################
# Spinner
###############################################################################
adm_spinner_start() {
  # adm_spinner_start "Mensagem inicial"
  local msg="${1:-}"
  if [[ "$ADM_SPINNER_ACTIVE" -eq 1 ]]; then
    return 0
  fi
  [[ -n "$msg" ]] && printf "%b%s%b %s " "$ADM_CLR_BOLD" "$(_adm_escape_pkg_tag "$ADM_LOG_PKG" "$ADM_LOG_CAT" "$ADM_LOG_VER")" "$ADM_CLR_RESET" "$msg"
  (
    # Loop simples de spinner
    while :; do
      printf "."
      sleep 0.25
    done
  ) &
  ADM_SPINNER_PID=$!
  ADM_SPINNER_ACTIVE=1
  disown "$ADM_SPINNER_PID" 2>/dev/null || true
}

adm_spinner__stop() {
  if [[ "$ADM_SPINNER_ACTIVE" -eq 1 && -n "$ADM_SPINNER_PID" ]]; then
    kill "$ADM_SPINNER_PID" 2>/dev/null || true
    wait "$ADM_SPINNER_PID" 2>/dev/null || true
    ADM_SPINNER_ACTIVE=0
    ADM_SPINNER_PID=""
  fi
}

adm_spinner_stop_ok() {
  # adm_spinner_stop_ok "mensagem final"
  local msg="${1:-}"
  adm_spinner__stop
  printf "  %b%s%b\n" "$ADM_CLR_GREEN" "${ADM_SYM_OK} ${msg:-OK}" "$ADM_CLR_RESET"
  adm_ok "${msg:-OK}"
}

adm_spinner_stop_fail() {
  # adm_spinner_stop_fail "mensagem final"
  local msg="${1:-Falha}"
  adm_spinner__stop
  printf "  %b%s%b\n" "$ADM_CLR_RED" "${ADM_SYM_ERR} ${msg}" "$ADM_CLR_RESET"
  adm_err "$msg"
}

###############################################################################
# Execução segura de comandos
###############################################################################
adm_run() {
  # adm_run --tag <nome> -- cmd args...
  local tag="cmd"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag) tag="$2"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  local cmd=( "$@" )
  [[ ${#cmd[@]} -eq 0 ]] && { adm_err "adm_run: nenhum comando fornecido"; return 2; }
  adm__logfile_assert || return 2

  # Executa redirecionando stdout/stderr para o log, e mostra resumo
  adm_log "INFO" "$ADM_LOG_PKG" "$tag" "executando: ${cmd[*]}"
  (
    set -o pipefail
    "${cmd[@]}" >>"$ADM_LOG_CURRENT" 2>&1
  )
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    adm_err "comando falhou (tag=$tag, rc=$rc). Ver log: $ADM_LOG_CURRENT"
  else
    adm_ok  "comando ok (tag=$tag)"
  fi
  return $rc
}

adm_run_retry() {
  # adm_run_retry --retries N --sleep S --tag <nome> -- cmd...
  local retries=3 sleep_s=2 tag="cmd"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --retries) retries="$2"; shift 2 ;;
      --sleep)   sleep_s="$2"; shift 2 ;;
      --tag)     tag="$2"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  local cmd=( "$@" )
  [[ ${#cmd[@]} -eq 0 ]] && { adm_err "adm_run_retry: nenhum comando fornecido"; return 2; }
  local attempt=1
  while :; do
    adm_log "INFO" "$ADM_LOG_PKG" "$tag" "tentativa ${attempt}/${retries}: ${cmd[*]}"
    if adm_run --tag "$tag" -- "${cmd[@]}"; then
      return 0
    fi
    if [[ $attempt -ge $retries ]]; then
      adm_err "todas as tentativas falharam (tag=$tag)"
      return 1
    fi
    adm_warn "${ADM_SYM_RETRY} nova tentativa em ${sleep_s}s (tag=$tag)"
    sleep "$sleep_s"
    attempt=$((attempt+1))
  done
}

adm_capture() {
  # adm_capture <varname> -- cmd...
  local __var="$1"; shift || true
  [[ -z "$__var" ]] && { adm_err "adm_capture: nome de variável não informado"; return 2; }
  [[ "$1" != "--" ]] && { adm_err "adm_capture: uso: adm_capture var -- cmd ..."; return 2; }
  shift
  local out
  adm__logfile_assert || return 2
  out="$(
    set -o pipefail
    "$@" 2>>"$ADM_LOG_CURRENT"
  )"
  local rc=$?
  printf -v "$__var" "%s" "$out"
  if [[ $rc -ne 0 ]]; then
    adm_err "adm_capture: comando falhou (rc=$rc)"
  fi
  return $rc
}

###############################################################################
# Locks (flock)
###############################################################################
adm_lock_acquire() {
  # adm_lock_acquire <name>
  local name="${1:-}"
  [[ -z "$name" ]] && { adm_err "adm_lock_acquire: nome vazio"; return 2; }
  local dir="${ADM_TMP_ROOT}/locks"; _adm_ensure_dir "$dir" || { adm_err "locks: não foi possível criar $dir"; return 3; }
  local file="${dir}/${name}.lock"
  # Abre FD dinâmico
  local fd
  exec {fd}>"$file" || { adm_err "locks: não foi possível abrir $file"; return 3; }
  if ! flock -n "$fd"; then
    adm_err "locks: recurso já bloqueado: $name"
    eval "exec ${fd}>&-"
    return 1
  fi
  __ADM_LOCK_FD["$name"]="$fd"
  adm_ok "lock adquirido: $name"
  return 0
}

adm_lock_release() {
  # adm_lock_release <name>
  local name="${1:-}"
  [[ -z "$name" ]] && { adm_err "adm_lock_release: nome vazio"; return 2; }
  local fd="${__ADM_LOCK_FD[$name]:-}"
  [[ -z "$fd" ]] && { adm_warn "lock '$name' não está adquirido por este processo"; return 0; }
  flock -u "$fd" 2>/dev/null || true
  eval "exec ${fd}>&-"
  unset "__ADM_LOCK_FD[$name]"
  adm_ok "lock liberado: $name"
  return 0
}

adm_with_lock() {
  # adm_with_lock <name> -- cmd...
  local name="${1:-}"
  shift || true
  [[ "$1" != "--" ]] && { adm_err "adm_with_lock: uso: adm_with_lock <name> -- cmd ..."; return 2; }
  shift
  adm_lock_acquire "$name" || return $?
  "$@"
  local rc=$?
  adm_lock_release "$name" || true
  return $rc
}

###############################################################################
# FS helpers
###############################################################################
adm_mktemp_dir() {
  # adm_mktemp_dir <hint>
  local hint="${1:-adm}"
  _adm_ensure_dir "$ADM_TMP_ROOT" || { adm_err "mktemp: não foi possível criar $ADM_TMP_ROOT"; return 3; }
  local d; d="$(mktemp -d "${ADM_TMP_ROOT}/${hint}.XXXXXX" 2>/dev/null)" || true
  if [[ -z "$d" || ! -d "$d" ]]; then
    # fallback
    d="${ADM_TMP_ROOT}/${hint}.${RANDOM}.$(date +%s)"
    mkdir -p -- "$d" || { adm_err "mktemp: falha ao criar diretório"; return 3; }
  fi
  echo "$d"
  return 0
}

adm_path_join() {
  # adm_path_join <base> <relative>
  local base="${1:-}" rel="${2:-}"
  if [[ -z "$base" ]]; then echo "$rel"; return 0; fi
  if [[ -z "$rel" ]]; then echo "$base"; return 0; fi
  case "$rel" in
    /*) echo "$rel" ;;
    *)  echo "${base%/}/$rel" ;;
  esac
}

adm_sanitize_name() {
  # adm_sanitize_name <token>
  local t="${1:-}"
  # mantem [a-z0-9._+-] e converte outros para _
  t="${t,,}"
  t="${t//[^a-z0-9._+-]/_}"
  printf "%s" "$t"
}

adm_write_file() {
  # adm_write_file <path> <content...>
  local path="${1:-}"; shift || true
  [[ -z "$path" ]] && { adm_err "write_file: path vazio"; return 2; }
  local dir; dir="$(dirname -- "$path")"
  _adm_ensure_dir "$dir" || { adm_err "write_file: não foi possível criar dir $dir"; return 3; }
  local tmp="${path}.tmp.$$"
  { printf "%s" "$*"; printf "\n" ; } > "$tmp" 2>/dev/null || { adm_err "write_file: falha escrita tmp"; rm -f -- "$tmp" || true; return 3; }
  mv -f -- "$tmp" "$path" 2>/dev/null || { adm_err "write_file: falha ao mover tmp -> destino"; rm -f -- "$tmp" || true; return 3; }
  return 0
}

adm_append_file() {
  # adm_append_file <path> <content...>
  local path="${1:-}"; shift || true
  [[ -z "$path" ]] && { adm_err "append_file: path vazio"; return 2; }
  local dir; dir="$(dirname -- "$path")"
  _adm_ensure_dir "$dir" || { adm_err "append_file: não foi possível criar dir $dir"; return 3; }
  { printf "%s" "$*"; printf "\n"; } >> "$path" 2>/dev/null || { adm_err "append_file: falha ao escrever em $path"; return 3; }
  return 0
}
# 01-adm-lib.part2.sh
# Continuação: checksum, validações, ambiente, erros, traps e wrappers de UX.
if [[ -n "${ADM_LIB_LOADED_PART2:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_LIB_LOADED_PART2=1

# Conf novamente?
if [[ -z "${ADM_CONF_LOADED:-}" ]]; then
  echo "ERRO: 01-adm-lib.part2 requer 00-adm-config.sh carregado antes." >&2
  return 2 2>/dev/null || exit 2
fi

###############################################################################
# Checksums
###############################################################################
adm_sha256() {
  # adm_sha256 <file> → stdout: hash
  local f="${1:-}"
  [[ -z "$f" ]] && { adm_err "sha256: arquivo não informado"; return 2; }
  [[ ! -f "$f" ]] && { adm_err "sha256: arquivo não existe: $f"; return 3; }
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -b -- "$f" 2>>"$ADM_LOG_CURRENT" | awk '{print $1}'
    return ${PIPESTATUS[0]}
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$f" 2>>"$ADM_LOG_CURRENT" | awk '{print $1}'
    return ${PIPESTATUS[0]}
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -- "$f" 2>>"$ADM_LOG_CURRENT" | awk '{print $2}'
    return ${PIPESTATUS[0]}
  else
    adm_err "sha256: nenhuma ferramenta disponível (sha256sum/shasum/openssl)"
    return 4
  fi
}

adm_verify_sha256() {
  # adm_verify_sha256 <file> <expected>
  local f="${1:-}" exp="${2:-}"
  [[ -z "$f" || -z "$exp" ]] && { adm_err "verify_sha256: uso: adm_verify_sha256 <file> <hash>"; return 2; }
  local got
  if ! got="$(adm_sha256 "$f")"; then
    adm_err "verify_sha256: falhou ao calcular hash"
    return 3
  fi
  if [[ "$got" != "$exp" ]]; then
    adm_err "checksum divergente: got=$got expected=$exp (arquivo=$f)"
    return 1
  fi
  adm_ok "checksum OK ($f)"
  return 0
}

###############################################################################
# Validações
###############################################################################
adm_validate_pkg_ident() {
  # adm_validate_pkg_ident <name>
  local n="${1:-}"
  [[ -z "$n" ]] && { adm_err "validate_pkg_ident: nome vazio"; return 2; }
  local s="${n,,}"
  if [[ "$s" =~ ^[a-z0-9._+-]+$ ]]; then
    return 0
  fi
  adm_err "nome de pacote inválido: '$n' (permitido: [a-z0-9._+-])"
  return 1
}

adm_validate_version() {
  # adm_validate_version <version>
  local v="${1:-}"
  [[ -z "$v" ]] && { adm_err "validate_version: versão vazia"; return 2; }
  if [[ "$v" =~ [[:space:]]|, ]]; then
    adm_err "versão inválida (espaços/vírgulas não permitidos): '$v'"
    return 1
  fi
  return 0
}

adm_validate_in_list() {
  # adm_validate_in_list <value> "<list space sep>"
  local val="${1:-}" list="${2:-}"
  local x
  for x in $list; do
    [[ "$x" == "$val" ]] && return 0
  done
  return 1
}

###############################################################################
# Políticas e ambiente
###############################################################################
adm_require_root_if_needed() {
  # Se ADM_REQUIRE_ROOT=true e destino for '/', exigir uid 0
  local dest="${DESTDIR:-$ADM_SYS_PREFIX}"
  if [[ "${ADM_REQUIRE_ROOT}" == "true" ]]; then
    if [[ "${dest:-/}" == "/" && "${EUID:-$(id -u)}" -ne 0 ]]; then
      adm_err "permissão: instalação em '/' requer root; use DESTDIR para testes ou rode como root"
      return 5
    fi
  fi
  return 0
}

adm_export_build_env() {
  # adm_export_build_env <profile> <pkg> <category> <version> <destdir>
  local profile="${1:-$ADM_PROFILE_DEFAULT}" pkg="${2:-}" cat="${3:-}" ver="${4:-}" dest="${5:-${DESTDIR:-}}"
  [[ -z "$pkg" || -z "$ver" ]] && { adm_err "export_build_env: pkg e version são obrigatórios"; return 2; }
  if ! adm_validate_in_list "$profile" "$ADM_PROFILES"; then
    adm_warn "perfil inválido '$profile' → usando default '$ADM_PROFILE_DEFAULT'"
    profile="$ADM_PROFILE_DEFAULT"
  fi
  export PKG_NAME="$pkg"
  export PKG_VERSION="$ver"
  export PKG_CATEGORY="$cat"
  export PROFILE="$profile"
  export DESTDIR="$dest"
  export LOGFILE="$ADM_LOG_CURRENT"
  # Exporta alguns caminhos úteis
  export ADM_ROOT ADM_CACHE_ROOT ADM_CACHE_SOURCES ADM_CACHE_TARBALLS ADM_LOG_ROOT ADM_TMP_ROOT ADM_SYS_PREFIX
  adm_ok "ambiente de build exportado (profile=$profile, destdir=${DESTDIR:--})"
  return 0
}

###############################################################################
# Erros e traps
###############################################################################
adm_die() {
  # adm_die <code> "mensagem..."
  local code="${1:-1}"; shift || true
  local msg="${*:-fatal}"
  adm_err "$msg"
  adm_spinner__stop
  # Libera locks que tenham sido adquiridos
  if ((${#__ADM_LOCK_FD[@]})); then
    local __k __fd
    for __k in "${!__ADM_LOCK_FD[@]}"; do
      __fd="${__ADM_LOCK_FD[$__k]}"
      flock -u "$__fd" 2>/dev/null || true
      eval "exec ${__fd}>&-"
      unset "__ADM_LOCK_FD[$__k]"
    done
  fi

  # Se estivermos sendo 'source'-ados, preferir return; caso contrário exit
  return "$code" 2>/dev/null || exit "$code"
}

adm_trap__handler() {
  local sig="$1"
  adm_err "interrompido por sinal: $sig"
  adm_spinner__stop
  # liberar locks
  if ((${#__ADM_LOCK_FD[@]})); then
    local __k __fd
    for __k in "${!__ADM_LOCK_FD[@]}"; do
      __fd="${__ADM_LOCK_FD[$__k]}"
      flock -u "$__fd" 2>/dev/null || true
      eval "exec ${__fd}>&-"
      unset "__ADM_LOCK_FD[$__k]"
    done
  fi
}

adm_trap_init() {
  trap 'adm_trap__handler INT;  adm_die 130 "interrompido (SIGINT)"' INT
  trap 'adm_trap__handler TERM; adm_die 143 "terminado (SIGTERM)"' TERM
  trap 'adm_trap__handler HUP;  adm_die 129 "terminado (SIGHUP)"' HUP
  adm_ok "traps instalados"
}

###############################################################################
# UX helpers de alto nível
###############################################################################
adm_with_spinner() {
  # adm_with_spinner "Mensagem..." -- cmd args...
  local msg="${1:-}"; shift || true
  [[ "$1" != "--" ]] && { adm_err "adm_with_spinner: uso: adm_with_spinner \"msg\" -- cmd ..."; return 2; }
  shift
  adm_spinner_start "$msg"
  (
    set -o pipefail
    "$@" >>"$ADM_LOG_CURRENT" 2>&1
  )
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    adm_spinner_stop_ok "$msg"
  else
    adm_spinner_stop_fail "$msg"
  fi
  return $rc
}

###############################################################################
# Marcar como carregado
###############################################################################
ADM_LIB_LOADED=1
export ADM_LIB_LOADED
