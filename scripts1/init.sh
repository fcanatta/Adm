#!/usr/bin/env bash
# /usr/src/adm/scripts/init.sh
# Inicializa toda a estrutura do sistema ADM.
# Cria diretórios, define permissões, exporta variáveis globais,
# e pode ser executado várias vezes sem causar conflitos.
set -euo pipefail
# ╭──────────────────────────────────────────────╮
# │ Funções de exibição colorida e logging leve │
# ╰──────────────────────────────────────────────╯
COL_RESET="\033[0m"
COL_INFO="\033[1;34m"
COL_OK="\033[1;32m"
COL_WARN="\033[1;33m"
COL_ERR="\033[1;31m"

timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() {
  local level="$1"; shift
  local msg="$*"
  case "$level" in
    INFO) printf "%b[%s]%b %s\n" "$COL_INFO" "$level" "$COL_RESET" "$msg" ;;
    OK)   printf "%b[%s]%b %s\n" "$COL_OK" "$level" "$COL_RESET" "$msg" ;;
    WARN) printf "%b[%s]%b %s\n" "$COL_WARN" "$level" "$COL_RESET" "$msg" ;;
    ERR)  printf "%b[%s]%b %s\n" "$COL_ERR" "$level" "$COL_RESET" "$msg" ;;
  esac
}

# ╭──────────────────────────────────────────────╮
# │ Definição e exportação de variáveis globais │
# ╰──────────────────────────────────────────────╯
export ADM_ROOT="/usr/src/adm"
export ADM_SCRIPTS_DIR="${ADM_ROOT}/scripts"
export ADM_DISTFILES="${ADM_ROOT}/distfiles"
export ADM_BINCACHE="${ADM_ROOT}/binary-cache"
export ADM_BUILD="${ADM_ROOT}/build"
export ADM_TOOLCHAIN="${ADM_ROOT}/toolchain"
export ADM_LOGS="${ADM_ROOT}/logs"
export ADM_STATE="${ADM_ROOT}/state"
export ADM_HOOKS="${ADM_ROOT}/hooks"
export ADM_METAFILES="${ADM_ROOT}/metafiles"
export ADM_UPDATES="${ADM_ROOT}/updates"
export ADM_PROFILE="${ADM_PROFILE:-performance}"
export ADM_NUM_JOBS="${ADM_NUM_JOBS:-$(nproc 2>/dev/null || echo 1)}"
export ADM_VERBOSE="${ADM_VERBOSE:-1}"
export ADM_LOCKFILE="${ADM_STATE}/adm.lock"
export ADM_LOGFILE="${ADM_LOGS}/init-$(date -u +%Y%m%dT%H%M%SZ).log"

# ╭──────────────────────────────────────────────╮
# │ Criação de diretórios (idempotente)         │
# ╰──────────────────────────────────────────────╯
log INFO "Verificando estrutura em ${ADM_ROOT}"

dirs=(
  "$ADM_ROOT"
  "$ADM_SCRIPTS_DIR"
  "$ADM_DISTFILES"
  "$ADM_BINCACHE"
  "$ADM_BUILD"
  "$ADM_TOOLCHAIN"
  "$ADM_LOGS"
  "$ADM_STATE"
  "$ADM_HOOKS"
  "$ADM_METAFILES"
  "$ADM_UPDATES"
)

for d in "${dirs[@]}"; do
  if [ ! -d "$d" ]; then
    install -d -m 755 "$d"
    log OK "Criado diretório: $d"
  else
    log INFO "Diretório existente: $d"
  fi
done

# ╭──────────────────────────────────────────────╮
# │ Permissões específicas por diretório        │
# ╰──────────────────────────────────────────────╯
chmod 755 "$ADM_ROOT" "$ADM_SCRIPTS_DIR" "$ADM_DISTFILES" "$ADM_BINCACHE" \
  "$ADM_BUILD" "$ADM_TOOLCHAIN" "$ADM_LOGS" "$ADM_HOOKS" "$ADM_METAFILES" "$ADM_UPDATES"
chmod 700 "$ADM_STATE"
chown -R root:root "$ADM_ROOT" 2>/dev/null || true

# ╭──────────────────────────────────────────────╮
# │ Inicialização de arquivos de controle       │
# ╰──────────────────────────────────────────────╯
touch "${ADM_STATE}/packages.db"
touch "${ADM_STATE}/bootstrap.state"
touch "${ADM_LOCKFILE}"
[ -f "${ADM_STATE}/current.profile" ] || echo "profile: ${ADM_PROFILE}" > "${ADM_STATE}/current.profile"

# ╭──────────────────────────────────────────────╮
# │ Verificação de dependências do sistema      │
# ╰──────────────────────────────────────────────╯
required_cmds=( bash tar curl make gcc sha256sum )
missing=0
for cmd in "${required_cmds[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    log ERR "Comando obrigatório ausente: $cmd"
    missing=1
  fi
done
if [ "$missing" -eq 1 ]; then
  log ERR "Dependências ausentes — instale os comandos acima antes de continuar."
  exit 1
fi
# ╭──────────────────────────────────────────────╮
# │ Registro de log e mensagem final            │
# ╰──────────────────────────────────────────────╯
echo "$(timestamp) [INFO] Estrutura ADM inicializada em ${ADM_ROOT}" >> "${ADM_LOGFILE}"
echo "$(timestamp) [OK] init.sh concluído com sucesso" >> "${ADM_LOGFILE}"

log OK "Estrutura de diretórios pronta."
log OK "Permissões verificadas."
log OK "Variáveis exportadas globalmente."
log OK "init.sh executado com sucesso — ambiente ADM pronto."
