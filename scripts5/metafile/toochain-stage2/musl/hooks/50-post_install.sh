#!/usr/bin/env sh
# Instala a libc e ajusta links/paths

set -eu

: "${SRC_DIR:?SRC_DIR não definido}"
: "${DESTDIR:?DESTDIR não definido}"
: "${SYSLIBDIR:?SYSLIBDIR não definido}"

# Instala a musl (usa targets próprios)
make -C "$SRC_DIR" DESTDIR="$DESTDIR" install

# Garantir que a ld-musl-*.so.1 esteja no SYSLIBDIR (/lib)
# musl já instala como /lib/ld-musl-$(arch).so.1; criamos um alias genérico opcional
arch="$(uname -m 2>/dev/null || echo x86_64)"
ldso=""
for f in "$DESTDIR$SYSLIBDIR"/ld-musl-*.so.1; do
  [ -e "$f" ] && ldso="$f" && break
done

if [ -n "$ldso" ]; then
  base="$(basename "$ldso")"
  # Link genérico (pode ajudar em imagens/resgates):
  ln -sfn "$base" "$DESTDIR$SYSLIBDIR/ld-musl.so.1" 2>/dev/null || true
fi

# /etc/ld-musl-*.path define caminhos de libs procurados pelo ldso musl (opcional)
etcdir="$DESTDIR/etc"
mkdir -p "$etcdir" 2>/dev/null || true
for f in "$DESTDIR$SYSLIBDIR"/ld-musl-*.so.1; do
  [ -e "$f" ] || continue
  suff="$(basename "$f" | sed 's/^ld-musl-//; s/\.so\.1$//')"
  echo "/lib:/usr/lib" > "$etcdir/ld-musl-$suff.path" 2>/dev/null || true
done

# Metadados auxiliares
{
  echo "NAME=musl"
  echo "STAGE=2"
  echo "PREFIX=${PREFIX}"
  echo "SYSLIBDIR=${SYSLIBDIR}"
  echo "TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$DESTDIR$SYSLIBDIR/.adm-musl-stage2.meta" 2>/dev/null || true
