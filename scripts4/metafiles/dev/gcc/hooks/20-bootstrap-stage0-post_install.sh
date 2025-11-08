#!/usr/bin/env bash
# 20-bootstrap-stage0-post_install.sh
# Hook de pós-instalação: valida o toolchain pass1 no stage e registra estado.

set -euo pipefail

log()  { command -v adm_step >/dev/null 2>&1 && adm_step "gcc-pass1" "stage0" "$* " || echo "[gcc-pass1-post] $*"; }
ok()   { command -v adm_ok   >/dev/null 2>&1 && adm_ok "$*"   || echo "[gcc-pass1-post][OK] $*"; }
warn() { command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[gcc-pass1-post][WARN] $*"; }
err()  { command -v adm_err  >/dev/null 2>&1 && adm_err "$*"  || { echo "[gcc-pass1-post][ERR] $*" >&2; exit 1; } }

: "${ROOT:?ROOT não definido (rootfs do stage0)}"
: "${TARGET:?TARGET não definido (ex.: x86_64-linux-gnu)}"

PREFIX="/tools"

# Garante PATH dentro do stage
mkdir -p -- "${ROOT}/etc/profile.d"
cat > "${ROOT}/etc/profile.d/adm-path-tools.sh" <<'EOF'
# ADM stage0: priorizar /tools/bin no PATH
case ":${PATH}:" in
  *":/tools/bin:"*) :;;
  *) export PATH="/tools/bin:${PATH}";;
esac
EOF

# Valida binários principais
validate_in_stage() {
  local bin="$1"; local args="${2:---version}"
  if command -v chroot >/dev/null 2>&1 && [[ -d "${ROOT}/proc" && -d "${ROOT}/dev" ]]; then
    chroot "${ROOT}" "${bin}" ${args} >/dev/null 2>&1
  else
    "${ROOT}${bin}" ${args} >/dev/null 2>&1
  fi
}

fails=0
for b in "/tools/bin/${TARGET}-gcc" "/tools/bin/${TARGET}-cpp"; do
  if validate_in_stage "$b" "--version"; then
    log "ok: $b"
  else
    warn "falha ao validar $b"
    fails=$((fails+1))
  fi
done

# Teste de linkagem mínima: compilar e linkar um 'hello' estático/dinâmico simples (best-effort)
tmpd="$(mktemp -d "${ROOT%/}/tmp/gccp1.XXXXXX")" || tmpd="${ROOT%/}/tmp"
cat > "${tmpd}/hello.c" <<'HELLO'
int main(void){return 0;}
HELLO

if command -v chroot >/dev/null 2>&1; then
  if chroot "${ROOT}" /tools/bin/${TARGET}-gcc -x c /tmp/hello.c -o /tmp/hello >/dev/null 2>&1; then
    log "teste de compilação OK (hello)"
  else
    warn "teste de compilação falhou (hello) — verifique binutils e sysroot"
    fails=$((fails+1))
  fi
else
  if "${ROOT}/tools/bin/${TARGET}-gcc" -x c "${tmpd}/hello.c" -o "${tmpd}/hello" >/dev/null 2>&1; then
    log "teste de compilação OK (hello)"
  else
    warn "teste de compilação falhou (hello) — ambiente sem chroot"
    fails=$((fails+1))
  fi
fi

# Registro no registry do stage (se disponível)
if command -v adm_registry_add >/dev/null 2>&1; then
  # Registra apenas os arquivos dentro de /tools relevantes a gcc pass1 (melhor esforço)
  adm_registry_add "dev/gcc@14.2.0" --root "${ROOT}" --owner "adm-bootstrap" --files-from <(cd "${ROOT}" && find tools -type f -path "*/bin/*${TARGET}*" -o -path "*/lib/gcc/*/*" -printf "%p\n") || true
fi

# Estado/relatório
state_dir="${ROOT}/usr/src/adm/state/bootstrap/stage0/gcc-pass1"
mkdir -p -- "${state_dir}"
{
  echo "stage=0"
  echo "package=dev/gcc"
  echo "version=14.2.0"
  echo "mode=pass1"
  echo "prefix=${PREFIX}"
  echo "target=${TARGET}"
  date -u +"built=%Y-%m-%dT%H:%M:%SZ"
  echo "validate_failures=${fails}"
} > "${state_dir}/build.info"

ok "gcc pass1 pronto. Próximo passo: headers/libc inicial e GCC pass2."
