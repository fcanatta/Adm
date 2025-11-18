#!/usr/bin/env bash
# post_install: iana-etc-20251022
# - garante /etc/services e /etc/protocols no ADM_INSTALL_ROOT
# - faz backup dos arquivos antigos se existirem

set -euo pipefail

: "${ADM_INSTALL_ROOT:="/"}"
ROOT="${ADM_INSTALL_ROOT%/}"

SRC_ETC="${ROOT}/usr/share/iana-etc"
DEST_ETC="${ROOT}/etc"

mkdir -p "${DEST_ETC}"

copy_with_backup() {
    local src="$1" dest="$2"

    if [[ ! -f "${src}" ]]; then
        echo "[iana-etc/post_install] AVISO: arquivo '${src}' não encontrado."
        return
    fi

    if [[ -f "${dest}" ]]; then
        local bak="${dest}.adm-bak-$(date +%Y%m%d%H%M%S)"
        echo "[iana-etc/post_install] '${dest}' existe, movendo para '${bak}'."
        mv -f "${dest}" "${bak}"
    fi

    echo "[iana-etc/post_install] Instalando '${dest#${ROOT}}'."
    cp -f "${src}" "${dest}"
}

# Geralmente o tarball instala em /usr/share/iana-etc ou semelhante.
# Ajusta aqui se você preferir outro layout no pacote.
copy_with_backup "${SRC_ETC}/services"  "${DEST_ETC}/services"
copy_with_backup "${SRC_ETC}/protocols" "${DEST_ETC}/protocols"

echo "[iana-etc/post_install] Concluído."
