#!/usr/bin/env bash
# initramfs.sh – Gestão EXTREMA de initramfs no ADM
#
# Responsável por:
#   - criar initramfs ao instalar kernel
#   - atualizar initramfs ao atualizar kernel/driver
#   - remover initramfs ao remover kernel
#   - rebuild-all quando mudar drivers críticos
#
# Backends suportados (auto):
#   - dracut
#   - mkinitcpio
#   - mkinitramfs (Debian/Ubuntu)
#   - fallback custom (busybox + modules + simples)

ADM_ROOT="/usr/src/adm"
ADM_SCRIPTS="$ADM_ROOT/scripts"
ADM_INITRAMFS_ROOT="/usr/src/adm/initramfs"
ADM_INITRAMFS_BACKUP="$ADM_INITRAMFS_ROOT/backup"
ADM_INITRAMFS_WORK="$ADM_INITRAMFS_ROOT/work"

ADM_INITRAMFS_BACKEND=""   # dracut|mkinitcpio|mkinitramfs|custom
ADM_INITRAMFS_DEFAULT_OUT="/boot"

IR_UI_OK=0

# -----------------------------
# Carregar ui.sh e db.sh (opcional)
# -----------------------------
_ir_load_mod() {
    local f="$1"
    if [ -r "$ADM_SCRIPTS/$f" ]; then
        # shellcheck source=/usr/src/adm/scripts/$f
        . "$ADM_SCRIPTS/$f" || return 1
        return 0
    fi
    return 1
}

_ir_load_mod "ui.sh" && IR_UI_OK=1
_ir_load_mod "db.sh" || true

# -----------------------------
# Logs
# -----------------------------
ir_log_info()  { [ "$IR_UI_OK" -eq 1 ] && adm_ui_log_info  "$*" || printf '[INFO] %s\n'  "$*"; }
ir_log_warn()  { [ "$IR_UI_OK" -eq 1 ] && adm_ui_log_warn  "$*" || printf '[WARN] %s\n'  "$*"; }
ir_log_error() { [ "$IR_UI_OK" -eq 1 ] && adm_ui_log_error "$*" || printf '[ERROR] %s\n' "$*"; }

ir_die() {
    ir_log_error "$@"
    exit 1
}

_ir_ts() {
    date +"%Y%m%d-%H%M%S"
}

_ir_trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# -----------------------------
# Helpers de FS / paths de kernel
# -----------------------------
ir_kernel_modules_dir() {
    # $1 = versão (ex: 6.9.3-gentoo)
    local ver="$1"
    [ -z "$ver" ] && return 1
    local d="/lib/modules/$ver"
    [ -d "$d" ] || return 1
    printf '%s\n' "$d"
}

ir_kernel_image_path() {
    # $1 = versão
    local ver="$1"
    [ -z "$ver" ] && return 1

    local cand
    for cand in \
        "/boot/vmlinuz-$ver" \
        "/boot/vmlinux-$ver" \
        "/boot/kernel-$ver" \
        "/boot/bzImage-$ver"
    do
        if [ -f "$cand" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    return 1
}

ir_initramfs_output_path() {
    # $1 = versão
    local ver="$1"
    [ -z "$ver" ] && return 1

    # padrão: /boot/initramfs-<ver>.img
    printf '%s/initramfs-%s.img\n' "$ADM_INITRAMFS_DEFAULT_OUT" "$ver"
}

# -----------------------------
# Backend detection
# -----------------------------
_ir_have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

ir_detect_backend() {
    # Se já detectado, retorna
    if [ -n "$ADM_INITRAMFS_BACKEND" ]; then
        printf '%s\n' "$ADM_INITRAMFS_BACKEND"
        return 0
    fi

    if _ir_have_cmd dracut; then
        ADM_INITRAMFS_BACKEND="dracut"
    elif _ir_have_cmd mkinitcpio; then
        ADM_INITRAMFS_BACKEND="mkinitcpio"
    elif _ir_have_cmd mkinitramfs; then
        ADM_INITRAMFS_BACKEND="mkinitramfs"
    else
        ADM_INITRAMFS_BACKEND="custom"
    fi

    ir_log_info "initramfs backend detectado: $ADM_INITRAMFS_BACKEND"
    printf '%s\n' "$ADM_INITRAMFS_BACKEND"
    return 0
}

# -----------------------------
# Backup de initramfs existente
# -----------------------------
ir_backup_initramfs() {
    # $1 = caminho do initramfs
    local img="$1"
    [ -z "$img" ] && return 0
    [ -f "$img" ] || return 0

    local ts="$(_ir_ts)"
    local base="${img##*/}"
    local dst_dir="$ADM_INITRAMFS_BACKUP/$ts"
    local dst="$dst_dir/$base"

    if ! mkdir -p "$dst_dir" 2>/dev/null; then
        ir_log_warn "Não foi possível criar diretório de backup: $dst_dir"
        return 0
    fi

    if cp -a "$img" "$dst" 2>/dev/null; then
        ir_log_info "Backup de initramfs criado: $dst"
    else
        ir_log_warn "Falha ao criar backup de initramfs: $dst"
    fi
}

# -----------------------------
# Build genérico (dispatch por backend)
# -----------------------------
_ir_build_dracut() {
    # $1 = versão, $2 = kernel_img, $3 = out_img
    local ver="$1" kimg="$2" out_img="$3"

    if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
        ir_log_warn "dracut geralmente requer root; tentando mesmo assim..."
    fi

    ir_log_info "Criando initramfs com dracut para kernel $ver -> $out_img"
    if ! dracut --force "$out_img" "$ver" >/dev/null 2>&1; then
        ir_log_error "dracut falhou para kernel $ver"
        return 1
    fi

    ir_log_info "initramfs criado com dracut: $out_img"
    return 0
}

_ir_build_mkinitcpio() {
    # $1 = versão, $2 = kernel_img, $3 = out_img
    local ver="$1" kimg="$2" out_img="$3"

    if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
        ir_log_warn "mkinitcpio geralmente é usado como root; tentando assim mesmo..."
    fi

    ir_log_info "Criando initramfs com mkinitcpio para kernel $ver -> $out_img"
    # mkinitcpio -k <kernel version> -g <output>
    if ! mkinitcpio -k "$ver" -g "$out_img" >/dev/null 2>&1; then
        ir_log_error "mkinitcpio falhou para kernel $ver"
        return 1
    fi

    ir_log_info "initramfs criado com mkinitcpio: $out_img"
    return 0
}

_ir_build_mkinitramfs() {
    # $1 = versão, $2 = kernel_img, $3 = out_img
    local ver="$1" kimg="$2" out_img="$3"

    if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
        ir_log_warn "mkinitramfs (Debian) requer root; tentando assim mesmo..."
    fi

    ir_log_info "Criando initramfs com mkinitramfs para kernel $ver -> $out_img"
    # mkinitramfs -o /boot/initrd.img-<ver> <ver>
    if ! mkinitramfs -o "$out_img" "$ver" >/dev/null 2>&1; then
        ir_log_error "mkinitramfs falhou para kernel $ver"
        return 1
    fi

    ir_log_info "initramfs criado com mkinitramfs: $out_img"
    return 0
}

_ir_build_custom() {
    # $1 = versão, $2 = kernel_img, $3 = out_img
    local ver="$1" kimg="$2" out_img="$3"

    ir_log_info "Criando initramfs custom para kernel $ver -> $out_img"

    if ! mkdir -p "$ADM_INITRAMFS_WORK/$ver" 2>/dev/null; then
        ir_log_error "Não foi possível criar diretório de trabalho custom: $ADM_INITRAMFS_WORK/$ver"
        return 1
    fi

    local work="$ADM_INITRAMFS_WORK/$ver"
    rm -rf "$work"/* 2>/dev/null || true

    # Estrutura mínima: /init, /bin/sh, /dev, /proc, /sys, /newroot
    mkdir -p \
        "$work/bin" \
        "$work/sbin" \
        "$work/dev" \
        "$work/proc" \
        "$work/sys" \
        "$work/newroot" \
        "$work/etc" 2>/dev/null || {
            ir_log_error "Falha ao criar estrutura mínima do initramfs custom"
            return 1
        }

    # init muito simples
    cat >"$work/init" <<'EOF'
#!/bin/sh
set -e

echo "ADM initramfs: montando /proc /sys /dev..."
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev || mount -t tmpfs dev /dev

echo "ADM initramfs: procurando root=..."
ROOTDEV="$(cat /proc/cmdline | sed -n 's/.*root=\([^ ]*\).*/\1/p')"

if [ -z "$ROOTDEV" ]; then
    echo "ADM initramfs: root= não definido, caindo para shell de emergência."
    exec sh
fi

echo "ADM initramfs: montando root em /newroot: $ROOTDEV"
mkdir -p /newroot
mount "$ROOTDEV" /newroot || {
    echo "ADM initramfs: falha ao montar $ROOTDEV; caindo para shell."
    exec sh
}

echo "ADM initramfs: trocando raiz..."
exec switch_root /newroot /sbin/init || exec sh
EOF

    chmod +x "$work/init" || {
        ir_log_error "Falha ao tornar /init executável no initramfs custom"
        return 1
    }

    # Tenta incluir busybox se existir
    if _ir_have_cmd busybox; then
        ir_log_info "Incluindo busybox no initramfs custom"
        cp "$(command -v busybox)" "$work/bin/busybox" 2>/dev/null || ir_log_warn "Falha ao copiar busybox"
        ln -sf /bin/busybox "$work/bin/sh" 2>/dev/null || true
    else
        ir_log_warn "busybox não encontrado; initramfs custom terá shell muito limitado"
        # Se /bin/sh existir no host, tenta copiar
        if [ -x /bin/sh ]; then
            cp /bin/sh "$work/bin/sh" 2>/dev/null || ir_log_warn "Falha ao copiar /bin/sh para initramfs"
        fi
    fi

    # Incluir módulos do kernel (somente como exemplo: tudo de /lib/modules/<ver>)
    local moddir
    moddir="$(ir_kernel_modules_dir "$ver" || echo "")"
    if [ -n "$moddir" ]; then
        mkdir -p "$work/lib/modules" 2>/dev/null || true
        cp -a "$moddir" "$work/lib/modules/" 2>/dev/null || ir_log_warn "Falha ao copiar módulos de kernel para initramfs custom"
    else
        ir_log_warn "Diretório de módulos para $ver não encontrado; initramfs custom sem módulos adicionais"
    fi

    # Gerar cpio+gzip
    (
        cd "$work" || exit 1
        if _ir_have_cmd cpio; then
            find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 >"$out_img" || exit 1
        else
            ir_log_error "cpio não encontrado; não é possível gerar initramfs custom"
            exit 1
        fi
    ) || {
        ir_log_error "Falha ao gerar initramfs custom para $ver"
        return 1
    }

    ir_log_info "initramfs custom criado: $out_img"
    return 0
}

ir_build_initramfs() {
    # $1 = kernel version
    local ver="$1"
    [ -z "$ver" ] && ir_die "ir_build_initramfs: versão de kernel não informada"

    local kimg out_img backend

    kimg="$(ir_kernel_image_path "$ver")" || ir_die "Imagem do kernel para versão '$ver' não encontrada em /boot"
    out_img="$(ir_initramfs_output_path "$ver")" || ir_die "Não foi possível determinar caminho de saída do initramfs para '$ver'"

    mkdir -p "$(dirname "$out_img")" 2>/dev/null || ir_die "Não foi possível criar diretório para $out_img"

    backend="$(ir_detect_backend)"

    ir_backup_initramfs "$out_img"

    case "$backend" in
        dracut)
            _ir_build_dracut "$ver" "$kimg" "$out_img" || ir_die "Falha ao criar initramfs com dracut para $ver"
            ;;
        mkinitcpio)
            _ir_build_mkinitcpio "$ver" "$kimg" "$out_img" || ir_die "Falha ao criar initramfs com mkinitcpio para $ver"
            ;;
        mkinitramfs)
            _ir_build_mkinitramfs "$ver" "$kimg" "$out_img" || ir_die "Falha ao criar initramfs com mkinitramfs para $ver"
            ;;
        custom)
            _ir_build_custom "$ver" "$kimg" "$out_img" || ir_die "Falha ao criar initramfs custom para $ver"
            ;;
        *)
            ir_die "Backend initramfs desconhecido: $backend"
            ;;
    esac

    ir_log_info "Initramfs final para kernel $ver: $out_img"
    return 0
}
# -----------------------------
# Atualizar initramfs (rebuild do mesmo ver)
# -----------------------------
ir_update_initramfs() {
    # $1 = versão
    local ver="$1"
    [ -z "$ver" ] && ir_die "ir_update_initramfs: versão de kernel não informada"

    ir_log_info "Atualizando initramfs para kernel $ver"
    ir_build_initramfs "$ver"
}

# -----------------------------
# Remover initramfs de um kernel
# -----------------------------
ir_remove_initramfs() {
    # $1 = versão
    local ver="$1"
    [ -z "$ver" ] && ir_die "ir_remove_initramfs: versão de kernel não informada"

    local img
    img="$(ir_initramfs_output_path "$ver" || echo "")"
    [ -z "$img" ] && ir_die "Não foi possível determinar caminho do initramfs para $ver"

    if [ ! -e "$img" ]; then
        ir_log_warn "Nenhum initramfs encontrado para $ver em $img; nada para remover"
        return 0
    fi

    ir_backup_initramfs "$img"
    if rm -f "$img" 2>/dev/null; then
        ir_log_info "Initramfs removido para kernel $ver: $img (backup em $ADM_INITRAMFS_BACKUP)"
    else
        ir_log_error "Falha ao remover initramfs $img para kernel $ver"
        return 1
    fi
}

# -----------------------------
# Rebuild de todos os initramfs para kernels instalados
# -----------------------------
ir_list_installed_kernels() {
    # Tenta DB (kernel-*), cai para /lib/modules
    local vers=""
    if declare -F adm_db_init >/dev/null 2>&1 && declare -F adm_db_list_installed >/dev/null 2>&1; then
        adm_db_init || true
        local line
        while read -r line; do
            [ -z "$line" ] && continue
            # formato: name version ...
            local name ver
            name="$(printf '%s\n' "$line" | awk '{print $1}')"
            ver="$(printf '%s\n' "$line" | awk '{print $2}')"
            case "$name" in
                kernel-*|linux-*|linux)
                    vers="$vers $ver"
                    ;;
            esac
        done <<EOF_LIST
$(adm_db_list_installed 2>/dev/null || true)
EOF_LIST
    fi

    # Se DB não deu nada, cai pra /lib/modules
    if [ -z "$vers" ]; then
        if [ -d /lib/modules ]; then
            for d in /lib/modules/*; do
                [ -d "$d" ] || continue
                vers="$vers ${d##*/}"
            done
        fi
    fi

    # imprimir único
    printf '%s\n' $vers | sort -u
}

ir_rebuild_all_initramfs() {
    local ver
    local list
    list="$(ir_list_installed_kernels)"

    if [ -z "$list" ]; then
        ir_log_warn "Nenhum kernel instalado detectado; não há initramfs a reconstruir"
        return 0
    fi

    ir_log_info "Reconstruindo initramfs para todos os kernels detectados:"
    printf '  %s\n' $list

    local fail=0
    for ver in $list; do
        if ! ir_build_initramfs "$ver"; then
            ir_log_error "Falha ao reconstruir initramfs para kernel $ver"
            fail=1
        fi
    done

    [ "$fail" -eq 0 ]
}

# -----------------------------
# Hooks para integração com install/remove/update de kernel/driver
# -----------------------------
adm_initramfs_on_kernel_install() {
    # $1 = nome do pacote (kernel-NOME), $2 = versão
    local pkg="$1"
    local ver="$2"

    if [ -z "$ver" ]; then
        ir_log_warn "adm_initramfs_on_kernel_install: versão não informada; tentando detectar via DB ou /lib/modules"
        # tenta resolver via pkg no DB
        if declare -F adm_db_init >/dev/null 2>&1 && declare -F adm_db_read_meta >/dev/null 2>&1; then
            adm_db_init || true
            if adm_db_read_meta "$pkg"; then
                ver="${DB_META_VERSION:-}"
            fi
        fi
    fi

    if [ -z "$ver" ]; then
        ir_log_error "adm_initramfs_on_kernel_install: não foi possível determinar versão de kernel para $pkg"
        return 1
    fi

    ir_log_info "Hook kernel-install: pkg=$pkg ver=$ver"
    ir_build_initramfs "$ver"
}

adm_initramfs_on_kernel_remove() {
    # $1 = nome do pacote, $2 = versão
    local pkg="$1"
    local ver="$2"

    if [ -z "$ver" ]; then
        ir_log_warn "adm_initramfs_on_kernel_remove: versão não informada; tentando deduzir via DB"
        if declare -F adm_db_init >/dev/null 2>&1 && declare -F adm_db_read_meta >/dev/null 2>&1; then
            adm_db_init || true
            if adm_db_read_meta "$pkg"; then
                ver="${DB_META_VERSION:-}"
            fi
        fi
    fi

    if [ -z "$ver" ]; then
        ir_log_error "adm_initramfs_on_kernel_remove: não foi possível determinar versão de kernel para $pkg"
        return 1
    fi

    ir_log_info "Hook kernel-remove: pkg=$pkg ver=$ver"
    ir_remove_initramfs "$ver"
}

adm_initramfs_on_driver_change() {
    # $1 = nome do pacote de driver (ex: nvidia, zfs, etc.)
    # Política: rebuild-all (mais seguro).
    local pkg="$1"
    [ -z "$pkg" ] && ir_log_warn "adm_initramfs_on_driver_change: nome de driver vazio; reconstruindo todos mesmo assim"

    ir_log_info "Hook driver-change: pkg=${pkg:-<unknown>} — reconstruindo initramfs de todos os kernels"
    ir_rebuild_all_initramfs
}

# -----------------------------
# CLI
# -----------------------------
ir_print_help() {
    cat <<EOF
Uso:
  initramfs.sh build <versao>
  initramfs.sh update <versao>
  initramfs.sh remove <versao>
  initramfs.sh rebuild-all
  initramfs.sh hook-kernel-install <pkg> <versao>
  initramfs.sh hook-kernel-remove  <pkg> <versao>
  initramfs.sh hook-driver-change  <pkg>

Exemplos:
  adm initramfs build 6.9.3-gentoo
  adm initramfs rebuild-all
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    CMD="$1"
    shift || true

    case "$CMD" in
        build)
            [ -z "$1" ] && { ir_print_help; exit 1; }
            ir_build_initramfs "$1"
            ;;
        update)
            [ -z "$1" ] && { ir_print_help; exit 1; }
            ir_update_initramfs "$1"
            ;;
        remove)
            [ -z "$1" ] && { ir_print_help; exit 1; }
            ir_remove_initramfs "$1"
            ;;
        rebuild-all)
            ir_rebuild_all_initramfs || exit 1
            ;;
        hook-kernel-install)
            [ $# -lt 2 ] && { ir_print_help; exit 1; }
            adm_initramfs_on_kernel_install "$1" "$2"
            ;;
        hook-kernel-remove)
            [ $# -lt 2 ] && { ir_print_help; exit 1; }
            adm_initramfs_on_kernel_remove "$1" "$2"
            ;;
        hook-driver-change)
            [ -z "$1" ] && { ir_print_help; exit 1; }
            adm_initramfs_on_driver_change "$1"
            ;;
        ""|-h|--help)
            ir_print_help
            ;;
        *)
            ir_log_error "Comando desconhecido: $CMD"
            ir_print_help
            exit 1
            ;;
    esac
fi
