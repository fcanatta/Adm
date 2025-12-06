#!/usr/bin/env bash
#
# chroot.profile
#
# Profile especial para usar o ADM *dentro* do chroot.
# Assumimos que o chroot já está em cima do rootfs que você construiu com o ADM.
#
# ROOTFS passa a ser "/" (pois já estamos dentro do rootfs).
# CHOST é detectado automaticamente se não estiver definido.

ADM_NAME="chroot"
ROOTFS="/"

# Detecta CHOST se não vier de fora
if [[ -z "${CHOST:-}" ]]; then
    if command -v gcc >/dev/null 2>&1; then
        CHOST="$(gcc -dumpmachine)"
    else
        # fallback genérico; ajuste se necessário
        CHOST="x86_64-linux-gnu"
    fi
fi

# Jobs de compilação
ADM_JOBS="${ADM_JOBS:-$(nproc 2>/dev/null || echo 2)}"

# Caminhos padrão dentro do chroot
export ROOTFS
export CHOST
export ADM_JOBS

# PATH padrão (sem /tools, já que é ambiente final; adicione se quiser)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
