#!/usr/bin/env bash
# 20-bootstrap-stage0-post_install.sh
# Hook de pós-instalação: validação básica e registro no stage

set -euo pipefail

log()  { command -v adm_step >/dev/null 2>&1 && adm_step "binutils" "stage0" "$* " || echo "[stage0-post] $*"; }
ok()   { command -v adm_ok   >/dev/null 2>&1 && adm_ok "$*"   || echo "[stage0-post][OK] $*"; }
warn() { command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[stage0-post][WARN] $*"; }
err()  { command -v adm_err  >/dev/null 2>&1 && adm_err "$*"  || { echo "[stage0-post][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido (rootfs do stage0)}"
PREFIX="/tools"

# Sanidade via chroot se possível; caso contrário, executa direto com QEMU/userland do host pode falhar — tratamos como best-effort.
validate_tool() {
  local bin="$1"
  if command -v chroot >/dev/null 2>&1 && [[ -d "${ROOT}/proc" && -d "${ROOT}/dev" ]]; then
    chroot "${ROOT}" "${bin}" --version >/dev/null 2>&1 || return 1
  else
    "${ROOT}${bin}" --version >/dev/null 2>&1 || return 1
  fi
}

log "validando ferramentas principais (/tools/bin)"
fails=0
for b in /tools/bin/ld /tools/bin/as /tools/bin/ar /tools/bin/ranlib /tools/bin/strings; do
  if validate_tool "$b"; then
    log "ok: $b"
  else
    warn "falha ao validar $b (pode ser ambiente sem chroot montado); continue a partir dos próximos passos"
    fails=$((fails+1))
  fi
done

# PATH do stage (garante presença de /tools/bin no login shell do stage)
mkdir -p -- "${ROOT}/etc/profile.d"
cat > "${ROOT}/etc/profile.d/adm-path-tools.sh" <<'EOF'
# ADM stage0: priorizar /tools/bin no PATH
case ":${PATH}:" in
  *":/tools/bin:"*) :;;
  *) export PATH="/tools/bin:${PATH}";;
esac
EOF

# Registry do stage (se disponíveis helpers)
if command -v adm_registry_add >/dev/null 2>&1; then
  adm_registry_add "dev/binutils@2.45" --root "${ROOT}" --owner "adm-bootstrap" --files-from <(cd "${ROOT}" && find tools -type f -printf "%p\n") || true
fi

# Logs de bootstrap
state_dir="${ROOT}/usr/src/adm/state/bootstrap/stage0/binutils"
mkdir -p -- "${state_dir}"
{
  echo "stage=0"
  echo "package=dev/binutils"
  echo "version=2.45"
  echo "prefix=${PREFIX}"
  date -u +"built=%Y-%m-%dT%H:%M:%SZ"
  echo "validate_failures=${fails}"
} > "${state_dir}/build.info"

ok "post_install concluído; binutils pronto para GCC pass1"
