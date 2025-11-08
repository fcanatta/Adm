#!/usr/bin/env sh
# Limpeza suave de artefatos auxiliares (manifest do uninstall gerencia o resto)

set -eu
: "${DESTDIR:=/}"
: "${PREFIX:=/usr}"

# Remover env opcional
rm -f "${DESTDIR}/etc/profile.d/moz-wayland.sh" 2>/dev/null || true
# Remover .desktop (será tratado pelo manifest; aqui só garantimos limpeza se sobrar)
rm -f "${DESTDIR}${PREFIX}/share/applications/firefox.desktop" 2>/dev/null || true
# Metadados
rm -f "${DESTDIR}${PREFIX}/lib/firefox/.adm-firefox.meta" 2>/dev/null || true
rm -f "${DESTDIR}${PREFIX}/lib/firefox-esr/.adm-firefox.meta" 2>/dev/null || true
exit 0
