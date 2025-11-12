#!/usr/bin/env bash
# 00.20-safety-locks-sandbox.sh
# Segurança, locks e sandbox para o ADM.
# Local: /usr/src/adm/scripts/00.20-safety-locks-sandbox.sh
###############################################################################
# Modo estrito + tratamento de erros
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_LOCK_DIR="${ADM_LOCK_DIR:-${ADM_STATE_DIR}/locks}"
ADM_PID_DIR="${ADM_PID_DIR:-${ADM_STATE_DIR}/pids}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"

# Cores (fallback se não houver 00.10 carregado)
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  ADM_COLOR_RST="$(tput sgr0)"; ADM_COLOR_OK="$(tput setaf 2)"; ADM_COLOR_WRN="$(tput setaf 3)"
  ADM_COLOR_ERR="$(tput setaf 1)"; ADM_COLOR_INF="$(tput setaf 6)"
else
  ADM_COLOR_RST=""; ADM_COLOR_OK=""; ADM_COLOR_WRN=""; ADM_COLOR_ERR=""; ADM_COLOR_INF=""
fi

adm_info() { echo -e "${ADM_COLOR_INF}[ADM]${ADM_COLOR_RST} $*"; }
adm_ok()   { echo -e "${ADM_COLOR_OK}[OK ]${ADM_COLOR_RST} $*"; }
adm_warn() { echo -e "${ADM_COLOR_WRN}[WAR]${ADM_COLOR_RST} $*" 1>&2; }
adm_err()  { echo -e "${ADM_COLOR_ERR}[ERR]${ADM_COLOR_RST} $*" 1>&2; }

__adm_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  adm_err "Falha: código=${code} linha=${line} função=${func}"
  exit "$code"
}
trap __adm_err_trap ERR

###############################################################################
# Utilidades
###############################################################################
adm_is_cmd() { command -v "$1" >/dev/null 2>&1; }

adm_require_cmds() {
  local miss=()
  for c in "$@"; do adm_is_cmd "$c" || miss+=("$c"); done
  if ((${#miss[@]})); then
    adm_err "Ferramentas ausentes: ${miss[*]}"
    exit 10
  fi
}

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

safe_rm() {
  # Remove com guarda anti-catástrofe
  local p="$1"
  [[ -n "$p" ]] || { adm_err "safe_rm: caminho vazio"; exit 11; }
  [[ "$p" == "/" ]] && { adm_err "safe_rm: recusa remover /"; exit 12; }
  [[ "$p" =~ ^/ ]] || { adm_err "safe_rm: caminho deve ser absoluto: $p"; exit 13; }
  rm -rf --one-file-system -- "$p"
}

###############################################################################
# Inicialização de segurança
###############################################################################
adm_safety_init() {
  __adm_ensure_dir "$ADM_STATE_DIR" 0755 root root
  __adm_ensure_dir "$ADM_LOCK_DIR"  0755 root root
  __adm_ensure_dir "$ADM_PID_DIR"   0755 root root
  __adm_ensure_dir "$ADM_TMPDIR"    0755 root root

  # arquivos special
  : "${ADM_LOCK_TIMEOUT:=900}"      # 15 min default
  : "${ADM_SANDBOX_MODE:=auto}"     # auto|bwrap|chroot|none
  : "${ADM_MIN_DISK_MB:=512}"       # mínimo livre p/ continuar
  : "${ADM_TIMEOUT_CMD:=timeout}"   # comando de timeout se existir

  # validação de timeout
  if ! adm_is_cmd "${ADM_TIMEOUT_CMD}"; then
    ADM_TIMEOUT_CMD="" # desativa timeout externo
  fi

  adm_ok "Safety inicializado. locks=${ADM_LOCK_DIR} pids=${ADM_PID_DIR} tmp=${ADM_TMPDIR}"
}

###############################################################################
# Locks com flock (por tipo e chave)
###############################################################################
__adm_lock_file() {
  local type="$1" key="$2"
  echo "${ADM_LOCK_DIR}/${type}.${key}.lock"
}
__adm_pid_file() {
  local type="$1" key="$2"
  echo "${ADM_PID_DIR}/${type}.${key}.pid"
}

adm_lock_acquire() {
  # uso: adm_lock_acquire <tipo> <chave> [timeout_seg]
  local type="${1:?tipo}" key="${2:?chave}" to="${3:-$ADM_LOCK_TIMEOUT}"
  local lf pf fd
  lf="$(__adm_lock_file "$type" "$key")"
  pf="$(__adm_pid_file "$type" "$key")"

  # Garante arquivo e descritor
  __adm_ensure_dir "$(dirname "$lf")"
  : > "$lf" || { adm_err "Não foi possível tocar lockfile: $lf"; exit 20; }

  # abre fd dinamicamente
  exec {fd}>"$lf" || { adm_err "Falha abrindo lockfile FD: $lf"; exit 21; }

  # tenta adquirir com timeout
  local end=$((SECONDS+to))
  while ! flock -n "$fd"; do
    if (( SECONDS >= end )); then
      adm_err "Timeout adquirindo lock: ${type}/${key}"
      exit 22
    fi
    sleep 0.2
  done

  # registra PID
  echo "$$" > "$pf"

  # registra trap para liberar lock
  local rel_fn="__adm_release_${type}_${key//[^A-Za-z0-9_]/_}_$fd"
  eval "${rel_fn}() { flock -u $fd; rm -f '$pf' || true; }"
  trap "${rel_fn}" EXIT

  adm_ok "Lock adquirido: ${type}/${key}"
  # retorna o FD em stdout (p/ quem quiser manter manualmente)
  echo "$fd"
}

adm_lock_release() {
  # uso: adm_lock_release <tipo> <chave> <fd-opcional>
  local type="${1:?tipo}" key="${2:?chave}" fd="${3:-}"
  local lf pf
  lf="$(__adm_lock_file "$type" "$key")"
  pf="$(__adm_pid_file "$type" "$key")"

  if [[ -n "$fd" ]]; then
    flock -u "$fd" 2>/dev/null || true
  fi
  rm -f -- "$pf" 2>/dev/null || true
  # Não removemos o lockfile para evitar TOCTOU; manter vazio é ok
  adm_ok "Lock liberado: ${type}/${key}"
}

adm_lock_is_held() {
  # uso: adm_lock_is_held <tipo> <chave> → exit 0 se detido
  local type="${1:?tipo}" key="${2:?chave}"
  local lf="$(__adm_lock_file "$type" "$key")"
  [[ -e "$lf" ]] || return 1
  # tenta adquirir non-block, se conseguir não estava detido
  exec {fd}>"$lf" || return 1
  if flock -n "$fd"; then
    flock -u "$fd"
    return 1
  fi
  return 0
}

###############################################################################
# Checagens de disco/tempo
###############################################################################
adm_check_disk() {
  # uso: adm_check_disk <path> [min_mb]
  local path="${1:?path}" need="${2:-$ADM_MIN_DISK_MB}"
  local avail
  avail=$(df -Pm "$path" 2>/dev/null | awk 'NR==2{print $4}')
  if ! [[ "$avail" =~ ^[0-9]+$ ]]; then
    adm_warn "Não foi possível determinar espaço livre em $path"
    return 0
  fi
  if (( avail < need )); then
    adm_err "Espaço insuficiente em $path: ${avail}MiB < ${need}MiB"
    exit 30
  fi
  adm_ok "Espaço OK em $path: ${avail}MiB (mín ${need}MiB)"
}

adm_with_timeout() {
  # uso: adm_with_timeout <segundos> -- comando args...
  local secs="${1:?segundos}"; shift
  if [[ -n "${ADM_TIMEOUT_CMD}" ]]; then
    "${ADM_TIMEOUT_CMD}" --preserve-status --signal=TERM "$secs" "$@"
  else
    # Sem timeout disponível: avisa e executa assim mesmo
    adm_warn "timeout indisponível; executando sem limite: $*"
    "$@"
  fi
}

###############################################################################
# Sandbox: detecção e helpers
###############################################################################
__adm_sandbox_detect_mode() {
  local want="${ADM_SANDBOX_MODE:-auto}"
  case "$want" in
    bwrap)
      adm_is_cmd bwrap && { echo bwrap; return; }
      adm_warn "bubblewrap não disponível; fallback para chroot"
      want="chroot"
      ;;&
    chroot)
      [[ $EUID -eq 0 ]] && { echo chroot; return; }
      adm_warn "chroot requer root; fallback para none"
      want="none"
      ;;&
    none)
      echo none; return
      ;;
    auto|*)
      if adm_is_cmd bwrap; then echo bwrap
      elif [[ $EUID -eq 0 ]]; then echo chroot
      else echo none
      fi
      ;;
  esac
}

__adm_bind_args_bwrap() {
  # Constrói args bwrap de bind mounts
  # uso: __adm_bind_args_bwrap <root> <rw|ro>:host:guest ...
  local root="$1"; shift
  local args=( "--bind" "$root" "/" )
  local spec s m h g mode

  # /dev, /proc, /sys básicos
  args+=( --dev-bind /dev /dev --proc /proc --ro-bind /sys /sys )

  for spec in "$@"; do
    IFS=':' read -r mode h g <<< "$spec"
    [[ -n "$h" && -n "$g" ]] || { adm_err "bind inválido: $spec"; exit 40; }
    case "$mode" in
      rw) args+=( --bind "$h" "$g" ) ;;
      ro) args+=( --ro-bind "$h" "$g" ) ;;
      *)  adm_err "modo de bind inválido (use rw|ro): $spec"; exit 41 ;;
    esac
  done
  printf '%s\0' "${args[@]}"
}

__adm_env_sanitize() {
  # Minimiza variáveis para sandbox (pode ser expandido depois)
  env -i \
    HOME="${HOME:-/root}" \
    PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}" \
    LANG="${LANG:-C.UTF-8}" \
    LC_ALL="${LC_ALL:-$LANG}" \
    TZ="${TZ:-UTC}" \
    "$@"
}
###############################################################################
# Execução em sandbox
###############################################################################
adm_sandbox_exec() {
  # uso:
  #   adm_sandbox_exec --root <dir> [--mode auto|bwrap|chroot|none]
  #                    [--bind rw:/host:/guest ...] [--timeout S]
  #                    -- comando args...
  local root="" mode="" timeout_s=""
  local binds=()
  while (($#)); do
    case "$1" in
      --root)    root="${2:-}"; shift 2 ;;
      --mode)    mode="${2:-}"; shift 2 ;;
      --bind)    binds+=("$2"); shift 2 ;;
      --timeout) timeout_s="${2:-}"; shift 2 ;;
      --)        shift; break ;;
      *) adm_err "adm_sandbox_exec: opção inválida: $1"; exit 50 ;;
    esac
  done
  [[ -n "$root" ]] || { adm_err "adm_sandbox_exec: --root é obrigatório"; exit 51; }
  [[ -d "$root" ]] || { adm_err "adm_sandbox_exec: root não existe: $root"; exit 52; }
  __adm_ensure_dir "$ADM_TMPDIR"

  local mode_sel="${mode:-$(__adm_sandbox_detect_mode)}"
  adm_info "Sandbox mode=${mode_sel} root=${root}"

  case "$mode_sel" in
    bwrap)
      adm_require_cmds bwrap
      # Montagens padrão + binds solicitados
      mapfile -d '' bargs < <(__adm_bind_args_bwrap "$root" "${binds[@]}")
      # shellcheck disable=SC2206
      local args=( ${bargs[@]} --unshare-user-try --unshare-pid --unshare-net --die-with-parent )
      if [[ -n "$timeout_s" ]]; then
        if [[ -n "${ADM_TIMEOUT_CMD}" ]]; then
          __adm_env_sanitize "${ADM_TIMEOUT_CMD}" --preserve-status --signal=TERM "$timeout_s" bwrap "${args[@]}" "$@"
        else
          adm_warn "timeout indisponível; executando bwrap sem limite"
          __adm_env_sanitize bwrap "${args[@]}" "$@"
        fi
      else
        __adm_env_sanitize bwrap "${args[@]}" "$@"
      fi
      ;;
    chroot)
      [[ $EUID -eq 0 ]] || { adm_err "chroot requer root"; exit 53; }
      # Garante /dev,/proc,/sys básicos
      for mp in dev proc sys; do
        [[ -d "${root}/${mp}" ]] || mkdir -p "${root}/${mp}"
      done
      mountpoint -q "${root}/proc" || mount -t proc proc "${root}/proc" || true
      mountpoint -q "${root}/sys"  || mount --rbind /sys "${root}/sys"  || true
      mountpoint -q "${root}/dev"  || mount --rbind /dev "${root}/dev"  || true

      # binds adicionais (somente RO para segurança)
      local spec h g
      for spec in "${binds[@]}"; do
        IFS=':' read -r m h g <<< "$spec"
        [[ -e "$h" ]] || { adm_warn "host não existe: $h (ignorando)"; continue; }
        case "$m" in
          rw) mount --rbind "$h" "${root}${g}" ;;
          ro) mount --rbind "$h" "${root}${g}"; mount -o remount,ro --bind "${root}${g}" "${root}${g}" ;;
          *)  adm_warn "modo inválido em bind (esperado rw|ro): $spec" ;;
        esac
      done

      if [[ -n "$timeout_s" && -n "${ADM_TIMEOUT_CMD}" ]]; then
        __adm_env_sanitize "${ADM_TIMEOUT_CMD}" --preserve-status --signal=TERM "$timeout_s" chroot "$root" /usr/bin/env -i PATH="$PATH" /bin/sh -lc "$*"
      else
        __adm_env_sanitize chroot "$root" /usr/bin/env -i PATH="$PATH" /bin/sh -lc "$*"
      fi
      ;;
    none)
      adm_warn "Executando sem sandbox."
      if [[ -n "$timeout_s" && -n "${ADM_TIMEOUT_CMD}" ]]; then
        __adm_env_sanitize "${ADM_TIMEOUT_CMD}" --preserve-status --signal=TERM "$timeout_s" "$@"
      else
        __adm_env_sanitize "$@"
      fi
      ;;
    *)
      adm_err "Modo de sandbox desconhecido: $mode_sel"
      exit 54
      ;;
  esac
}

###############################################################################
# Fakeroot (somente para empacotamento)
###############################################################################
adm_fakeroot_exec() {
  # uso: adm_fakeroot_exec -- comando args...
  # Verifica contexto: empacotamento deve chamar esta função (não build)
  if ! adm_is_cmd fakeroot; then
    adm_warn "fakeroot indisponível; seguindo sem ele"
    "$@"
    return
  fi
  # Em alguns sistemas, fakeroot falha silenciosamente sem /proc
  if [[ ! -r /proc/self/status ]]; then
    adm_err "fakeroot requer /proc; ambiente inválido"
    exit 60
  fi
  fakeroot -- "$@"
}

###############################################################################
# Utilidades de estágio: locks nomeados
###############################################################################
adm_stage_lock_acquire() {
  # uso: adm_stage_lock_acquire <build|install|package|update|gc> <programa>
  local stage="${1:?stage}" prog="${2:?programa}"
  adm_lock_acquire "stage-${stage}" "$prog" "${ADM_LOCK_TIMEOUT}"
}
adm_stage_lock_release() {
  local stage="${1:?stage}" prog="${2:?programa}" fd="${3:-}"
  adm_lock_release "stage-${stage}" "$prog" "$fd"
}

###############################################################################
# Guardas adicionais e relatórios
###############################################################################
adm_require_root_for_install() {
  if [[ $EUID -ne 0 ]]; then
    adm_err "Instalação em / requer root."
    exit 70
  fi
}
adm_guard_not_root_for_build() {
  if [[ $EUID -eq 0 ]]; then
    adm_warn "Construir como root não é recomendado; prossiga por sua conta."
  }
}

adm_mount_sanity() {
  # Checa se / é RW, se /tmp existe, etc.
  local rwflag
  rwflag=$(awk '$2=="/"{print $4}' /proc/mounts | head -n1 || echo "rw")
  if [[ "$rwflag" != *"rw"* ]]; then
    adm_err "Filesystem raiz está somente leitura; não é possível continuar."
    exit 71
  fi
  [[ -d /tmp && -w /tmp ]] || { adm_err "/tmp indisponível ou sem escrita"; exit 72; }
}

###############################################################################
# Execução direta para teste rápido
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  adm_safety_init
  adm_check_disk "${ADM_ROOT}"
  fd="$(adm_stage_lock_acquire build selftest)"
  # tentativa de sandbox noop
  adm_sandbox_exec --root "/" --mode none --timeout 5 -- /bin/sh -lc 'echo "sandbox ok: $(id -u)"'
  adm_stage_lock_release build selftest "$fd"
  adm_ok "Selftest concluído."
fi
