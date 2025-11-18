#!/usr/bin/env bash
# pre_build: perl 5.42.0
# - roda ./Configure com opções sensatas
# - usa /usr como prefixo
# - usa threads
# - não roda se já existir config.sh

set -euo pipefail

: "${ADM_BUILD_DIR:="${PWD}"}"
cd "${ADM_BUILD_DIR}"

if [[ -f config.sh ]]; then
    echo "[perl/pre_build] Perl já configurado (config.sh existe), pulando."
    exit 0
fi

PROFILE="${ADM_PROFILE:-normal}"

# flags suaves por profile
case "${PROFILE}" in
    aggressive)
        export CFLAGS="${CFLAGS:-} -O3 -pipe"
        ;;
    minimal)
        export CFLAGS="${CFLAGS:-} -O2 -pipe"
        ;;
    *)
        export CFLAGS="${CFLAGS:-} -O2 -pipe"
        ;;
esac

echo "[perl/pre_build] Rodando ./Configure (profile=${PROFILE})."

# -des: usa defaults e não pergunta nada
./Configure -des \
  -Dprefix=/usr \
  -Dvendorprefix=/usr \
  -Dprivlib=/usr/lib/perl5/5.42/core_perl \
  -Darchlib=/usr/lib/perl5/5.42/core_perl \
  -Dvendorlib=/usr/lib/perl5/5.42/vendor_perl \
  -Dvendorarch=/usr/lib/perl5/5.42/vendor_perl \
  -Dman1dir=/usr/share/man/man1 \
  -Dman3dir=/usr/share/man/man3 \
  -Dusethreads \
  -Duseshrplib

echo "[perl/pre_build] Configure concluído."
