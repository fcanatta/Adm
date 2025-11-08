#!/usr/bin/env sh
# Prepara .config do kernel e diretório de build

set -eu
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:?BUILD_DIR não definido}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Falta $1" >&2; exit 1; }; }
for t in make awk sed tar xz; do need "$t"; done

# Kernel compila in-tree; usamos SRC_DIR como workdir
# Se desejar out-of-tree, ajuste: O=$BUILD_DIR em todos os 'make'
: "${O:=$SRC_DIR}"

# Configuração
cd "$SRC_DIR"
if [ -n "${ADM_KERNEL_CONFIG}" ] && [ -f "${ADM_KERNEL_CONFIG}" ]; then
  cp -f "${ADM_KERNEL_CONFIG}" .config
  make O="$O" olddefconfig
else
  make O="$O" "${ADM_KERNEL_DEFCONFIG}"
fi

# Localversion opcional
if [ -n "${ADM_KERNEL_LOCALVERSION}" ]; then
  printf "%s\n" "${ADM_KERNEL_LOCALVERSION}" > localversion
fi

# Exporta O para as próximas etapas
echo "$O" > "${BUILD_DIR}/.kbuild_O"
