#!/usr/bin/env sh
# Copia firmwares para DESTDIR/FW_DEST, com filtro opcional

set -eu
: "${SRC_DIR:?SRC_DIR não definido}"
: "${DESTDIR:?DESTDIR não definido}"
: "${FW_DEST:=/lib/firmware}"

dst="${DESTDIR}${FW_DEST}"
mkdir -p "$dst" || true

if [ -z "${ADM_FIRMWARE_FILTER}" ]; then
  # Tudo (pode ser grande)
  # Exclui arquivos de VCS e LICENSES duplicadas extras se quiser reduzir
  tar -C "$SRC_DIR" -cf - . 2>/dev/null | tar -C "$dst" -xf -
else
  # Somente padrões selecionados
  for pat in ${ADM_FIRMWARE_FILTER}; do
    # Usa find para suportar globs
    find "$SRC_DIR" -path "$SRC_DIR/.git" -prune -o -type f -name "$(basename "$pat")" -print 2>/dev/null | while read -r f; do
      rel="${f#$SRC_DIR/}"
      dstd="$(dirname "$dst/$rel")"
      mkdir -p "$dstd" || true
      cp -a "$f" "$dst/$rel"
    done
    # Suporte a padrões com subdiretórios (ex: amdgpu/*)
    case "$pat" in
      */*) 
        # copia diretórios que casem com o prefixo
        pfx="${pat%/*}"
        if [ -d "$SRC_DIR/$pfx" ]; then
          mkdir -p "$dst/$pfx" || true
          tar -C "$SRC_DIR/$pfx" -cf - . 2>/dev/null | tar -C "$dst/$pfx" -xf -
        fi
        ;;
    esac
  done
fi

# Metadados auxiliares
{
  echo "NAME=linux-firmware"
  echo "DEST=${FW_DEST}"
  echo "FILTER=${ADM_FIRMWARE_FILTER}"
  echo "TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$dst/.adm-linux-firmware.meta" 2>/dev/null || true
