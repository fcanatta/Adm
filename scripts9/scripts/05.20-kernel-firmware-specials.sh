#!/usr/bin/env bash
# 05.20-kernel-firmware-specials.sh
# Kernel/Firmware/Bootloader builder inteligente com instalação em DESTDIR.
###############################################################################
# Modo estrito + traps (sem erros silenciosos)
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__kfs_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] kernel-firmware-specials falhou: code=${code} line=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __kfs_err_trap ERR

###############################################################################
# Caminhos, logging, utils
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_LOG_DIR="${ADM_LOG_DIR:-${ADM_STATE_DIR}/logs}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"

adm_is_cmd(){ command -v "$1" >/dev/null 2>&1; }
__ensure_dir(){
  local d="$1" mode="${2:-0755}" owner="${3:-root}" group="${4:-root}"
  if [[ ! -d "$d" ]]; then
    if adm_is_cmd install; then
      if [[ $EUID -ne 0 ]] && adm_is_cmd sudo; then
        sudo install -d -m "$mode" -o "$owner" -g "$group" "$d"
      else
        install -d -m "$mode" -o "$owner" -g "$group" "$d"
      fi
    else
      mkdir -p "$d"; chmod "$mode" "$d"; chown "$owner:$group" "$d" || true
    fi
  fi
}
__ensure_dir "$ADM_STATE_DIR"; __ensure_dir "$ADM_LOG_DIR"; __ensure_dir "$ADM_TMPDIR"

# Cores simples
if [[ -t 1 ]] && adm_is_cmd tput && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RST="$(tput sgr0)"; C_OK="$(tput setaf 2)"; C_WRN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INF="$(tput setaf 6)"
else
  C_RST=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""
fi
kfs_info(){  echo -e "${C_INF}[ADM]${C_RST} $*"; }
kfs_ok(){    echo -e "${C_OK}[OK ]${C_RST} $*"; }
kfs_warn(){  echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
kfs_err(){   echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }
tmpfile(){ mktemp "${ADM_TMPDIR}/kfs.XXXXXX"; }

###############################################################################
# Hooks & contexto do pacote
###############################################################################
__pkg_root(){
  local cat="${ADM_META[category]:-}" name="${ADM_META[name]:-}"
  [[ -n "$cat" && -n "$name" ]] || { echo ""; return 1; }
  printf '%s/%s/%s' "$ADM_ROOT" "$cat" "$name"
}
__hooks_dirs(){
  local pr; pr="$(__pkg_root)" || return 0
  printf '%s\n' "$pr/hooks" "$ADM_ROOT/hooks"
}
adm_hooks_run(){
  # uso: adm_hooks_run <stage> [env...]
  local stage="${1:?}"; shift || true
  local d f ran=0
  for d in $(__hooks_dirs); do
    [[ -d "$d" ]] || continue
    for f in "$d/$stage" "$d/$stage.sh"; do
      if [[ -x "$f" ]]; then
        kfs_info "Hook: $(realpath -m "$f")"
        ( set -Eeuo pipefail; "$f" "$@" )
        ran=1
      fi
    done
  done
  (( ran )) || kfs_info "Hook '${stage}': nenhum"
}

###############################################################################
# CLI & parâmetros
###############################################################################
KFS_KERNEL=1
KFS_FIRMWARE=1
KFS_UBOOT=1
KFS_JOBS="${JOBS:-$(adm_is_cmd nproc && nproc || echo 2)}"
KFS_PROFILE="${ADM_PROFILE:-normal}"
KFS_LIBC="${ADM_LIBC:-}"
KFS_ARCH="${ARCH:-}"
KFS_CROSS="${CROSS_COMPILE:-}"
KFS_LLVM=0
KFS_DEFCONFIG=""
KFS_KCONFIG_PATH=""
KFS_LOCALMOD=0
KFS_OLDDEF=1
KFS_LTO=0
KFS_THINLTO=0
KFS_MODULES_COMPRESS="xz"   # xz|zstd|none
KFS_INITRAMFS="none"        # dracut|mkinitcpio|busybox|none
KFS_SIGN=0
KFS_DTBS=1
KFS_HEADERS=1
KFS_KVER_SUFFIX=""
KFS_FW_WHITELIST=""
KFS_FW_BLACKLIST=""
KFS_BOARD=""  # para U-Boot

kfs_usage(){
  cat <<'EOF'
Uso:
  05.20-kernel-firmware-specials.sh --workdir DIR --destdir DIR [opções]

Selecionadores:
  --kernel-only           Apenas kernel
  --firmware-only         Apenas firmware
  --uboot-only            Apenas U-Boot

Kernel:
  --arch ARCH             ARCH do kernel (ex: x86_64, arm64)
  --cross PREFIX          CROSS_COMPILE=PREFIX (ex: aarch64-linux-gnu-)
  --llvm                  LLVM=1 (clang/lld)
  --defconfig NAME        make <NAME>_defconfig
  --kconfig PATH          Config custom (merge se existir .config)
  --localmodconfig        make localmodconfig
  --no-olddefconfig       Não rodar olddefconfig (padrão roda)
  --lto                   Ativar LTO (se suportado)
  --thinlto               Ativar ThinLTO (llvm)
  --modules-compress {xz|zstd|none}
  --initramfs {dracut|mkinitcpio|busybox|none}
  --sign                  Assinar kernel/módulos (X.509/EFI se possível)
  --dtbs/--no-dtbs        (habilita por padrão)
  --headers/--no-headers  (habilita por padrão)
  --kver-suffix STR       Sufixo extra p/ versão do kernel (ex: -adm)

Firmware:
  --whitelist 'glob1,glob2'    Incluir apenas estes padrões
  --blacklist 'glob1,glob2'    Excluir estes padrões

U-Boot:
  --board NAME            nome de defconfig (ex: qemu_arm64)

Geral:
  --profile {aggressive|normal|minimal}
  --libc {glibc|musl}
  --jobs N
  --help
EOF
}

parse_cli(){
  WORKDIR="" DESTDIR=""
  while (($#)); do
    case "$1" in
      --workdir) WORKDIR="${2:-}"; shift 2 ;;
      --destdir) DESTDIR="${2:-}"; shift 2 ;;
      --kernel-only)   KFS_KERNEL=1; KFS_FIRMWARE=0; KFS_UBOOT=0; shift ;;
      --firmware-only) KFS_KERNEL=0; KFS_FIRMWARE=1; KFS_UBOOT=0; shift ;;
      --uboot-only)    KFS_KERNEL=0; KFS_FIRMWARE=0; KFS_UBOOT=1; shift ;;
      --arch) KFS_ARCH="${2:-}"; shift 2 ;;
      --cross) KFS_CROSS="${2:-}"; shift 2 ;;
      --llvm) KFS_LLVM=1; shift ;;
      --defconfig) KFS_DEFCONFIG="${2:-}"; shift 2 ;;
      --kconfig) KFS_KCONFIG_PATH="${2:-}"; shift 2 ;;
      --localmodconfig) KFS_LOCALMOD=1; shift ;;
      --no-olddefconfig) KFS_OLDDEF=0; shift ;;
      --lto) KFS_LTO=1; shift ;;
      --thinlto) KFS_THINLTO=1; shift ;;
      --modules-compress) KFS_MODULES_COMPRESS="${2:-xz}"; shift 2 ;;
      --initramfs) KFS_INITRAMFS="${2:-none}"; shift 2 ;;
      --sign) KFS_SIGN=1; shift ;;
      --dtbs) KFS_DTBS=1; shift ;;
      --no-dtbs) KFS_DTBS=0; shift ;;
      --headers) KFS_HEADERS=1; shift ;;
      --no-headers) KFS_HEADERS=0; shift ;;
      --kver-suffix) KFS_KVER_SUFFIX="${2:-}"; shift 2 ;;
      --whitelist) KFS_FW_WHITELIST="${2:-}"; shift 2 ;;
      --blacklist) KFS_FW_BLACKLIST="${2:-}"; shift 2 ;;
      --board) KFS_BOARD="${2:-}"; shift 2 ;;
      --profile) KFS_PROFILE="${2:-normal}"; shift 2 ;;
      --libc)    KFS_LIBC="${2:-}"; shift 2 ;;
      --jobs)    KFS_JOBS="${2:-$KFS_JOBS}"; shift 2 ;;
      --help|-h) kfs_usage; exit 0 ;;
      *) kfs_err "opção inválida: $1"; kfs_usage; exit 2 ;;
    esac
  done
  [[ -d "$WORKDIR" ]] || { kfs_err "WORKDIR inválido"; exit 3; }
  [[ -n "$DESTDIR" ]] || { kfs_err "DESTDIR não informado"; exit 4; }
  __ensure_dir "$DESTDIR"
}

###############################################################################
# Logs por componente
###############################################################################
__mk_logs(){
  local cat="${ADM_META[category]:-unknown}" prog="${ADM_META[name]:-unknown}"
  local stamp; stamp="$(date -u +%Y%m%d-%H%M%S)"
  KFS_LOG_DIR="${ADM_LOG_DIR}/kfs/${cat}/${prog}/${stamp}"; __ensure_dir "$KFS_LOG_DIR"
  LOG_KCFG="${KFS_LOG_DIR}/01-kconfig.log"
  LOG_KBLD="${KFS_LOG_DIR}/02-kbuild.log"
  LOG_KINS="${KFS_LOG_DIR}/03-kinstall.log"
  LOG_FW="${KFS_LOG_DIR}/10-firmware.log"
  LOG_UB="${KFS_LOG_DIR}/20-uboot.log"
}

__runt(){ local log="${1:?}"; shift; [[ "$1" == "--" ]] && shift || { kfs_err "__runt uso"; return 2; }; set -o pipefail; ( "$@" 2>&1 | tee -a "$log" ); }

###############################################################################
# Detecção de componente (kernel/firmware/uboot)
###############################################################################
is_kernel_tree(){ [[ -f "$1/Makefile" ]] && grep -qE '^VERSION|^KBUILD' "$1/Makefile" 2>/dev/null; }
is_linux_firmware_tree(){ [[ -d "$1" ]] && ( [[ -d "$1/amd" || -d "$1/intel" || -d "$1/rtl_nic" ]] || compgen -G "$1/**/*.bin" >/dev/null ); }
is_uboot_tree(){ [[ -f "$1/Makefile" ]] && grep -q 'U-Boot' "$1/README" 2>/dev/null || [[ -f "$1/doc/README" && -d "$1/board" ]]; }
###############################################################################
# KERNEL: preparo de ambiente e configuração
###############################################################################
__kernel_env(){
  local wk="$1"
  KMAKE=( make -C "$wk" )
  [[ -n "$KFS_ARCH" ]]  && KMAKE+=( ARCH="$KFS_ARCH" )
  [[ -n "$KFS_CROSS" ]] && KMAKE+=( CROSS_COMPILE="$KFS_CROSS" )
  (( KFS_LLVM )) && KMAKE+=( LLVM=1 )
  KMAKE+=( -j "${KFS_JOBS}" )
}

__kernel_apply_profile_flags(){
  local extraKC="" extraKL=""
  case "$KFS_PROFILE" in
    aggressive)
      extraKC+=" -O3 -pipe"
      (( KFS_LTO )) && extraKC+=" -flto"
      (( KFS_THINLTO )) && extraKC+=" -flto=thin"
      ;;
    normal)  extraKC+=" -O2 -pipe" ;;
    minimal) extraKC+=" -O0" ;;
  esac
  export KCFLAGS="${KCFLAGS:-}${KCFLAGS:+ }${extraKC}"
  export KCPPFLAGS="${KCPPFLAGS:-}"
  export KASAN="${KASAN:-0}"
  export KUBSAN="${KUBSAN:-0}"
  export LDFLAGS="${LDFLAGS:-}${LDFLAGS:+ }${extraKL}"
}

kernel_configure(){
  local wk="$1"
  __kernel_env "$wk"
  __kernel_apply_profile_flags

  adm_hooks_run "pre-kernel-config"

  if [[ -n "$KFS_DEFCONFIG" ]]; then
    kfs_info "make ${KFS_DEFCONFIG}_defconfig"
    __runt "$LOG_KCFG" -- "${KMAKE[@]}" "${KFS_DEFCONFIG}_defconfig"
  elif (( KFS_LOCALMOD )); then
    kfs_info "make localmodconfig"
    __runt "$LOG_KCFG" -- "${KMAKE[@]}" localmodconfig
  elif [[ -f "$wk/defconfig" ]]; then
    kfs_info "merge defconfig"
    cp -f "$wk/defconfig" "$wk/.config"
  elif [[ -f "$wk/arch/${KFS_ARCH:-$(uname -m)}/configs/defconfig" ]]; then
    kfs_info "make defconfig (padrão)"
    __runt "$LOG_KCFG" -- "${KMAKE[@]}" defconfig
  fi

  if [[ -n "$KFS_KCONFIG_PATH" && -r "$KFS_KCONFIG_PATH" ]]; then
    kfs_info "mergeconfig: $(basename "$KFS_KCONFIG_PATH")"
    cp -f "$KFS_KCONFIG_PATH" "$wk/.config.merge"
    __runt "$LOG_KCFG" -- "${KMAKE[@]}" KCONFIG_ALLCONFIG=".config.merge" alldefconfig || true
    rm -f "$wk/.config.merge"
  fi

  (( KFS_OLDDEF )) && { kfs_info "olddefconfig"; __runt "$LOG_KCFG" -- "${KMAKE[@]}" olddefconfig; }

  adm_hooks_run "post-kernel-config"
}

###############################################################################
# KERNEL: build, modules, dtbs
###############################################################################
kernel_build(){
  local wk="$1"
  __kernel_env "$wk"

  adm_hooks_run "pre-kernel-build"

  # alvo principal (arch-dependente)
  local img_targets=( bzImage Image zImage vmlinux )
  local built_any=0 t
  for t in "${img_targets[@]}"; do
    if __runt "$LOG_KBLD" -- "${KMAKE[@]}" "$t"; then built_any=1; break; fi
  done
  (( built_any )) || { kfs_err "falha ao construir imagem do kernel"; exit 40; }

  # módulos
  __runt "$LOG_KBLD" -- "${KMAKE[@]}" modules || true
  # dtbs
  (( KFS_DTBS )) && __runt "$LOG_KBLD" -- "${KMAKE[@]}" dtbs || true

  adm_hooks_run "post-kernel-build"
}

###############################################################################
# KERNEL: instalação em DESTDIR
###############################################################################
__kernel_version(){
  local wk="$1"
  ( cd "$wk" && make kernelrelease 2>/dev/null ) || (cd "$wk" && scripts/setlocalversion 2>/dev/null && make -s kernelversion )
}

__kernel_pick_image(){
  local wk="$1"
  local arch="${KFS_ARCH:-$(uname -m)}"
  case "$arch" in
    x86_64|i?86)   [[ -f "$wk/arch/x86/boot/bzImage" ]] && echo "$wk/arch/x86/boot/bzImage" && return ;;
    arm64|aarch64) [[ -f "$wk/arch/arm64/boot/Image" ]] && echo "$wk/arch/arm64/boot/Image" && return ;;
    arm*)          compgen -G "$wk/arch/arm/boot/zImage" >/dev/null && echo "$wk/arch/arm/boot/zImage" && return ;;
    riscv*)        [[ -f "$wk/arch/riscv/boot/Image" ]] && echo "$wk/arch/riscv/boot/Image" && return ;;
    *)             [[ -f "$wk/vmlinux" ]] && echo "$wk/vmlinux" && return ;;
  esac
  echo ""
}

kernel_install(){
  local wk="$1" dd="$2"
  adm_hooks_run "pre-kernel-install"

  local kver; kver="$(__kernel_version "$wk")"
  [[ -n "$KFS_KVER_SUFFIX" ]] && kver="${kver}${KFS_KVER_SUFFIX}"

  local img; img="$(__kernel_pick_image "$wk")"
  [[ -n "$img" && -r "$img" ]] || { kfs_err "imagem do kernel não encontrada"; exit 41; }
  __ensure_dir "$dd/boot"; __ensure_dir "$dd/lib/modules"

  local kvdir="$dd/lib/modules/$kver"
  __ensure_dir "$kvdir"
  # install modules
  __runt "$LOG_KINS" -- make -C "$wk" modules_install INSTALL_MOD_PATH="$dd" INSTALL_MOD_STRIP=0
  # compressão de módulos
  case "$KFS_MODULES_COMPRESS" in
    xz)   find "$kvdir" -type f -name '*.ko' -print0 | xargs -0 -r -n1 -P"${KFS_JOBS}" xz -T0 -f ;;
    zstd) find "$kvdir" -type f -name '*.ko' -print0 | xargs -0 -r -n1 -P"${KFS_JOBS}" zstd -q -19 --rm ;;
    none) : ;;
    *) kfs_warn "compressor de módulos desconhecido: $KFS_MODULES_COMPRESS" ;;
  esac

  # install image + System.map + config
  install -Dm0644 "$img"                "$dd/boot/vmlinuz-${kver}"
  [[ -f "$wk/System.map" ]] && install -Dm0644 "$wk/System.map" "$dd/boot/System.map-${kver}"
  [[ -f "$wk/.config"    ]] && install -Dm0644 "$wk/.config"   "$dd/boot/config-${kver}"

  # dtbs
  if (( KFS_DTBS )); then
    local dtdir="$dd/usr/lib/dtbs/${kver}"
    __ensure_dir "$dtdir"
    if compgen -G "$wk/arch/*/boot/dts/**/*.dtb" >/dev/null; then
      find "$wk/arch" -path '*/boot/dts/*.dtb' -o -path '*/boot/dts/**/*.dtb' -type f -print0 \
        | xargs -0 -I{} install -Dm0644 "{}" "$dtdir/{}"
    fi
  fi

  # headers
  if (( KFS_HEADERS )); then
    __runt "$LOG_KINS" -- make -C "$wk" INSTALL_HDR_PATH="$dd/usr" headers_install
    # opcional: kernel-devel simplificado
    local hdir="$dd/usr/src/linux-headers-${kver}"
    __ensure_dir "$hdir"
    ( cd "$wk" && tar -c --exclude='./.*' --exclude='./source' --exclude='./build' include scripts arch | tar -x -C "$hdir" ) || true
  fi

  kfs_ok "Kernel instalado em DESTDIR (versão: ${kver})"

  # initramfs
  case "$KFS_INITRAMFS" in
    dracut)
      if adm_is_cmd dracut; then
        __runt "$LOG_KINS" -- dracut --force --kver "$kver" --no-hostonly --fstab --kernel-image "$dd/boot/vmlinuz-${kver}" "$dd/boot/initramfs-${kver}.img"
      else
        kfs_warn "dracut não encontrado"
      fi
      ;;
    mkinitcpio)
      if adm_is_cmd mkinitcpio; then
        __runt "$LOG_KINS" -- mkinitcpio -k "$kver" -g "$dd/boot/initramfs-${kver}.img"
      else
        kfs_warn "mkinitcpio não encontrado"
      fi
      ;;
    busybox)
      # busybox cpio minimal (sem autodiscovery completa)
      if adm_is_cmd busybox; then
        local ir="$dd/boot/initramfs-${kver}.img"
        ( cd "$dd"; find . -mindepth 1 -type f -print0 | \
          cpio --null -o --format=newc | gzip -9 > "$ir" ) || kfs_warn "initramfs busybox falhou"
      else
        kfs_warn "busybox não encontrado"
      fi
      ;;
    none|"" ) : ;;
    *) kfs_warn "initramfs desconhecido: $KFS_INITRAMFS" ;;
  esac

  # assinatura (Secure Boot / módulos)
  if (( KFS_SIGN )); then
    kfs_sign_artifacts "$wk" "$dd" "$kver" || kfs_warn "assinatura falhou"
  fi

  adm_hooks_run "post-kernel-install"
}

###############################################################################
# KERNEL: assinatura (módulos/EFI)
###############################################################################
kfs_sign_artifacts(){
  local wk="$1" dd="$2" kver="$3"
  # Chaves X.509 esperadas em ${ADM_STATE_DIR}/keys/{signing_key.pem, signing_key.x509}
  local kdir="${ADM_STATE_DIR}/keys"
  local key="$kdir/signing_key.pem" crt="$kdir/signing_key.x509"
  if [[ -r "$key" && -r "$crt" ]]; then
    if adm_is_cmd scripts/sign-file; then
      find "$dd/lib/modules/$kver" -type f -name '*.ko*' -print0 | while IFS= read -r -d '' m; do
        case "$m" in *.ko|*.ko.gz|*.ko.xz|*.ko.zst) ;; *) continue ;; esac
        # descomprimir, assinar, recomprimir
        local raw="$m"
        if [[ "$m" == *.xz ]]; then xz -d -f "$m"; raw="${m%.xz}"
        elif [[ "$m" == *.zst ]]; then zstd -d -q --rm "$m"; raw="${m%.zst}"
        elif [[ "$m" == *.gz ]]; then gunzip -f "$m"; raw="${m%.gz}"
        fi
        scripts/sign-file sha256 "$key" "$crt" "$raw" || true
        # recomprime
        case "$KFS_MODULES_COMPRESS" in
          xz) xz -T0 -f "$raw" ;;
          zstd) zstd -q -19 --rm "$raw" ;;
          none) : ;;
        esac
      done
    else
      kfs_warn "scripts/sign-file não disponível para assinar módulos"
    fi
  else
    kfs_warn "chaves de assinatura ausentes em $kdir"
  fi

  # Assinar kernel EFI (se for o caso)
  local efi="$dd/boot/efi/EFI/Linux/linux-${kver}.efi"
  if [[ -f "$efi" ]]; then
    if adm_is_cmd sbsign; then
      sbsign --key "$key" --cert "$crt" --output "$efi" "$efi" || true
    elif adm_is_cmd pesign; then
      pesign -s -i "$efi" -o "$efi" -c "ADM Secure Boot" -n /etc/pki/pesign || true
    elif adm_is_cmd ukify; then
      # ukify pode criar imagem unificada; se já existir, tentar assinar
      ukify --sign-key "$key" --sign-cert "$crt" "$efi" || true
    else
      kfs_warn "nenhuma ferramenta EFI signing encontrada"
    fi
  fi
}

###############################################################################
# FIRMWARE: instalação
###############################################################################
install_firmware_tree(){
  local wk="$1" dd="$2"
  adm_hooks_run "pre-firmware"
  __ensure_dir "$dd/usr/lib/firmware"
  local includes excludes
  IFS=',' read -r -a includes <<< "${KFS_FW_WHITELIST:-}"
  IFS=',' read -r -a excludes <<< "${KFS_FW_BLACKLIST:-}"

  shopt -s globstar nullglob
  local copied=0
  if ((${#includes[@]})); then
    for g in "${includes[@]}"; do
      for f in "$wk/$g"; do
        [[ -f "$f" ]] || continue
        install -Dm0644 "$f" "$dd/usr/lib/firmware/${f#"$wk/"}"
        ((copied++))
      done
    done
  else
    # tudo menos blacklist
    while IFS= read -r -d '' f; do
      local rel="${f#"$wk/"}" skip=0
      for g in "${excludes[@]:-}"; do [[ -n "$g" && "$rel" == $g ]] && { skip=1; break; }; done
      ((skip)) && continue
      install -Dm0644 "$f" "$dd/usr/lib/firmware/$rel"; ((copied++))
    done < <(find "$wk" -type f \( -name '*.bin' -o -name '*.fw' -o -name '*.ucode' -o -name '*.hex' -o -name '*.dat' \) -print0)
  fi
  shopt -u globstar nullglob

  kfs_ok "Firmware: ${copied} arquivos instalados em $dd/usr/lib/firmware"
  adm_hooks_run "post-firmware"
}

###############################################################################
# U-BOOT: build e instalação
###############################################################################
uboot_build_install(){
  local wk="$1" dd="$2"
  adm_hooks_run "pre-uboot"

  local mk=( make -C "$wk" -j "${KFS_JOBS}" )
  [[ -n "$KFS_CROSS" ]] && mk+=( CROSS_COMPILE="$KFS_CROSS" )
  [[ -n "$KFS_ARCH"  ]] && mk+=( ARCH="$KFS_ARCH" )

  local def="${KFS_BOARD:-}"
  if [[ -z "$def" ]]; then
    # heurística simples: tenta detectar algum *_defconfig
    def="$( (cd "$wk/configs" 2>/dev/null && ls -1 *_defconfig 2>/dev/null | head -n1 || true) )"
    def="${def%_defconfig}"
  fi
  [[ -n "$def" ]] || { kfs_warn "U-Boot: não foi possível determinar defconfig"; return 0; }

  __runt "$LOG_UB" -- "${mk[@]}" "${def}_defconfig"
  __runt "$LOG_UB" -- "${mk[@]}" all

  # instalar
  local outdir="$dd/usr/lib/u-boot/${def}"
  __ensure_dir "$outdir"
  compgen -G "$wk/u-boot*" >/dev/null && install -Dm0644 "$wk"/u-boot* "$outdir/" || true
  compgen -G "$wk/spl/*" >/dev/null && ( cd "$wk/spl" && find . -type f -maxdepth 1 -print0 | xargs -0 -I{} install -Dm0644 "{}" "$outdir/{}" ) || true
  # ferramentas
  compgen -G "$wk/tools/*env*" >/dev/null && install -Dm0755 "$wk"/tools/*env* "$dd/usr/bin/" || true

  kfs_ok "U-Boot instalado em $outdir"
  adm_hooks_run "post-uboot"
}
###############################################################################
# Orquestração principal
###############################################################################
kfs_run(){
  parse_cli "$@"
  __mk_logs

  local has_kernel=0 has_fw=0 has_ub=0
  is_kernel_tree "$WORKDIR" && has_kernel=1
  is_linux_firmware_tree "$WORKDIR" && has_fw=1
  is_uboot_tree "$WORKDIR" && has_ub=1

  # Se usuário filtrou, respeitar seletores
  (( KFS_KERNEL ))  || has_kernel=0
  (( KFS_FIRMWARE ))|| has_fw=0
  (( KFS_UBOOT ))   || has_ub=0

  if (( has_kernel==0 && has_fw==0 && has_ub==0 )); then
    kfs_warn "Nenhum alvo reconhecido no WORKDIR (ou desativado por flags)."
  fi

  # Kernel
  if (( has_kernel )); then
    kfs_info "==== KERNEL ===="
    kernel_configure "$WORKDIR"
    kernel_build "$WORKDIR"
    kernel_install "$WORKDIR" "$DESTDIR"
  fi

  # Firmware
  if (( has_fw )); then
    kfs_info "==== FIRMWARE ===="
    install_firmware_tree "$WORKDIR" "$DESTDIR"
  fi

  # U-Boot
  if (( has_ub )); then
    kfs_info "==== U-BOOT ===="
    uboot_build_install "$WORKDIR" "$DESTDIR"
  fi

  kfs_ok "Concluído. Logs em: $KFS_LOG_DIR"
}

###############################################################################
# Execução direta
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  kfs_run "$@"
fi
