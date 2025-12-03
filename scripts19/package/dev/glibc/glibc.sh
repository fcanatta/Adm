#!/usr/bin/env bash
# Script de construção do Glibc para o adm
#
# Caminho esperado:
#   /mnt/adm/packages/libs/glibc/glibc.sh
#
# O adm fornece:
#   SRC_DIR  : diretório com o source extraído do tarball
#   DESTDIR  : raiz de instalação temporária (pkgroot)
#   PROFILE  : glibc / musl / outro (string)
#   NUMJOBS  : número de jobs para o make
#
# Este script define:
#   PKG_VERSION
#   SRC_URL
#   (opcional) SRC_MD5
#   função pkg_build()
#
# OBS:
#   - Glibc 2.42 pede GCC >= 12.1 e Binutils >= 2.39.
#   - Pressupõe headers de kernel já instalados em /usr/include.

PKG_VERSION="2.42"
SRC_URL="https://ftp.osuosl.org/pub/lfs/lfs-packages/12.4/glibc-${PKG_VERSION}.tar.xz"
# Alternativa oficial:
# SRC_URL="https://ftp.gnu.org/gnu/glibc/glibc-${PKG_VERSION}.tar.xz"
# SRC_MD5 opcional:
# SRC_MD5="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

#--------------------------------------------------------
# Geração de locales (chamado depois do "make install")
#--------------------------------------------------------
generate_glibc_locales() {
  # Usa localedef do sistema host
  local localedef_bin="${LOCALEDEF:-localedef}"
  local adm_root="${ADM_ROOT:-/mnt/adm}"
  local locale_gen_file="${adm_root}/etc/locale.gen"

  if ! command -v "$localedef_bin" >/dev/null 2>&1; then
    echo "==> [glibc] AVISO: localedef não encontrado; pulando geração de locales."
    return 0
  fi

  echo "==> [glibc] Gerando locales dentro do DESTDIR usando: $localedef_bin"

  # Lê lista de locales de um arquivo estilo LFS:
  #   <locale> <charmap>
  # Ex:
  #   en_US.UTF-8 UTF-8
  #   pt_BR.UTF-8 UTF-8
  local entries=()

  if [[ -f "$locale_gen_file" ]]; then
    echo "==> [glibc] Usando lista de locales de: $locale_gen_file"
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="$(echo "$line" | xargs || true)"
      [[ -z "$line" ]] && continue
      entries+=("$line")
    done < "$locale_gen_file"
  else
    echo "==> [glibc] $locale_gen_file não encontrado; usando conjunto padrão mínimo."
    entries+=("en_US.UTF-8 UTF-8")
    entries+=("pt_BR.UTF-8 UTF-8")
  fi

  if ((${#entries[@]} == 0)); then
    echo "==> [glibc] Nenhum locale definido; pulando geração."
    return 0
  fi

  # Gera cada locale em DESTDIR
  #   localedef --prefix="$DESTDIR" -i <input> -f <charmap> <locale>
  #   onde <input> é o nome sem ".charset", ex: pt_BR para pt_BR.UTF-8
  for entry in "${entries[@]}"; do
    local locale_name charset in_name
    locale_name="${entry%% *}"
    charset="${entry##* }"
    # parte antes do primeiro ponto: pt_BR.UTF-8 -> pt_BR
    in_name="${locale_name%%.*}"

    echo "   - Gerando locale: $locale_name (charmap: $charset, input: $in_name)"
    if ! "$localedef_bin" --prefix="$DESTDIR" \
           -i "$in_name" -f "$charset" "$locale_name" 2>/dev/null; then
      echo "      AVISO: falha ao gerar locale $locale_name ($charset)."
      echo "             Verifique se os arquivos de locale existem em /usr/share/i18n/locales."
      # não dou exit 1 aqui pra não matar o build todo por um locale opcional
    fi
  done

  echo "==> [glibc] Geração de locales concluída."
}

pkg_build() {
  set -euo pipefail

  echo "==> [glibc] Build iniciado"
  echo "    Versão  : ${PKG_VERSION}"
  echo "    SRC_DIR : ${SRC_DIR}"
  echo "    DESTDIR : ${DESTDIR}"
  echo "    PROFILE : ${PROFILE:-desconhecido}"
  echo "    NUMJOBS : ${NUMJOBS:-1}"

  cd "$SRC_DIR"

  #------------------------------------
  # Detecção de arquitetura e flags
  #------------------------------------
  local ARCH CFLAGS_GLIBC
  ARCH="$(uname -m)"

  case "$ARCH" in
    i?86)
      ARCH=i386
      CFLAGS_GLIBC="-O2 -pipe"
      ;;
    x86_64)
      CFLAGS_GLIBC="-O2 -pipe -fno-omit-frame-pointer"
      ;;
    *)
      CFLAGS_GLIBC="-O2 -pipe"
      ;;
  esac

  echo "==> [glibc] ARCH   : $ARCH"
  echo "==> [glibc] CFLAGS : $CFLAGS_GLIBC"

  #------------------------------------
  # PROFILE (informativo)
  #------------------------------------
  case "${PROFILE:-}" in
    glibc|"")
      echo "==> [glibc] PROFILE = glibc (esperado para esta libc)"
      ;;
    musl)
      echo "==> [glibc] PROFILE = musl, mas estamos construindo glibc (provável rootfs/chroot)."
      ;;
    *)
      echo "==> [glibc] PROFILE desconhecido (${PROFILE}), apenas informativo."
      ;;
  esac

  #------------------------------------
  # Patches recomendados LFS 12.4
  #------------------------------------
  local PATCH_BASE="https://www.linuxfromscratch.org/patches/lfs/development"

  apply_patch_stream() {
    local url="$1"
    echo "==> [glibc] Baixando e aplicando patch: $url"
    if command -v curl >/dev/null 2>&1; then
      if ! curl -fsSL "$url" | patch -Np1; then
        echo "ERRO: falha ao aplicar patch de $url"
        exit 1
      fi
    elif command -v wget >/dev/null 2>&1; then
      if ! wget -qO- "$url" | patch -Np1; then
        echo "ERRO: falha ao aplicar patch de $url"
        exit 1
      fi
    else
      echo "ERRO: nem curl nem wget disponíveis para baixar patches."
      exit 1
    fi
  }

  # upstream_fixes + fhs (LFS 12.4)
  apply_patch_stream "${PATCH_BASE}/glibc-2.42-upstream_fixes-1.patch"
  apply_patch_stream "${PATCH_BASE}/glibc-2.42-fhs-1.patch"

  echo "==> [glibc] Patches upstream_fixes-1 e fhs-1 aplicados."

  #------------------------------------
  # Ajuste em stdlib/abort.c (Valgrind fix)
  #------------------------------------
  echo "==> [glibc] Aplicando ajuste em stdlib/abort.c (Valgrind fix)"
  sed -e '/unistd.h/i #include <string.h>' \
      -e '/libc_rwlock_init/c\
  __libc_rwlock_define_initialized (, reset_lock);\
  memcpy (&lock, &reset_lock, sizeof (lock));' \
      -i stdlib/abort.c

  #------------------------------------
  # Diretório de build separado
  #------------------------------------
  echo "==> [glibc] Criando diretório de build"
  rm -rf build
  mkdir -p build
  cd build

  # Garantir ldconfig/sln em /usr/sbin (dentro do DESTDIR)
  echo "rootsbindir=/usr/sbin" > configparms

  #------------------------------------
  # Configure (baseado no LFS 12.4)
  #------------------------------------
  echo "==> [glibc] Rodando configure"

  CFLAGS="$CFLAGS_GLIBC" \
  ../configure \
    --prefix=/usr                   \
    --disable-werror                \
    --disable-nscd                  \
    libc_cv_slibdir=/usr/lib        \
    --enable-stack-protector=strong \
    --enable-kernel=5.4

  echo "==> [glibc] configure concluído"

  #------------------------------------
  # Compilação
  #------------------------------------
  echo "==> [glibc] Compilando..."
  make -j"${NUMJOBS:-1}"
  echo "==> [glibc] make concluído"

  #------------------------------------
  # Testes (opcionais – pesados)
  #------------------------------------
  # echo "==> [glibc] Testes (make check)..."
  # make check || true

  #------------------------------------
  # Instalação em DESTDIR
  #------------------------------------
  echo "==> [glibc] Instalando em DESTDIR=${DESTDIR}"
  make DESTDIR="$DESTDIR" install

  #------------------------------------
  # Geração de locales dentro do DESTDIR
  #------------------------------------
  generate_glibc_locales

  # Não faço strip agressivo em glibc (melhor para debug).
  echo "==> [glibc] Build do glibc-${PKG_VERSION} finalizado com sucesso."
}
