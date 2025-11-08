#!/usr/bin/env sh
# Limpeza pós-desinstalação — não toca fora do prefix

set -eu

: "${PREFIX:?PREFIX não definido}"
: "${TARGET:?TARGET não definido}"

# Apenas remove symlinks “curtos” se apontavam para o target atual
for link in "${PREFIX}/bin/ld"; do
  [ -L "$link" ] || continue
  tgt="$(readlink "$link" || true)"
  case "$tgt" in
    "${TARGET}-ld") rm -f "$link" || true;;
  esac
done

# Não removemos diretórios do PREFIX; o adm-install se encarrega via manifest.
exit 0
