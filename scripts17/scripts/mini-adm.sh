#!/usr/bin/env bash
#
# mini-adm.sh
# -----------
# Mini "adm" para construir o cross-toolchain + temporary tools do LFS
# até GCC-15.2.0 Pass 2, com:
#   - retomada
#   - log central + log por pacote
#   - registro simples de conclusão
#   - verificação de integridade opcional
#   - metas em ./meta/<pacote>.meta (no mesmo diretório do script)
#
# Uso:
#   LFS=/mnt/lfs ./mini-adm.sh build-all
#   LFS=/mnt/lfs ./mini-adm.sh build gcc-pass1
#   LFS=/mnt/lfs ./mini-adm.sh verify-all
#   LFS=/mnt/lfs ./mini-adm.sh status
#
# Cada meta deve definir, no mínimo:
#   PKG_NAME
#   PKG_BUILD()   # compilar e instalar o passo (já pode fazer install)
#
# Opcional:
#   PKG_INSTALL() # se quiser separar build de install
#   PKG_CHECK()   # verificação de integridade do pacote
#
# O script passa as variáveis de versão abaixo para o ambiente
# (você pode usar dentro dos .meta, ex: "binutils-${BINUTILS_VER}.tar.xz").
#

set -euo pipefail

########################################
# 1. Versões (ajuste se o livro mudar) #
########################################

BINUTILS_VER="2.45.1"
GCC_VER="15.2.0"
LINUX_VER="6.17.8"           # API Headers
GLIBC_VER="2.42"
LIBSTDCXX_VER="$GCC_VER"     # libstdc++ do mesmo GCC

M4_VER="1.4.20"
NCURSES_VER="6.5-20250809"
BASH_VER="5.3"
COREUTILS_VER="9.9"
DIFFUTILS_VER="3.12"
FILE_VER="5.46"
FINDUTILS_VER="4.10.0"
GAWK_VER="5.3.2"
GREP_VER="3.12"
GZIP_VER="1.14"
MAKE_VER="4.4.1"
PATCH_VER="2.8"
SED_VER="4.9"
TAR_VER="1.35"
XZ_VER="5.8.1"
MUSL_VER=1.2.5

########################################
# 2. Configuração e diretórios básicos #
########################################

# LFS tem que estar definido externamente, como no livro
: "${LFS:?VARIÁVEL LFS não definida. Ex: export LFS=/mnt/lfs}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META_DIR="$SCRIPT_DIR/meta"

STATE_DIR="$LFS/.mini-adm-state"
LOG_DIR="$LFS/logs"
REGISTRY_FILE="$STATE_DIR/registry.lst"
GLOBAL_LOG="$LOG_DIR/mini-adm.log"

mkdir -p "$META_DIR" "$STATE_DIR" "$LOG_DIR"

# Diretórios principais do LFS (livro)
mkdir -p "$LFS"/{sources,tools}
chmod -v 777 "$LFS/sources" 2>/dev/null || true

########################################
# 3. Logging simples (arquivo + cores) #
########################################

if [[ -t 1 ]]; then
  C_INFO="\033[1;32m"
  C_WARN="\033[1;33m"
  C_ERR="\033[1;31m"
  C_RESET="\033[0m"
else
  C_INFO=""; C_WARN=""; C_ERR=""; C_RESET=""
fi

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

log() {
  local level="$1"; shift
  local msg="$*"
  echo "[$(timestamp)] [$level] $msg" >>"$GLOBAL_LOG"
  case "$level" in
    INFO)  echo -e "${C_INFO}[*]${C_RESET} $msg" ;;
    WARN)  echo -e "${C_WARN}[!]${C_RESET} $msg" ;;
    ERROR) echo -e "${C_ERR}[x]${C_RESET} $msg" ;;
    *)     echo "[$level] $msg" ;;
  esac
}

die() {
  log ERROR "$*"
  exit 1
}

########################################
# 4. Registro / retomada               #
########################################

# Arquivo: $STATE_DIR/<pacote>.done → marca concluído
pkg_done_flag() {
  local pkg="$1"
  echo "$STATE_DIR/${pkg}.done"
}

is_pkg_done() {
  local pkg="$1"
  [[ -f "$(pkg_done_flag "$pkg")" ]]
}

mark_pkg_done() {
  local pkg="$1"
  touch "$(pkg_done_flag "$pkg")"
  echo "$(timestamp)  $pkg  OK" >>"$REGISTRY_FILE"
}

########################################
# 5. Exportar variáveis de versão      #
########################################

export_version_vars() {
  export BINUTILS_VER GCC_VER LINUX_VER GLIBC_VER LIBSTDCXX_VER
  export M4_VER NCURSES_VER BASH_VER COREUTILS_VER DIFFUTILS_VER
  export FILE_VER FINDUTILS_VER GAWK_VER GREP_VER GZIP_VER
  export MAKE_VER PATCH_VER SED_VER TAR_VER XZ_VER MUSL_VER
  export LFS
}

########################################
# 6. Carregar meta de pacote           #
########################################

# Convenção: META_DIR/<pacote>.meta
# Ex: meta/binutils-pass1.meta
#     meta/gcc-pass2.meta
load_meta() {
  local pkg="$1"
  local meta_file="$META_DIR/${pkg}.meta"

  [[ -f "$meta_file" ]] || die "Metadata não encontrado: $meta_file"

  # limpamos funções antigas pra evitar lixo de outros metas
  unset PKG_NAME PKG_BUILD PKG_INSTALL PKG_CHECK || true

  # shellcheck source=/dev/null
  source "$meta_file"

  : "${PKG_NAME:="$pkg"}"

  if ! declare -F PKG_BUILD >/dev/null 2>&1; then
    die "PKG_BUILD não definido no metadata $meta_file"
  fi
}

########################################
# 7. Execução de um pacote             #
########################################

run_pkg() {
  local pkg="$1"
  export_version_vars

  if is_pkg_done "$pkg"; then
    log INFO "Pacote '$pkg' já marcado como concluído, pulando."
    return 0
  fi

  load_meta "$pkg"

  local pkg_log="$LOG_DIR/${pkg}.log"
  echo "=== $(timestamp) : INÍCIO $pkg ===" >>"$pkg_log"

  log INFO "Iniciando '$pkg' (PKG_NAME=${PKG_NAME})"

  # Execução do build + install com log separado
  {
    echo "[mini-adm] $(timestamp) - PKG_BUILD $pkg"
    PKG_BUILD
    if declare -F PKG_INSTALL >/dev/null 2>&1; then
      echo "[mini-adm] $(timestamp) - PKG_INSTALL $pkg"
      PKG_INSTALL
    fi
  } >>"$pkg_log" 2>&1 || {
    log ERROR "Falha ao construir '$pkg'. Veja $pkg_log"
    echo "=== $(timestamp) : FALHA $pkg ===" >>"$pkg_log"
    return 1
  }

  mark_pkg_done "$pkg"
  log INFO "Pacote '$pkg' concluído com sucesso."
  echo "=== $(timestamp) : FIM OK $pkg ===" >>"$pkg_log"
}

########################################
# 8. Verificação de integridade        #
########################################

verify_pkg() {
  local pkg="$1"
  export_version_vars
  load_meta "$pkg"

  if ! declare -F PKG_CHECK >/dev/null 2>&1; then
    log WARN "PKG_CHECK não definido para '$pkg'; verificação básica."
    # Verificação mínima: se tiver PKG_MAIN_BIN definido no meta,
    # checamos existência.
    if [[ -n "${PKG_MAIN_BIN:-}" ]]; then
      if [[ -x "$LFS/$PKG_MAIN_BIN" ]]; then
        log INFO "Verificação simples OK para '$pkg' (binário $PKG_MAIN_BIN existe)."
        return 0
      else
        log ERROR "Verificação simples FALHOU para '$pkg' (não achei $LFS/$PKG_MAIN_BIN)."
        return 1
      fi
    fi
    # Sem PKG_CHECK e sem PKG_MAIN_BIN -> nada a fazer
    return 0
  fi

  log INFO "Rodando PKG_CHECK para '$pkg'..."
  if PKG_CHECK; then
    log INFO "Integridade OK para '$pkg'."
    return 0
  else
    log ERROR "Integridade FALHOU para '$pkg'."
    return 1
  fi
}

########################################
# 9. Ordem de build (LFS até GCC p2)   #
########################################

# Nomes de pacotes (correspondem a arquivos meta/<nome>.meta)
BUILD_ORDER=(
  binutils-pass1          # Binutils-2.45.1 - Pass 1
  gcc-pass1               # GCC-15.2.0     - Pass 1
  linux-headers           # Linux-6.17.8 API Headers
  glibc                   # Glibc-2.42
  libstdcpp               # Libstdc++ from GCC-15.2.0
  m4                      # M4-1.4.20
  ncurses                 # Ncurses-6.5-20250809
  bash                    # Bash-5.3
  coreutils               # Coreutils-9.9
  diffutils               # Diffutils-3.12
  file                    # File-5.46
  findutils               # Findutils-4.10.0
  gawk                    # Gawk-5.3.2
  grep                    # Grep-3.12
  gzip                    # Gzip-1.14
  make                    # Make-4.4.1
  patch                   # Patch-2.8
  sed                     # Sed-4.9
  tar                     # Tar-1.35
  xz                      # Xz-5.8.1
  binutils-pass2          # Binutils-2.45.1 - Pass 2
  gcc-pass2               # GCC-15.2.0     - Pass 2
  musl                    # Libc musl
  toolchain-check         # Roda a checagem no final
)

########################################
# 10. Comandos de alto nível           #
########################################

cmd_build_all() {
  local pkg
  for pkg in "${BUILD_ORDER[@]}"; do
    run_pkg "$pkg" || exit 1
  done
}

cmd_build_one() {
  local pkg="$1"
  run_pkg "$pkg"
}

# Remove flag .done e log de um pacote, para permitir rebuild limpo
cmd_clean_one() {
  local pkg="$1"
  local flag
  flag="$(pkg_done_flag "$pkg")"

  # Remove flag de concluído
  if [[ -f "$flag" ]]; then
    rm -f "$flag"
    log INFO "Removido flag de conclusão: $flag"
  else
    log WARN "Flag de conclusão não existe para '$pkg' ($flag)"
  fi

  # Remove log específico do pacote
  local pkg_log="$LOG_DIR/${pkg}.log"
  if [[ -f "$pkg_log" ]]; then
    rm -f "$pkg_log"
    log INFO "Removido log de pacote: $pkg_log"
  else
    log WARN "Log do pacote '$pkg' não existe ($pkg_log)"
  fi
}

# Rebuild = clean + build de um pacote
cmd_rebuild_one() {
  local pkg="$1"
  cmd_clean_one "$pkg"
  run_pkg "$pkg"
}

# Checagem rápida do toolchain via meta/toolchain-check.meta
cmd_check_toolchain() {
  # Usa verify_pkg para reaproveitar PKG_CHECK do meta
  if verify_pkg "toolchain-check"; then
    log INFO "Toolchain OK de acordo com meta toolchain-check."
  else
    log ERROR "Toolchain com problemas (veja logs e meta toolchain-check)."
    return 1
  fi
}

cmd_verify_all() {
  local failures=0
  local pkg
  for pkg in "${BUILD_ORDER[@]}"; do
    if ! verify_pkg "$pkg"; then
      failures=$((failures+1))
    fi
  done
  if (( failures > 0 )); then
    log ERROR "Verificação terminou com $failures falhas."
    return 1
  else
    log INFO "Verificação OK para todos os pacotes."
  fi
}

cmd_status() {
  echo "Estado dos pacotes (LFS = $LFS):"
  local pkg
  for pkg in "${BUILD_ORDER[@]}"; do
    if is_pkg_done "$pkg"; then
      echo "  [OK ] $pkg"
    else
      echo "  [   ] $pkg"
    fi
  done
  echo
  echo "Registro (últimas linhas) em: $REGISTRY_FILE"
  [[ -f "$REGISTRY_FILE" ]] && tail -n 10 "$REGISTRY_FILE" || echo "(vazio)"
}

usage() {
  cat <<EOF
Uso: $(basename "$0") <comando> [pacote]

Comandos:
  build-all              - constrói todos os pacotes na ordem do BUILD_ORDER
  build <pacote>         - constrói um pacote específico (usa meta/<pacote>.meta)
  clean <pacote>         - apaga flag .done e log do pacote (para rebuild limpo)
  rebuild <pacote>       - clean + build do pacote
  verify-all             - roda PKG_CHECK (ou verificação simples) em todos
  check-toolchain        - roda apenas a checagem do meta 'toolchain-check'
  status                 - mostra o que já foi concluído

Exemplos:
  LFS=/mnt/lfs $(basename "$0") build-all
  LFS=/mnt/lfs $(basename "$0") build gcc-pass1
  LFS=/mnt/lfs $(basename "$0") clean gcc-pass1
  LFS=/mnt/lfs $(basename "$0") rebuild gcc-pass1
  LFS=/mnt/lfs $(basename "$0") check-toolchain
  LFS=/mnt/lfs $(basename "$0") verify-all
EOF
}

########################################
# 11. Dispatch                         #
########################################

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    build-all)
      cmd_build_all
      ;;
    build)
      [[ $# -ge 1 ]] || die "Informe o nome do pacote. Ex: $0 build gcc-pass1"
      cmd_build_one "$1"
      ;;
    clean)
      [[ $# -ge 1 ]] || die "Informe o nome do pacote. Ex: $0 clean gcc-pass1"
      cmd_clean_one "$1"
      ;;
    rebuild)
      [[ $# -ge 1 ]] || die "Informe o nome do pacote. Ex: $0 rebuild gcc-pass1"
      cmd_rebuild_one "$1"
      ;;
    verify-all)
      cmd_verify_all
      ;;
    check-toolchain)
      cmd_check_toolchain
      ;;
    status)
      cmd_status
      ;;
    ""|-h|--help|help)
      usage
      ;;
    *)
      die "Comando desconhecido: $cmd"
      ;;
  esac
}

main "$@"
