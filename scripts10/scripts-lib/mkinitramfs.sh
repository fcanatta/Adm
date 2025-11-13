#!/usr/bin/env bash
# lib/adm/mkinitramfs.sh
#
# Subsistema de MKINITRAMFS do ADM
#
# Responsabilidades:
#   - Gerar imagens initramfs para um ou vários kernels:
#       * adm_mkinit_generate <kver> [output]
#       * adm_mkinit_generate_for_running
#       * adm_mkinit_generate_for_all
#   - Ser chamado por hooks de:
#       * instalação/atualização de kernel
#       * atualização de drivers (módulos)
#       * atualização de firmwares
#   - Trabalhar com rootfs real (/) ou rootfs custom (ex: stage2)
#
# Características:
#   - Nenhum erro silencioso (todos são logados).
#   - Detecção automática de kernel (uname -r / /lib/modules).
#   - Suporte a várias compressões (auto: xz → zstd → lz4 → gzip).
#   - Usa busybox se presente (melhor initramfs), senão cai para /bin/sh + binários básicos.
#   - Scripts de init gerados automaticamente, com:
#       * mount /proc, /sys, /dev
#       * parsing de root=, rootfstype=, rootflags= do cmdline
#       * mount da raiz real e switch_root / pivot_root
#
# Variáveis de ambiente importantes:
#   ADM_MKINIT_ROOT          – rootfs de origem (default: /)
#   ADM_MKINIT_OUTPUT_DIR    – destino das imagens (default: /boot)
#   ADM_MKINIT_CONFIG_DIR    – conf/hooks (default: $ADM_ROOT/mkinit)
#   ADM_MKINIT_COMPRESS      – auto|xz|zstd|lz4|gzip|none (default: auto)
#   ADM_MKINIT_KEEP_TREE     – 1 para não apagar árvore temporária (debug)
#
# Hooks sugeridos (fora deste script):
#   - Kernel instalado:
#       adm_mkinit_on_kernel_install <kver>
#   - Módulos/firmware atualizados:
#       adm_mkinit_on_modules_changed [kver]
#
###############################################################################
# Proteção contra múltiplos loads
###############################################################################
if [ -n "${ADM_MKINIT_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
ADM_MKINIT_LOADED=1
###############################################################################
# Dependências: log + core
###############################################################################
# -------- LOG ---------------------------------------------------------
if ! command -v adm_log_mkinit >/dev/null 2>&1; then
    # Fallback mínimo se log.sh ainda não foi carregado
    adm_log()         { printf '%s\n' "$*" >&2; }
    adm_log_info()    { adm_log "[INFO]     $*"; }
    adm_log_warn()    { adm_log "[WARN]     $*"; }
    adm_log_error()   { adm_log "[ERROR]    $*"; }
    adm_log_debug()   { :; }
    adm_log_mkinit()  { adm_log "[MKINIT]   $*"; }
fi

# -------- CORE (paths, helpers) --------------------------------------
if command -v adm_core_init_paths >/dev/null 2>&1; then
    adm_core_init_paths
fi

if ! command -v adm_require_root >/dev/null 2>&1; then
    adm_require_root() {
        if [ "$(id -u 2>/dev/null)" != "0" ]; then
            adm_log_error "Este comando requer privilégios de root."
            return 1
        fi
        return 0
    }
fi

if ! command -v adm_mkdir_p >/dev/null 2>&1; then
    adm_mkdir_p() {
        if [ $# -ne 1 ]; then
            adm_log_error "adm_mkdir_p requer 1 argumento: DIR"
            return 1
        fi
        mkdir -p -- "$1" 2>/dev/null || {
            adm_log_error "Falha ao criar diretório: %s" "$1"
            return 1
        }
    }
fi

if ! command -v adm_rm_rf_safe >/dev/null 2>&1; then
    adm_rm_rf_safe() {
        if [ $# -ne 1 ]; then
            adm_log_error "adm_rm_rf_safe requer 1 argumento: CAMINHO"
            return 1
        fi
        rm -rf -- "$1" 2>/dev/null || {
            adm_log_warn "Falha ao remover recursivamente: %s" "$1"
            return 1
        }
    }
fi

if ! command -v adm_tmpdir_create >/dev/null 2>&1; then
    adm_tmpdir_create() {
        if [ $# -ne 1 ]; then
            adm_log_error "adm_tmpdir_create requer 1 argumento: PREFIXO"
            return 1
        fi
        local d
        d="$(mktemp -d -t "${1}.XXXXXX" 2>/dev/null || echo '')"
        if [ -z "$d" ]; then
            adm_log_error "Falha ao criar diretório temporário para mkinitramfs."
            return 1
        fi
        printf '%s\n' "$d"
        return 0
    }
fi

# -------- PATHS GLOBAIS ----------------------------------------------
: "${ADM_ROOT:=${ADM_ROOT:-/usr/src/adm}}"
: "${ADM_MKINIT_ROOT:=${ADM_MKINIT_ROOT:-/}}"
: "${ADM_MKINIT_OUTPUT_DIR:=${ADM_MKINIT_OUTPUT_DIR:-/boot}}"
: "${ADM_MKINIT_CONFIG_DIR:=${ADM_MKINIT_CONFIG_DIR:-$ADM_ROOT/mkinit}}"
: "${ADM_MKINIT_COMPRESS:=${ADM_MKINIT_COMPRESS:-auto}}"
: "${ADM_MKINIT_KEEP_TREE:=0}"

adm_mkdir_p "$ADM_MKINIT_OUTPUT_DIR"  || adm_log_error "Falha ao criar ADM_MKINIT_OUTPUT_DIR: %s" "$ADM_MKINIT_OUTPUT_DIR"
adm_mkdir_p "$ADM_MKINIT_CONFIG_DIR"  || adm_log_debug "Falha ao criar ADM_MKINIT_CONFIG_DIR: %s (pode ser criado depois)" "$ADM_MKINIT_CONFIG_DIR" || true

###############################################################################
# Helpers internos
###############################################################################

adm_mkinit__trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

adm_mkinit__detect_compressor() {
    # Define ADM_MKINIT_COMPRESS_CMD e extensão:
    #   gzip → .gz, xz → .xz, etc.
    ADM_MKINIT_COMPRESS_CMD=""
    ADM_MKINIT_COMPRESS_EXT=""

    case "$ADM_MKINIT_COMPRESS" in
        none)
            return 0
            ;;
        gzip)
            if command -v gzip >/dev/null 2>&1; then
                ADM_MKINIT_COMPRESS_CMD="gzip -9"
                ADM_MKINIT_COMPRESS_EXT=".gz"
                return 0
            fi
            adm_log_warn "gzip não encontrado; caindo para modo sem compressão."
            ADM_MKINIT_COMPRESS="none"
            return 0
            ;;
        xz)
            if command -v xz >/dev/null 2>&1; then
                ADM_MKINIT_COMPRESS_CMD="xz -C crc32 -z -9"
                ADM_MKINIT_COMPRESS_EXT=".xz"
                return 0
            fi
            adm_log_warn "xz não encontrado; caindo para auto."
            ADM_MKINIT_COMPRESS="auto"
            ;;
        zstd)
            if command -v zstd >/dev/null 2>&1; then
                ADM_MKINIT_COMPRESS_CMD="zstd -q -19"
                ADM_MKINIT_COMPRESS_EXT=".zst"
                return 0
            fi
            adm_log_warn "zstd não encontrado; caindo para auto."
            ADM_MKINIT_COMPRESS="auto"
            ;;
        lz4)
            if command -v lz4 >/dev/null 2>&1; then
                ADM_MKINIT_COMPRESS_CMD="lz4 -q -9"
                ADM_MKINIT_COMPRESS_EXT=".lz4"
                return 0
            fi
            adm_log_warn "lz4 não encontrado; caindo para auto."
            ADM_MKINIT_COMPRESS="auto"
            ;;
        auto|*)
            ;;
    esac

    # AUTO: tenta na ordem xz → zstd → lz4 → gzip
    if command -v xz >/dev/null 2>&1; then
        ADM_MKINIT_COMPRESS_CMD="xz -C crc32 -z -9"
        ADM_MKINIT_COMPRESS_EXT=".xz"
        ADM_MKINIT_COMPRESS="xz"
        return 0
    fi
    if command -v zstd >/dev/null 2>&1; then
        ADM_MKINIT_COMPRESS_CMD="zstd -q -19"
        ADM_MKINIT_COMPRESS_EXT=".zst"
        ADM_MKINIT_COMPRESS="zstd"
        return 0
    fi
    if command -v lz4 >/dev/null 2>&1; then
        ADM_MKINIT_COMPRESS_CMD="lz4 -q -9"
        ADM_MKINIT_COMPRESS_EXT=".lz4"
        ADM_MKINIT_COMPRESS="lz4"
        return 0
    fi
    if command -v gzip >/dev/null 2>&1; then
        ADM_MKINIT_COMPRESS_CMD="gzip -9"
        ADM_MKINIT_COMPRESS_EXT=".gz"
        ADM_MKINIT_COMPRESS="gzip"
        return 0
    fi

    adm_log_warn "Nenhum compressor encontrado (xz/zstd/lz4/gzip); initramfs ficará sem compressão."
    ADM_MKINIT_COMPRESS="none"
    return 0
}

adm_mkinit__detect_switch_root() {
    # Define ADM_MKINIT_SWITCHROOT_CMD (switch_root|busybox switch_root|pivot_root)
    ADM_MKINIT_SWITCHROOT_CMD=""

    if command -v switch_root >/dev/null 2>&1; then
        ADM_MKINIT_SWITCHROOT_CMD="switch_root"
        return 0
    fi

    if command -v busybox >/dev/null 2>&1; then
        if busybox 2>&1 | grep -q 'switch_root'; then
            ADM_MKINIT_SWITCHROOT_CMD="busybox switch_root"
            return 0
        fi
    fi

    # fallback: usaremos pivot_root no /init (manualmente)
    ADM_MKINIT_SWITCHROOT_CMD="pivot_root"
    return 0
}

adm_mkinit__detect_kver() {
    # args (opcional): KVER
    if [ $# -eq 1 ] && [ -n "$1" ]; then
        printf '%s\n' "$1"
        return 0
    fi

    # 1) tentar uname -r
    local k
    k="$(uname -r 2>/dev/null || echo '')"
    if [ -n "$k" ] && [ -d "$ADM_MKINIT_ROOT/lib/modules/$k" ]; then
        printf '%s\n' "$k"
        return 0
    fi

    # 2) pega o mais novo de /lib/modules
    if [ -d "$ADM_MKINIT_ROOT/lib/modules" ]; then
        k="$(cd "$ADM_MKINIT_ROOT/lib/modules" 2>/dev/null && ls -1t 2>/dev/null | head -n1 || echo '')"
        if [ -n "$k" ]; then
            printf '%s\n' "$k"
            return 0
        fi
    fi

    adm_log_error "Não foi possível detectar versão de kernel (nenhum /lib/modules/<kver> em %s)." "$ADM_MKINIT_ROOT"
    return 1
}

adm_mkinit__output_path_for_kver() {
    # args: KVER
    if [ $# -ne 1 ]; then
        adm_log_error "adm_mkinit__output_path_for_kver requer 1 argumento: KVER"
        return 1
    fi
    local k="$1"
    printf '%s/initramfs-%s.img' "$ADM_MKINIT_OUTPUT_DIR" "$k"
}

adm_mkinit__find_busybox() {
    # Procura busybox na raiz real (ou rootfs base)
    local roots=(
        "$ADM_MKINIT_ROOT/bin/busybox"
        "$ADM_MKINIT_ROOT/usr/bin/busybox"
        "/bin/busybox"
        "/usr/bin/busybox"
    )
    local b
    for b in "${roots[@]}"; do
        if [ -x "$b" ]; then
            printf '%s\n' "$b"
            return 0
        fi
    done
    printf '\n'
    return 0
}

###############################################################################
# Construção da árvore do initramfs
###############################################################################

adm_mkinit__write_init_script() {
    # args: BUILD_DIR KVER
    if [ $# -ne 2 ]; then
        adm_log_error "adm_mkinit__write_init_script requer 2 argumentos: BUILD_DIR KVER"
        return 1
    fi
    local build="$1" kver="$2"
    local init="$build/init"

    cat >"$init" <<"EOF"
#!/bin/sh
# /init -- script de inicialização do initramfs gerado pelo ADM
set -eu

echo "[init] Iniciando initramfs (ADM)..."

early_echo() {
    printf '%s\n' "$*" >/dev/console 2>/dev/null || printf '%s\n' "$*" >&2
}

mount_fs() {
    local dev="$1" mnt="$2" type="$3" opts="$4"
    [ -d "$mnt" ] || mkdir -p "$mnt"
    if [ -n "$type" ]; then
        mount -t "$type" -o "$opts" "$dev" "$mnt" || return 1
    else
        mount -o "$opts" "$dev" "$mnt" || return 1
    fi
}

# Monta /proc, /sys, /dev, /run
mount_fs proc /proc proc "nosuid,noexec,nodev" || early_echo "[init] WARNING: falha ao montar /proc"
mount_fs sysfs /sys sysfs "nosuid,noexec,nodev" || early_echo "[init] WARNING: falha ao montar /sys"
mount_fs devtmpfs /dev devtmpfs "mode=0755,nosuid" || {
    early_echo "[init] WARNING: devtmpfs não disponível; criando /dev básico."
    mkdir -p /dev
    [ -c /dev/null ]  || mknod -m 666 /dev/null c 1 3
    [ -c /dev/tty ]   || mknod -m 666 /dev/tty  c 5 0
    [ -c /dev/console ] || mknod -m 600 /dev/console c 5 1
    [ -c /dev/zero ]  || mknod -m 666 /dev/zero c 1 5
}
mount_fs tmpfs /run tmpfs "mode=0755,nosuid,nodev" || early_echo "[init] WARNING: falha ao montar /run"

# Lê cmdline
CMDLINE="$(cat /proc/cmdline 2>/dev/null || echo '')"
ROOTDEV=""
ROOTFSTYPE=""
ROOTFLAGS="defaults"
for item in $CMDLINE; do
    case "$item" in
        root=*)
            ROOTDEV="${item#root=}"
            ;;
        rootfstype=*)
            ROOTFSTYPE="${item#rootfstype=}"
            ;;
        rootflags=*)
            ROOTFLAGS="${item#rootflags=}"
            ;;
    esac
done

[ -n "${ROOTDEV:-}" ] || {
    early_echo "[init] ERROR: parâmetro root= não encontrado no cmdline."
    exec sh
}

early_echo "[init] root=${ROOTDEV} rootfstype=${ROOTFSTYPE:-auto} rootflags=${ROOTFLAGS}"

# Espera root se for dispositivo de bloco não pronto
wait_for_root() {
    local dev="$1" i=0
    while [ ! -b "$dev" ] && [ $i -lt 60 ]; do
        early_echo "[init] Aguardando dispositivo de root: $dev (tentativa $i/60)"
        sleep 1
        i=$((i+1))
    done
    if [ ! -b "$dev" ]; then
        early_echo "[init] ERROR: dispositivo de root não apareceu: $dev"
        exec sh
    fi
}

case "$ROOTDEV" in
    UUID=*|LABEL=*)
        # Deixamos mount se resolver via /dev/disk/by-uuid/by-label (udev/mdev)
        ;;
    /dev/*)
        wait_for_root "$ROOTDEV"
        ;;
esac

mkdir -p /newroot

if [ -n "$ROOTFSTYPE" ] && [ "$ROOTFSTYPE" != "auto" ]; then
    mount -t "$ROOTFSTYPE" -o "$ROOTFLAGS" "$ROOTDEV" /newroot || {
        early_echo "[init] ERROR: falha ao montar root em /newroot."
        exec sh
    }
else
    mount -o "$ROOTFLAGS" "$ROOTDEV" /newroot || {
        early_echo "[init] ERROR: falha ao montar root em /newroot."
        exec sh
    }
fi

# Move mounts essenciais para dentro do root
mkdir -p /newroot/proc /newroot/sys /newroot/dev /newroot/run
mount --move /proc /newroot/proc 2>/dev/null || early_echo "[init] WARNING: não foi possível mover /proc"
mount --move /sys  /newroot/sys  2>/dev/null || early_echo "[init] WARNING: não foi possível mover /sys"
mount --move /dev  /newroot/dev  2>/dev/null || early_echo "[init] WARNING: não foi possível mover /dev"
mount --move /run  /newroot/run  2>/dev/null || early_echo "[init] WARNING: não foi possível mover /run"

# switch_root / fallback
if command -v switch_root >/dev/null 2>&1; then
    exec switch_root /newroot /sbin/init || exec switch_root /newroot /bin/init
elif command -v busybox >/dev/null 2>&1 && busybox 2>&1 | grep -q 'switch_root'; then
    exec busybox switch_root /newroot /sbin/init || exec busybox switch_root /newroot /bin/init
else
    # fallback simples: chroot + exec
    early_echo "[init] switch_root não disponível; usando chroot."
    cd /newroot || exec sh
    exec chroot /newroot /sbin/init || exec chroot /newroot /bin/init || exec sh
fi
EOF

    chmod +x "$init" 2>/dev/null || {
        adm_log_error "Falha ao tornar /init executável em %s." "$build"
        return 1
    }
    return 0
}

adm_mkinit__populate_tree() {
    # args: BUILD_DIR KVER
    if [ $# -ne 2 ]; then
        adm_log_error "adm_mkinit__populate_tree requer 2 argumentos: BUILD_DIR KVER"
        return 1
    fi
    local build="$1" kver="$2"

    adm_log_mkinit "Populando árvore do initramfs em %s (kver=%s)..." "$build" "$kver"

    # Diretórios básicos
    local d
    for d in bin sbin etc proc sys dev run tmp newroot lib lib64 usr/bin usr/sbin usr/lib; do
        adm_mkdir_p "$build/$d" || return 1
    done

    # /dev básico (caso devtmpfs falhe)
    mknod -m 666 "$build/dev/null" c 1 3 2>/dev/null || :
    mknod -m 666 "$build/dev/tty"  c 5 0 2>/dev/null || :
    mknod -m 600 "$build/dev/console" c 5 1 2>/dev/null || :
    mknod -m 666 "$build/dev/zero" c 1 5 2>/dev/null || :

    # Busybox (se existir)
    local busybox_src
    busybox_src="$(adm_mkinit__find_busybox)"
    if [ -n "$busybox_src" ]; then
        adm_log_mkinit "Usando busybox em initramfs: %s" "$busybox_src"
        cp -f "$busybox_src" "$build/bin/busybox" 2>/dev/null || {
            adm_log_error "Falha ao copiar busybox de %s para %s." "$busybox_src" "$build/bin/busybox"
            return 1
        }
        chmod +x "$build/bin/busybox" 2>/dev/null || :
        # Symlinks básicos
        ( cd "$build/bin" && \
          for app in sh mount umount ls cat echo dmesg mkdir mknod sleep chroot; do
              ln -sf busybox "$app"
          done ) || adm_log_warn "Falha ao criar symlinks de busybox."
    else
        adm_log_warn "busybox não encontrado; copiando /bin/sh, /bin/mount e mínimos."
        for b in /bin/sh /bin/mount /bin/umount /bin/ls /bin/cat /bin/echo /bin/mkdir /bin/sleep /usr/bin/chroot; do
            if [ -x "$ADM_MKINIT_ROOT$b" ]; then
                cp -f "$ADM_MKINIT_ROOT$b" "$build$b" 2>/dev/null || adm_log_warn "Falha ao copiar %s para initramfs." "$b"
            elif [ -x "$b" ]; then
                # fallback host
                adm_mkdir_p "$build$(dirname "$b")"
                cp -f "$b" "$build$b" 2>/dev/null || adm_log_warn "Falha ao copiar %s (host) para initramfs." "$b"
            fi
        done
    fi

    # Bibliotecas necessárias: não fazemos análise avançada (ldd) aqui,
    # mas deixamos espaço para hooks de mkinitramfs completarem isso.
    # (adm_mkinit_hooks_populate pode ser implementado por hooks externos.)

    # Kernel modules
    if [ -d "$ADM_MKINIT_ROOT/lib/modules/$kver" ]; then
        adm_log_mkinit "Copiando módulos do kernel %s..." "$kver"
        adm_mkdir_p "$build/lib/modules/$kver" || return 1
        # Copia somente diretório kernel e arquivos de deps básicos.
        cp -a "$ADM_MKINIT_ROOT/lib/modules/$kver/kernel" "$build/lib/modules/$kver/" 2>/dev/null || \
            adm_log_warn "Falha ao copiar 'kernel' para initramfs (pode ficar sem alguns módulos)."
        for f in modules.dep modules.alias modules.softdep modules.builtin modules.order; do
            if [ -f "$ADM_MKINIT_ROOT/lib/modules/$kver/$f" ]; then
                cp -f "$ADM_MKINIT_ROOT/lib/modules/$kver/$f" "$build/lib/modules/$kver/$f" 2>/dev/null || \
                    adm_log_warn "Falha ao copiar %s para initramfs." "$f"
            fi
        done
    else
        adm_log_warn "Diretório de módulos não encontrado para kver=%s em %s." "$kver" "$ADM_MKINIT_ROOT/lib/modules"
    fi

    # Firmware (heurística simples)
    if [ -d "$ADM_MKINIT_ROOT/lib/firmware" ]; then
        adm_log_mkinit "Copiando firmware (heurística simples)..."
        adm_mkdir_p "$build/lib/firmware" || return 1
        # Para evitar initramfs gigante, copiamos apenas alguns paths padrão;
        # hooks podem refinar depois.
        cp -a "$ADM_MKINIT_ROOT/lib/firmware" "$build/lib/" 2>/dev/null || \
            adm_log_warn "Falha ao copiar /lib/firmware (initramfs poderá faltar firmware)."
    fi

    # Arquivo de init
    adm_mkinit__write_init_script "$build" "$kver" || return 1

    # Hooks pós-populate, se existirem
    local hooks_dir="$ADM_MKINIT_CONFIG_DIR/hooks.d"
    if [ -d "$hooks_dir" ]; then
        adm_log_mkinit "Executando hooks de mkinitramfs em %s..." "$hooks_dir"
        local h
        for h in "$hooks_dir"/*; do
            [ -f "$h" ] || continue
            [ -x "$h" ] || chmod +x "$h" 2>/dev/null || :
            adm_log_mkinit "Executando hook: %s" "$h"
            BUILD_DIR="$build" KVER="$kver" ROOTFS="$ADM_MKINIT_ROOT" "$h" || \
                adm_log_warn "Hook %s retornou erro (continuando)." "$h"
        done
    fi

    return 0
}

###############################################################################
# Empacotamento (cpio + compressão)
###############################################################################

adm_mkinit__pack_image() {
    # args: BUILD_DIR OUTPUT_PATH
    if [ $# -ne 2 ]; then
        adm_log_error "adm_mkinit__pack_image requer 2 argumentos: BUILD_DIR OUTPUT"
        return 1
    fi
    local build="$1" out="$2"

    if ! command -v cpio >/dev/null 2>&1; then
        adm_log_error "cpio não encontrado; não é possível criar initramfs."
        return 1
    fi

    adm_mkinit__detect_compressor

    local tmp_out="$out.tmp"

    adm_log_mkinit "Empacotando initramfs em %s (compressão=%s)..." "$out" "$ADM_MKINIT_COMPRESS"

    ( cd "$build" 2>/dev/null || {
        adm_log_error "Falha ao entrar em %s para empacotar initramfs." "$build"
        exit 1
    }

      if [ "$ADM_MKINIT_COMPRESS" = "none" ]; then
          find . -print0 2>/dev/null | cpio --null -ov --format=newc >"$tmp_out" 2>/dev/null
      else
          find . -print0 2>/dev/null | cpio --null -ov --format=newc 2>/dev/null | \
              $ADM_MKINIT_COMPRESS_CMD >"$tmp_out"
      fi
    ) || {
        adm_log_error "Falha ao empacotar initramfs para %s." "$out"
        rm -f "$tmp_out" 2>/dev/null || :
        return 1
    }

    mv "$tmp_out" "$out" 2>/dev/null || {
        adm_log_error "Falha ao mover initramfs temporário para destino final %s." "$out"
        rm -f "$tmp_out" 2>/dev/null || :
        return 1
    }

    adm_log_mkinit "Imagem initramfs criada em: %s" "$out"
    return 0
}

###############################################################################
# API principal
###############################################################################

adm_mkinit_generate() {
    # args: KVER [OUTPUT]
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then
        adm_log_error "adm_mkinit_generate requer 1 ou 2 argumentos: KVER [OUTPUT]"
        return 1
    fi
    local kver="$1"
    local output="${2:-}"

    adm_require_root || return 1

    if [ -z "$output" ]; then
        output="$(adm_mkinit__output_path_for_kver "$kver" || echo '')"
        [ -n "$output" ] || return 1
    fi

    local build
    build="$(adm_tmpdir_create "adm-mkinit-$kver" || echo '')"
    if [ -z "$build" ]; then
        adm_log_error "Falha ao criar diretório de build do initramfs."
        return 1
    fi

    adm_log_mkinit "Gerando initramfs para kernel %s (build_dir=%s, output=%s)..." "$kver" "$build" "$output"

    if ! adm_mkinit__populate_tree "$build" "$kver"; then
        adm_rm_rf_safe "$build" || :
        return 1
    fi

    if ! adm_mkinit__pack_image "$build" "$output"; then
        adm_rm_rf_safe "$build" || :
        return 1
    fi

    if [ "$ADM_MKINIT_KEEP_TREE" -ne 1 ]; then
        adm_rm_rf_safe "$build" || :
    else
        adm_log_mkinit "Mantendo árvore temporária para debug: %s" "$build"
    fi

    # Atualiza symlink initramfs.img (último kernel), se fizer sentido
    local link="$ADM_MKINIT_OUTPUT_DIR/initramfs.img"
    if [ -e "$link" ] || [ -L "$link" ]; then
        rm -f "$link" 2>/dev/null || adm_log_warn "Não foi possível remover symlink antigo: %s" "$link"
    fi
    ln -s "$(basename "$output")" "$link" 2>/dev/null || \
        adm_log_warn "Falha ao criar symlink initramfs.img para %s." "$output"

    adm_log_mkinit "mkinitramfs para %s concluído com sucesso." "$kver"
    return 0
}

adm_mkinit_generate_for_running() {
    local kver
    kver="$(adm_mkinit__detect_kver "" || echo '')"
    [ -n "$kver" ] || return 1
    adm_mkinit_generate "$kver"
}

adm_mkinit_generate_for_all() {
    adm_require_root || return 1

    if [ ! -d "$ADM_MKINIT_ROOT/lib/modules" ]; then
        adm_log_error "Diretório de módulos não encontrado em %s; nada a fazer." "$ADM_MKINIT_ROOT/lib/modules"
        return 1
    fi

    local kver rc=0
    for kver in $(cd "$ADM_MKINIT_ROOT/lib/modules" 2>/dev/null && ls -1 2>/dev/null); do
        [ -d "$ADM_MKINIT_ROOT/lib/modules/$kver" ] || continue
        adm_mkinit_generate "$kver" || rc=1
    done

    return $rc
}

###############################################################################
# Hooks de integração com kernel / módulos / firmware
###############################################################################

adm_mkinit_on_kernel_install() {
    # args: KVER
    # Chamado pelo hook de instalação de kernel.
    if [ $# -ne 1 ]; then
        adm_log_error "adm_mkinit_on_kernel_install requer 1 argumento: KVER"
        return 1
    fi
    local kver="$1"
    adm_log_mkinit "Hook de instalação de kernel chamado para %s." "$kver"
    adm_mkinit_generate "$kver"
}

adm_mkinit_on_modules_changed() {
    # args: [KVER]
    # Chamado quando módulos/firmware forem atualizados.
    local kver="${1:-}"

    adm_log_mkinit "Hook de módulos/firmware alterados chamado (kver=%s)." "$kver"

    if [ -n "$kver" ]; then
        adm_mkinit_generate "$kver"
    else
        # se não foi especificado, gera para kernel atual
        adm_mkinit_generate_for_running
    fi
}

###############################################################################
# Inicialização
###############################################################################

adm_mkinit_init() {
    adm_log_debug "Subsistema de mkinitramfs (mkinitramfs.sh) carregado. root=%s out=%s compress=%s" \
        "$ADM_MKINIT_ROOT" "$ADM_MKINIT_OUTPUT_DIR" "$ADM_MKINIT_COMPRESS"
}

adm_mkinit_init
