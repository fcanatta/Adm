#!/usr/bin/env sh
# Instala no DESTDIR/PREFIX, cria wrapper, .desktop e ícones

set -eu
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:?BUILD_DIR não definido}"
: "${DESTDIR:?DESTDIR não definido}"
: "${PREFIX:?PREFIX não definido}"

cd "$SRC_DIR"

# Instala binários e recursos no tree padrão (lib/firefox, bin/firefox, etc)
# Algumas versões aceitam --destdir; em outras, honram DESTDIR no ambiente.
export DESTDIR
"$PYTHON" ./mach install --verbose || {
  echo "[ERROR] mach install falhou" >&2
  exit 1
}

# Determinar diretório de aplicação (normalmente ${PREFIX}/lib/firefox ou firefox-esr)
appdir_guess="${DESTDIR}${PREFIX}/lib"
appname=""
for d in firefox firefox-esr; do
  [ -d "${appdir_guess}/${d}" ] && appname="$d" && break
done
[ -n "$appname" ] || appname="firefox"
APPDIR="${DESTDIR}${PREFIX}/lib/${appname}"
mkdir -p "$APPDIR" || true

# Wrapper executável em /usr/bin/firefox
bindir="${DESTDIR}${PREFIX}/bin"
mkdir -p "$bindir" || true
cat > "${bindir}/firefox" <<'EOF'
#!/usr/bin/env sh
set -e
APPDIR="/usr/lib/firefox"
[ -d "/usr/lib/firefox-esr" ] && APPDIR="/usr/lib/firefox-esr"
# Wayland opcional
[ "${MOZ_ENABLE_WAYLAND:-0}" = "1" ] && export MOZ_ENABLE_WAYLAND=1
exec "${APPDIR}/firefox" "$@"
EOF
chmod 0755 "${bindir}/firefox"

# Se o usuário pediu Wayland por padrão, exportamos via wrapper de sistema (opcional)
if [ "${ADM_FIREFOX_ENABLE_WAYLAND:-0}" -eq 1 ]; then
  # No wrapper acima já honramos MOZ_ENABLE_WAYLAND se set; aqui criamos um env file opcional
  mkdir -p "${DESTDIR}/etc/profile.d" || true
  echo 'export MOZ_ENABLE_WAYLAND=1' > "${DESTDIR}/etc/profile.d/moz-wayland.sh"
  chmod 0644 "${DESTDIR}/etc/profile.d/moz-wayland.sh"
fi

# Arquivo de preferências do vendor (não falha se caminho mudar entre versões)
prefdir="${APPDIR}/browser/defaults/preferences"
mkdir -p "$prefdir" || true
cat > "${prefdir}/vendor.js" <<'EOF'
// Ajustes mínimos seguros
pref("browser.shell.checkDefaultBrowser", false);
pref("app.update.auto", false);
pref("datareporting.healthreport.uploadEnabled", false);
pref("toolkit.telemetry.enabled", false);
EOF

# .desktop
appsdir="${DESTDIR}${PREFIX}/share/applications"
mkdir -p "$appsdir" || true
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

# Ícones (usa os do branding distribuído no dist)
icondir_base="${DESTDIR}${PREFIX}/share/icons/hicolor"
for sz in 16 22 24 32 48 64 128 256; do
  src_png="$(find "$BUILD_DIR/dist" -type f -path "*/browser/branding/*/${sz}x${sz}/apps/firefox.png" | head -n1 || true)"
  [ -n "$src_png" ] || continue
  d="${icondir_base}/${sz}x${sz}/apps"
  mkdir -p "$d" || true
  cp -f "$src_png" "$d/firefox.png"
done
# Ícone escalável
src_svg="$(find "$BUILD_DIR/dist" -type f -name "firefox.svg" | head -n1 || true)"
if [ -n "$src_svg" ]; then
  d="${icondir_base}/scalable/apps"
  mkdir -p "$d" || true
  cp -f "$src_svg" "$d/firefox.svg"
fi

# Metadado auxiliar
{
  echo "NAME=firefox"
  echo "PREFIX=${PREFIX}"
  echo "BINDIR=${PREFIX}/bin"
  echo "APPDIR=${PREFIX}/lib/${appname}"
  echo "DESKTOP=${PREFIX}/share/applications/firefox.desktop"
  echo "TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${APPDIR}/.adm-firefox.meta" 2>/dev/null || true
