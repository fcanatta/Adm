#!/usr/bin/env sh
# adm-log.sh — Biblioteca de logging para o sistema ADM
# Compatível com sh/dash/ash/bash. Sem dependências externas obrigatórias.
# =========================
# 0) Configuração padrão
# =========================
: "${ADM_LOG_LEVEL:=INFO}"              # TRACE|DEBUG|INFO|WARN|ERROR|FATAL
: "${ADM_LOG_FILE_MIN_LEVEL:=TRACE}"
: "${ADM_LOG_FORMAT:=human}"            # human | json | human+json
: "${ADM_LOG_COLOR:=auto}"              # auto | always | never
: "${ADM_LOG_DIR:=/usr/src/adm/logs}"
: "${ADM_LOG_TIME_FMT:=iso8601}"        # iso8601 | epoch_ms
: "${ADM_QUIET:=0}"                     # 1 para silenciar tela
: "${ADM_VERBOSE:=0}"                   # 1 eleva nível para DEBUG
: "${ADM_TRACE:=0}"                     # 1 eleva nível para TRACE
: "${ADM_LOG_MAX_SIZE:=0}"              # 0 = sem rotação por tamanho
# Contexto (podem ser definidos externamente)
: "${ADM_STAGE:=}"          # host|stage0|stage1|stage2
: "${ADM_CHROOT:=}"         # nome do chroot
: "${ADM_PROFILE:=}"        # minimal|normal|aggressive
: "${ADM_PIPELINE:=}"       # fetch|detect|resolve|build|install|pack|uninstall|update|kinit|clean
: "${ADM_PKG_NAME:=}"       # nome do pacote atual
: "${ADM_PKG_VERSION:=}"    # versão do pacote
: "${ADM_PKG_CATEGORY:=}"   # categoria do pacote
: "${ADM_PKG_DIR:=}"        # caminho da árvore do programa (se vazio, usa $PWD)
# =========================
# 1) Estado interno
# =========================
_adm_log_initialized=0
_adm_log_tty=0
_adm_log_color_enable=0
_adm_log_scope=""
_adm_log_file=""
_adm_log_json_file=""
_adm_log_masks=""      # lista separada por | (regex simples de substituição literal)
# =========================
# 2) Utilidades
# =========================
_adm_log_is_tty() {
  [ -t 1 ] && return 0 || return 1
}

# Mapa de níveis para número
_adm_log_level_num() {
  case "$1" in
    TRACE) echo 10;;
    DEBUG) echo 20;;
    INFO)  echo 30;;
    WARN)  echo 40;;
    ERROR) echo 50;;
    FATAL) echo 60;;
    OK)    echo 25;; # especial
    STEP)  echo 28;; # especial
    *)     echo 999;;
  esac
}

# Comparar níveis (retorna 0 se level_a >= level_b)
_adm_log_level_ge() {
  la=$(_adm_log_level_num "$1")
  lb=$(_adm_log_level_num "$2")
  [ "$la" -ge "$lb" ]
}

# Timestamp
_adm_log_ts() {
  if [ "$ADM_LOG_TIME_FMT" = "epoch_ms" ]; then
    # POSIX sh: sem %N, então multiplicamos por mil via awk (fallback)
    date +%s | awk '{printf "%d000\n",$1}'
  else
    # ISO 8601 com timezone
    date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([0-9][0-9]\)$/:\1/'
  fi
}

# Sanitização básica de strings para JSON
_adm_json_escape() {
  # substitui \ por \\ ; " por \" ; nova linha por \n ; tab por \t
  printf "%s" "$1" | \
    sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | awk 'BEGIN{RS="\r";ORS=""}{gsub(/\n/,"\\n");print}'
}

# Cores
# Rosa (magenta) em negrito para estágio; amarelo em negrito para caminho
_adm_color_setup() {
  if [ "$ADM_LOG_COLOR" = "never" ] || [ "$TERM" = "dumb" ] || [ -n "$NO_COLOR" ]; then
    _adm_log_color_enable=0
    return
  fi
  if [ "$ADM_LOG_COLOR" = "always" ] || _adm_log_is_tty; then
    _adm_log_color_enable=1
  else
    _adm_log_color_enable=0
  fi
}

# Paleta
_adm_c_reset() { [ "$_adm_log_color_enable" -eq 1 ] && printf "\033[0m"; }
_adm_c_bold()  { [ "$_adm_log_color_enable" -eq 1 ] && printf "\033[1m"; }
_adm_c_dim()   { [ "$_adm_log_color_enable" -eq 1 ] && printf "\033[2m"; }

_adm_c_level() {
  # retorna código de cor por nível (sem reset)
  if [ "$_adm_log_color_enable" -ne 1 ]; then return; fi
  case "$1" in
    TRACE) printf "\033[38;5;246m";; # cinza
    DEBUG) printf "\033[36m";;       # ciano
    INFO)  printf "\033[32m";;       # verde
    WARN)  printf "\033[33m";;       # amarelo
    ERROR) printf "\033[31m";;       # vermelho
    FATAL) printf "\033[97;41m";;    # branco c/ fundo vermelho
    STEP)  printf "\033[35m";;       # magenta
    OK)    printf "\033[32;1m";;     # verde bold
    *)     printf "\033[0m";;
  esac
}

_adm_c_stage()  { [ "$_adm_log_color_enable" -eq 1 ] && printf "\033[35;1m"; }  # rosa/magenta bold
_adm_c_path()   { [ "$_adm_log_color_enable" -eq 1 ] && printf "\033[33;1m"; }  # amarelo bold
_adm_c_scope()  { [ "$_adm_log_color_enable" -eq 1 ] && printf "\033[38;5;244m"; } # cinza claro

# Máscara de segredos simples (substituição literal)
_adm_apply_masks() {
  _msg="$1"
  IFS='|' ; set -- $_adm_log_masks ; IFS=' '
  for pattern in "$@"; do
    [ -n "$pattern" ] || continue
    _msg=$(printf "%s" "$_msg" | sed "s/${pattern}/***MASK***/g")
  done
  printf "%s" "$_msg"
}

# =========================
# 3) Inicialização & arquivos
# =========================

adm_log_init() {
  # Eleva nível se verbose/trace
  if [ "$ADM_TRACE" -eq 1 ]; then ADM_LOG_LEVEL=TRACE; fi
  if [ "$ADM_VERBOSE" -eq 1 ] && ! _adm_log_level_ge "$ADM_LOG_LEVEL" DEBUG; then ADM_LOG_LEVEL=DEBUG; fi

  _adm_log_tty=0
  if _adm_log_is_tty; then _adm_log_tty=1; fi
  _adm_color_setup

  # Diretórios
  _today="$(date +%F 2>/dev/null || echo today)"
  _base="$ADM_LOG_DIR"
  [ -d "$_base" ] || mkdir -p "$_base" 2>/dev/null || true

  # Subdir por pipeline (fallback build)
  _sub="${ADM_PIPELINE:-build}"
  _dir="$_base/$_sub/$_today"
  [ -d "$_dir" ] || mkdir -p "$_dir" 2>/dev/null || true

  # Nome de arquivo por pacote/versão
  _pkg="${ADM_PKG_NAME:-session}"
  _ver="${ADM_PKG_VERSION:-0}"
  _adm_log_file="$_dir/${_pkg}@${_ver}.log"

  # JSON opcional
  case "$ADM_LOG_FORMAT" in
    *json*) _adm_log_json_file="$_dir/${_pkg}@${_ver}.jsonl";;
    *) _adm_log_json_file="";;
  esac

  _adm_log_initialized=1

  # Traps para erros e sinais
  trap '_adm_trap_err $LINENO' ERR
  trap '_adm_trap_sig INT' INT
  trap '_adm_trap_sig TERM' TERM

  # Cabeçalho
  adm_log_section "ADM LOG INIT"
  adm_log_info "log_dir=$_dir file=$_adm_log_file format=$ADM_LOG_FORMAT tty=$_adm_log_tty color=$_adm_log_color_enable"
}

_adm_trap_err() {
  _line="$1"
  adm_log_error "Trap ERR at line=${_line} (last rc=$?) in script=${0##*/}"
}

_adm_trap_sig() {
  _sig="$1"
  adm_log_warn "Signal caught: ${_sig} — attempting graceful shutdown"
}

# =========================
# 4) Contexto & scope
# =========================

adm_log_set_context() {
  # uso: adm_log_set_context key value
  _k="$1"; shift
  _v="$*"
  case "$_k" in
    stage) ADM_STAGE="$_v";;
    chroot) ADM_CHROOT="$_v";;
    profile) ADM_PROFILE="$_v";;
    pkg) ADM_PKG_NAME="$_v";;
    version) ADM_PKG_VERSION="$_v";;
    category) ADM_PKG_CATEGORY="$_v";;
    pipeline) ADM_PIPELINE="$_v";;
    pkgdir) ADM_PKG_DIR="$_v";;
    *) :;;
  esac
}

adm_log_scope_push() {
  [ -n "$1" ] || return 0
  if [ -z "$_adm_log_scope" ]; then
    _adm_log_scope="$1"
  else
    _adm_log_scope="$_adm_log_scope/$1"
  fi
}

adm_log_scope_pop() {
  # remove o último elemento
  case "$_adm_log_scope" in
    */*) _adm_log_scope="${_adm_log_scope%/*}";;
    *) _adm_log_scope="";;
  esac
}

adm_log_section() {
  _title="$*"
  _rule="============================================================="
  _ts="$(_adm_log_ts)"
  if [ "$_adm_log_color_enable" -eq 1 ] && [ "$ADM_QUIET" -ne 1 ]; then
    printf "%s\n" "$_rule"
    printf "%s" "$(_adm_c_bold)"; printf "[%s] " "$_ts"; _adm_c_reset
    printf "%s" "$(_adm_c_scope)"; printf "%s" "$_title"; _adm_c_reset
    printf "\n%s\n" "$_rule"
  else
    [ "$ADM_QUIET" -ne 1 ] && printf "%s [%s] %s\n%s\n" "$_rule" "$_ts" "$_title" "$_rule"
  fi
  # arquivo
  printf "%s [%s] %s\n%s\n" "$_rule" "$_ts" "$_title" "$_rule" >>"$_adm_log_file" 2>/dev/null || true
}

# =========================
# 5) Formatação de linha
# =========================

_adm_format_context_human() {
  # Estágio destacado em rosa negrito
  _stage="${ADM_STAGE:-host}"
  _chroot="${ADM_CHROOT:-}"
  _profile="${ADM_PROFILE:-}"
  _pipeline="${ADM_PIPELINE:-}"
  _pkg="${ADM_PKG_NAME:-}"
  _ver="${ADM_PKG_VERSION:-}"
  _cat="${ADM_PKG_CATEGORY:-}"

  # Caminho do diretório do programa (amarelo bold). Usa $ADM_PKG_DIR, senão $PWD.
  _path="${ADM_PKG_DIR:-$PWD}"

  if [ "$_adm_log_color_enable" -eq 1 ]; then
    _ctx="("
    _ctx="$_ctx$(_adm_c_stage)${_stage}$(_adm_c_reset)"
    [ -n "$_pipeline" ] && _ctx="$_ctx:$(_adm_c_scope)${_pipeline}$(_adm_c_reset)"
    [ -n "$_pkg" ] && _ctx="$_ctx ${_pkg}"
    [ -n "$_ver" ] && _ctx="$_ctx@${_ver}"
    [ -n "$_cat" ] && _ctx="$_ctx ${_cat}"
    [ -n "$_profile" ] && _ctx="$_ctx profile=${_profile}"
    [ -n "$_chroot" ] && _ctx="$_ctx chroot=${_chroot}"
    _ctx="$_ctx path=$(_adm_c_path)${_path}$(_adm_c_reset)"
    [ -n "$_adm_log_scope" ] && _ctx="$_ctx scope=$(_adm_c_scope)${_adm_log_scope}$(_adm_c_reset)"
    _ctx="$_ctx)"
    printf "%s" "$_ctx"
  else
    _ctx="($_stage"
    [ -n "$_pipeline" ] && _ctx="$_ctx:${_pipeline}"
    [ -n "$_pkg" ] && _ctx="$_ctx ${_pkg}"
    [ -n "$_ver" ] && _ctx="$_ctx@${_ver}"
    [ -n "$_cat" ] && _ctx="$_ctx ${_cat}"
    [ -n "$_profile" ] && _ctx="$_ctx profile=${_profile}"
    [ -n "$_chroot" ] && _ctx="$_ctx chroot=${_chroot}"
    _ctx="$_ctx path=${_path}"
    [ -n "$_adm_log_scope" ] && _ctx="$_ctx scope=${_adm_log_scope}"
    _ctx="$_ctx)"
    printf "%s" "$_ctx"
  fi
}

_adm_format_line_human() {
  _ts="$1"; _lvl="$2"; shift 2
  _msg="$*"
  _msg=$(_adm_apply_masks "$_msg")
  # Cabeçalho com cor do nível
  if [ "$_adm_log_color_enable" -eq 1 ]; then
    _lvlc="$(_adm_c_level "$_lvl")"
    _bold="$(_adm_c_bold)"
    _rst="$(_adm_c_reset)"
    printf "%s[%s]%s %s%-5s%s %s %s\n" \
      "$_bold" "$_ts" "$_rst" "$_lvlc" "$_lvl" "$_rst" "$(_adm_format_context_human)" "$_msg"
  else
    printf "[%s] %-5s %s %s\n" "$_ts" "$_lvl" "$(_adm_format_context_human)" "$_msg"
  fi
}

_adm_format_line_file() {
  _ts="$1"; _lvl="$2"; shift 2
  _msg="$*"
  _msg=$(_adm_apply_masks "$_msg")
  printf "[%s] %-5s %s %s\n" "$_ts" "$_lvl" "$(_adm_format_context_human | sed 's/\x1b\[[0-9;]*m//g')" "$_msg"
}

_adm_write_json() {
  [ -n "$_adm_log_json_file" ] || return 0
  _ts="$1"; _lvl="$2"; _msg="$3"
  _msg=$(_adm_apply_masks "$_msg")
  _json_msg=$(_adm_json_escape "$_msg")
  _path="${ADM_PKG_DIR:-$PWD}"

  printf '{' > /tmp/.adm_json_line.$$
  printf '"ts":"%s",' "$(_adm_json_escape "$_ts")" >> /tmp/.adm_json_line.$$
  printf '"level":"%s",' "$_lvl" >> /tmp/.adm_json_line.$$
  printf '"stage":"%s",' "$(_adm_json_escape "${ADM_STAGE:-host}")" >> /tmp/.adm_json_line.$$
  printf '"pipeline":"%s",' "$(_adm_json_escape "${ADM_PIPELINE:-}")" >> /tmp/.adm_json_line.$$
  printf '"pkg":"%s",' "$(_adm_json_escape "${ADM_PKG_NAME:-}")" >> /tmp/.adm_json_line.$$
  printf '"version":"%s",' "$(_adm_json_escape "${ADM_PKG_VERSION:-}")" >> /tmp/.adm_json_line.$$
  printf '"category":"%s",' "$(_adm_json_escape "${ADM_PKG_CATEGORY:-}")" >> /tmp/.adm_json_line.$$
  printf '"profile":"%s",' "$(_adm_json_escape "${ADM_PROFILE:-}")" >> /tmp/.adm_json_line.$$
  printf '"chroot":"%s",' "$(_adm_json_escape "${ADM_CHROOT:-}")" >> /tmp/.adm_json_line.$$
  printf '"path":"%s",' "$(_adm_json_escape "$_path")" >> /tmp/.adm_json_line.$$
  printf '"scope":"%s",' "$(_adm_json_escape "$_adm_log_scope")" >> /tmp/.adm_json_line.$$
  printf '"pid":%d,' "$$" >> /tmp/.adm_json_line.$$
  printf '"msg":"%s"' "$_json_msg" >> /tmp/.adm_json_line.$$
  printf '}\n' >> /tmp/.adm_json_line.$$

  cat /tmp/.adm_json_line.$$ >>"$_adm_log_json_file" 2>/dev/null || true
  rm -f /tmp/.adm_json_line.$$ 2>/dev/null || true
}

# =========================
# 6) Emissão (tela + arquivo)
# =========================

_adm_emit() {
  _lvl="$1"; shift
  _ts="$(_adm_log_ts)"
  _line_human="$(_adm_format_line_human "$_ts" "$_lvl" "$*")"
  _line_file="$(_adm_format_line_file "$_ts" "$_lvl" "$*")"

  # Tela (se não quiet e nível >= ADM_LOG_LEVEL)
  if [ "$ADM_QUIET" -ne 1 ] && _adm_log_level_ge "$_lvl" "$ADM_LOG_LEVEL"; then
    printf "%s" "$_line_human"
  fi

  # Arquivo (sempre que nível >= ADM_LOG_FILE_MIN_LEVEL)
  [ -n "$_adm_log_file" ] || return 0
  if _adm_log_level_ge "$_lvl" "$ADM_LOG_FILE_MIN_LEVEL"; then
    # Rotação simples por tamanho
    if [ "$ADM_LOG_MAX_SIZE" -gt 0 ] && [ -f "$_adm_log_file" ]; then
      _sz=$(wc -c < "$_adm_log_file" 2>/dev/null || echo 0)
      if [ "$_sz" -gt "$ADM_LOG_MAX_SIZE" ]; then
        mv -f "$_adm_log_file" "${_adm_log_file%.log}.1.log" 2>/dev/null || true
      fi
    fi
    printf "%s" "$_line_file" >>"$_adm_log_file" 2>/dev/null || true
  fi

  # JSON opcional
  case "$ADM_LOG_FORMAT" in
    *json*) _adm_write_json "$_ts" "$_lvl" "$*";;
    *) :;;
  esac
}

# =========================
# 7) API de nível
# =========================

adm_log_trace() { _adm_emit TRACE "$*"; }
adm_log_debug() { _adm_emit DEBUG "$*"; }
adm_log_info()  { _adm_emit INFO  "$*"; }
adm_log_warn()  { _adm_emit WARN  "$*"; }
adm_log_error() { _adm_emit ERROR "$*"; return 1; }

adm_log_fatal() {
  _msg="$1"; _code="${2:-1}"
  _adm_emit FATAL "$_msg"
  exit "$_code"
}

adm_log_step_start() {
  _adm_step_desc="$*"
  _adm_step_id=$(_adm_step_id_next)
  _adm_timer_store "step_${_adm_step_id}" "$(_adm_now_ms)"
  _adm_emit STEP "BEGIN: ${_adm_step_desc}"
  # retorna id via echo para encadear
  echo "$_adm_step_id"
}

adm_log_step_ok() {
  _adm_emit OK "OK: ${_adm_step_desc:-step}"
}
adm_log_step_warn() {
  _adm_emit WARN "WARN: ${_adm_step_desc:-step}"
}
adm_log_step_error() {
  _adm_emit ERROR "ERROR: ${_adm_step_desc:-step}"
}

# =========================
# 8) Timers
# =========================

_adm_now_ms() {
  # Aproximação portátil
  date +%s | awk '{printf "%d000\n",$1}'
}

_adm_timer_store() {
  # key, value
  eval "ADM_TIMER_$1=$2"
}

_adm_timer_read() {
  # key -> echo value
  eval "printf \"%s\" \"\$ADM_TIMER_$1\""
}

_adm_step_id_next() {
  : "${ADM_STEP_SEQ:=0}"
  ADM_STEP_SEQ=$((ADM_STEP_SEQ+1))
  printf "%s" "$ADM_STEP_SEQ"
}

adm_log_timer_start() {
  _id="$1"
  [ -n "$_id" ] || { adm_log_error "timer_start: missing id"; return 1; }
  _adm_timer_store "$_id" "$(_adm_now_ms)"
  adm_log_debug "timer_start id=${_id}"
}

adm_log_timer_end() {
  _id="$1"
  [ -n "$_id" ] || { adm_log_error "timer_end: missing id"; return 1; }
  _start="$(_adm_timer_read "$_id")"
  [ -n "$_start" ] || { adm_log_warn "timer_end: id=${_id} not started"; return 1; }
  _end="$(_adm_now_ms)"
  _dur=$((_end - _start))
  _adm_emit INFO "timer: id=${_id} duration_ms=${_dur}"
}

# =========================
# 9) Exec wrapper + máscaras
# =========================

adm_log_mask() {
  # adicionar padrão literal (separação por |)
  _p="$*"
  [ -n "$_p" ] || return 0
  if [ -z "$_adm_log_masks" ]; then
    _adm_log_masks="$_p"
  else
    _adm_log_masks="$_adm_log_masks|$_p"
  fi
}

adm_log_exec() {
  # Executa comando com log de início/fim e RC
  # Uso: adm_log_exec comando arg1 arg2 ...
  [ $# -gt 0 ] || { adm_log_error "exec: missing command"; return 127; }
  _cmd="$*"
  _masked=$(_adm_apply_masks "$_cmd")

  _id="exec_$(_adm_step_id_next)"
  _start="$(_adm_now_ms)"
  _adm_emit STEP "EXEC BEGIN: ${_masked}"

  # Executa sem mascarar no shell (precisa do real)
  # shellcheck disable=SC2086
  "$@"
  _rc=$?

  _end="$(_adm_now_ms)"
  _dur=$((_end - _start))
  if [ $_rc -eq 0 ]; then
    _adm_emit OK "EXEC OK rc=0 duration_ms=${_dur} cmd=${_masked}"
  else
    _adm_emit ERROR "EXEC FAIL rc=${_rc} duration_ms=${_dur} cmd=${_masked}"
  fi
  return $_rc
}

# =========================
# 10) Fechamento
# =========================

adm_log_close() {
  adm_log_info "closing logs"
  # nada crítico a fechar; placeholder para flush futuro
}

# =========================
# 11) Auto-init opcional
# =========================
# Permite que o script seja 'sourced' e usado imediatamente
if [ "${ADM_LOG_AUTO_INIT:-1}" -eq 1 ] && [ "$_adm_log_initialized" -eq 0 ]; then
  adm_log_init
fi
