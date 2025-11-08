#!/usr/bin/env sh
# Compila Firefox; se PGO=1, faz duas fases (generate -> perf -> use)

set -eu
: "${SRC_DIR:?SRC_DIR não definido}"
: "${BUILD_DIR:?BUILD_DIR não definido}"
: "${PYTHON:?}"

cd "$SRC_DIR"
export MOZ_OFFICIAL=1
export MOZBUILD_STATE_PATH="${BUILD_DIR}/.mozstate"
mkdir -p "$MOZBUILD_STATE_PATH" || true

run_mach_build(){
  "$PYTHON" ./mach build
}

pgo_generate(){
  # altera .mozconfig para --enable-profile-generate
  moz="$BUILD_DIR/.mozconfig"
  cp -f "$moz" "$moz.pregen"
  { cat "$moz.pregen"; echo "ac_add_options --enable-profile-generate"; } > "$moz"
  # limpa parcialmente objeto para garantir instrumentação
  "$PYTHON" ./mach clobber || true
  run_mach_build
}

pgo_profileserver(){
  # tenta rodar profileserver (xvfb-run se houver; senão headless)
  timeout_min="${ADM_FIREFOX_PGO_TIMEOUT:-10}"
  if command -v xvfb-run >/dev/null 2>&1; then
    xvfb-run --auto-servernum --server-args="-screen 0 1280x800x24" \
      "$PYTHON" ./mach python build/pgo/profileserver.py --timeout "${timeout_min}" || \
      echo "[WARN] profileserver falhou (xvfb)"
  else
    # fallback: tenta --headless com profileserver
    "$PYTHON" ./mach python build/pgo/profileserver.py --timeout "${timeout_min}" --headless || \
      echo "[WARN] profileserver falhou (headless)"
  fi
}

pgo_use(){
  moz="$BUILD_DIR/.mozconfig"
  cp -f "$moz" "$moz.gen"
  # remove generate e habilita profile-use
  grep -v -- '--enable-profile-generate' "$moz.gen" > "$moz.gen2" || true
  { cat "$moz.gen2"; echo "ac_add_options --enable-profile-use"; } > "$moz"
  # rebuild com uso do perfil (mantendo LTO se pedido)
  "$PYTHON" ./mach clobber || true
  run_mach_build
}

if [ "${ADM_FIREFOX_PGO:-0}" -eq 1 ]; then
  echo "[PGO] Fase 1: generate"
  pgo_generate
  echo "[PGO] Rodando profileserver"
  pgo_profileserver
  echo "[PGO] Fase 2: use"
  pgo_use
else
  run_mach_build
fi

# Registra distdir
echo "$BUILD_DIR/dist" > "$BUILD_DIR/.distdir"
