#!/usr/bin/env bash
# adm-mkinitramfs.sh
# Cria initramfs/mkinitramfs compatível com ADM (para /boot ou stage)
# Suporta dry-run, --yes, chroot, inclusão de modules e busybox, escolha de compressor.
# Comentários: todas as operações com risco são explicitamente marcadas.
#
# Uso (exemplos):
#  sudo adm-mkinitramfs.sh --kernel-version 6.1.0 --dest /boot --compress xz
#  adm-mkinitramfs.sh --chroot /usr/src/adm/stage0/root --kernel-version 6.1.0 --output initrd.img
#  adm-mkinitramfs.sh --dry-run --kernel-version 6.1.0 --dest /boot
#
set -euo pipefail
IFS=$'\n\t'

# ---------------- configuração padrão ----------------
SCRIPT_NAME="$(basename "$0")"
ADM_TMP="${ADM_TMP:-/usr/src/adm/temp}"
DEFAULT_COMPRESSOR="auto"
KEEP_TEMP=0
DRYRUN=0
YES=0
VERBOSE=0
DEST=""
STAGE_DIR=""
OUTPUT_NAME=""
KERNEL_VERSION=""
KERNEL_IMAGE=""
INCLUDE_MODULES=1
MODULES_DIR=""
BUSYBOX_BINARY=""
CHROOT_PATH=""
COMPRESSOR="${DEFAULT_COMPRESSOR}"
WORKDIR=""
CPIO_CMD="${CPIO_CMD:-cpio}"
FIND_CMD="${FIND_CMD:-find}"

# ---------------- utilitários ----------------
log() { printf "\033[1;36m[adm-mkinitramfs]\033[0m %s\n" "$*"; }
info() { printf "\033[1;32m[info]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[error]\033[0m %s\n" "$*" >&2; exit 1; }

# print and run (respects dry-run)
run() {
  if [ "${DRYRUN}" -eq 1 ]; then
    log "[dry-run] $*"
  else
    if [ "${VERBOSE}" -eq 1 ]; then
      log "Running: $*"
    fi
    eval "$@"
  fi
}

confirm() {
  # if YES set, skip prompt (used for automation) — dangerous writes still commented above
  if [ "${YES}" -eq 1 ]; then
    return 0
  fi
  printf "%s [y/N]: " "$1"
  read -r ans || return 1
  case "${ans}" in
    y|Y|yes|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

usage() {
  cat <<EOF
$SCRIPT_NAME - cria initramfs/mkinitramfs para ADM

Opções:
  --dest <dir>             destino (ex: /boot). Se ausente usa --stage-dir.
  --stage-dir <dir>        constrói initramfs dentro do stage (DESTDIR).
  --output <name>          nome do arquivo de saída (ex: initrd.img-<ver>.img)
  --kernel-version <ver>   versão do kernel (ex: 6.1.0); se ausente tenta detectar uname -r
  --kernel-image <path>    caminho para o vmlinuz (alternativa a kernel-version)
  --no-modules             não incluir /lib/modules
  --modules-dir <dir>      diretório alternativo de módulos
  --busybox <path>         caminho para busybox estático (se não fornecido procura no PATH)
  --compressor <auto|gzip|xz|zstd>
  --chroot <path>          construir dentro de chroot (usa adm-chroot se disponível)
  --dry-run                apenas simula operações, não altera nada
  --yes                    assume yes (ignora prompts)
  --keep-temp              não remove diretório temporário (para debug)
  --verbose                saída verbosa
  -h, --help               mostra este help

Exemplos:
  sudo $SCRIPT_NAME --kernel-version 6.1.0 --dest /boot --compressor xz
  $SCRIPT_NAME --chroot /usr/src/adm/stage0/root --kernel-version 6.1.0 --output initrd.img
EOF
  exit 1
}

# ---------------- parse args ----------------
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;;
    --stage-dir) STAGE_DIR="$2"; shift 2 ;;
    --output) OUTPUT_NAME="$2"; shift 2 ;;
    --kernel-version) KERNEL_VERSION="$2"; shift 2 ;;
    --kernel-image) KERNEL_IMAGE="$2"; shift 2 ;;
    --no-modules) INCLUDE_MODULES=0; shift ;;
    --modules-dir) MODULES_DIR="$2"; shift 2 ;;
    --busybox) BUSYBOX_BINARY="$2"; shift 2 ;;
    --compressor) COMPRESSOR="$2"; shift 2 ;;
    --chroot) CHROOT_PATH="$2"; shift 2 ;;
    --dry-run) DRYRUN=1; shift ;;
    --yes) YES=1; shift ;;
    --keep-temp) KEEP_TEMP=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage ;;
    *) err "Arg desconhecido: $1" ;;
  esac
done

# ---------------- sanidade e detect ----------------
if [ -z "${DEST}" ] && [ -z "${STAGE_DIR}" ]; then
  warn "Nem --dest nem --stage-dir especificados. O arquivo de initramfs será criado no diretório temporário e NÃO instalado automaticamente."
fi

# detect kernel version if not provided
if [ -z "${KERNEL_VERSION}" ] && [ -z "${KERNEL_IMAGE}" ]; then
  if [ -n "${CHROOT_PATH}" ]; then
    # tenta detectar dentro do chroot
    if command -v adm-chroot >/dev/null 2>&1; then
      KERNEL_VERSION="$(adm-chroot exec "${CHROOT_PATH}" -- uname -r 2>/dev/null || true)"
    fi
  fi
  KERNEL_VERSION="${KERNEL_VERSION:-$(uname -r 2>/dev/null || true)}"
fi

# choose compressor
choose_compressor() {
  local c="${COMPRESSOR}"
  if [ "${c}" = "auto" ]; then
    if command -v zstd >/dev/null 2>&1; then echo "zstd"
    elif command -v xz >/dev/null 2>&1; then echo "xz"
    elif command -v gzip >/dev/null 2>&1; then echo "gzip"
    else echo "gzip"
    fi
  else
    echo "${c}"
  fi
}
COMPRESSOR="$(choose_compressor)"

# check required tools
check_requirements() {
  local missing=()
  for tool in "${CPIO_CMD}" "${FIND_CMD}" mktemp mkdir chown chmod ln rm; do
    if ! command -v "${tool}" >/dev/null 2>&1 && [ "${tool}" != "${CPIO_CMD}" ]; then
      missing+=("${tool}")
    fi
  done
  # cpio
  if ! command -v cpio >/dev/null 2>&1; then missing+=("cpio"); fi
  # compressor
  case "${COMPRESSOR}" in
    zstd) command -v zstd >/dev/null 2>&1 || missing+=("zstd") ;;
    xz)   command -v xz >/dev/null 2>&1 || missing+=("xz") ;;
    gzip) command -v gzip >/dev/null 2>&1 || missing+=("gzip") ;;
  esac
  if [ "${#missing[@]}" -ne 0 ]; then
    warn "Ferramentas ausentes: ${missing[*]} — algumas operações podem falhar."
  fi
}
check_requirements

# ---------------- preparar workdir ----------------
WORKDIR="$(mktemp -d "${ADM_TMP:-/tmp}/adm-mkinitramfs.XXXXXX")"
[ "${VERBOSE}" -eq 1 ] && log "Workdir temporário: ${WORKDIR}"
if [ "${DRYRUN}" -eq 1 ]; then
  log "Modo dry-run ativo — nada será gravado no host"
fi

cleanup() {
  if [ "${KEEP_TEMP}" -eq 1 ]; then
    log "Preservando temporário: ${WORKDIR}"
  else
    if [ "${DRYRUN}" -eq 1 ]; then
      log "Dry-run: limpar temporários simulados (nenhuma remoção real)"
    else
      rm -rf -- "${WORKDIR}" || true
      [ "${VERBOSE}" -eq 1 ] && log "Workdir removido: ${WORKDIR}"
    fi
  fi
}
trap cleanup EXIT

# ---------------- montagem do initramfs (conteúdo) ----------------
# criamos uma estrutura mínima:
# /bin /sbin /lib /lib64 /dev /proc /sys /run /etc /usr (se necessário)
create_base_tree() {
  local root="$1"
  run "mkdir -p '${root}'"
  for d in bin sbin lib lib64 dev proc sys run etc usr lib/modules; do
    run "mkdir -p '${root}/${d}'"
  done
  # permissões mínimas
  run "chmod 0755 '${root}'"
}

# copiar busybox (opcional)
install_busybox() {
  local root="$1"
  local bb="${BUSYBOX_BINARY}"
  if [ -z "${bb}" ]; then
    # tenta localizar busybox estático executável no PATH
    bb="$(command -v busybox 2>/dev/null || true)"
  fi
  if [ -z "${bb}" ]; then
    warn "busybox não encontrado; initramfs gerado pode precisar de /bin/sh e utilitários externos"
    return 0
  fi
  if [ ! -x "${bb}" ]; then
    warn "busybox especificado não é executável: ${bb}"
    return 0
  fi
  log "Incluindo busybox: ${bb}"
  run "cp -a '${bb}' '${root}/bin/busybox'"
  # criar links dos applets (lista reduzida para robustez)
  local applets=(sh mount umount ls cat echo sleep mkdir mknod mount pivot_root switch_root sleep)
  for a in "${applets[@]}"; do
    run "ln -sf busybox '${root}/bin/${a}'" || true
  done
  run "chmod +x '${root}/bin/busybox' || true"
}

# instalar módulos do kernel (copia /lib/modules/<ver> inteira)
install_modules() {
  local root="$1"
  if [ "${INCLUDE_MODULES}" -ne 1 ]; then
    log "Incluir módulos desativado (--no-modules)"
    return 0
  fi
  local moddir="${MODULES_DIR}"
  if [ -z "${moddir}" ]; then
    if [ -n "${STAGE_DIR}" ]; then
      moddir="${STAGE_DIR}/lib/modules/${KERNEL_VERSION}"
    else
      moddir="/lib/modules/${KERNEL_VERSION}"
    fi
  fi
  if [ ! -d "${moddir}" ]; then
    warn "Diretório de módulos não encontrado: ${moddir} — pulando inclusão de módulos"
    return 0
  fi
  log "Copiando módulos de: ${moddir}"
  run "cp -a '${moddir}' '${root}/lib/modules/'"
}

# criar /init script (entrypoint do initramfs)
write_init_script() {
  local root="$1"
  local cmdline="${2:-}"
  local init="${root}/init"
  cat > "${TMPDIR}/init.tmp" <<'EOF'
#!/bin/sh
# init - minimal init for ADM initramfs
set -e
# mount pseudo-filesystems
mount -t proc proc /proc || true
mount -t sysfs sysfs /sys || true
mount -t devtmpfs devtmpfs /dev || true
export PATH="/bin:/sbin:/usr/bin:/usr/sbin"

# Optional: parse kernel cmdline for debug or single-user flags
# TODO: more sophisticated handling if needed

# Try to switch to real root (assumes root is on /dev/sda1 or kernel cmdline provides root=)
# WARNING: The following commands may be dangerous if run on a live system incorrectly.
# They are executed in the initramfs context and should not affect the host outside chroot.
# We leave these as safe best-effort: try mount and pivot_root/switch_root if available.

if [ -n "$(command -v switch_root 2>/dev/null)" ]; then
    # prefer switch_root if available (busybox or system)
    echo "Attempting switch_root..."
    # find a likely root device from /proc/cmdline
    ROOTDEV="$(cat /proc/cmdline | sed -n 's/.*root=\([^ ]*\).*/\1/p')"
    if [ -n "${ROOTDEV}" ]; then
        mkdir -p /newroot
        mount "${ROOTDEV}" /newroot 2>/dev/null || true
        if [ -d /newroot ]; then
            exec switch_root /newroot /sbin/init || exec switch_root /newroot /bin/sh || true
        fi
    fi
fi

# fallback: drop to sh to let user investigate
exec /bin/sh
EOF
  run "mv '${TMPDIR}/init.tmp' '${init}'"
  run "chmod +x '${init}'"
}

# assemble cpio archive and compress
assemble_initramfs() {
  local root="$1"
  local out="$2"  # full path output file
  log "Criando initramfs em ${out} (compressor=${COMPRESSOR})"
  # create a portable cpio image from root contents
  # important: run from root to preserve relative paths
  if [ "${DRYRUN}" -eq 1 ]; then
    log "[dry-run] cpio from ${root} -> ${out}"
    return 0
  fi
  pushd "${root}" >/dev/null
  # ensure device nodes are minimal (mknod requires root); we avoid creating special dev nodes automatically
  # If required, user hooks can create additional nodes under hooks/ pre-tar.
  ${FIND_CMD} . -print0 | ${CPIO_CMD} --null -ov --format=newc > "${out}.cpio" || {
    popd >/dev/null
    err "cpio failure"
  }
  popd >/dev/null

  case "${COMPRESSOR}" in
    zstd)
      if command -v zstd >/dev/null 2>&1; then
        run "zstd -q -19 '${out}.cpio' -o '${out}'" || err "zstd failed"
        rm -f -- "${out}.cpio"
      else
        err "zstd não disponível"
      fi
      ;;
    xz)
      if command -v xz >/dev/null 2>&1; then
        run "xz -z -9 -c '${out}.cpio' > '${out}'" || err "xz failed"
        rm -f -- "${out}.cpio"
      else
        err "xz não disponível"
      fi
      ;;
    gzip)
      if command -v gzip >/dev/null 2>&1; then
        run "gzip -c9 '${out}.cpio' > '${out}'" || err "gzip failed"
        rm -f -- "${out}.cpio"
      else
        err "gzip não disponível"
      fi
      ;;
    *)
      err "Compressor desconhecido: ${COMPRESSOR}"
      ;;
  esac
  log "Initramfs criado: ${out}"
}

# ---------------- execução principal ----------------
main() {
  info "Iniciando adm-mkinitramfs"
  info "COMPRESSOR=${COMPRESSOR} DRYRUN=${DRYRUN} CHROOT=${CHROOT_PATH:-none}"

  # safety: writing to /boot is risky => require explicit confirmation (unless --yes)
  if [ -n "${DEST}" ] && [ "${DEST}" = "/boot" ] && [ "${DRYRUN}" -ne 1 ] && [ "${YES}" -ne 1 ]; then
    warn "Operação irá escrever em /boot — isso pode tornar o sistema não inicializável se feito incorretamente."
    if ! confirm "Deseja continuar e escrever em /boot?"; then
      err "Operação abortada pelo usuário."
    fi
  fi

  # determine output filename
  if [ -n "${OUTPUT_NAME}" ]; then
    OUTNAME="${OUTPUT_NAME}"
  else
    # default: initramfs-<kernelver>.img.<ext>
    base="initramfs"
    kv="${KERNEL_VERSION:-$(uname -r 2>/dev/null || 'unknown')}"
    ext="img"
    case "${COMPRESSOR}" in
      zstd) ext="${ext}.zst" ;;
      xz)   ext="${ext}.xz" ;;
      gzip) ext="${ext}.gz" ;;
    esac
    OUTNAME="${base}-${kv}.${ext}"
  fi

  # create working tree
  create_base_tree "${WORKDIR}"

  # include busybox if available
  install_busybox "${WORKDIR}"

  # copy modules (if requested)
  install_modules "${WORKDIR}"

  # write init
  write_init_script "${WORKDIR}"

  # run optional hooks: if package has hooks in /usr/src/adm/initramfs-hooks, run them
  local global_hooks_dir="/usr/src/adm/initramfs-hooks"
  if [ -d "${global_hooks_dir}" ]; then
    for h in "${global_hooks_dir}"/*; do
      [ -x "${h}" ] || continue
      log "Executando hook global: ${h}"
      if [ "${DRYRUN}" -eq 1 ]; then
        log "[dry-run] ${h} ${WORKDIR}"
      else
        "${h}" "${WORKDIR}" || warn "Hook retornou falha: ${h}"
      fi
    done
  fi

  # assemble
  mkdir -p "${ADM_TMP:-/tmp}/adm-mkinitramfs-out" || true
  OUTPATH="${ADM_TMP:-/tmp}/adm-mkinitramfs-out/${OUTNAME}"
  assemble_initramfs "${WORKDIR}" "${OUTPATH}"

  # copy to destination if requested (risky)
  if [ -n "${DEST}" ]; then
    # if /boot, ensure file name unique (ask confirmation)
    target="${DEST%/}/${OUTNAME}"
    if [ "${DRYRUN}" -eq 1 ]; then
      log "[dry-run] copiar '${OUTPATH}' para '${target}'"
    else
      if [ -e "${target}" ] && [ "${YES}" -ne 1 ]; then
        warn "Arquivo alvo já existe: ${target}"
        if ! confirm "Sobrescrever ${target}?"; then
          err "Aborting to avoid overwrite"
        fi
      fi
      # Operation of writing to /boot is risky: comment and require privileges
      # Risco: sobrescrever initramfs atual pode impedir boot. Garantir que tenha backup.
      log "Copiando initramfs para ${target} (operação de risco - ver comentários no script)"
      run "cp -a -- '${OUTPATH}' '${target}'"
      run "chmod 0644 '${target}' || true"
      log "Arquivo instalado em ${target}"
    fi
  elif [ -n "${STAGE_DIR}" ]; then
    # Copy into stage (e.g., stage boot dir)
    stage_target="${STAGE_DIR%/}/${OUTNAME}"
    if [ "${DRYRUN}" -eq 1 ]; then
      log "[dry-run] copiar '${OUTPATH}' para '${stage_target}'"
    else
      log "Copiando initramfs para stage ${stage_target}"
      run "mkdir -p '$(dirname "${stage_target}")'"
      run "cp -a -- '${OUTPATH}' '${stage_target}'"
      log "Arquivo copiado para stage: ${stage_target}"
    fi
  else
    log "Nenhum destino especificado. Resultado em: ${OUTPATH}"
  fi

  info "adm-mkinitramfs finalizado com sucesso (modo dry-run=${DRYRUN})"
}

main "$@"
