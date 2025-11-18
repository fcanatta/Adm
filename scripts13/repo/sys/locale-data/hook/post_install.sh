#!/usr/bin/env bash
# post_install: locale-data (glibc)
# Gera locales usando localedef dentro do ADM_INSTALL_ROOT.
# Usa lista em ADM_LOCALES ou um conjunto padrão minimal.
# Se quiser set mínimo exportar antes
# export ADM_LOCALES="C.UTF-8 en_US.UTF-8 pt_BR.UTF-8"

set -euo pipefail

: "${ADM_INSTALL_ROOT:="/"}"
ROOT="${ADM_INSTALL_ROOT%/}"

# Lista de locales:
# - se ADM_LOCALES estiver setado (ex: "pt_BR.UTF-8 en_US.UTF-8"), usa ele
# - senão, usa um conjunto padrão
if [[ -n "${ADM_LOCALES:-}" ]]; then
    LOCALES="${ADM_LOCALES}"
else
    LOCALES="C.UTF-8 en_US.UTF-8 pt_BR.UTF-8"
fi

LOCALEDEF_BIN="${ROOT}/usr/bin/localedef"
if [[ ! -x "${LOCALEDEF_BIN}" ]]; then
    echo "[locale-data/post_install] localedef não encontrado em ${LOCALEDEF_BIN}, abortando geração de locales."
    exit 0
fi

LOCALE_DIR="/usr/lib/locale"

echo "[locale-data/post_install] Gerando locales em '${ROOT}${LOCALE_DIR}' para:"
echo "  ${LOCALES}"

# gera dentro do chroot, para usar a glibc recém instalada
for loc in ${LOCALES}; do
    # separa "lang" e "charset" (ex: pt_BR.UTF-8 → pt_BR.UTF-8 / UTF-8)
    lang="${loc%%.*}"
    charset="${loc#*.}"
    [[ "$charset" == "$lang" ]] && charset="UTF-8"

    echo "[locale-data/post_install] localedef -i ${lang} -f ${charset} ${loc}"
    chroot "${ROOT}" /usr/bin/localedef \
        -i "${lang}" -f "${charset}" "${loc}" \
        || echo "[locale-data/post_install] AVISO: falha ao gerar locale ${loc}."
done

echo "[locale-data/post_install] Geração de locales concluída."
