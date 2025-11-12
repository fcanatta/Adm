#!/usr/bin/env bash
# Autodetecta libs via pkg-config, aplica flags de performance e habilita encoders/decoders
set -Eeuo pipefail

export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"

: "${PREFIX:=/usr}"
: "${SYSROOT:=/}"
: "${CC:=cc}"

# perfil aggressive → otimizações
if [[ "${ADM_PROFILE:-}" == "aggressive" ]]; then
  export CFLAGS="${CFLAGS:-} -O3 -pipe -fno-plt -march=native -mtune=native"
  export CXXFLAGS="${CXXFLAGS:-} -O3 -pipe -fno-plt -march=native -mtune=native"
fi

have() { command -v "$1" >/dev/null 2>&1; }
pc() { pkg-config --exists "$1" 2>/dev/null; }

OPTS=(
  --prefix="${PREFIX}"
  --enable-gpl                # muitos codecs são gpl (x264/x265)
  --enable-version3
  --enable-pic
  --enable-optimizations
  --enable-stripping
  --enable-libmfx            # se intel-media estiver disponível, ffmpeg ainda lida (opcional)
)

# Nonfree (fdk-aac, etc.) apenas se pedido explicitamente
if [[ "${ADM_FFMPEG_NONFREE:-0}" == "1" ]]; then
  OPTS+=( --enable-nonfree )
fi

# Codecs principais (habilita se existir)
pc x264      && OPTS+=( --enable-libx264 )
pc x265      && OPTS+=( --enable-libx265 )
pc aom       && OPTS+=( --enable-libaom )
pc dav1d     && OPTS+=( --enable-libdav1d )
pc vpx       && OPTS+=( --enable-libvpx )
pc opus      && OPTS+=( --enable-libopus )
pc vorbis    && OPTS+=( --enable-libvorbis )
pc mp3lame   && OPTS+=( --enable-libmp3lame )
pc fdk-aac   && OPTS+=( --enable-libfdk-aac )   # requer --enable-nonfree efetivo

# Subs/legendas, fontes, imagens
pc libass    && OPTS+=( --enable-libass )
pc fribidi   && OPTS+=( --enable-libfribidi )
pc freetype2 && OPTS+=( --enable-libfreetype )
pc libwebp   && OPTS+=( --enable-libwebp )

# Áudio/Som
pc alsa      && OPTS+=( --enable-alsa )
pc sdl2      && OPTS+=( --enable-sdl2 )         # ffplay

# Aceleração de vídeo (ativa se headers/libs existirem)
pc libva     && OPTS+=( --enable-vaapi )
pc vdpau     && OPTS+=( --enable-vdpau )

# NVENC/NVDEC (se cabeçalhos NVIDIA estiverem no sistema)
if [[ -d /usr/include/ffnvcodec || -d "${SYSROOT}/usr/include/ffnvcodec" ]]; then
  OPTS+=( --enable-nvenc --enable-cuda --enable-cuvid )
fi

# MUSL: desabilitar coisas problemáticas se necessário (auto-detect simples)
if echo | ${CC} -dM -E - 2>/dev/null | grep -qi musl; then
  OPTS+=( --disable-asm )  # se tiver nasm/compat ok; caso falhe, ASM pode ser desativado
fi

export CONFIGURE_OPTS="${CONFIGURE_OPTS:-} ${OPTS[*]}"
export MAKE_TARGETS="${MAKE_TARGETS:-all}"
export MAKE_INSTALL_TARGETS="${MAKE_INSTALL_TARGETS:-install}"

echo "[ffmpeg] CONFIGURE_OPTS=${CONFIGURE_OPTS}"
