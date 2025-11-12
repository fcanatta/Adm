#!/usr/bin/env bash
# 07.20-rollback-snapshots.sh
# Snapshots e rollback com detecção de backend (btrfs, zfs, lvm, linkdest, tar).

###############################################################################
# Modo estrito + traps
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__snp_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] rollback-snapshots falhou: code=${code} line=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __snp_err_trap ERR

###############################################################################
# Caminhos, logging, utils
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_LOG_DIR="${ADM_LOG_DIR:-${ADM_STATE_DIR}/logs}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"

SNP_DB_DIR="${SNP_DB_DIR:-${ADM_STATE_DIR}/snapshots}"   # onde ficam metadados
SNP_STG_DIR="${SNP_STG_DIR:-${ADM_STATE_DIR}/snapshot-staging}" # mounts temporários
SNP_EXP_DIR="${SNP_EXP_DIR:-${ADM_STATE_DIR}/snapshot-exports}"  # tarballs

adm_is_cmd(){ command -v "$1" >/dev/null 2>&1; }
__ensure_dir(){
  local d="$1" mode="${2:-0755}"
  [[ -d "$d" ]] || install -d -m "$mode" "$d"
}
__ensure_dir "$ADM_STATE_DIR"; __ensure_dir "$ADM_LOG_DIR"; __ensure_dir "$ADM_TMPDIR"
__ensure_dir "$SNP_DB_DIR"; __ensure_dir "$SNP_STG_DIR"; __ensure_dir "$SNP_EXP_DIR"

# Cores simples
if [[ -t 1 ]] && adm_is_cmd tput && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RST="$(tput sgr0)"; C_OK="$(tput setaf 2)"; C_WRN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INF="$(tput setaf 6)"; C_BD="$(tput bold)"
else
  C_RST=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""; C_BD=""
fi
snp_info(){  echo -e "${C_INF}[ADM]${C_RST} $*"; }
snp_ok(){    echo -e "${C_OK}[OK ]${C_RST} $*"; }
snp_warn(){  echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
snp_err(){   echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }
tmpfile(){ mktemp "${ADM_TMPDIR}/snp.XXXXXX"; }
now_utc(){ date -u +%Y%m%d-%H%M%S; }

# Locks por root-id
__lock(){
  local id="$1"; __ensure_dir "${ADM_STATE_DIR}/locks"
  exec {__SNP_FD}>"${ADM_STATE_DIR}/locks/snap-${id}.lock"
  flock -n ${__SNP_FD} || { snp_warn "aguardando lock de ${id}…"; flock ${__SNP_FD}; }
}
__unlock(){ :; }  # fd fecha ao sair

###############################################################################
# Hooks (pre/post por operação)
###############################################################################
__hooks_dirs(){
  printf '%s\n' "${ADM_ROOT}/hooks" "${ADM_ROOT}/hooks/snapshots"
}
snp_hooks_run(){
  local stage="${1:?}"; shift || true
  local d f ran=0
  for d in $(__hooks_dirs); do
    [[ -d "$d" ]] || continue
    for f in "$d/$stage" "$d/$stage.sh"; do
      if [[ -x "$f" ]]; then
        snp_info "Hook: $(realpath -m "$f")"
        ( set -Eeuo pipefail; "$f" "$@" )
        ran=1
      fi
    done
  done
  (( ran )) || snp_info "Hook '${stage}': nenhum"
}

###############################################################################
# CLI
###############################################################################
CMD=""                 # create|list|show|diff|mount|umount|rollback|delete|prune|protect|unprotect|export|import|verify
ROOT="/"               # alvo lógico (raiz do sistema/chroot)
LABEL=""               # rótulo amigável do snapshot
BACKEND="auto"         # auto|btrfs|zfs|lvm|linkdest|tar
INCLUDE_PATHS=""       # CSV; se vazio, snap do ROOT inteiro (dependendo do backend)
READONLY=1
DRYRUN=0
KEEP_LAST=0
MAX_AGE_DAYS=0
PROTECT_FLAG=0
FORCE=0                # destrutivo (rollback/linkdest)
MOUNT_NAME=""          # mount alias (para mount/umount)
SNAP_KEY=""            # id exato para operar (timestamp-label)
EXPORT_FMT="zst"       # zst|xz
VERIFY_DEPTH=0         # 0=rápido; 1=hash superficial; 2=hash de conteúdo
DIFF_AGAINST=""        # snapshot A..B; se vazio, usa anterior

snp_usage(){
  cat <<'EOF'
Uso:
  07.20-rollback-snapshots.sh <comando> [opções]

Comandos:
  create        Cria snapshot do ROOT
  list          Lista snapshots do ROOT
  show          Mostra metadados do snapshot
  diff          Lista diferenças entre snapshots (A..B)
  mount         Monta snapshot em staging
  umount        Desmonta snapshot de staging
  rollback      Restaura estado do snapshot (destrutivo!)
  delete        Remove snapshot
  prune         Política de retenção (KEEP N, AGE D)
  protect       Marca snapshot como protegido (não deletar/mergear)
  unprotect     Remove proteção
  export        Exporta snapshot (send/receive ou tarball)
  import        Importa snapshot exportado
  verify        Verifica integridade do snapshot

Opções comuns:
  --root PATH             Raiz (default: /)
  --backend auto|btrfs|zfs|lvm|linkdest|tar
  --label STR             Rótulo do snapshot
  --key ID                Chave do snapshot (YYYYmmdd-HHMMSS-label)
  --include "p1,p2"       Subpaths a incluir (linkdest/tar)
  --rw / --ro             Snapshot RW/RO (se suportado)
  --force                 Força operações destrutivas
  --dry-run               Não altera nada, só simula
  --keep-last N           (prune) manter últimos N
  --max-age-days D        (prune) excluir > D dias (se não protegido)
  --mount-name NAME       apelido para mount staging
  --export-fmt zst|xz     formato de export (tar.*) quando backend=tar
  --verify-depth 0..2     nível de verificação (0 simples, 2 forte)
  --diff A..B             par para diff (senão, usa anterior)
  --help
EOF
}

parse_cli(){
  [[ $# -ge 1 ]] || { snp_usage; exit 2; }
  CMD="$1"; shift
  while (($#)); do
    case "$1" in
      --root) ROOT="${2:-/}"; shift 2 ;;
      --backend) BACKEND="${2:-auto}"; shift 2 ;;
      --label) LABEL="${2:-}"; shift 2 ;;
      --key) SNAP_KEY="${2:-}"; shift 2 ;;
      --include) INCLUDE_PATHS="${2:-}"; shift 2 ;;
      --rw) READONLY=0; shift ;;
      --ro) READONLY=1; shift ;;
      --force) FORCE=1; shift ;;
      --dry-run) DRYRUN=1; shift ;;
      --keep-last) KEEP_LAST="${2:-0}"; shift 2 ;;
      --max-age-days) MAX_AGE_DAYS="${2:-0}"; shift 2 ;;
      --mount-name) MOUNT_NAME="${2:-}"; shift 2 ;;
      --export-fmt) EXPORT_FMT="${2:-zst}"; shift 2 ;;
      --verify-depth) VERIFY_DEPTH="${2:-0}"; shift 2 ;;
      --diff) DIFF_AGAINST="${2:-}"; shift 2 ;;
      --help|-h) snp_usage; exit 0 ;;
      *) snp_err "opção inválida: $1"; snp_usage; exit 2 ;;
    esac
  done
  [[ -d "$ROOT" ]] || { snp_err "--root inválido"; exit 2; }
}

###############################################################################
# Backend detection & IDs
###############################################################################
root_fs_type(){
  # tenta via findmnt/lsblk/stat
  if adm_is_cmd findmnt; then
    findmnt -no FSTYPE --target "$ROOT" 2>/dev/null || echo ""
  else
    stat -f -c %T "$ROOT" 2>/dev/null || echo ""
  fi
}
root_block_dev(){
  adm_is_cmd findmnt && findmnt -no SOURCE --target "$ROOT" 2>/dev/null || echo ""
}
root_id(){
  # ID legível do root (para namespace de snapshots no DB)
  local dev; dev="$(root_block_dev)"
  local fs; fs="$(root_fs_type)"
  printf '%s@%s' "${dev:-unknown}" "${fs:-fs}"
}

snap_dir_for(){
  local id="$1"
  printf '%s/%s' "$SNP_DB_DIR" "$(echo "$id" | tr '/ ' '__')"
}
snap_key(){
  local lbl="$1"
  local ts; ts="$(now_utc)"
  [[ -n "$lbl" ]] && printf '%s-%s' "$ts" "$lbl" || printf '%s' "$ts"
}
meta_path(){
  local rootid="$1" key="$2"
  printf '%s/%s/meta.json' "$(snap_dir_for "$rootid")" "$key"
}
mkdir_snap(){
  local rootid="$1" key="$2"
  install -d -m 0755 "$(snap_dir_for "$rootid")/$key"
}

###############################################################################
# Helpers JSON
###############################################################################
json_write(){
  local file="$1"; shift
  local tmp; tmp="$(tmpfile)"
  {
    echo "{"
    local first=1 k v
    for kv in "$@"; do
      k="${kv%%=*}"; v="${kv#*=}"
      ((first)) || echo ","
      printf '  "%s": %s' "$k" "$v"
      first=0
    done
    echo ""
    echo "}"
  } > "$tmp"
  mv -f "$tmp" "$file"
}
json_q(){ printf '%q' "$1"; } # aspas tipo bash

###############################################################################
# BACKENDS: funções de baixo nível (create/mount/rollback/delete/export/import)
###############################################################################
# Cada backend deve implementar:
#   be_<name>_detect
#   be_<name>_create <root> <target_path> <ro:0/1>
#   be_<name>_mount  <root> <target_path> <mount_point>
#   be_<name>_umount <mount_point>
#   be_<name>_rollback <root> <target_path> <force:0/1>
#   be_<name>_delete <root> <target_path>
#   be_<name>_export <root> <target_path> <destination_file>
#   be_<name>_import <root> <incoming_file> <target_path>

# -------- BTRFS --------
be_btrfs_detect(){ [[ "$(root_fs_type)" == "btrfs" ]] && adm_is_cmd btrfs; }
be_btrfs_create(){
  local root="$1" tgt="$2" ro="$3"
  local parent; parent="$(dirname "$tgt")"; __ensure_dir "$parent"
  local src_subv; src_subv="$(btrfs subvolume show -q "$root" >/dev/null 2>&1 && echo "$root" || echo "$root")"
  if (( DRYRUN )); then
    snp_info "(dry-run) btrfs subvolume snapshot ${ro:+-r} '$root' '$tgt'"
  else
    btrfs subvolume snapshot $([[ "$ro" -eq 1 ]] && echo -r) "$src_subv" "$tgt"
  fi
}
be_btrfs_mount(){
  local root="$1" tgt="$2" mnt="$3"
  __ensure_dir "$mnt"
  mount -o subvol="${tgt#$root}" "$(root_block_dev)" "$mnt"
}
be_btrfs_umount(){ umount -R "$1" 2>/dev/null || umount "$1"; }
be_btrfs_rollback(){
  local root="$1" tgt="$2" force="$3"
  (( force )) || { snp_err "btrfs rollback requer --force (destrutivo)"; return 2; }
  # Estratégia: renomear current → old, snapshot → current (subvol default)
  local dev; dev="$(root_block_dev)"
  local mnt; mnt="$(mktemp -d "${SNP_STG_DIR}/btrfs.XXXX")"
  mount "$dev" "$mnt"
  local subcur subsnap
  subcur="$(btrfs subvolume get-default "$mnt" | awk '{print $NF}')"
  subsnap="${tgt#$mnt}"
  [[ -z "$subsnap" ]] && subsnap="$tgt"
  btrfs subvolume set-default "$tgt" "$mnt"
  umount "$mnt"
  snp_ok "btrfs: default subvolume apontado para snapshot (reboot recomendado)"
}
be_btrfs_delete(){ btrfs subvolume delete -c "$2"; }
be_btrfs_export(){
  local root="$1" tgt="$2" out="$3"
  # btrfs send/receive tarball não é trivial; exporta como send stream
  if (( DRYRUN )); then snp_info "(dry-run) btrfs send '$tgt' > '$out'"; else btrfs send "$tgt" | zstd -q -19 -o "$out"; fi
}
be_btrfs_import(){
  local root="$1" in="$2" tgt="$3"
  local parent; parent="$(dirname "$tgt")"; __ensure_dir "$parent"
  zstd -q -d -c "$in" | btrfs receive "$parent"
}

# -------- ZFS --------
be_zfs_detect(){ adm_is_cmd zfs && zfs list -H -o name "$(root_block_dev 2>/dev/null)" >/dev/null 2>&1; }
be_zfs_create(){
  local root="$1" tgt="$2" ro="$3"
  local ds; ds="$(zfs list -H -o name -t filesystem -r 2>/dev/null | head -n1)"
  local snap="${ds}@$(basename "$tgt")"
  (( DRYRUN )) || zfs snapshot "$snap"
}
be_zfs_mount(){ :; } # snapshots ZFS são acessíveis via .zfs/snapshot
be_zfs_umount(){ :; }
be_zfs_rollback(){
  local root="$1" tgt="$2" force="$3"
  (( force )) || { snp_err "zfs rollback requer --force"; return 2; }
  local ds; ds="$(zfs list -H -o name -t filesystem -r 2>/dev/null | head -n1)"
  local snap="${ds}@$(basename "$tgt")"
  zfs rollback -r "$snap"
}
be_zfs_delete(){
  local ds; ds="$(zfs list -H -o name -t filesystem -r 2>/dev/null | head -n1)"
  zfs destroy -r "${ds}@$(basename "$2")"
}
be_zfs_export(){
  local ds; ds="$(zfs list -H -o name -t filesystem -r 2>/dev/null | head -n1)"
  local snap="${ds}@$(basename "$2")"
  zfs send "$snap" | zstd -q -19 -o "$3"
}
be_zfs_import(){
  local ds; ds="$(zfs list -H -o name -t filesystem -r 2>/dev/null | head -n1)"
  zstd -q -d -c "$2" | zfs receive -u "$ds"
}

# -------- LVM (snapshot de LV) --------
be_lvm_detect(){ adm_is_cmd lvs && root_block_dev | grep -q '^/dev/'; }
be_lvm_create(){
  local root="$1" tgt="$2" ro="$3"
  local lv; lv="$(root_block_dev)"
  local size; size="$(lvs --noheadings -o LV_SIZE "$lv" | awk '{print $1}')"
  local sname; sname="$(basename "$tgt")"
  (( DRYRUN )) || lvcreate -s -n "$sname" -L "$size" "$lv"
}
be_lvm_mount(){
  local root="$1" tgt="$2" mnt="$3"
  __ensure_dir "$mnt"; mount "$tgt" "$mnt"
}
be_lvm_umount(){ umount "$1"; }
be_lvm_rollback(){
  local root="$1" tgt="$2" force="$3"
  (( force )) || { snp_err "lvm rollback requer --force"; return 2; }
  lvconvert --merge "$tgt"
  snp_ok "LVM: merge solicitado; efetivado no próximo activate/mount"
}
be_lvm_delete(){ lvremove -f "$2"; }
be_lvm_export(){ snp_warn "LVM export via raw dd não implementado"; false; }
be_lvm_import(){ snp_warn "LVM import não implementado"; false; }

# -------- LINKDEST (rsync hardlinks) --------
be_linkdest_detect(){ [[ "$(root_fs_type)" != "btrfs" && "$(root_fs_type)" != "zfs" ]]; }
be_linkdest_create(){
  local root="$1" tgt="$2" ro="$3"
  local prev; prev="$(dirname "$tgt")/current"
  __ensure_dir "$tgt"
  local inc; IFS=',' read -r -a inc <<< "${INCLUDE_PATHS:-}"
  if (( DRYRUN )); then
    snp_info "(dry-run) rsync --archive --hard-links --numeric-ids --delete --link-dest='$prev' '$root' '$tgt'"
  else
    if ((${#inc[@]}>0)); then
      local p; for p in "${inc[@]}"; do
        rsync -aHAX --numeric-ids --delete --link-dest="$prev" "$root/$p"/ "$tgt/$p"/
      done
    else
      rsync -aHAX --numeric-ids --delete --link-dest="$prev" "$root"/ "$tgt"/
    fi
    rm -f "$(dirname "$tgt")/current"
    ln -snf "$tgt" "$(dirname "$tgt")/current"
  fi
}
be_linkdest_mount(){ :; }  # já é uma árvore de arquivos
be_linkdest_umount(){ :; }
be_linkdest_rollback(){
  local root="$1" tgt="$2" force="$3"
  (( force )) || { snp_err "rollback linkdest requer --force (rsync destrutivo)"; return 2; }
  rsync -aHAX --numeric-ids --delete "$tgt"/ "$root"/
}
be_linkdest_delete(){ rm -rf "$2"; }
be_linkdest_export(){
  local out="$3"
  ( cd "$(dirname "$2")" && tar -cpf - "$(basename "$2")" ) | zstd -q -19 -o "$out"
}
be_linkdest_import(){
  local root="$1" in="$2" tgt="$3"
  __ensure_dir "$(dirname "$tgt")"
  zstd -q -d -c "$in" | tar -xpf - -C "$(dirname "$tgt")"
}

# -------- TAR (sempre disponível, backup/export) --------
be_tar_detect(){ true; }
be_tar_create(){
  local root="$1" tgt="$2" ro="$3"
  local out="${tgt}.tar.${EXPORT_FMT}"
  ( cd "$root" && tar --numeric-owner --owner=0 --group=0 -cpf - . ) \
    | { [[ "$EXPORT_FMT" == "xz" ]] && xz -T0 -9e -c || zstd -q -19 -T0 -c; } > "$out"
}
be_tar_mount(){ snp_warn "tar não é montável diretamente"; false; }
be_tar_umount(){ :; }
be_tar_rollback(){
  local root="$1" tgt="$2" force="$3"
  (( force )) || { snp_err "rollback tar requer --force (extrai sobre ROOT)"; return 2; }
  local tarf="${tgt}.tar.${EXPORT_FMT}"
  [[ -r "$tarf" ]] || { snp_err "arquivo não encontrado: $tarf"; return 3; }
  { [[ "$tarf" == *.zst ]] && zstd -q -d -c "$tarf" || xz -d -c "$tarf"; } | tar -xpf - -C "$root"
}
be_tar_delete(){ rm -f "${2}.tar.zst" "${2}.tar.xz" 2>/dev/null || true; }
be_tar_export(){ cp -f "${2}.tar.${EXPORT_FMT}" "$3"; }
be_tar_import(){
  local root="$1" in="$2" tgt="$3"
  cp -f "$in" "${tgt}.tar.${EXPORT_FMT}"
}

# Escolha do backend efetivo
pick_backend(){
  local be="$BACKEND"
  if [[ "$BACKEND" == "auto" ]]; then
    if be_btrfs_detect; then be="btrfs"
    elif be_zfs_detect; then be="zfs"
    elif be_lvm_detect; then be="lvm"
    else be="linkdest"
    fi
  fi
  echo "$be"
}
###############################################################################
# Metadados, criação e listagem
###############################################################################
write_meta(){
  local rootid="$1" key="$2" backend="$3" ro="$4"
  local meta; meta="$(meta_path "$rootid" "$key")"
  json_write "$meta" \
    "root"=$(json_q "$ROOT") \
    "root_id"=$(json_q "$rootid") \
    "key"=$(json_q "$key") \
    "label"=$(json_q "$LABEL") \
    "backend"=$(json_q "$backend") \
    "readonly"=$ro \
    "created_utc"=$(json_q "$(date -u +%FT%TZ)") \
    "protected"=0
}

list_snaps(){
  local rootid="$1" dir; dir="$(snap_dir_for "$rootid")"
  [[ -d "$dir" ]] || { snp_info "sem snapshots"; return 0; }
  find "$dir" -maxdepth 1 -mindepth 1 -type d -printf "%f\n" | sort
}

show_meta(){
  local rootid="$1" key="$2"
  local meta; meta="$(meta_path "$rootid" "$key")"
  [[ -r "$meta" ]] || { snp_err "meta ausente: $meta"; return 2; }
  cat "$meta"
}

###############################################################################
# Operações de alto nível
###############################################################################
op_create(){
  local rootid; rootid="$(root_id)"
  __lock "$rootid"
  local be; be="$(pick_backend)"
  local key; key="${SNAP_KEY:-$(snap_key "$LABEL")}"
  local sdir; sdir="$(snap_dir_for "$rootid")/$key"
  mkdir_snap "$rootid" "$key"

  snp_hooks_run "pre-create" "ROOT=$ROOT" "BACKEND=$be" "KEY=$key"
  case "$be" in
    btrfs)   be_btrfs_create   "$ROOT" "$sdir/subvol" "$READONLY" ;;
    zfs)     be_zfs_create     "$ROOT" "$sdir/zsnap"  "$READONLY" ;;
    lvm)     be_lvm_create     "$ROOT" "$sdir/lvsnap" "$READONLY" ;;
    linkdest)be_linkdest_create"$ROOT" "$sdir/tree"   "$READONLY" ;;
    tar)     be_tar_create     "$ROOT" "$sdir/archive" "$READONLY" ;;
    *) snp_err "backend desconhecido: $be"; exit 2 ;;
  esac
  write_meta "$rootid" "$key" "$be" "$READONLY"
  snp_hooks_run "post-create" "KEY=$key"
  __unlock
  snp_ok "Snapshot criado: $key  (backend=$be)"
}

op_list(){
  list_snaps "$(root_id)"
}

op_show(){
  local key="${SNAP_KEY:?--key é obrigatório}"
  show_meta "$(root_id)" "$key"
}

op_mount(){
  local rootid; rootid="$(root_id)"
  local be; be="$(pick_backend)"
  local key="${SNAP_KEY:?--key é obrigatório}"
  local sdir; sdir="$(snap_dir_for "$rootid")/$key"
  local mnt="${SNP_STG_DIR}/${MOUNT_NAME:-$key}"
  snp_hooks_run "pre-mount" "KEY=$key" "MNT=$mnt"
  case "$be" in
    btrfs) be_btrfs_mount "$ROOT" "$sdir/subvol" "$mnt" ;;
    zfs)   snp_info "ZFS: acesse via .zfs/snapshot/<key> (montagem direta omitida)"; __ensure_dir "$mnt" ;;
    lvm)   be_lvm_mount "$ROOT" "$sdir/lvsnap" "$mnt" ;;
    linkdest) __ensure_dir "$mnt"; mount --bind "$sdir/tree" "$mnt" ;;
    tar)   snp_err "tar não é montável"; return 2 ;;
  esac
  snp_hooks_run "post-mount" "KEY=$key" "MNT=$mnt"
  snp_ok "Montado em: $mnt"
}

op_umount(){
  local mnt="${SNP_STG_DIR}/${MOUNT_NAME:?--mount-name requerido}"
  snp_hooks_run "pre-umount" "MNT=$mnt"
  if mountpoint -q "$mnt"; then umount -R "$mnt" 2>/dev/null || umount "$mnt"; fi
  rmdir "$mnt" 2>/dev/null || true
  snp_hooks_run "post-umount" "MNT=$mnt"
  snp_ok "Desmontado: $mnt"
}

op_rollback(){
  local rootid; rootid="$(root_id)"
  local be; be="$(pick_backend)"
  local key="${SNAP_KEY:?--key é obrigatório}"
  local sdir; sdir="$(snap_dir_for "$rootid")/$key"
  snp_hooks_run "pre-rollback" "KEY=$key" "FORCE=$FORCE"
  case "$be" in
    btrfs)   be_btrfs_rollback   "$ROOT" "$sdir/subvol" "$FORCE" ;;
    zfs)     be_zfs_rollback     "$ROOT" "$sdir/zsnap"  "$FORCE" ;;
    lvm)     be_lvm_rollback     "$ROOT" "$sdir/lvsnap" "$FORCE" ;;
    linkdest)be_linkdest_rollback"$ROOT" "$sdir/tree"   "$FORCE" ;;
    tar)     be_tar_rollback     "$ROOT" "$sdir/archive" "$FORCE" ;;
  esac
  snp_hooks_run "post-rollback" "KEY=$key"
  snp_ok "Rollback solicitado (backend=$be)."
}

op_delete(){
  local rootid; rootid="$(root_id)"
  local be; be="$(pick_backend)"
  local key="${SNAP_KEY:?--key é obrigatório}"
  local meta; meta="$(meta_path "$rootid" "$key")"
  [[ -r "$meta" ]] || { snp_err "meta ausente"; return 2; }
  grep -q '"protected": 1' "$meta" 2>/dev/null && { snp_err "snapshot protegido"; return 3; }
  local sdir; sdir="$(snap_dir_for "$rootid")/$key"
  snp_hooks_run "pre-delete" "KEY=$key"
  case "$be" in
    btrfs) be_btrfs_delete "$ROOT" "$sdir/subvol" ;;
    zfs)   be_zfs_delete   "$ROOT" "$sdir/zsnap"  ;;
    lvm)   be_lvm_delete   "$ROOT" "$sdir/lvsnap" ;;
    linkdest) be_linkdest_delete "$ROOT" "$sdir/tree" ;;
    tar)   be_tar_delete "$ROOT" "$sdir/archive" ;;
  esac
  rm -rf "$sdir"
  snp_hooks_run "post-delete" "KEY=$key"
  snp_ok "Snapshot removido: $key"
}

op_prune(){
  local rootid; rootid="$(root_id)"
  local dir; dir="$(snap_dir_for "$rootid")"
  [[ -d "$dir" ]] || { snp_info "sem snapshots"; return 0; }
  local keys; keys="$(list_snaps "$rootid" | sort -r)"
  # KEEP_LAST
  if (( KEEP_LAST > 0 )); then
    local i=0 k
    while read -r k; do
      (( i < KEEP_LAST )) || { SNAP_KEY="$k" op_delete || true; }
      ((i++))
    done <<< "$keys"
  fi
  # MAX_AGE_DAYS
  if (( MAX_AGE_DAYS > 0 )); then
    local cutoff; cutoff="$(date -u -d "-${MAX_AGE_DAYS} days" +%Y%m%d%H%M%S)"
    while read -r k; do
      local ts="${k%%-*}"; ts="${ts//-/}" # YYYYmmddHHMMSS
      local meta; meta="$(meta_path "$rootid" "$k")"
      grep -q '"protected": 1' "$meta" 2>/dev/null && continue
      [[ "$ts" -lt "$cutoff" ]] && { SNAP_KEY="$k" op_delete || true; }
    done <<< "$(list_snaps "$rootid")"
  fi
}

op_protect_toggle(){
  local rootid; rootid="$(root_id)"
  local key="${SNAP_KEY:?--key é obrigatório}"
  local meta; meta="$(meta_path "$rootid" "$key")"
  [[ -r "$meta" ]] || { snp_err "meta ausente"; return 2; }
  local tmp; tmp="$(tmpfile)"
  if [[ "$1" == "1" ]]; then
    sed 's/"protected":[[:space:]]*0/"protected": 1/' "$meta" > "$tmp" || true
  else
    sed 's/"protected":[[:space:]]*1/"protected": 0/' "$meta" > "$tmp" || true
  fi
  mv -f "$tmp" "$meta"
  snp_ok "Proteção=$( [[ "$1" == "1" ]] && echo ON || echo OFF ): $key"
}

op_export(){
  local rootid; rootid="$(root_id)"
  local be; be="$(pick_backend)"
  local key="${SNAP_KEY:?--key é obrigatório}"
  local sdir; sdir="$(snap_dir_for "$rootid")/$key"
  local out="${SNP_EXP_DIR}/${key}.${be}.snap"
  snp_hooks_run "pre-export" "KEY=$key" "OUT=$out"
  case "$be" in
    btrfs)   be_btrfs_export "$ROOT" "$sdir/subvol" "$out" ;;
    zfs)     be_zfs_export   "$ROOT" "$sdir/zsnap"  "$out" ;;
    lvm)     snp_err "export LVM não implementado"; return 2 ;;
    linkdest)be_linkdest_export "$ROOT" "$sdir/tree" "$out" ;;
    tar)     be_tar_export "$ROOT" "$sdir/archive" "$out" ;;
  esac
  snp_hooks_run "post-export" "KEY=$key" "OUT=$out"
  snp_ok "Exportado: $out"
}

op_import(){
  local rootid; rootid="$(root_id)"
  local be; be="$(pick_backend)"
  local in="${SNAP_KEY:?--key deve apontar para arquivo de import}"
  local key; key="$(snap_key "$LABEL")"
  local sdir; sdir="$(snap_dir_for "$rootid")/$key"
  mkdir_snap "$rootid" "$key"
  snp_hooks_run "pre-import" "IN=$in" "KEY=$key"
  case "$be" in
    btrfs)   be_btrfs_import "$ROOT" "$in" "$sdir/subvol" ;;
    zfs)     be_zfs_import   "$ROOT" "$in" "$sdir/zsnap" ;;
    linkdest)be_linkdest_import "$ROOT" "$in" "$sdir/tree" ;;
    tar)     be_tar_import "$ROOT" "$in" "$sdir/archive" ;;
    lvm)     snp_err "import LVM não implementado"; return 2 ;;
  esac
  write_meta "$rootid" "$key" "$be" 1
  snp_hooks_run "post-import" "KEY=$key"
  snp_ok "Importado: $key"
}

op_verify(){
  local rootid; rootid="$(root_id)"
  local key="${SNAP_KEY:?--key é obrigatório}"
  local sdir; sdir="$(snap_dir_for "$rootid")/$key"
  local be; be="$(pick_backend)"
  local rc=0
  case "$be" in
    linkdest)
      if (( VERIFY_DEPTH >= 1 )); then
        # checagem superficial: contagem de arquivos
        find "$sdir/tree" -type f | wc -l | xargs echo "files:"
      fi
      if (( VERIFY_DEPTH >= 2 )); then
        # hash de conteúdo (pode ser caro)
        (cd "$sdir/tree" && find . -type f -print0 | xargs -0 sha256sum >/dev/null) || rc=1
      fi
      ;;
    btrfs|zfs|lvm) snp_info "verify: rely on backend health (scrub recomendado)";;
    tar)
      local f="${sdir}/archive.tar.${EXPORT_FMT}"
      [[ -r "$f" ]] || { snp_err "arquivo ausente: $f"; return 2; }
      { [[ "$f" == *.zst ]] && zstd -tq "$f" || xz -t "$f"; } || rc=1
      ;;
  esac
  (( rc==0 )) && snp_ok "verify OK: $key" || snp_err "verify FAIL: $key"
  return "$rc"
}

op_diff(){
  local rootid; rootid="$(root_id)"
  local be; be="$(pick_backend)"
  local range="${DIFF_AGAINST:-}"
  local a b
  if [[ -z "$range" ]]; then
    # pega anterior a SNAP_KEY
    local keys; keys=($(list_snaps "$rootid" | sort))
    local i idx=-1
    for ((i=0;i<${#keys[@]};i++)); do [[ "${keys[$i]}" == "$SNAP_KEY" ]] && idx=$i; done
    (( idx <= 0 )) && { snp_warn "não há snapshot anterior"; return 0; }
    a="${keys[$((idx-1))]}"; b="$SNAP_KEY"
  else
    a="${range%%..*}"; b="${range##*..}"
  fi
  snp_info "diff: $a .. $b"
  case "$be" in
    linkdest)
      local da db
      da="$(snap_dir_for "$rootid")/$a/tree"
      db="$(snap_dir_for "$rootid")/$b/tree"
      diff -urN --no-dereference "$da" "$db" || true
      ;;
    btrfs) snp_info "use 'btrfs send -p …' para delta; diff de FS em produção é caro" ;;
    zfs)   snp_info "use 'zfs diff dataset@A dataset@B' se disponível" ;;
    lvm|tar) snp_warn "diff não suportado diretamente neste backend" ;;
  esac
}

###############################################################################
# MAIN
###############################################################################
snp_run(){
  parse_cli "$@"
  local rootid; rootid="$(root_id)"
  case "$CMD" in
    create)   op_create ;;
    list)     op_list ;;
    show)     op_show ;;
    mount)    op_mount ;;
    umount)   op_umount ;;
    rollback) op_rollback ;;
    delete)   op_delete ;;
    prune)    op_prune ;;
    protect)  op_protect_toggle 1 ;;
    unprotect)op_protect_toggle 0 ;;
    export)   op_export ;;
    import)   op_import ;;
    verify)   op_verify ;;
    diff)     op_diff ;;
    *) snp_err "comando inválido: $CMD"; exit 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  snp_run "$@"
fi
