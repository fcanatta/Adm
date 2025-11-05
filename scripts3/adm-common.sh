#!/usr/bin/env bash
# adm-common.sh
# Núcleo compartilhado para todos os scripts ADM.
# - Variáveis de ambiente e paths
# - Logging colorido (usa tput quando disponível)
# - Flags: --force, --no-dry-run, --profile <name>
# - Helpers: run_cmd, require_root, safe_mounts/safe_umounts
# - Hooks runner (global e por-programa em metafiles)
# - Leitura segura de metafile KEY=VAL
#
# IMPORTANTE: Sempre source este arquivo no topo dos outros scripts:
# . "$(dirname "$0")/adm-common.sh"

set -euo pipefail
IFS=$'\n\t'

# ----- Configuração básica -----
ADM_BASE="/usr/src/adm"
ADM_SCRIPTS="${ADM_BASE}/scripts"
ADM_METAFILES="${ADM_BASE}/metafiles"
ADM_DB="${ADM_BASE}/db"
ADM_UPDATE="${ADM_BASE}/update"
ADM_CACHE="${ADM_BASE}/cache"
ADM_BOOTSTRAP="${ADM_BASE}/bootstrap"
ADM_LOG="${ADM_BASE}/log"
ADM_DESTDIR="${ADM_BASE}/destdir"
ADM_TEMP="${ADM_BASE}/temp"
ADM_PACKAGES="${ADM_BASE}/packages"
ADM_PATCHES_GLOBAL="${ADM_BASE}/patches"
ADM_HOOKS_GLOBAL="${ADM_BASE}/hooks"
ADM_SOURCES_CACHE="${ADM_CACHE}/sources"

# Default behavior: dry-run enabled until user passes --no-dry-run
ADM_DRYRUN=1
ADM_FORCE=0
ADM_PROFILE="${ADM_BASE}/profile.default"

# ----- Colors via tput (fallback ANSI) -----
use_tput=0
if command -v tput >/dev/null 2>&1; then
  # check if terminal supports colors
  if [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    use_tput=1
  fi
fi

if [ "${use_tput}" -eq 1 ]; then
  T_RESET="$(tput sgr0)"
  T_BOLD="$(tput bold)"
  T_RED="$(tput setaf 1)"
  T_GREEN="$(tput setaf 2)"
  T_YELLOW="$(tput setaf 3)"
  T_BLUE="$(tput setaf 4)"
  T_MAGENTA="$(tput setaf 5)"
  T_CYAN="$(tput setaf 6)"
else
  T_RESET="\e[0m"
  T_BOLD="\e[1m"
  T_RED="\e[31m"
  T_GREEN="\e[32m"
  T_YELLOW="\e[33m"
  T_BLUE="\e[34m"
  T_MAGENTA="\e[35m"
  T_CYAN="\e[36m"
fi

# ----- Log file (unique per session) -----
mkdir -p "${ADM_LOG}" >/dev/null 2>&1 || true
LOGFILE="${ADM_LOG}/adm-$(date +%Y%m%d-%H%M%S).log"

# ----- Utility: safe echo to log and stdout -----
adm_log() {
  local level="${1:-INFO}"; shift || true
  local msg="$*"
  local color="${T_RESET}"
  case "${level}" in
    INFO) color="${T_BLUE}" ;;
    OK) color="${T_GREEN}" ;;
    WARN) color="${T_YELLOW}" ;;
    ERR) color="${T_RED}" ;;
    HINT) color="${T_CYAN}" ;;
    *) color="${T_RESET}" ;;
  esac
  # Print to stdout with color and to logfile without color (timestamped)
  printf "%b[%s]%b %s\n" "${color}" "${level}" "${T_RESET}" "${msg}"
  printf "[%s] [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "${msg}" >> "${LOGFILE}"
}

# ----- Parse common flags (call early in each script) -----
adm_parse_common_flags() {
  # Accepts flags: --force, --no-dry-run, --profile <file>
  local argv=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --force)
        ADM_FORCE=1
        shift
        ;;
      --no-dry-run)
        ADM_DRYRUN=0
        shift
        ;;
      --profile)
        if [ -n "${2:-}" ]; then
          ADM_PROFILE="$2"; shift 2
        else
          adm_log ERR "Flag --profile requer um argumento"; return 1
        fi
        ;;
      --help|-h)
        argv+=("$1"); shift ;;
      *)
        argv+=("$1"); shift ;;
    esac
  done
  # restore positional parameters
  set -- "${argv[@]}"
  # export current flags for child scripts if needed
  export ADM_DRYRUN ADM_FORCE ADM_PROFILE
  return 0
}

# ----- Ensure directories exist (idempotente) -----
adm_ensure_dirs() {
  mkdir -p "${ADM_SCRIPTS}" \
           "${ADM_METAFILES}" \
           "${ADM_DB}" \
           "${ADM_UPDATE}" \
           "${ADM_CACHE}" \
           "${ADM_SOURCES_CACHE}" \
           "${ADM_BOOTSTRAP}" \
           "${ADM_LOG}" \
           "${ADM_DESTDIR}" \
           "${ADM_TEMP}" \
           "${ADM_PACKAGES}" \
           "${ADM_HOOKS_GLOBAL}" \
           "${ADM_PATCHES_GLOBAL}" >/dev/null 2>&1 || true
}

# Create default profile if missing
adm_ensure_profile() {
  if [ ! -f "${ADM_PROFILE}" ]; then
    adm_log INFO "Criando profile default em ${ADM_PROFILE}"
    if [ "${ADM_DRYRUN}" -eq 1 ]; then
      adm_log INFO "[dry-run] criar profile.default"
    else
      cat > "${ADM_PROFILE}" <<'EOF'
# profile.default - variáveis de build
CC=gcc
CXX=g++
CFLAGS="-O2 -pipe"
CXXFLAGS="-O2 -pipe"
MAKEFLAGS="-j$(nproc)"
PREFIX=/usr
EOF
      adm_log OK "Profile default criado: ${ADM_PROFILE}"
    fi
  fi
}

# ----- Safety helpers -----
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    adm_log ERR "Necessário executar como root. Use sudo ou entre como root."
    return 1
  fi
  return 0
}

# run_cmd: centraliza execução com dry-run e logging
# Usage: run_cmd "command as string"
run_cmd() {
  local cmd="$*"
  if [ "${ADM_DRYRUN}" -eq 1 ]; then
    adm_log INFO "[dry-run] ${cmd}"
    return 0
  fi
  adm_log INFO "${cmd}"
  # use eval intentionally to allow shell features in commands
  if eval "${cmd}"; then
    adm_log OK "OK: ${cmd}"
    return 0
  else
    adm_log ERR "FAILED: ${cmd}"
    return 1
  fi
}

# run_critical: executes command but requires ADM_FORCE to be 1 (guardado)
# Usage: run_critical "explanation" "command..."
run_critical() {
  local reason="$1"; shift
  local cmd="$*"
  adm_log WARN "Operação crítica: ${reason}"
  if [ "${ADM_FORCE}" -ne 1 ]; then
    adm_log ERR "Requer --force para executar: ${cmd}"
    return 1
  fi
  run_cmd "${cmd}"
}

# ----- Chroot safe mounts/unmounts -----
safe_mounts() {
  # mount /dev, /dev/pts, /proc, /sys into <root>
  local root="${1:-}"
  if [ -z "${root}" ]; then adm_log ERR "safe_mounts requer rootdir"; return 1; fi
  adm_log INFO "Montando pseudo-filesystems em ${root} (bind mounts)"
  run_cmd "mount --bind /dev '${root}/dev' || true"
  run_cmd "mount --bind /dev/pts '${root}/dev/pts' || true"
  run_cmd "mount -t proc proc '${root}/proc' || true"
  run_cmd "mount --bind /sys '${root}/sys' || true"
  return 0
}

safe_umounts() {
  local root="${1:-}"; if [ -z "${root}" ]; then adm_log ERR "safe_umounts requer rootdir"; return 1; fi
  adm_log INFO "Desmontando pseudo-filesystems em ${root}"
  # attempt reverse order and ignore failures to avoid blocking
  run_cmd "umount -lf '${root}/sys' || true"
  run_cmd "umount -lf '${root}/proc' || true"
  run_cmd "umount -lf '${root}/dev/pts' || true"
  run_cmd "umount -lf '${root}/dev' || true"
  return 0
}

# ----- Hooks runner -----
# Hooks are executed from:
# 1) Global hooks: ${ADM_HOOKS_GLOBAL}/${stage}/*.sh
# 2) Package hooks if provided: ${ADM_METAFILES}/${category}/${program}/hooks/*.sh
# Hooks are executed in lexicographic order.
run_hooks() {
  local stage="$1"
  local category="${2:-}"
  local program="${3:-}"
  shift 3 || true

  adm_log INFO "Procurando hooks para stage='${stage}' category='${category}' program='${program}'"

  # global hooks
  if [ -d "${ADM_HOOKS_GLOBAL}/${stage}" ]; then
    for hook in "${ADM_HOOKS_GLOBAL}/${stage}"/*.sh; do
      [ -f "${hook}" ] || continue
      adm_log INFO "Executando hook global: ${hook}"
      if [ "${ADM_DRYRUN}" -eq 1 ]; then
        adm_log INFO "[dry-run] sh '${hook}' '${@:-}'"
      else
        sh "${hook}" "${@:-}" || { adm_log ERR "Hook falhou: ${hook}"; return 1; }
      fi
    done
  fi

  # package-local hooks (no subfolders as requested; but accept directory hooks/)
  if [ -n "${category}" ] && [ -n "${program}" ]; then
    local pkgdir="${ADM_METAFILES}/${category}/${program}"
    local hookdir="${pkgdir}/hooks"
    if [ -d "${hookdir}" ]; then
      for hook in "${hookdir}"/*.sh; do
        [ -f "${hook}" ] || continue
        adm_log INFO "Executando hook pacote: ${hook}"
        if [ "${ADM_DRYRUN}" -eq 1 ]; then
          adm_log INFO "[dry-run] sh '${hook}' '${@:-}'"
        else
          sh "${hook}" "${@:-}" || { adm_log ERR "Hook falhou: ${hook}"; return 1; }
        fi
      done
    fi
  fi

  return 0
}

# ----- Patch applier helper (per-package) -----
# Aplica patches localizados em ${ADM_METAFILES}/${category}/${program}/patch/*
adm_apply_patches() {
  local workdir="$1"; local category="$2"; local program="$3"
  [ -d "${workdir}" ] || { adm_log ERR "workdir inválido: ${workdir}"; return 1; }
  local pkgpatchdir="${ADM_METAFILES}/${category}/${program}/patch"
  if [ ! -d "${pkgpatchdir}" ]; then
    adm_log INFO "Nenhum patch de pacote em ${pkgpatchdir}"
    return 0
  fi
  adm_log INFO "Aplicando patches em ${pkgpatchdir} para ${program}..."
  for p in "${pkgpatchdir}"/*.patch "${pkgpatchdir}"/*.diff; do
    [ -f "${p}" ] || continue
    adm_log INFO "Patch: $(basename "${p}")"
    if [ "${ADM_DRYRUN}" -eq 1 ]; then
      adm_log INFO "[dry-run] (cd '${workdir}' && patch -p1 < '${p}')"
    else
      (cd "${workdir}" && patch -p1 < "${p}") || { adm_log ERR "Falha ao aplicar patch ${p}"; return 1; }
    fi
  done
  adm_log OK "Patches aplicados."
  return 0
}

# ----- Read KEY=VAL metafile safely -----
# Usage: read_metafile_val <metafile> <KEY>
read_metafile_val() {
  local mf="$1"; local key="$2"
  if [ ! -f "${mf}" ]; then
    return 1
  fi
  # Accept lines like KEY="value" or KEY=value ; ignore comments and spaces
  # Use awk to safely parse
  awk -F= -v k="${key}" '
    BEGIN{IGNORECASE=0}
    /^[[:space:]]*#/ { next }
    $1~k {
      val=$0
      sub("^[^=]*=","",val)
      gsub(/^[ \t]+|[ \t]+$/,"",val)
      # remove surrounding quotes if present
      if (val ~ /^".*"$/) { val = substr(val,2,length(val)-2) }
      if (val ~ /^'\''.*'\''$/) { val = substr(val,2,length(val)-2) }
      print val
      exit
    }
  ' "${mf}"
}

# ----- Read multiple KEY=VAL lines into env (careful) -----
# Usage: adm_source_metafile <metafile>
adm_source_metafile() {
  local mf="$1"
  if [ ! -f "${mf}" ]; then
    adm_log ERR "metafile não encontrado: ${mf}"
    return 1
  fi
  # Only allow KEY=VAL lines with safe keys (alnum and underscore)
  while IFS= read -r line; do
    # skip blanks and comments
    case "${line}" in
      ''|\#*) continue ;;
    esac
    # match KEY=VALUE
    if echo "${line}" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*='; then
      # evaluate in a subshell to avoid surprises, then export
      # using printf to preserve quoting
      key=$(printf "%s" "${line}" | awk -F= '{print $1}')
      val=$(printf "%s" "${line}" | cut -d= -f2-)
      # remove surrounding quotes safely
      val=$(printf "%s" "${val}" | sed -E "s/^['\"]//; s/['\"]$//")
      export "${key}"="${val}"
    else
      adm_log WARN "Linha do metafile ignorada (formato inválido): ${line}"
    fi
  done < "${mf}"
  return 0
}

# ----- Small helpers -----
mktempdir() {
  local tmp
  tmp=$(mktemp -d "${ADM_TEMP}/adm.XXXXXX") || { adm_log ERR "falha ao criar tempdir"; return 1; }
  printf "%s" "${tmp}"
}

# safe join paths with no duplicate slashes
joinpath() {
  local a="$1"; local b="$2"
  if [ -z "${a}" ]; then printf "%s" "${b}"; else printf "%s" "${a%/}/${b#/}"; fi
}

# ----- Initialization on source -----
# When sourced, ensure base directories exist and profile present.
adm_ensure_dirs
adm_ensure_profile

# export common vars for child scripts
export ADM_BASE ADM_SCRIPTS ADM_METAFILES ADM_DB ADM_UPDATE ADM_CACHE ADM_BOOTSTRAP ADM_LOG ADM_DESTDIR ADM_TEMP ADM_PACKAGES ADM_SOURCES_CACHE ADM_PATCHES_GLOBAL ADM_HOOKS_GLOBAL ADM_PROFILE ADM_DRYRUN ADM_FORCE
