#!/usr/bin/env bash
# /usr/src/adm/scripts/init.sh
# Inicialização do sistema ADM Build
# Cria toda a estrutura de diretórios, configura permissões, carrega perfil ativo e ambiente.
set -euo pipefail

# ======================
# 1. Variáveis principais
# ======================
ADM_ROOT="/usr/src/adm"
ADM_SCRIPTS_DIR="${ADM_ROOT}/scripts"
ADM_LOGS="${ADM_ROOT}/logs"
ADM_STATE="${ADM_ROOT}/state"
ADM_METAFILES="${ADM_ROOT}/metafiles"
ADM_UPDATES="${ADM_ROOT}/updates"
ADM_DISTFILES="${ADM_ROOT}/distfiles"
ADM_BINCACHE="${ADM_ROOT}/binary-cache"
ADM_BUILD="${ADM_ROOT}/build"

# ======================
# 2. Funções de log básicas
# ======================
COL_RESET="\033[0m"; COL_INFO="\033[1;34m"; COL_OK="\033[1;32m"; COL_WARN="\033[1;33m"; COL_ERR="\033[1;31m"

info()  { printf "%b[INFO]%b  %s\n" "${COL_INFO}" "${COL_RESET}" "$*"; }
ok()    { printf "%b[ OK ]%b  %s\n" "${COL_OK}" "${COL_RESET}" "$*"; }
warn()  { printf "%b[WARN]%b  %s\n" "${COL_WARN}" "${COL_RESET}" "$*"; }
err()   { printf "%b[ERR ]%b  %s\n" "${COL_ERR}" "${COL_RESET}" "$*"; }

# ======================
# 3. Criação da estrutura principal
# ======================
info "Verificando estrutura de diretórios..."
for d in "${ADM_SCRIPTS_DIR}" "${ADM_LOGS}" "${ADM_STATE}" "${ADM_METAFILES}" "${ADM_UPDATES}" "${ADM_DISTFILES}" "${ADM_BINCACHE}" "${ADM_BUILD}"; do
    mkdir -p "$d"
    chmod 755 "$d" 2>/dev/null || true
done
ok "Estrutura de diretórios verificada."

# ======================
# 4. Criar logs e arquivo de estado inicial
# ======================
ADM_INIT_LOG="${ADM_LOGS}/init-$(date -u +%Y%m%dT%H%M%SZ).log"
touch "${ADM_INIT_LOG}" 2>/dev/null || true
chmod 644 "${ADM_INIT_LOG}" 2>/dev/null || true

# ======================
# 5. Carregar ou inicializar perfil ativo
# ======================
info "Carregando perfil ativo do sistema..."
if [ -f "${ADM_SCRIPTS_DIR}/profile.sh" ]; then
    if ! bash "${ADM_SCRIPTS_DIR}/profile.sh" --validate >/dev/null 2>&1; then
        warn "Perfil ativo ausente ou inválido. Recriando perfil padrão..."
        bash "${ADM_SCRIPTS_DIR}/profile.sh" set performance >/dev/null 2>&1 || true
    fi

    if [ -f "${ADM_STATE}/current.profile" ]; then
        # Carrega variáveis do perfil ativo no ambiente atual
        set -a
        source "${ADM_STATE}/current.profile" 2>/dev/null || warn "Falha ao carregar current.profile"
        set +a
        ok "Perfil carregado: ${ADM_PROFILE:-performance}"
    else
        warn "Arquivo current.profile não encontrado, criando perfil padrão..."
        bash "${ADM_SCRIPTS_DIR}/profile.sh" set performance >/dev/null 2>&1 || true
        set -a
        source "${ADM_STATE}/current.profile" 2>/dev/null || true
        set +a
        ok "Perfil padrão performance criado e carregado."
    fi
else
    warn "profile.sh não encontrado — usando perfil padrão (performance)."
    ADM_PROFILE="performance"
    CFLAGS="-O2 -march=native -pipe"
    MAKEFLAGS="-j$(nproc)"
    LDFLAGS="-Wl,-O1 -Wl,--as-needed"
    export ADM_PROFILE CFLAGS MAKEFLAGS LDFLAGS
fi

# ======================
# 6. Exibir cabeçalho do sistema
# ======================
loadavg=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0.00")
cpu_cores=$(nproc 2>/dev/null || echo "1")
mem_total=$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "0")
host=$(hostname 2>/dev/null || echo "builder")

printf "\n\033[1;36m╔════════════════════════════════════════════════════════════╗\033[0m\n"
printf "\033[1;36m║  ADM Build System v1.0 (%s)                                ║\033[0m\n" "Profile: ${ADM_PROFILE:-performance}"
printf "\033[1;36m║  Host: %-20s CPU: %-3s cores  Mem: %-5sGB  Load: %-5s ║\033[0m\n" "${host}" "${cpu_cores}" "${mem_total}" "${loadavg}"
printf "\033[1;36m╚════════════════════════════════════════════════════════════╝\033[0m\n\n"

# ======================
# 7. Registrar estado e saída
# ======================
{
  echo "=== ADM INIT SESSION ==="
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Host: ${host}"
  echo "Profile: ${ADM_PROFILE:-performance}"
  echo "CPU Cores: ${cpu_cores}"
  echo "Memory(GB): ${mem_total}"
  echo "Load: ${loadavg}"
  echo "CFLAGS=${CFLAGS:-undefined}"
  echo "MAKEFLAGS=${MAKEFLAGS:-undefined}"
  echo "LDFLAGS=${LDFLAGS:-undefined}"
  echo "========================="
} >> "${ADM_INIT_LOG}"

ok "Ambiente inicializado com sucesso."
ok "Registro: ${ADM_INIT_LOG}"

# ======================
# 8. Exportar variáveis globais
# ======================
export ADM_ROOT ADM_SCRIPTS_DIR ADM_LOGS ADM_STATE ADM_METAFILES ADM_UPDATES ADM_DISTFILES ADM_BINCACHE ADM_BUILD
export ADM_PROFILE CFLAGS CXXFLAGS LDFLAGS MAKEFLAGS
