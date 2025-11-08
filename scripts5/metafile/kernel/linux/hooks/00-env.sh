#!/usr/bin/env sh
# Ambiente de build do kernel (nativo)

set -eu

: "${DESTDIR:=/}"               # o pipeline instalará no root via manifest
: "${PREFIX:=/usr}"             # não é usado pelo kernel, mantido por consistência
: "${MAKEFLAGS:=-j$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
: "${SOURCE_DATE_EPOCH:=1704067200}"
: "${KBUILD_BUILD_USER:=adm}"
: "${KBUILD_BUILD_HOST:=builder}"
: "${KBUILD_BUILD_TIMESTAMP:=Mon Jan 01 00:00:00 UTC 2024}"
export DESTDIR PREFIX MAKEFLAGS SOURCE_DATE_EPOCH \
       KBUILD_BUILD_USER KBUILD_BUILD_HOST KBUILD_BUILD_TIMESTAMP LC_ALL=C

# Configuração
# ADM_KERNEL_CONFIG: caminho opcional de um .config para usar
# ADM_KERNEL_DEFCONFIG: ex: "defconfig" ou "x86_64_defconfig" (fallback)
: "${ADM_KERNEL_CONFIG:=}"
: "${ADM_KERNEL_DEFCONFIG:=defconfig}"
# Sufixo de versão opcional (exibe em uname -r como localversion)
: "${ADM_KERNEL_LOCALVERSION:=}"
# Compressão do kernel ao instalar (bzImage/Imagem já vêm do build)
: "${ADM_KERNEL_IMAGE:=bzImage}"     # bzImage (x86), Image (arm64), etc.
export ADM_KERNEL_CONFIG ADM_KERNEL_DEFCONFIG ADM_KERNEL_LOCALVERSION ADM_KERNEL_IMAGE
