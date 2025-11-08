#!/usr/bin/env bash
# 12-adm-bootstrap.part1.sh
# Bootstrap e toolchain por stages (0→3), criando rootfs isolados usando os módulos ADM.
###############################################################################
# Guardas e pré-requisitos
###############################################################################
if [[ -n "${ADM_BOOTSTRAP_LOADED_PART1:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_BOOTSTRAP_LOADED_PART1=1

for _m in ADM_CONF_LOADED ADM_LIB_LOADED; do
  if [[ -z "${!_m:-}" ]]; then
    echo "ERRO: 12-adm-bootstrap requer módulos básicos carregados (00/01). Faltando: ${_m}" >&2
    return 2 2>/dev/null || exit 2
  fi
done

: "${ADM_STAGES_ROOT:=/usr/src/adm/stages}"
: "${ADM_STATE_ROOT:=/usr/src/adm/state}"
: "${ADM_TMP_ROOT:=/usr/src/adm/tmp}"
: "${ADM_MIN_DISK_MB:=2048}"
: "${ADM_PROFILE_DEFAULT:=minimal}"
: "${ADM_LIBC_DEFAULT:=musl}"

# Logs & mensagens
bs_err()  { adm_err "$*"; }
bs_warn() { adm_warn "$*"; }
bs_info() { adm_log INFO "${BS_CTX_STAGE:-stage}" "bootstrap" "$*"; }

###############################################################################
# Contexto global por execução
###############################################################################
declare -Ag BS=(
  [arch]="" [triplet]="" [libc]="${ADM_LIBC_DEFAULT}" [profile]="${ADM_PROFILE_DEFAULT}"
  [rootfs_dir]="" [driver]="auto" [qemu]="" [no_chroot]="false" [offline]="${ADM_OFFLINE:-false}"
  [bin_dir]="" [source_only]="false" [no_test]="false" [no_strip]="false" [jobs]=""
  [verbose]="false" [strict]="false" [resume]="false" [force_rebuild]="false" [keep_going]="false"
)
declare -Ag BS_PATHS=()
declare -Ag BS_LOCKS=()

###############################################################################
# Utilidades gerais
###############################################################################
_bs_require_cmd() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || { bs_err "comando obrigatório ausente: $c"; return 2; }; done; }

_bs_space_check() {
  local need="${1:-$ADM_MIN_DISK_MB}" dir="${2:-$ADM_STAGES_ROOT}"
  local avail
  avail="$(df -Pm "$dir" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
  (( avail >= need )) || { bs_err "espaço insuficiente (precisa ${need}MB, disponível ${avail}MB) em $dir"; return 3; }
}

_bs_lock_path()  { echo "${ADM_STATE_ROOT%/}/locks/bootstrap-stage$1.lock"; }
_bs_lock_acquire() {
  local stage="$1" p="$(_bs_lock_path "$stage")"
  mkdir -p -- "${p%/*}" || true
  exec {BS_LOCKS[$stage]}> "$p" || { bs_err "não foi possível abrir lock ($p)"; return 3; }
  flock -n "${BS_LOCKS[$stage]}" || { bs_err "stage $stage bloqueado por outra execução"; return 3; }
}
_bs_lock_release() {
  local stage="$1"
  if [[ -n "${BS_LOCKS[$stage]:-}" ]]; then
    flock -u "${BS_LOCKS[$stage]}" 2>/dev/null || true
    exec {BS_LOCKS[$stage]}>&- 2>/dev/null || true
  fi
}

_bs_paths_init() {
  local n="$1"
  local base="${ADM_STAGES_ROOT%/}/stage${n}"
  BS_PATHS[rootfs]="$base/rootfs"
  BS_PATHS[logs]="$base/logs"
  BS_PATHS[plan]="$base/plan"
  BS_PATHS[state]="$base/state"
  BS_PATHS[env]="$base/env"
  BS_PATHS[build]="$base/build"
  BS_PATHS[sbom]="$base/sbom"
  mkdir -p -- "${BS_PATHS[rootfs]}" "${BS_PATHS[logs]}" "${BS_PATHS[plan]}" "${BS_PATHS[state]}" "${BS_PATHS[env]}" "${BS_PATHS[build]}" "${BS_PATHS[sbom]}" || {
    bs_err "falha ao criar diretórios do stage $n em $base"; return 3; }
}

_bs_log_path() { echo "${BS_PATHS[logs]%/}/$1.log"; }

_bs_detect_host() {
  BS[arch]="$(uname -m 2>/dev/null || echo unknown)"
  case "${BS[arch]}" in
    x86_64)           BS[triplet]="x86_64-linux-gnu";;
    aarch64)          BS[triplet]="aarch64-linux-gnu";;
    riscv64)          BS[triplet]="riscv64-linux-gnu";;
    armv7l|armhf)     BS[triplet]="armv7l-linux-gnueabihf";;
    i?86)             BS[triplet]="i686-linux-gnu";;
    *) bs_warn "arquitetura desconhecida: ${BS[arch]} — especifique --target-triplet";;
  esac
}

_bs_check_tools_host() {
  _bs_require_cmd tar zstd rsync awk sed grep find df || return $?
  command -v chroot >/dev/null 2>&1 || bs_warn "chroot não encontrado — será tentado bwrap/proot se necessário"
  return 0
}

_bs_env_stage_defaults() {
  export LANG=C LC_ALL=C TZ=UTC
  export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1704067200}" # 2024-01-01
  umask 022
}

_bs_write_envfile() {
  local n="$1" f="${BS_PATHS[env]%/}/stage${n}.env"
  {
    echo "LANG=C"; echo "LC_ALL=C"; echo "TZ=UTC"
    echo "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
    echo "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}"
    [[ -n "${BS[jobs]}" ]] && echo "MAKEFLAGS=-j${BS[jobs]}"
    [[ "${BS[no_strip]}" == "true" ]] && echo "ADM_NO_STRIP=true"
    echo "ADM_PROFILE=${BS[profile]}"
    echo "ADM_LIBC=${BS[libc]}"
    echo "ADM_TARGET=${BS[triplet]}"
  } > "$f" 2>/dev/null || { bs_err "falha ao escrever env do stage $n"; return 3; }
}

_bs_driver_choose() {
  local n="$1"
  local d="${BS[driver]}"
  if [[ "$d" == "auto" ]]; then
    if command -v chroot >/dev/null 2>&1; then d="chroot"
    elif command -v bwrap >/dev/null 2>&1; then d="bwrap"
    elif command -v proot >/dev/null 2>&1; then d="proot"
    else d="none"; fi
  fi
  [[ "${BS[no_chroot]}" == "true" ]] && d="none"
  BS[driver]="$d"
  if [[ "$n" -ge 1 && "$d" == "none" ]]; then
    bs_err "stage$n requer ambiente isolado; sem driver de chroot/bwrap/proot (--no-chroot não suportado)"; return 5;
  fi
}

_bs_qemu_setup() {
  local root="${BS_PATHS[rootfs]}"
  local q="${BS[qemu]}"
  [[ -z "$q" ]] && return 0
  command -v "$q" >/dev/null 2>&1 || { bs_err "qemu não encontrado: $q"; return 5; }
  mkdir -p -- "${root%/}/usr/bin" || true
  cp -f -- "$(command -v "$q")" "${root%/}/usr/bin/" || { bs_err "falha ao copiar $q para rootfs"; return 3; }
  return 0
}
_bs_qemu_teardown() {
  local root="${BS_PATHS[rootfs]}"
  local q="${BS[qemu]}"
  [[ -z "$q" ]] && return 0
  rm -f -- "${root%/}/usr/bin/${q##*/}" 2>/dev/null || true
}

_bs_mounts=()
_bs_mount_chroot() {
  local root="${BS_PATHS[rootfs]}" mlog="$(_bs_log_path mount)"
  : > "$mlog" 2>/dev/null || true
  case "${BS[driver]}" in
    chroot)
      for p in proc sys dev run; do mkdir -p -- "${root%/}/$p"; done
      mount -t proc proc "${root%/}/proc" >>"$mlog" 2>&1 || { bs_err "mount proc falhou"; return 3; }
      _bs_mounts+=("${root%/}/proc")
      mount -t sysfs sys "${root%/}/sys" >>"$mlog" 2>&1 || { bs_err "mount sys falhou"; return 3; }
      _bs_mounts+=("${root%/}/sys")
      mount --bind /dev "${root%/}/dev" >>"$mlog" 2>&1 || { bs_err "bind /dev falhou"; return 3; }
      _bs_mounts+=("${root%/}/dev")
      mount --bind /run "${root%/}/run" >>"$mlog" 2>&1 || true
      _bs_mounts+=("${root%/}/run")
      ;;
    bwrap|proot|none)
      : # mounts desnecessários; bwrap/proot criam namespaces próprios; none = sem chroot
      ;;
    *) bs_err "driver desconhecido: ${BS[driver]}"; return 2;;
  esac
  return 0
}
_bs_umount_chroot() {
  local mlog="$(_bs_log_path mount)"
  for ((i=${#_bs_mounts[@]}-1; i>=0; i--)); do
    umount -l "${_bs_mounts[$i]}" >>"$mlog" 2>&1 || true
  done
  _bs_mounts=()
}

_bs_chroot_exec() {
  # _bs_chroot_exec <cmd...>
  local root="${BS_PATHS[rootfs]}"
  case "${BS[driver]}" in
    chroot) chroot "$root" /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C TZ=UTC "$@";;
    bwrap)
      bwrap --bind "$root" / --dev-bind /dev /dev --proc /proc --bind /sys /sys --setenv LANG C --setenv LC_ALL C --setenv TZ UTC "$@"
      ;;
    proot)
      proot -R "$root" -b /dev -b /proc -b /sys -w / -0 /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C LC_ALL=C TZ=UTC "$@"
      ;;
    none)
      # execução dentro do host — apenas para stage0 com cuidado
      "$@"
      ;;
    *)
      bs_err "driver desconhecido para chroot exec"; return 2;;
  esac
}

###############################################################################
# Planos e execução de pacotes no rootfs
###############################################################################
_bs_plan_path() { echo "${BS_PATHS[plan]%/}/plan.txt"; }

_bs_generate_plan() {
  local n="$1" prof="$2" plan="$(_bs_plan_path)"
  command -v adm_resolve_plan >/dev/null 2>&1 || { bs_err "resolver (07) não disponível"; return 2; }
  local targets=""
  case "$n" in
    0) targets="sys/linux-headers sys/libc-headers dev/binutils-bootstrap dev/gcc-bootstrap sys/busybox dev/make shell/bash";;
    1) targets="dev/binutils dev/gcc libs/${BS[libc]} shell/bash sys/coreutils sys/sed sys/awk sys/grep sys/findutils sys/diffutils sys/file sys/tar sys/gzip sys/xz sys/zstd sys/patch lang/perl lang/python-min dev/pkg-config dev/cmake dev/ninja dev/meson";;
    2) targets="dev/binutils dev/gcc libs/${BS[libc]} shell/bash sys/coreutils";;
    3) targets="sys/base sys/net-base editors/nano misc/ca-certificates";;
    *) bs_err "stage inválido para plano: $n"; return 1;;
  esac
  local args=(--profile "$prof")
  [[ "${BS[offline]}" == "true" ]] && args+=(--offline)
  local out
  out="$(adm_resolve_plan $targets "${args[@]}")" || { bs_err "falha ao gerar plano stage$n"; return 4; }
  printf "%s\n" "$out" > "$plan" 2>/dev/null || { bs_err "não foi possível escrever planfile: $plan"; return 3; }
  return 0
}

_bs_install_pkg_into_rootfs() {
  # _bs_install_pkg_into_rootfs <cat> <name> <ver|-> <origin>
  local cat="$1" name="$2" ver="$3"
  local root="${BS_PATHS[rootfs]}"
  local args=(--root "$root")
  [[ -n "${BS[bin_dir]}" ]]     && args+=(--bin-dir "${BS[bin_dir]}")
  [[ "${BS[source_only]}" == "true" ]] && args+=(--source-only)
  [[ "${BS[offline]}" == "true" ]]     && args+=(--offline)
  [[ "${BS[no_strip]}" == "true" ]]    && args+=(--no-opts) # reduz risco de hardening agressivo incidental
  [[ -n "${BS[jobs]}" ]]               && export MAKEFLAGS="-j${BS[jobs]}"

  if [[ "$ver" != "-" && -n "$ver" ]]; then args+=(--version "$ver"); fi

  adm_step "$name" "$ver" "instalando no rootfs"
  if ! adm_install_pkg "$cat" "$name" "${args[@]}"; then
    bs_err "instalação falhou: $cat/$name@$ver (veja logs do install em state/logs)"
    return 4
  fi
  return 0
}

_bs_run_plan_in_rootfs() {
  local n="$1" plan="$(_bs_plan_path)" log="$(_bs_log_path install)"
  : > "$log" 2>/dev/null || true
  [[ -r "$plan" ]] || { bs_err "planfile ausente: $plan"; return 3; }
  local step
  while IFS= read -r step; do
    [[ "$step" =~ ^STEP ]] || continue
    local cn ver cat name
    cn="$(awk '{print $3}' <<<"$step")"
    ver="${cn#*@}"; name="${cn%*@}"; name="${name#*/}"; cat="${cn%%/*}"
    # permite adm_install resolver (com deps) internamente; aqui passamos cada alvo na ordem do plano
    if ! _bs_install_pkg_into_rootfs "$cat" "$name" "$ver" >>"$log" 2>&1; then
      if [[ "${BS[keep_going]}" == "true" ]]; then
        bs_warn "falha em $cat/$name@$ver — keep-going habilitado, prosseguindo"
        continue
      fi
      echo "veja: $log"
      return 4
    fi
  done < "$plan"
  return 0
}

###############################################################################
# Snapshot, summary e testes
###############################################################################
_bs_snapshot_rootfs() {
  local n="$1" root="${BS_PATHS[rootfs]}" sfile="${ADM_STAGES_ROOT%/}/stage${n}/rootfs.tar.zst" slog="$(_bs_log_path snapshot)"
  : > "$slog" 2>/dev/null || true
  adm_step "snapshot" "stage$n" "empacotando rootfs"
  (cd "$root" && tar --numeric-owner --owner=0 --group=0 --sort=name --mtime="@${SOURCE_DATE_EPOCH:-1704067200}" -cpf - . | zstd -19 -T0 -o "$sfile") >>"$slog" 2>&1 || {
    bs_err "snapshot falhou (veja: $slog)"; return 3; }
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${sfile%/*}" && sha256sum "$(basename -- "$sfile")" > "$(basename -- "$sfile").sha256") >>"$slog" 2>&1 || true
  fi
  return 0
}

_bs_summary_write() {
  local n="$1" root="${BS_PATHS[rootfs]}" sfile="${ADM_STAGES_ROOT%/}/stage${n}/summary.json"
  local size; size="$(du -sm "$root" 2>/dev/null | awk '{print $1}')"
  local now; now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf '{"stage":%s,"profile":"%s","libc":"%s","rootfs":"%s","size_mb":%s,"time":"%s"}\n' \
    "$n" "${BS[profile]}" "${BS[libc]}" "$root" "${size:-0}" "$now" > "$sfile" 2>/dev/null || true
}

_bs_sanity_tests() {
  local n="$1" tlog="$(_bs_log_path tests)"
  [[ "${BS[no_test]}" == "true" ]] && { bs_info "sanity tests desabilitados (--no-test)"; return 0; }
  : > "$tlog" 2>/dev/null || true
  adm_step "tests" "stage$n" "sanity checks"

  # hello.c
  local root="${BS_PATHS[rootfs]}"
  cat > "${root%/}/tmp/hello.c" <<'EOF'
#include <stdio.h>
int main(){ printf("hello\n"); return 0; }
EOF
  _bs_chroot_exec /usr/bin/env -i PATH=/usr/bin:/bin cc /tmp/hello.c -o /tmp/hello >>"$tlog" 2>&1 || {
    bs_err "teste: compilação cc falhou (veja: $tlog)"; return 4; }
  _bs_chroot_exec /usr/bin/env -i PATH=/usr/bin:/bin /tmp/hello >>"$tlog" 2>&1 || {
    bs_err "teste: execução binário simples falhou (veja: $tlog)"; return 4; }
  rm -f -- "${root%/}/tmp/hello.c" "${root%/}/tmp/hello" 2>/dev/null || true

  # ldd em binários-chave, se existir
  for b in /bin/sh /usr/bin/bash /usr/bin/gcc /bin/busybox; do
    _bs_chroot_exec /usr/bin/env -i PATH=/usr/bin:/bin sh -c "[ -x $b ] && ldd $b >/dev/null 2>&1 || true" >>"$tlog" 2>&1 || true
  done
  return 0
}
# 12-adm-bootstrap.part2.sh
# Orquestração dos stages, init, all, resume, snapshot e clean.
if [[ -n "${ADM_BOOTSTRAP_LOADED_PART2:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_BOOTSTRAP_LOADED_PART2=1
###############################################################################
# Preparação e validações
###############################################################################
adm_bootstrap_init() {
  local arch="" triplet="" libc="${ADM_LIBC_DEFAULT}" profile="${ADM_PROFILE_DEFAULT}" rootfs_dir="" driver="auto"
  local qemu="" offline="${ADM_OFFLINE:-false}" no_chroot=false verbose=false strict=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --arch) arch="$2"; shift 2;;
      --target-triplet) triplet="$2"; shift 2;;
      --libc) libc="$2"; shift 2;;
      --profile) profile="$2"; shift 2;;
      --rootfs-dir) rootfs_dir="$2"; shift 2;;
      --driver|--chroot-driver) driver="$2"; shift 2;;
      --with-qemu) qemu="$2"; shift 2;;
      --offline) offline=true; shift;;
      --no-chroot) no_chroot=true; shift;;
      --verbose) verbose=true; shift;;
      --strict) strict=true; shift;;
      *) bs_warn "opção desconhecida: $1"; shift;;
    esac
  done

  _bs_check_tools_host || return $?
  _bs_detect_host

  [[ -n "$arch" ]]    && BS[arch]="$arch"
  [[ -n "$triplet" ]] && BS[triplet]="$triplet"
  [[ -n "$libc"   ]]  && BS[libc]="$libc"
  [[ -n "$profile"]]  && BS[profile]="$profile"
  [[ -n "$rootfs_dir" ]] && BS[rootfs_dir]="$rootfs_dir"
  BS[driver]="$driver"; BS[qemu]="$qemu"
  BS[offline]="$offline"; BS[no_chroot]="$no_chroot"; BS[verbose]="$verbose"; BS[strict]="$strict"

  _bs_space_check "$ADM_MIN_DISK_MB" "${ADM_STAGES_ROOT%/}" || return $?
  mkdir -p -- "${ADM_STAGES_ROOT%/}" || { bs_err "falha ao criar ${ADM_STAGES_ROOT}"; return 3; }
  for n in 0 1 2 3; do
    BS_CTX_STAGE="stage$n"
    _bs_paths_init "$n" || return $?
    _bs_write_envfile "$n" || return $?
  done
  adm_ok "bootstrap init concluído (arch=${BS[arch]}, triplet=${BS[triplet]}, libc=${BS[libc]}, profile=${BS[profile]})"
}

###############################################################################
# Execução de um stage específico
###############################################################################
adm_bootstrap_stage() {
  local n="$1"; shift || true
  [[ "$n" =~ ^[0-3]$ ]] || { bs_err "uso: adm_bootstrap_stage <0|1|2|3> [flags]"; return 1; }

  # Flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) BS[profile]="$2"; shift 2;;
      --offline) BS[offline]=true; shift;;
      --bin-dir) BS[bin_dir]="$2"; shift 2;;
      --source-only) BS[source_only]=true; shift;;
      --no-test) BS[no_test]=true; shift;;
      --no-strip) BS[no_strip]=true; shift;;
      --jobs) BS[jobs]="$2"; shift 2;;
      --verbose) BS[verbose]=true; shift;;
      --strict) BS[strict]=true; shift;;
      --resume) BS[resume]=true; shift;;
      --force-rebuild) BS[force_rebuild]=true; shift;;
      --keep-going) BS[keep_going]=true; shift;;
      --driver|--chroot-driver) BS[driver]="$2"; shift 2;;
      --with-qemu) BS[qemu]="$2"; shift 2;;
      --no-chroot) BS[no_chroot]=true; shift;;
      *) bs_warn "opção desconhecida: $1"; shift;;
    esac
  done

  BS_CTX_STAGE="stage$n"
  _bs_paths_init "$n" || return $?
  _bs_write_envfile "$n" || return $?
  _bs_driver_choose "$n" || return $?
  _bs_space_check "$ADM_MIN_DISK_MB" "${BS_PATHS[rootfs]}" || return $?

  _bs_lock_acquire "$n" || return $?
  trap '_bs_umount_chroot; _bs_qemu_teardown; _bs_lock_release '"$n" EXIT

  # Hooks globais: pre-stageN
  if command -v adm_hooks_run >/dev/null 2>&1; then
    ROOTFS="${BS_PATHS[rootfs]}" STAGE="$n" PROFILE="${BS[profile]}" adm_hooks_run "pre-stage$n" || {
      [[ "${BS[strict]}" == "true" ]] && { bs_err "hook pre-stage$n falhou"; return 4; } || bs_warn "hook pre-stage$n falhou"
    }
  fi

  # Geração do plano
  adm_step "plan" "stage$n" "gerando plano"
  _bs_generate_plan "$n" "${BS[profile]}" || return $?

  # QEMU (se necessário)
  if [[ -n "${BS[qemu]}" ]]; then
    _bs_qemu_setup || return $?
  fi

  # Montar chroot se aplicável
  _bs_mount_chroot || { bs_err "montagem do chroot falhou"; return 3; }

  # Executa plano: build+install no rootfs (adm_install_pkg decide bin/source)
  adm_step "install" "stage$n" "executando plano no rootfs"
  _bs_run_plan_in_rootfs "$n" || return $?

  # Tests
  _bs_sanity_tests "$n" || return $?

  # Snapshot
  _bs_snapshot_rootfs "$n" || return $?

  # Summary
  _bs_summary_write "$n" || true

  # Hooks globais: post-stageN
  if command -v adm_hooks_run >/dev/null 2>&1; then
    ROOTFS="${BS_PATHS[rootfs]}" STAGE="$n" PROFILE="${BS[profile]}" adm_hooks_run "post-stage$n" || {
      [[ "${BS[strict]}" == "true" ]] && { bs_err "hook post-stage$n falhou"; return 4; } || bs_warn "hook post-stage$n falhou"
    }
  fi

  adm_ok "stage$n concluído"
  _bs_umount_chroot
  _bs_qemu_teardown
  _bs_lock_release "$n"
  trap - EXIT
  return 0
}

###############################################################################
# Executar todos os stages (0→3)
###############################################################################
adm_bootstrap_all() {
  local flags=("$@")
  for n in 0 1 2 3; do
    adm_step "stage" "$n" "iniciando"
    if ! adm_bootstrap_stage "$n" "${flags[@]}"; then
      bs_err "stage$n falhou — interrupção do pipeline all"
      return 4
    fi
  done
  adm_ok "bootstrap completo (stages 0→3)"
}

###############################################################################
# Resume
###############################################################################
adm_bootstrap_resume() {
  # Estratégia simples: encontra o menor N cujo snapshot ainda não existe, ou última execução incompleta
  for n in 0 1 2 3; do
    local snap="${ADM_STAGES_ROOT%/}/stage${n}/rootfs.tar.zst"
    if [[ ! -r "$snap" ]]; then
      bs_info "retomando a partir do stage$n"
      adm_bootstrap_stage "$n" --resume || return $?
    fi
  done
  adm_ok "nada a retomar — todos os snapshots presentes"
}

###############################################################################
# Snapshot manual
###############################################################################
adm_bootstrap_snapshot() {
  local n="$1"
  [[ "$n" =~ ^[0-3]$ ]] || { bs_err "uso: adm_bootstrap_snapshot <0|1|2|3>"; return 1; }
  BS_CTX_STAGE="stage$n"
  _bs_paths_init "$n" || return $?
  _bs_snapshot_rootfs "$n" || return $?
  _bs_summary_write "$n" || true
  adm_ok "snapshot refeito (stage$n)"
}

###############################################################################
# Clean
###############################################################################
adm_bootstrap_clean() {
  local stage="" all=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage) stage="$2"; shift 2;;
      --all) all=true; shift;;
      *) bs_warn "opção desconhecida: $1"; shift;;
    esac
  done

  if [[ "$all" == "true" ]]; then
    rm -rf -- "${ADM_STAGES_ROOT%/}/stage"{0,1,2,3} 2>/dev/null || true
    adm_ok "todos os stages limpos (diretórios removidos)"
    return 0
  fi

  if [[ -n "$stage" ]]; then
    [[ "$stage" =~ ^[0-3]$ ]] || { bs_err "--stage requer 0..3"; return 1; }
    local base="${ADM_STAGES_ROOT%/}/stage${stage}"
    # desmontar qualquer resto
    for m in proc sys dev run; do
      umount -l "${base%/}/rootfs/$m" 2>/dev/null || true
    done
    rm -rf -- "$base/build" "$base/logs" "$base/state" 2>/dev/null || true
    adm_ok "stage${stage} limpo (preservado rootfs e snapshot)"
    return 0
  fi

  bs_err "uso: adm_bootstrap_clean [--all] [--stage N]"
  return 1
}
# 12-adm-bootstrap.part3.sh
# CLI e ajudantes finais
if [[ -n "${ADM_BOOTSTRAP_LOADED_PART3:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_BOOTSTRAP_LOADED_PART3=1

###############################################################################
# CLI
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="$1"; shift || true
  case "$cmd" in
    init)       adm_bootstrap_init "$@" || exit $?;;
    stage)      adm_bootstrap_stage "$@" || exit $?;;
    all)        adm_bootstrap_all "$@" || exit $?;;
    resume)     adm_bootstrap_resume "$@" || exit $?;;
    snapshot)   adm_bootstrap_snapshot "$@" || exit $?;;
    clean)      adm_bootstrap_clean "$@" || exit $?;;
    *)
      echo "uso:" >&2
      echo "  $0 init [--arch A] [--target-triplet T] [--libc musl|glibc] [--profile minimal|normal|aggressive] [--rootfs-dir DIR]" >&2
      echo "           [--driver auto|chroot|bwrap|proot] [--with-qemu qemu-<arch>-static] [--offline] [--no-chroot] [--verbose] [--strict]" >&2
      echo "  $0 stage <0|1|2|3> [--profile P] [--offline] [--bin-dir DIR] [--source-only] [--no-test] [--no-strip] [--jobs N]" >&2
      echo "           [--resume] [--force-rebuild] [--keep-going] [--driver D] [--with-qemu Q]" >&2
      echo "  $0 all   [mesmas flags de stage]" >&2
      echo "  $0 resume" >&2
      echo "  $0 snapshot <0|1|2|3>" >&2
      echo "  $0 clean [--all] [--stage N]" >&2
      exit 2;;
  esac
fi

ADM_BOOTSTRAP_LOADED=1
export ADM_BOOTSTRAP_LOADED
