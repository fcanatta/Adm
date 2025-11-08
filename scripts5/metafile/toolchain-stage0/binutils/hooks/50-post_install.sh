#!/usr/bin/env sh
# Ajustes pós-instalação no DESTDIR (sem tocar no / “vivo”)

set -eu

: "${DESTDIR:?DESTDIR não definido}"
: "${PREFIX:?PREFIX não definido}"
: "${TARGET:?TARGET não definido}"

# Garante diretórios esperados
mkdir -p "${DESTDIR}${PREFIX}/bin" \
         "${DESTDIR}${PREFIX}/${TARGET}/bin" \
         "${DESTDIR}${PREFIX}/lib" 2>/dev/null || true

# Garantir que 'ld' e 'as' do target estejam acessíveis via ${TARGET}-*
# (normalmente o 'make install' já cria, aqui só conferimos/sincronizamos)
for tool in ar as ld nm objcopy objdump ranlib readelf size strings strip; do
  # Se a variante ${TARGET}-${tool} existir, OK; caso contrário, crie link para a genérica
  if [ ! -x "${DESTDIR}${PREFIX}/bin/${TARGET}-${tool}" ] && [ -x "${DESTDIR}${PREFIX}/bin/${tool}" ]; then
    ln -sf "${tool}" "${DESTDIR}${PREFIX}/bin/${TARGET}-${tool}"
  fi
done

# Opcional: linkar 'ld' “curto” apontando para ${TARGET}-ld (em stage0 só no PREFIX, nunca em /)
if [ -x "${DESTDIR}${PREFIX}/bin/${TARGET}-ld" ] && [ ! -e "${DESTDIR}${PREFIX}/bin/ld" ]; then
  ln -sf "${TARGET}-ld" "${DESTDIR}${PREFIX}/bin/ld"
fi

# Registro leve para o registry (o adm-install gera manifest; aqui só um meta auxiliar no DESTDIR)
{
  echo "NAME=binutils"
  echo "TARGET=${TARGET}"
  echo "PREFIX=${PREFIX}"
  echo "STAGE=0"
  echo "TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${DESTDIR}${PREFIX}/.adm-binutils-stage0.meta" 2>/dev/null || true
