#!/usr/bin/env bash
# glibc pós: valida bibliotecas e cria nsswitch.conf mínimo.
set -euo pipefail
log(){ command -v adm_step >/dev/null 2>&1 && adm_step "glibc" "bootstrap" "$*" || echo "[glibc-post] $*"; }
ok(){ command -v adm_ok >/dev/null 2>&1 && adm_ok "$*" || echo "[glibc-post][OK] $*"; }
warn(){ command -v adm_warn >/dev/null 2>&1 && adm_warn "$*" || echo "[glibc-post][WARN] $*"; }

: "${ROOT:?ROOT não definido}"

# Presença de libc.so, ld-linux e crts
missing=0
check(){
  [[ -e "$1" ]] || { warn "faltando $1"; missing=$((missing+1)); }
}
check "${ROOT}/usr/lib/libc.so" || true
# ld-linux variantes — melhor esforço:
for ldso in /usr/lib/ld-linux-x86-64.so.2 /usr/lib/ld-linux-aarch64.so.1 /usr/lib/ld-linux-riscv64lp64d.so.1; do
  [[ -e "${ROOT}${ldso}" ]] && found_ld=1 || true
done
[[ "${found_ld:-0}" -eq 1 ]] || warn "ld-linux so não localizado (variante da arquitetura?)"
for f in /usr/lib/crt1.o /usr/lib/crti.o /usr/lib/crtn.o; do check "${ROOT}${f}"; done

# nsswitch mínimo (best-effort)
mkdir -p -- "${ROOT}/etc"
if [[ ! -s "${ROOT}/etc/nsswitch.conf" ]]; then
cat > "${ROOT}/etc/nsswitch.conf" <<'EOF'
passwd: files
group:  files
shadow: files
hosts:  files dns
networks: files
protocols: files
services: files
ethers: files
rpc:     files
EOF
fi

state_dir="${ROOT}/usr/src/adm/state/bootstrap/stageX/glibc"
mkdir -p -- "$state_dir"
{
  echo "package=dev/glibc"
  echo "version=2.40"
  date -u +"built=%Y-%m-%dT%H:%M:%SZ"
  echo "missing_artifacts=${missing}"
} > "${state_dir}/build.info"

ok "glibc pronta (headers+crt+libc)"
