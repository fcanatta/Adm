#!/usr/bin/env sh
# Instala app, wrapper, .desktop, ícones e perfil AppArmor opcional

set -eu
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:?BUILD_DIR não definido}"
: "${DESTDIR:?DESTDIR não definido}"
: "${PREFIX:?PREFIX não definido}"

cd "$SRC_DIR"
export DESTDIR
"${PYTHON:-python3}" ./mach install --verbose || { echo "[ERROR] mach install falhou" >&2; exit 1; }

# Detecta appdir
appdir_guess="${DESTDIR}${PREFIX}/lib"; appname=""
for d in firefox firefox-esr; do [ -d "${appdir_guess}/${d}" ] && appname="$d" && break; done
[ -n "$appname" ] || appname="firefox"
APPDIR="${DESTDIR}${PREFIX}/lib/${appname}"
mkdir -p "$APPDIR" || true

# Wrapper
bindir="${DESTDIR}${PREFIX}/bin"; mkdir -p "$bindir" || true
cat > "${bindir}/firefox" <<'EOF'
#!/usr/bin/env sh
set -e
APPDIR="/usr/lib/firefox"; [ -d "/usr/lib/firefox-esr" ] && APPDIR="/usr/lib/firefox-esr"
# Wayland opcional
[ "${MOZ_ENABLE_WAYLAND:-0}" = "1" ] && export MOZ_ENABLE_WAYLAND=1
exec "${APPDIR}/firefox" "$@"
EOF
chmod 0755 "${bindir}/firefox"

# Wayland por padrão?
if [ "${ADM_FIREFOX_ENABLE_WAYLAND:-0}" -eq 1 ]; then
  mkdir -p "${DESTDIR}/etc/profile.d" || true
  echo 'export MOZ_ENABLE_WAYLAND=1' > "${DESTDIR}/etc/profile.d/moz-wayland.sh"
  chmod 0644 "${DESTDIR}/etc/profile.d/moz-wayland.sh"
fi

# vendor.js
prefdir="${APPDIR}/browser/defaults/preferences"; mkdir -p "$prefdir" || true
cat > "${prefdir}/vendor.js" <<'EOF'
pref("browser.shell.checkDefaultBrowser", false);
pref("app.update.auto", false);
pref("datareporting.healthreport.uploadEnabled", false);
pref("toolkit.telemetry.enabled", false);
EOF

# .desktop
appsdir="${DESTDIR}${PREFIX}/share/applications"; mkdir -p "$appsdir" || true
cat > "${appsdir}/firefox.desktop" <<'EOF'
[Desktop Entry]
Name=Firefox
GenericName=Web Browser
Comment=Browse the World Wide Web
Exec=firefox %u
Terminal=false
Type=Application
Icon=firefox
Categories=Network;WebBrowser;
MimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;
StartupNotify=true
EOF

# Ícones
icondir_base="${DESTDIR}${PREFIX}/share/icons/hicolor"
for sz in 16 22 24 32 48 64 128 256; do
  src_png="$(find "$BUILD_DIR/dist" -type f -path "*/browser/branding/*/${sz}x${sz}/apps/firefox.png" | head -n1 || true)"
  [ -n "$src_png" ] || continue
  d="${icondir_base}/${sz}x${sz}/apps"; mkdir -p "$d" || true
  cp -f "$src_png" "$d/firefox.png"
done
src_svg="$(find "$BUILD_DIR/dist" -type f -name "firefox.svg" | head -n1 || true)"
if [ -n "$src_svg" ]; then d="${icondir_base}/scalable/apps"; mkdir -p "$d" || true; cp -f "$src_svg" "$d/firefox.svg"; fi

# ======== AppArmor opcional ========
if [ "${ADM_FIREFOX_INSTALL_APPARMOR:-0}" -eq 1 ]; then
  aap_dir="${DESTDIR}/etc/apparmor.d"
  mkdir -p "$aap_dir" || true
  cat > "${aap_dir}/usr.lib.firefox.firefox" <<'AAE'
# Perfil AppArmor simples para /usr/lib/firefox/firefox
#include <tunables/global>
profile usr.lib.firefox.firefox flags=(attach_disconnected,mediate_deleted) {
  #binário principal
  /usr/lib/firefox/firefox ixr,
  /usr/lib/firefox-esr/firefox ixr,
  # libs e recursos
  /usr/lib/** mr,
  /usr/share/** r,
  # perfis básicos
  /etc/** r,
  # cache do usuário (runtime permitirá via abstrações do sistema)
  owner @{HOME}/.mozilla/** rwk,
  owner /tmp/** rw,
  # rede
  network inet stream,
  network inet6 stream,
  # herdado de abstrações comuns (se disponíveis)
  #include <abstractions/base>
  #include <abstractions/fonts>
  #include <abstractions/nameservice>
  #include <abstractions/ssl_certs>
}
AAE
  # ativação do perfil fica a cargo do administrador (host), ex:
  # apparmor_parser -r -W /etc/apparmor.d/usr.lib.firefox.firefox
fi

# Metadados
{
  echo "NAME=firefox"
  echo "PREFIX=${PREFIX}"
  echo "APPDIR=${PREFIX}/lib/${appname}"
  echo "LTO=${ADM_FIREFOX_LTO}"
  echo "PGO=${ADM_FIREFOX_PGO}"
  echo "TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${APPDIR}/.adm-firefox.meta" 2>/dev/null || true
