#!/usr/bin/env bash
#
# adm-bootstrap.sh (unificado: glibc + musl)
#
# Orquestra o bootstrap completo do toolchain dentro de um ROOTFS do ADM:
#
#   pass1  -> toolchain temporário em /tools (binutils-pass1, gcc-pass1)
#   libc   -> linux-api-headers + glibc OU musl final
#   pass2  -> zlib, gmp, mpfr, mpc, binutils final, gcc final
#   final  -> limpeza de /tools + sanity-checks básicos
#
# Recursos:
#   - suporta perfis glibc e musl no mesmo script
#   - detecção automática da libc (glibc/musl) via ADM_LIBC, ADM_PROFILE ou CHOST
#   - fila bonita e colorida com nome, versão, posição e quantos faltam
#   - retomada automática (modo "all") a partir do último pacote concluído
#
# Uso:
#   ADM_PROFILE=glibc ./adm-bootstrap.sh all
#   ADM_PROFILE=musl  ./adm-bootstrap.sh all
#
#   ./adm-bootstrap.sh pass1
#   ./adm-bootstrap.sh libc
#   ./adm-bootstrap.sh pass2
#   ./adm-bootstrap.sh final
#
# Variáveis úteis:
#   ADM_SH            caminho do adm.sh              (padrão: /opt/adm/adm.sh)
#   ADM_PROFILE       nome do profile                (padrão: glibc)
#   ADM_PROFILE_DIR   diretório dos profiles         (padrão: /opt/adm/profiles)
#   ADM_PACKAGES_DIR  diretório dos pacotes          (padrão: /opt/adm/packages)
#   ADM_STATE_DIR     diretório de estado do script  (padrão: /opt/adm/state)
#   ADM_LIBC          força libc: glibc | musl       (se não setado, é detectado)
#   BOOTSTRAP_VERBOSE 0|1                            (padrão: 1)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuráveis e defaults
# ---------------------------------------------------------------------------

ADM_SH="${ADM_SH:-/opt/adm/adm.sh}"
ADM_PROFILE="${ADM_PROFILE:-glibc}"
ADM_PROFILE_DIR="${ADM_PROFILE_DIR:-/opt/adm/profiles}"
ADM_PACKAGES_DIR="${ADM_PACKAGES_DIR:-/opt/adm/packages}"
ADM_STATE_DIR="${ADM_STATE_DIR:-/opt/adm/state}"
BOOTSTRAP_VERBOSE="${BOOTSTRAP_VERBOSE:-1}"

mkdir -p "$ADM_STATE_DIR"

# ---------------------------------------------------------------------------
# Cores e UI
# ---------------------------------------------------------------------------

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

banner() {
  local msg="$1"
  printf "\n${C_MAGENTA}==========${C_RESET} ${C_BOLD}%s${C_RESET} ${C_MAGENTA}==========${C_RESET}\n" "$msg"
}

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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_adm() {
  local cmd="$1"; shift
  local pkg="$1"; shift || true

  if [[ "$BOOTSTRAP_VERBOSE" == "1" ]]; then
    log "INFO" "adm: $cmd $pkg $*"
  fi

  "$ADM_SH" "$cmd" "$pkg" "$@"
}

load_profile() {
  local pf="${ADM_PROFILE_DIR}/${ADM_PROFILE}.profile"
  [[ -f "$pf" ]] || die "Profile não encontrado: $pf"

  # shellcheck source=/dev/null
  . "$pf"

  : "${ROOTFS:?ROOTFS não definido no profile ${ADM_PROFILE}}"
  : "${CHOST:?CHOST não definido no profile ${ADM_PROFILE}}"

  log "INFO" "Profile: $ADM_PROFILE  ROOTFS=$ROOTFS  CHOST=$CHOST"
}

detect_libc() {
  if [[ -n "${ADM_LIBC:-}" ]]; then
    LIBC="$ADM_LIBC"
  elif [[ "$ADM_PROFILE" == *musl* ]]; then
    LIBC="musl"
  elif [[ "${CHOST:-}" == *musl* ]]; then
    LIBC="musl"
  else
    LIBC="glibc"
  fi

  case "$LIBC" in
    glibc|musl) ;;
    *) die "ADM_LIBC/PROFILE/CHOST sugerem libc desconhecida: $LIBC" ;;
  esac

  log "INFO" "Libc detectada: $LIBC"
}

# Lê PKG_VERSION do script do pacote
get_pkg_version() {
  local pkg_id="$1"   # ex: core/gcc
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

# ---------------------------------------------------------------------------
# Fila e retomada
# ---------------------------------------------------------------------------

# Cada item da fila é uma string "tipo:identificador":
#   tipo = pkg | action
#   identificador (tipo=pkg) = core/gcc, etc
#   identificador (tipo=action) = nome da ação (final-glibc/final-musl)
QUEUE_ITEMS=()
QUEUE_TYPES=()

append_pkg()   { QUEUE_TYPES+=("pkg");    QUEUE_ITEMS+=("$1"); }
append_action(){ QUEUE_TYPES+=("action"); QUEUE_ITEMS+=("$1"); }

build_queue() {
  QUEUE_ITEMS=()
  QUEUE_TYPES=()

  # PASS1 (comum glibc/musl) – toolchain temporário em /tools
  append_pkg "core/binutils-pass1"
  append_pkg "core/gcc-pass1"

  # LIBC + headers
  append_pkg "core/linux-api-headers"
  if [[ "$LIBC" == "glibc" ]]; then
    append_pkg "core/glibc"
  else
    append_pkg "core/musl"
  fi

  # PASS2 – libs de suporte e toolchain final
  append_pkg "core/zlib"
  append_pkg "core/gmp"
  append_pkg "core/mpfr"
  append_pkg "core/mpc"
  append_pkg "core/binutils"
  append_pkg "core/gcc"

  # FINAL – ação especial
  if [[ "$LIBC" == "glibc" ]]; then
    append_action "final-glibc"
  else
    append_action "final-musl"
  fi
}

STATE_FILE() {
  # estado separado por profile+libc
  echo "$ADM_STATE_DIR/bootstrap-${ADM_PROFILE}-${LIBC}.state"
}

load_state_index() {
  local sf; sf="$(STATE_FILE)"
  if [[ -f "$sf" ]]; then
    # shellcheck source=/dev/null
    . "$sf" || true
    echo "${LAST_INDEX:- -1}"
  else
    echo -1
  fi
}

save_state_index() {
  local idx="$1"
  local sf; sf="$(STATE_FILE)"
  cat >"$sf" <<EOF
# Último índice concluído com sucesso
LAST_INDEX=$idx
EOF
}

reset_state() {
  rm -f "$(STATE_FILE)"
}

# ---------------------------------------------------------------------------
# Execução da fila
# ---------------------------------------------------------------------------

print_queue_header() {
  local total="${#QUEUE_ITEMS[@]}"
  banner "Bootstrap ($LIBC) – $total etapas"

  printf "${C_CYAN}%-4s %-32s %-12s %-s${C_RESET}\n" "#" "Pacote/Ação" "Versão" "Status"
  printf "${C_DIM}%s${C_RESET}\n" "----------------------------------------------------------------------------"
}

run_final_action() {
  local which="$1"

  case "$which" in
    final-glibc)
      banner "Fase FINAL (glibc)"
      # Remove /tools
      if [[ -d "$ROOTFS/tools" ]]; then
        log "INFO" "Removendo toolchain temporário em $ROOTFS/tools"
        rm -rf "$ROOTFS/tools"
      else
        log "INFO" "$ROOTFS/tools já não existe (limpo)."
      fi
      # ldconfig se existir
      if [[ -x "$ROOTFS/sbin/ldconfig" ]]; then
        log "INFO" "Rodando ldconfig dentro do ROOTFS"
        chroot "$ROOTFS" /sbin/ldconfig || log "WARN" "ldconfig falhou (verifique depois)."
      fi
      ;;
    final-musl)
      banner "Fase FINAL (musl)"
      if [[ -d "$ROOTFS/tools" ]]; then
        log "INFO" "Removendo toolchain temporário em $ROOTFS/tools"
        rm -rf "$ROOTFS/tools"
      else
        log "INFO" "$ROOTFS/tools já não existe (limpo)."
      fi
      # check simples pro ld-musl-*.so.1
      local ld_musl
      ld_musl="$(find "$ROOTFS"/lib -maxdepth 1 -type f -name 'ld-musl-*.so.1' 2>/dev/null | head -n1 || true)"
      if [[ -n "$ld_musl" ]]; then
        log "INFO" "Dynamic linker musl detectado: ${ld_musl#$ROOTFS}"
      else
        log "WARN" "Nenhum ld-musl-*.so.1 encontrado em $ROOTFS/lib (verifique o pacote core/musl)."
      fi
      ;;
    *)
      die "Ação final desconhecida: $which"
      ;;
  esac
}

run_queue_all_with_resume() {
  build_queue
  local total="${#QUEUE_ITEMS[@]}"
  print_queue_header

  local last_idx; last_idx="$(load_state_index)"
  local start_idx=$(( last_idx + 1 ))
  if (( start_idx < 0 )); then start_idx=0; fi
  if (( start_idx >= total )); then
    log "OK" "Todas as etapas já foram concluídas anteriormente (LAST_INDEX=$last_idx)."
    return 0
  fi

  for (( i = start_idx; i < total; i++ )); do
    local kind="${QUEUE_TYPES[i]}"
    local ident="${QUEUE_ITEMS[i]}"
    local pos=$(( i + 1 ))
    local remaining=$(( total - pos ))

    if [[ "$kind" == "pkg" ]]; then
      local pkg="$ident"
      local ver; ver="$(get_pkg_version "$pkg")"

      printf "${C_BOLD}[%2d/%2d]${C_RESET} ${C_GREEN}%-32s${C_RESET} ${C_CYAN}%-12s${C_RESET} " \
        "$pos" "$total" "$pkg" "$ver"
      printf "${C_YELLOW}(faltam %d)${C_RESET}\n" "$remaining"

      # Build + install
      run_adm build   "$pkg"
      run_adm install "$pkg"

      log "OK" "Pacote concluído: $pkg ($ver)"
    else
      # ação especial (final)
      printf "${C_BOLD}[%2d/%2d]${C_RESET} ${C_MAGENTA}%-32s${C_RESET} ${C_CYAN}%-12s${C_RESET} " \
        "$pos" "$total" "$ident" "—"
      printf "${C_YELLOW}(faltam %d)${C_RESET}\n" "$remaining"

      run_final_action "$ident"
      log "OK" "Ação concluída: $ident"
    fi

    # Atualiza estado somente depois de concluir a etapa com sucesso
    save_state_index "$i"
  done

  log "OK" "Bootstrap completo para profile=$ADM_PROFILE libc=$LIBC"
}

run_queue_phase_simple() {
  local phase="$1"
  build_queue
  local total="${#QUEUE_ITEMS[@]}"

  print_queue_header
  log "INFO" "Rodando somente fase: $phase (sem retomada automática)"

  # Mapear subconjunto da fila para a fase
  local indices=()

  case "$phase" in
    pass1)
      indices=(0 1)
      ;;
    libc)
      indices=(2 3)
      ;;
    pass2)
      # zlib, gmp, mpfr, mpc, binutils, gcc
      indices=(4 5 6 7 8 9)
      ;;
    final)
      indices=(10)
      ;;
    *)
      die "Fase desconhecida (phase simple): $phase"
      ;;
  esac

  local idx
  for idx in "${indices[@]}"; do
    local kind="${QUEUE_TYPES[idx]}"
    local ident="${QUEUE_ITEMS[idx]}"
    local pos=$(( idx + 1 ))
    local remaining=$(( total - pos ))

    if [[ "$kind" == "pkg" ]]; then
      local ver; ver="$(get_pkg_version "$ident")"
      printf "${C_BOLD}[%2d/%2d]${C_RESET} ${C_GREEN}%-32s${C_RESET} ${C_CYAN}%-12s${C_RESET} " \
        "$pos" "$total" "$ident" "$ver"
      printf "${C_YELLOW}(faltam %d na fila completa)${C_RESET}\n" "$remaining"

      run_adm build   "$ident"
      run_adm install "$ident"
      log "OK" "Pacote concluído: $ident ($ver)"
    else
      printf "${C_BOLD}[%2d/%2d]${C_RESET} ${C_MAGENTA}%-32s${C_RESET} ${C_CYAN}%-12s${C_RESET} " \
        "$pos" "$total" "$ident" "—"
      printf "${C_YELLOW}(faltam %d na fila completa)${C_RESET}\n" "$remaining"

      run_final_action "$ident"
      log "OK" "Ação concluída: $ident"
    fi
  done
}

usage() {
  cat <<EOF
Uso: $(basename "$0") <fase>

Fases:
  pass1   - binutils-pass1 + gcc-pass1 (toolchain temporário em /tools)
  libc    - linux-api-headers + glibc/musl final
  pass2   - zlib, gmp, mpfr, mpc, binutils final, gcc final
  final   - limpeza /tools + sanity-check simples
  all     - executa todas as fases com fila e retomada automática

Exemplos:
  ADM_PROFILE=glibc ./$(basename "$0") all
  ADM_PROFILE=musl  ./$(basename "$0") all

  ./$(basename "$0") pass1
  ./$(basename "$0") libc
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  local phase="$1"; shift || true

  [[ -x "$ADM_SH" ]] || die "adm.sh não encontrado ou não executável: $ADM_SH"

  load_profile
  detect_libc

  case "$phase" in
    all)
      banner "Bootstrap completo (profile=$ADM_PROFILE, libc=$LIBC)"
      run_queue_all_with_resume
      ;;
    pass1|libc|pass2|final)
      # Modo fase única: não mexe no arquivo de estado
      banner "Bootstrap fase '$phase' (profile=$ADM_PROFILE, libc=$LIBC)"
      run_queue_phase_simple "$phase"
      ;;
    reset-state)
      reset_state
      log "OK" "Estado de retomada limpo para profile=$ADM_PROFILE libc=$LIBC"
      ;;
    *)
      usage
      die "Fase desconhecida: $phase"
      ;;
  esac
}

main "$@"
