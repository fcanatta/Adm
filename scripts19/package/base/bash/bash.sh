#!/usr/bin/env bash
# bash-5.3.sh
#
# Pacote: GNU Bash 5.3
#
# Objetivo:
#   - Construir e instalar o bash-5.3 no sistema alvo via adm,
#     com destino final em /usr (e opcionalmente /bin via symlink).
#
# Integração com adm:
#   - Usa:
#       SRC_DIR   -> diretório com o código-fonte extraído (bash-5.3)
#       DESTDIR   -> raiz fake usada para "make install"
#       NUMJOBS   -> número de jobs (opcional)
#   - Respeita TARGET_TRIPLET se definido (cross/nativo).
#
# Diferencial:
#   - Detecta automaticamente se existe readline instalada em
#     ${ADM_ROOTFS}/usr/include e ${ADM_ROOTFS}/usr/lib:
#       * se SIM => usa --with-installed-readline
#       * se NÃO => deixa o bash usar a readline interna

PKG_VERSION="5.3"

SRC_URL="https://ftp.gnu.org/gnu/bash/bash-${PKG_VERSION}.tar.gz"
SRC_MD5=""

pkg_build() {
    # Variáveis fornecidas pelo adm:
    #   SRC_DIR, DESTDIR, NUMJOBS
    cd "$SRC_DIR"

    # ===========================================
    # 1. TARGET_TRIPLET, ADM_ROOTFS
    # ===========================================

    : "${TARGET_TRIPLET:=}"

    if [[ -z "$TARGET_TRIPLET" ]]; then
        # Se não foi setado, tentamos HOST ou config.guess
        if [[ -n "${HOST:-}" ]]; then
            TARGET_TRIPLET="$HOST"
        else
            if [[ -x "./support/config.guess" ]]; then
                TARGET_TRIPLET="$(./support/config.guess)"
            else
                TARGET_TRIPLET="$(uname -m)-unknown-linux-gnu"
            fi
        fi
    fi

    echo ">> bash-${PKG_VERSION} host/target: ${TARGET_TRIPLET}"

    : "${ADM_ROOTFS:=/}"
    case "$ADM_ROOTFS" in
        /) ;;
        */) ADM_ROOTFS="${ADM_ROOTFS%/}" ;;
    esac
    echo ">> ADM_ROOTFS = ${ADM_ROOTFS}"

    # ===========================================
    # 2. Flags padrão e ambiente
    # ===========================================

    : "${NUMJOBS:=1}"
    : "${CFLAGS:=-O2 -pipe}"
    : "${CXXFLAGS:=-O2 -pipe}"

    export CFLAGS
    export CXXFLAGS

    # Se quiser forçar cross:
    # export CC="${TARGET_TRIPLET}-gcc"

    # Determinar BUILD/HOST (ajuda em cenários cross)
    if [[ -x "./support/config.guess" ]]; then
        BUILD_TRIPLET="$(./support/config.guess)"
    else
        BUILD_TRIPLET="$(uname -m)-unknown-linux-gnu"
    fi
    HOST_TRIPLET="${TARGET_TRIPLET}"

    echo ">> BUILD_TRIPLET = ${BUILD_TRIPLET}"
    echo ">> HOST_TRIPLET  = ${HOST_TRIPLET}"

    # ===========================================
    # 3. DETECÇÃO DE READLINE EXTERNA
    # ===========================================
    #
    # Procura por:
    #   - headers:   ${ADM_ROOTFS}/usr/include/readline/readline.h
    #   - libs:      ${ADM_ROOTFS}/usr/lib/libreadline.so*
    #
    # Se achar, ajusta CPPFLAGS/LDFLAGS e usa --with-installed-readline.
    # Caso contrário, deixa o bash usar a readline interna.

    USE_INSTALLED_READLINE=0

    RL_ROOT="${ADM_ROOTFS}"
    RL_INC_DIR_1="${RL_ROOT}/usr/include/readline"
    RL_INC_DIR_2="${RL_ROOT}/usr/include"
    RL_LIB_DIR="${RL_ROOT}/usr/lib"

    have_header=0
    have_lib=0

    # Headers
    if [[ -f "${RL_INC_DIR_1}/readline.h" ]]; then
        have_header=1
        RL_INC_USE="${RL_INC_DIR_1}"
    elif [[ -f "${RL_INC_DIR_2}/readline/readline.h" ]]; then
        have_header=1
        RL_INC_USE="${RL_INC_DIR_2}/readline"
    fi

    # Libs
    if ls "${RL_LIB_DIR}"/libreadline.so* >/dev/null 2>&1; then
        have_lib=1
        RL_LIB_USE="${RL_LIB_DIR}"
    fi

    if [[ "$have_header" -eq 1 && "$have_lib" -eq 1 ]]; then
        USE_INSTALLED_READLINE=1
        echo ">> Detectada readline externa em:"
        echo "     include: ${RL_INC_USE}"
        echo "     lib:     ${RL_LIB_USE}"

        # Ajustar CPPFLAGS/LDFLAGS para o configure do bash
        CPPFLAGS="${CPPFLAGS:-} -I${RL_INC_USE}"
        LDFLAGS="${LDFLAGS:-} -L${RL_LIB_USE}"

        export CPPFLAGS
        export LDFLAGS
    else
        echo ">> NÃO foi detectada readline externa completa em ${ADM_ROOTFS}."
        echo "   - have_header=${have_header}, have_lib=${have_lib}"
        echo "   - Bash usará a readline interna embutida."
    fi

    # ===========================================
    # 4. Diretório de build separado
    # ===========================================

    rm -rf build
    mkdir -v build
    cd       build

    # ===========================================
    # 5. Configure do bash
    # ===========================================
    #
    # Opções base:
    #   --prefix=/usr
    #   --build / --host
    #   --without-bash-malloc  -> usa malloc da libc (recomendado)
    #
    # Se USE_INSTALLED_READLINE=1:
    #   adiciona --with-installed-readline

    cfg_opts=(
        --prefix=/usr
        --build="${BUILD_TRIPLET}"
        --host="${HOST_TRIPLET}"
        --without-bash-malloc
    )

    if [[ "$USE_INSTALLED_READLINE" -eq 1 ]]; then
        cfg_opts+=( --with-installed-readline )
    fi

    echo ">> Rodando ./configure do bash com opções:"
    printf '   %q\n' ../configure "${cfg_opts[@]}"

    ../configure "${cfg_opts[@]}"

    # ===========================================
    # 6. Compilar e instalar em DESTDIR
    # ===========================================

    echo ">> Compilando bash-${PKG_VERSION} ..."
    make -j"${NUMJOBS}"

    echo ">> Instalando bash-${PKG_VERSION} em DESTDIR=${DESTDIR} ..."
    make DESTDIR="${DESTDIR}" install

    # ===========================================
    # 7. (Opcional) Criar /bin/bash como symlink para /usr/bin/bash
    # ===========================================
    #
    # Muitos scripts esperam /bin/bash.
    # Você pode ativar isso aqui, ou tratar em um pacote filesystem/base.

    # mkdir -pv "${DESTDIR}/bin"
    # ln -svf ../usr/bin/bash "${DESTDIR}/bin/bash"

    echo ">> bash-${PKG_VERSION} construído e instalado em DESTDIR=${DESTDIR}."
}
