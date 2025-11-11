#!/usr/bin/env bash
# Garante atalho .desktop e ícone (se o tarball não instalar)
set -Eeuo pipefail
: "${DESTDIR:=/}"
: "${PREFIX:=/usr}"

mkdir -p "${DESTDIR}${PREFIX}/share/applications" "${DESTDIR}${PREFIX}/share/pixmaps"
cat > "${DESTDIR}${PREFIX}/share/applications/qutebrowser.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=qutebrowser
Exec=qutebrowser %u
Icon=qutebrowser
Terminal=false
Categories=Network;WebBrowser;
MimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;
DESK
# Ícone genérico como fallback (o pacote upstream costuma fornecer)
if [[ ! -f "${DESTDIR}${PREFIX}/share/pixmaps/qutebrowser.png" ]]; then
  : # deixe para o pacote upstream ou tema de ícones do sistema
fi
echo "[qutebrowser] desktop file OK"
