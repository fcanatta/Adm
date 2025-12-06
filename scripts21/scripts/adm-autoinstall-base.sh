#!/usr/bin/env bash
#
# adm-autoinstall-base.sh
#
# Instala automaticamente um "base system" de pacotes dentro do chroot,
# usando o ADM, com:
#   - fila colorida
#   - retomada automática
#   - logs por pacote
#
# Execute preferencialmente DENTRO do chroot, com:
#   ADM_PROFILE=chroot ./adm-autoinstall-base.sh all
#
set -euo pipefail

ADM_SH="${ADM_SH:-/opt/adm/adm.sh}"
ADM_PROFILE="${ADM_PROFILE:-chroot}"
ADM_PACKAGES_DIR="${ADM_PACKAGES_DIR:-/opt/adm/packages}"
ADM_STATE_DIR="${ADM_STATE_DIR:-/opt/adm/state}"
ADM_LOG_DIR="${ADM_LOG_DIR:-/opt/adm/logs}"

mkdir -p "$ADM_STATE_DIR" "$ADM_LOG_DIR"

# --------------------------- CORES / UI ----------------------------

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_MAGENTA=$'\033[35m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_MAGENTA=""; C_CYAN=""
fi

log() {
  local level="$1"; shift
  local color="$C_RESET"
  case "$level" in
    INFO)  color="$C_BLUE" ;;
    WARN)  color="$C_YELLOW" ;;
    ERRO)  color="$C_RED" ;;
    OK)    color="$C_GREEN" ;;
  esac
  printf "%s[%s]%s %s\n" "$color" "$level" "$C_RESET" "$*" >&2
}

die() {
  log "ERRO" "$*"
  exit 1
}

banner() {
  local msg="$1"
  printf "\n${C_MAGENTA}==========${C_RESET} ${C_BOLD}%s${C_RESET} ${C_MAGENTA}==========${C_RESET}\n" "$msg"
}

# --------------------------- HELPERS ----------------------------

run_adm() {
  local cmd="$1"; shift
  local pkg="$1"; shift || true

  log "INFO" "adm: $cmd $pkg $*"
  "$ADM_SH" "$cmd" "$pkg" "$@"
}

get_pkg_version() {
  local pkg_id="$1"   # ex: core/bash
  local cat="${pkg_id%%/*}"
  local name="${pkg_id##*/}"
  local script="$ADM_PACKAGES_DIR/$cat/$name/$name.sh"

  if [[ ! -f "$script" ]]; then
    echo "?" ; return 0
  fi

  (
    set +u
    PKG_VERSION=""
    # shellcheck source=/dev/null
    . "$script" >/dev/null 2>&1 || true
    echo "${PKG_VERSION:-?}"
  )
}

STATE_FILE() {
  echo "$ADM_STATE_DIR/autobase-${ADM_PROFILE}.state"
}

load_last_index() {
  local sf; sf="$(STATE_FILE)"
  if [[ -f "$sf" ]]; then
    # shellcheck source=/dev/null
    . "$sf" || true
    echo "${LAST_INDEX:- -1}"
  else
    echo -1
  fi
}

save_last_index() {
  local idx="$1"
  local sf; sf="$(STATE_FILE)"
  cat >"$sf" <<EOF
LAST_INDEX=$idx
EOF
}

reset_state() {
  rm -f "$(STATE_FILE)"
}

# --------------------------- FILA ----------------------------

# Ajuste esta fila para refletir os pacotes reais do seu repositório ADM.
build_queue() {
  BASE_QUEUE=(
    core/file
    core/bash
    core/coreutils
    core/diffutils
    core/findutils
    core/gawk
    core/grep
    core/gzip
    core/make
    core/patch
    core/sed
    core/tar
    core/xz
    core/util-linux
    core/procps-ng
    core/shadow
    core/e2fsprogs
    core/kbd
    core/kmod
    core/less
    # Adicione/remova o que quiser aqui
  )
}

print_header() {
  local total="$1"
  banner "AutoInstall Base (profile=$ADM_PROFILE) – $total pacotes"

  printf "${C_CYAN}%-4s %-32s %-12s %-s${C_RESET}\n" "#" "Pacote" "Versão" "Status"
  printf "${C_DIM}%s${C_RESET}\n" "----------------------------------------------------------------------------"
}

run_queue_all() {
  build_queue
  local total="${#BASE_QUEUE[@]}"
  if (( total == 0 )); then
    die "Fila de pacotes base vazia."
  fi

  print_header "$total"

  local last_idx; last_idx="$(load_last_index)"
  local start_idx=$(( last_idx + 1 ))
  (( start_idx < 0 )) && start_idx=0
  (( start_idx >= total )) && { log "OK" "Todos os pacotes da base já foram instalados."; return 0; }

  local i
  for (( i=start_idx; i<total; i++ )); do
    local pkg="${BASE_QUEUE[i]}"
    local ver; ver="$(get_pkg_version "$pkg")"
    local pos=$(( i + 1 ))
    local done="$i"
    local left=$(( total - pos ))

    printf "${C_BOLD}[%2d/%2d]${C_RESET} ${C_GREEN}%-32s${C_RESET} ${C_CYAN}%-12s${C_RESET} " \
      "$pos" "$total" "$pkg" "$ver"
    printf "${C_YELLOW}(construídos: %d, faltam: %d)${C_RESET}\n" "$done" "$left"

    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local log_file="$ADM_LOG_DIR/autobase-${ADM_PROFILE}-${pkg//\//_}-${ts}.log"

    log "INFO" "Log do pacote será salvo em: $log_file"

    {
      echo "=== LOG DO PACOTE: $pkg ($ver) ==="
      echo "Data: $(date)"
      echo "Profile: $ADM_PROFILE"
      echo "----------------------------------"
    } >"$log_file"

    # Build
    if ! run_adm build "$pkg" >>"$log_file" 2>&1; then
      echo >>"$log_file"
      echo "ERRO: falha ao construir $pkg ($ver)" >>"$log_file"
      die "Falha ao construir $pkg ($ver). Veja o log em: $log_file"
    fi

    # Install
    if ! run_adm install "$pkg" >>"$log_file" 2>&1; then
      echo >>"$log_file"
      echo "ERRO: falha ao instalar $pkg ($ver)" >>"$log_file"
      die "Falha ao instalar $pkg ($ver). Veja o log em: $log_file"
    fi

    log "OK" "Pacote concluído: $pkg ($ver)"

    save_last_index "$i"
  done

  log "OK" "AutoInstall Base concluído para profile=$ADM_PROFILE"
}

usage() {
  cat <<EOF
Uso: $(basename "$0") <comando>

Comandos:
  all         - instala todos os pacotes base (com retomada)
  reset       - reseta o estado de retomada
  show-queue  - mostra a fila atual de pacotes

Exemplos (dentro do chroot):
  ADM_PROFILE=chroot $(basename "$0") all
  ADM_PROFILE=chroot $(basename "$0") show-queue
  ADM_PROFILE=chroot $(basename "$0") reset
EOF
}

show_queue() {
  build_queue
  local total="${#BASE_QUEUE[@]}"
  banner "Fila de pacotes base (total: $total)"
  local i
  for (( i=0; i<total; i++ )); do
    printf "%2d) %s\n" "$((i+1))" "${BASE_QUEUE[i]}"
  done
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  local cmd="$1"; shift || true

  [[ -x "$ADM_SH" ]] || die "adm.sh não encontrado ou não executável: $ADM_SH"

  case "$cmd" in
    all)
      run_queue_all
      ;;
    reset)
      reset_state
      log "OK" "Estado de retomada resetado para profile=$ADM_PROFILE"
      ;;
    show-queue)
      show_queue
      ;;
    *)
      usage
      die "Comando desconhecido: $cmd"
      ;;
  esac
}

main "$@"
