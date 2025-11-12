#!/usr/bin/env bash
# Cria/atualiza /etc/default/grub com valores sensatos.
# Respeita ADM_PROFILE (aggressive|normal|minimal).
# Idempotente: só modifica as chaves-alvo e preserva comentários/linhas desconhecidas.

set -Eeuo pipefail
: "${DESTDIR:=/}"
CFG_DIR="${DESTDIR}/etc/default"
CFG="${CFG_DIR}/grub"

mkdir -p "${CFG_DIR}"

# --- funçõezinhas úteis ---
have() { command -v "$1" >/dev/null 2>&1; }
kv_set() {
  # kv_set KEY VALUE  → define/atualiza linha KEY=VALUE (com aspas se tiver espaço)
  local k="$1"; shift
  local v="$*"
  local qv
  if [[ "$v" =~ [[:space:]] ]]; then qv="\"$v\""; else qv="$v"; fi
  if grep -qE "^[[:space:]]*${k}=" "$CFG" 2>/dev/null; then
    # substitui a linha inteira do KEY=
    sed -Ei "s|^[[:space:]]*${k}=.*$|${k}=${qv}|" "$CFG"
  else
    echo "${k}=${qv}" >> "$CFG"
  fi
}

# --- valores por perfil ---
PROFILE="${ADM_PROFILE:-normal}"
# Defaults base (neutros e seguros)
GRUB_TIMEOUT_DEFAULT="5"
GRUB_DISTRIBUTOR_DEFAULT="ADM"
GRUB_GFXPAYLOAD_DEFAULT="keep"
GRUB_TERMINAL_DEFAULT=""
CMDLINE_BASE_DEFAULT="quiet loglevel=3"
CMDLINE_EXTRA_DEFAULT=""

case "$PROFILE" in
  aggressive)
    # Aviso: 'mitigations=off' reduz segurança para máxima performance.
    CMDLINE_BASE_DEFAULT="quiet loglevel=3 nowatchdog"
    CMDLINE_EXTRA_DEFAULT="mitigations=off preempt=full threadirqs zswap.enabled=1 zswap.compressor=zstd zswap.max_pool_percent=25 zswap.zpool=zsmalloc"
    GRUB_TIMEOUT_DEFAULT="2"
    ;;
  minimal)
    CMDLINE_BASE_DEFAULT="quiet"
    CMDLINE_EXTRA_DEFAULT=""
    GRUB_TIMEOUT_DEFAULT="5"
    ;;
  normal|*)
    # já definido nos defaults
    ;;
esac

# Se arquivo não existe, cria um template básico preservando compatibilidade.
if [[ ! -f "$CFG" ]]; then
  cat > "$CFG" <<'TEMPLATE'
# /etc/default/grub - gerado pelo ADM (pode editar; este hook só atualiza chaves específicas)
# Documentação: grub-mkconfig(8), info -f grub -n 'Simple configuration'
# Dica: edite GRUB_CMDLINE_LINUX_DEFAULT e rode 'grub-mkconfig -o /boot/grub/grub.cfg'

# As chaves abaixo podem ser atualizadas automaticamente por este hook.
TEMPLATE
fi

# Define/atualiza chaves
kv_set GRUB_TIMEOUT              "${GRUB_TIMEOUT_DEFAULT}"
kv_set GRUB_DISTRIBUTOR          "${GRUB_DISTRIBUTOR_DEFAULT}"
kv_set GRUB_GFXPAYLOAD_LINUX     "${GRUB_GFXPAYLOAD_DEFAULT}"

# Terminal gráfico por padrão; em minimal pode preferir stay empty.
if [[ "$PROFILE" == "minimal" ]]; then
  kv_set GRUB_TERMINAL "console"
else
  # se quiser forçar gfxterm, descomente:
  # kv_set GRUB_TERMINAL "gfxterm"
  :
fi

# Linha extra “global” (para todos os boots)
# Mantemos GRUB_CMDLINE_LINUX separado para quem quiser parâmetros permanentes do admin.
if ! grep -qE "^[[:space:]]*GRUB_CMDLINE_LINUX=" "$CFG" 2>/dev/null; then
  echo 'GRUB_CMDLINE_LINUX=""' >> "$CFG"
fi

# Linha “default” (modo normal) — combinável com GRUB_CMDLINE_LINUX
# Montamos a partir do perfil atual.
CMDLINE_DEFAULT="${CMDLINE_BASE_DEFAULT}"
[[ -n "${CMDLINE_EXTRA_DEFAULT}" ]] && CMDLINE_DEFAULT="${CMDLINE_DEFAULT} ${CMDLINE_EXTRA_DEFAULT}"
kv_set GRUB_CMDLINE_LINUX_DEFAULT "${CMDLINE_DEFAULT}"

# Algumas opções convenientes
# Descomente se quiser memórias/diagnósticos no menu
if ! grep -qE "^[[:space:]]*#?GRUB_DISABLE_RECOVERY=" "$CFG"; then
  echo 'GRUB_DISABLE_RECOVERY="false"' >> "$CFG"
fi

# Info final
echo "[grub-defaults] Perfil: ${PROFILE}"
echo "[grub-defaults] Arquivo: ${CFG}"
grep -E '^(GRUB_TIMEOUT|GRUB_DISTRIBUTOR|GRUB_GFXPAYLOAD_LINUX|GRUB_TERMINAL|GRUB_CMDLINE_LINUX|GRUB_CMDLINE_LINUX_DEFAULT|GRUB_DISABLE_RECOVERY)=' "$CFG" || true
