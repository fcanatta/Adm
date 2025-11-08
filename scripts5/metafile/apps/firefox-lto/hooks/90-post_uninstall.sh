#!/usr/bin/env sh
set -eu
: "${DESTDIR:=/}"
: "${PREFIX:=/usr}"
rm -f "${DESTDIR}/etc/profile.d/moz-wayland.sh" 2>/dev/null || true
rm -f "${DESTDIR}${PREFIX}/share/applications/firefox.desktop" 2>/dev/null || true
rm -f "${DESTDIR}${PREFIX}/lib/firefox/.adm-firefox.meta" 2>/dev/null || true
rm -f "${DESTDIR}${PREFIX}/lib/firefox-esr/.adm-firefox.meta" 2>/dev/null || true
# Perfil AppArmor opcional
rm -f "${DESTDIR}/etc/apparmor.d/usr.lib.firefox.firefox" 2>/dev/null || true
exit 0
