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
# Detectar LFS e LFS_TGT automaticamente
########################################

# 1) Se LFS não estiver definido, tenta detectar automaticamente
if [[ -z "${LFS:-}" ]]; then
    # Caminho padrão usado pela maioria dos usuários LFS
    if [[ -d /mnt/lfs ]]; then
        export LFS="/mnt/lfs"
    else
        echo "ERRO: Variável LFS não definida e /mnt/lfs não existe."
        echo "Defina manualmente: export LFS=/caminho"
        exit 1
    fi
fi

# 2) Se LFS_TGT não estiver definido, gera automaticamente:
if [[ -z "${LFS_TGT:-}" ]]; then
    export LFS_TGT="$(uname -m)-lfs-linux-gnu"
fi

echo "Usando:"
echo "  LFS = $LFS"
echo "  LFS_TGT = $LFS_TGT"

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

  # limpamos funções e variáveis de checagem antigas pra evitar lixo de outros metas
  unset PKG_NAME PKG_BUILD PKG_INSTALL PKG_CHECK \
        PKG_MAIN_BIN PKG_MAIN_BINS \
        PKG_CHECK_BINS PKG_CHECK_LIBS PKG_CHECK_DIRS PKG_CHECK_CMDS \
        PKG_CHECK_CHROOT || true

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

# Checagem genérica baseada em variáveis do metadata:
#   PKG_MAIN_BIN         - string, caminho relativo à raiz do LFS (ex: /usr/bin/gcc)
#   PKG_MAIN_BINS        - array, vários binários principais
#   PKG_CHECK_BINS       - array, executáveis adicionais
#   PKG_CHECK_LIBS       - array, arquivos de biblioteca (ex: /usr/lib/libc.so.6)
#   PKG_CHECK_DIRS       - array, diretórios que devem existir
#   PKG_CHECK_CMDS       - array, comandos para rodar
#   PKG_CHECK_CHROOT=1   - se definido e =1, PKG_CHECK_CMDS rodam em chroot $LFS
#
# Retornos:
#   0 - tudo OK
#   1 - algum check falhou
#   2 - nenhum critério genérico definido
run_generic_pkg_checks() {
  local pkg="$1"
  local total=0
  local fail=0
  local has_cfg=0

  # Detecta se há algum critério configurado
  if [[ -n "${PKG_MAIN_BIN:-}" ]]; then has_cfg=1; fi
  if [[ "${PKG_MAIN_BINS+set}" == "set" ]];      then has_cfg=1; fi
  if [[ "${PKG_CHECK_BINS+set}" == "set" ]];     then has_cfg=1; fi
  if [[ "${PKG_CHECK_LIBS+set}" == "set" ]];     then has_cfg=1; fi
  if [[ "${PKG_CHECK_DIRS+set}" == "set" ]];     then has_cfg=1; fi
  if [[ "${PKG_CHECK_CMDS+set}" == "set" ]];     then has_cfg=1; fi

  if (( has_cfg == 0 )); then
    # Nenhuma checagem declarada nesse meta
    return 2
  fi

  # Helper interno para checar um path sob $LFS
  _check_path() {
    local kind="$1"   # BIN | LIB | DIR
    local path="$2"
    local full="$LFS$path"

    case "$kind" in
      BIN)
        if [[ -x "$full" ]]; then
          log INFO "Check [$pkg] bin OK: $path"
        else
          log ERROR "Check [$pkg] bin FALHOU: $path (não executável em $full)"
          fail=$((fail+1))
        fi
        ;;
      LIB)
        if [[ -f "$full" ]]; then
          log INFO "Check [$pkg] lib OK: $path"
        else
          log ERROR "Check [$pkg] lib FALHOU: $path (não existe em $full)"
          fail=$((fail+1))
        fi
        ;;
      DIR)
        if [[ -d "$full" ]]; then
          log INFO "Check [$pkg] dir OK: $path"
        else
          log ERROR "Check [$pkg] dir FALHOU: $path (não existe em $full)"
          fail=$((fail+1))
        fi
        ;;
    esac
    total=$((total+1))
  }

  # 1) PKG_MAIN_BIN (string única)
  if [[ -n "${PKG_MAIN_BIN:-}" ]]; then
    _check_path BIN "$PKG_MAIN_BIN"
  fi

  # 2) PKG_MAIN_BINS (array)
  if [[ "${PKG_MAIN_BINS+set}" == "set" ]]; then
    local b
    for b in "${PKG_MAIN_BINS[@]}"; do
      _check_path BIN "$b"
    done
  fi

  # 3) PKG_CHECK_BINS
  if [[ "${PKG_CHECK_BINS+set}" == "set" ]]; then
    local b
    for b in "${PKG_CHECK_BINS[@]}"; do
      _check_path BIN "$b"
    done
  fi

  # 4) PKG_CHECK_LIBS
  if [[ "${PKG_CHECK_LIBS+set}" == "set" ]]; then
    local f
    for f in "${PKG_CHECK_LIBS[@]}"; do
      _check_path LIB "$f"
    done
  fi

  # 5) PKG_CHECK_DIRS
  if [[ "${PKG_CHECK_DIRS+set}" == "set" ]]; then
    local d
    for d in "${PKG_CHECK_DIRS[@]}"; do
      _check_path DIR "$d"
    done
  fi

  # 6) PKG_CHECK_CMDS (com ou sem chroot)
  if [[ "${PKG_CHECK_CMDS+set}" == "set" ]]; then
    local cmd
    for cmd in "${PKG_CHECK_CMDS[@]}"; do
      total=$((total+1))
      if [[ "${PKG_CHECK_CHROOT:-0}" -eq 1 ]]; then
        log INFO "Check [$pkg] cmd (chroot) → $cmd"
        if chroot "$LFS" /bin/sh -lc "$cmd" >/dev/null 2>&1; then
          log INFO "Check [$pkg] cmd OK (chroot): $cmd"
        else
          log ERROR "Check [$pkg] cmd FALHOU (chroot): $cmd"
          fail=$((fail+1))
        fi
      else
        log INFO "Check [$pkg] cmd → $cmd"
        if /bin/sh -lc "$cmd" >/dev/null 2>&1; then
          log INFO "Check [$pkg] cmd OK: $cmd"
        else
          log ERROR "Check [$pkg] cmd FALHOU: $cmd"
          fail=$((fail+1))
        fi
      fi
    done
  fi

  # Resultado final
  if (( fail > 0 )); then
    return 1
  fi

  # Se chegou aqui, havia critérios e nenhum falhou
  return 0
}

########################################
# 8. Verificação de integridade        #
########################################

verify_pkg() {
  local pkg="$1"
  export_version_vars
  load_meta "$pkg"

  local rc_generic=0

  # 1) Se o meta tiver PKG_CHECK personalizado, usa primeiro
  if declare -F PKG_CHECK >/dev/null 2>&1; then
    log INFO "Rodando PKG_CHECK personalizado para '$pkg'..."
    if ! PKG_CHECK; then
      log ERROR "Integridade FALHOU para '$pkg' (PKG_CHECK personalizado)."
      return 1
    fi
    log INFO "PKG_CHECK personalizado OK para '$pkg'."

    # Tenta checagem genérica adicional se houver critérios
    if run_generic_pkg_checks "$pkg"; then
      log INFO "Checagem genérica adicional (se definida) OK para '$pkg'."
      return 0
    else
      rc_generic=$?
      case "$rc_generic" in
        1)
          log ERROR "Checagem genérica adicional FALHOU para '$pkg'."
          return 1
          ;;
        2)
          # nenhum critério genérico definido; tudo bem
          log INFO "Nenhuma checagem genérica extra definida para '$pkg'."
          return 0
          ;;
        *)
          log ERROR "Checagem genérica retornou código inesperado ($rc_generic) para '$pkg'."
          return 1
          ;;
      esac
    fi
  fi

  # 2) Sem PKG_CHECK personalizado: usar apenas checagem genérica
  log WARN "PKG_CHECK não definido para '$pkg'; usando checagem genérica (se configurada)."

  if run_generic_pkg_checks "$pkg"; then
    log INFO "Checagem genérica OK para '$pkg'."
    return 0
  else
    rc_generic=$?
    case "$rc_generic" in
      1)
        log ERROR "Checagem genérica FALHOU para '$pkg'."
        return 1
        ;;
      2)
        log WARN "Nenhuma checagem genérica configurada para '$pkg'; considerando OK por enquanto."
        return 0
        ;;
      *)
        log ERROR "Checagem genérica retornou código inesperado ($rc_generic) para '$pkg'."
        return 1
        ;;
    esac
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
