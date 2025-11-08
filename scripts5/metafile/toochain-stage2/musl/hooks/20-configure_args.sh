#!/usr/bin/env sh
# musl aceita ./configure com --prefix e --syslibdir; ecoe em uma linha

set -eu
: "${PREFIX:?}"
: "${SYSLIBDIR:?}"
# --libdir segue syslibdir na musl
echo "--prefix=${PREFIX} --syslibdir=${SYSLIBDIR}"
