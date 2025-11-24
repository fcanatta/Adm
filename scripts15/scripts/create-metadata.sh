#!/usr/bin/env bash
# create-metadata.sh
#
# Cria um arquivo /usr/src/packages/<category>/<name>/metadata
# usando como template padrão o metadata do xz-5.8.1 que você definiu.
#
# Uso:
#   sudo ./create-metadata.sh <nome> [categoria] [versao] [release]
#
# Defaults:
#   categoria = core
#   versao    = 5.8.1
#   release   = 1
#
# Ex:
#   sudo ./create-metadata.sh xz
#   sudo ./create-metadata.sh xz core 5.8.1 1
#   sudo ./create-metadata.sh attr core 2.5.2 1   # depois edite URL/SHA/depends no metadata

set -euo pipefail

BASE_DIR="/usr/src/packages"

usage() {
  cat <<EOF
Uso: $0 <nome> [categoria] [versao] [release]

  <nome>      Nome do programa (obrigatório)
  categoria   Categoria (default: core)
  versao      Versão (default: 5.8.1)
  release     Release (default: 1)

Exemplos:
  sudo $0 xz
  sudo $0 xz core 5.8.1 1
  sudo $0 attr core 2.5.2 1
EOF
  exit 1
}

if [ "$#" -lt 1 ]; then
  usage
fi

NAME="$1"
CATEGORY="${2:-core}"
VERSION="${3:-5.8.1}"
RELEASE="${4:-1}"

TARGET_DIR="${BASE_DIR}/${CATEGORY}/${NAME}"
METADATA_FILE="${TARGET_DIR}/metadata"

if [ "$(id -u)" -ne 0 ]; then
  echo "Este script precisa ser executado como root (para escrever em ${BASE_DIR})." >&2
  exit 1
fi

echo ">> Criando diretório: ${TARGET_DIR}"
mkdir -p "${TARGET_DIR}"

if [ -e "${METADATA_FILE}" ]; then
  echo "!! O arquivo ${METADATA_FILE} já existe."
  read -r -p "Sobrescrever? (digite 'SIM' para confirmar): " ans
  if [ "${ans}" != "SIM" ]; then
    echo "Cancelado."
    exit 1
  fi
fi

echo ">> Gerando metadata em ${METADATA_FILE}"

cat > "${METADATA_FILE}" <<EOF
# /usr/src/packages/${CATEGORY}/${NAME}/metadata

name="${NAME}"
category="${CATEGORY}"
version="${VERSION}"
release="${RELEASE}"

# Fonte oficial (a mesma que o LFS usa, versão estável atual)
sources=(
  "https://tukaani.org/xz/xz-\${version}.tar.xz"
)

depends=(
  "bash"
  "gcc"
  "make"
  "coreutils"
)

# SHA256 real do xz-\${version}.tar.xz
# (para outros pacotes, ajuste manualmente)
sha256sums=(
  "xz-\${version}.tar.xz=0b54f79df85912504de0b14aec7971e3f964491af1812d83447005807513cd9e"
)

# Descobre versão mais nova usando a página oficial do XZ.
upstream_latest_version() {
  local html
  if command -v curl >/dev/null 2>&1; then
    html="\$(curl -fsSL "https://tukaani.org/xz/")" || return 1
  else
    html="\$(wget -qO- "https://tukaani.org/xz/")" || return 1
  fi

  printf '%s\n' "\$html" \
    | sed -n 's/.*xz-\\([0-9][0-9.]*\\)\\.tar\\.xz.*/\\1/p' \
    | sort -V | tail -n1
}

# BUILD REAL – seguindo exatamente o LFS:
#   ./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/xz-\${version}
#   make
#   make check
#   make install
# Aqui o "make install" vai para DESTDIR pra permitir empacotamento.
build() {
  : "\${DESTDIR:=/}"

  # Encontrar diretório xz-\${version}
  local sdir
  sdir="\$(find . -mindepth 1 -maxdepth 1 -type d -name "xz-\${version}" | head -n1)"

  if [ -z "\$sdir" ]; then
    echo "Diretório xz-\${version} não encontrado" >&2
    return 1
  fi

  cd "\$sdir"

  ./configure --prefix=/usr \
              --disable-static \
              --docdir=/usr/share/doc/xz-\${version}

  make

  # Testes (como no livro)
  make check

  # Instalação em DESTDIR
  make DESTDIR="\${DESTDIR}" install
}
EOF

echo ">> Pronto."
echo "Arquivo criado: ${METADATA_FILE}"
echo
echo "ATENÇÃO:"
echo "- Este modelo é específico do xz (URL, SHA, docdir, build)."
echo "- Se você usar para outro pacote (${NAME}), ajuste manualmente:"
echo "  * sources"
echo "  * depends"
echo "  * sha256sums"
echo "  * função build()"
