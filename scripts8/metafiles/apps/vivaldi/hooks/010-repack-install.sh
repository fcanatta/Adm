#!/usr/bin/env bash
# Extrai .deb/.rpm em DESTDIR e cria symlinks/desktop
set -Eeuo pipefail
: "${DESTDIR:=/}"
: "${PREFIX:=/usr}"

shopt -s nullglob
deb=( *.deb )
rpm=( *.rpm )

work="$(pwd)/.repack"
mkdir -p "$work"

if (( ${#deb[@]} )); then
  echo "[vivaldi] extraindo .deb"
  # .deb é ar: data.tar.{xz,zst,gz}
  rm -rf "$work" && mkdir -p "$work"
  ar x "${deb[0]}"
  tarball=""
  for t in data.tar.zst data.tar.xz data.tar.gz data.tar; do
    [[ -f "$t" ]] && tarball="$t" && break
  done
  [[ -n "$tarball" ]] || { echo "[vivaldi] ERRO: data.tar.* ausente no deb"; exit 2; }
  mkdir -p "$work/root"
  tar -C "$work/root" -xf "$tarball"
  # mover para /opt/vivaldi mantendo estrutura
  mkdir -p "${DESTDIR}/opt"
  if [[ -d "$work/root/opt/vivaldi" ]]; then
    cp -a "$work/root/opt/vivaldi" "${DESTDIR}/opt/"
  else
    # alguns pacotes instalam em /usr/lib/vivaldi
    if [[ -d "$work/root/usr/lib/vivaldi" ]]; then
      mkdir -p "${DESTDIR}/opt"
      cp -a "$work/root/usr/lib/vivaldi" "${DESTDIR}/opt/"
    fi
  fi
  # desktop e ícones (se existirem)
  if [[ -d "$work/root/usr/share" ]]; then
    cp -a "$work/root/usr/share" "${DESTDIR}/usr/"
  fi
elif (( ${#rpm[@]} )); then
  echo "[vivaldi] extraindo .rpm"
  rm -rf "$work" && mkdir -p "$work"
  if command -v rpm2cpio >/dev/null 2>&1; then
    rpm2cpio "${rpm[0]}" | (cd "$work" && cpio -idm)
  else
    echo "[vivaldi] ERRO: rpm2cpio não encontrado"; exit 2
  fi
  mkdir -p "${DESTDIR}"
  cp -a "$work/." "${DESTDIR}/"
else
  echo "[vivaldi] ERRO: faltou .deb ou .rpm"; exit 2
fi

# binário wrapper
mkdir -p "${DESTDIR}${PREFIX}/bin"
cat > "${DESTDIR}${PREFIX}/bin/vivaldi" <<'WRAP'
#!/usr/bin/env bash
exec /opt/vivaldi/vivaldi "$@"
WRAP
chmod +x "${DESTDIR}${PREFIX}/bin/vivaldi"

# .desktop (se não vier no pacote)
if [[ ! -f "${DESTDIR}${PREFIX}/share/applications/vivaldi-stable.desktop" ]]; then
  mkdir -p "${DESTDIR}${PREFIX}/share/applications"
  cat > "${DESTDIR}${PREFIX}/share/applications/vivaldi.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=Vivaldi
Exec=vivaldi %U
Icon=vivaldi
Terminal=false
Categories=Network;WebBrowser;
MimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;
DESK
fi

echo "[vivaldi] instalado em /opt/vivaldi; wrapper /usr/bin/vivaldi criado"
