#!/usr/bin/env bash
# shellcheck shell=bash
#
# Detecta CPU, compiladores e ferramentas, gerando:
#   meta/detected-tools.info
#   meta/optimization.profile

set -Eeuo pipefail

ROOT_DIR="/usr/src/adm"
SCRIPTS_DIR="$ROOT_DIR/scripts"

# shellcheck source=/usr/src/adm/scripts/lib/common.sh
. "$SCRIPTS_DIR/lib/common.sh"
# shellcheck source=/usr/src/adm/scripts/lib/meta.sh
. "$SCRIPTS_DIR/lib/meta.sh"

TOOLS_INFO_NAME="detected-tools.info"
OPT_PROFILE_NAME="optimization.profile"

main() {
  adm_require_root
  adm_meta_init

  adm_log_init "/usr/src/adm/logs" "detect-optimizations.log"
  task_start "Detectando otimizações e ferramentas disponíveis"

  detect_cpu_and_flags
  detect_compilers
  detect_misc_tools

  write_optimization_profile

  task_ok "Detecção concluída."
}

detect_cpu_and_flags() {
  log_info "Detectando CPU e possíveis flags"

  local arch cpu_vendor cpu_model n_cores
  arch="$(uname -m || echo unknown)"

  if command -v lscpu >/dev/null 2>&1; then
    cpu_vendor="$(lscpu | awk -F: '/Vendor ID/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
    cpu_model="$(lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
    n_cores="$(lscpu | awk -F: '/^CPU\(s\)/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
  else
    cpu_vendor="unknown"
    cpu_model="unknown"
    n_cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  fi

  log_info "Arquitetura: $arch"
  log_info "Vendor: $cpu_vendor"
  log_info "Modelo: $cpu_model"
  log_info "Cores: $n_cores"

  local cflags_base="-O2 -pipe"
  local extra_flags=""

  case "$arch" in
    x86_64)
      extra_flags="-fstack-protector-strong"
      ;;
    aarch64)
      extra_flags="-fstack-protector-strong"
      ;;
    *)
      extra_flags=""
      ;;
  esac

  local makeflags="-j$n_cores"

  adm_meta_set "cpu.arch" "$arch"
  adm_meta_set "cpu.vendor" "$cpu_vendor"
  adm_meta_set "cpu.model" "$cpu_model"
  adm_meta_set "cpu.cores" "$n_cores"
  adm_meta_set "build.default.cflags" "$cflags_base $extra_flags"
  adm_meta_set "build.default.makeflags" "$makeflags"
}

detect_compilers() {
  log_info "Detectando compiladores e linkers"

  local cc_candidates=("gcc" "clang")
  local cxx_candidates=("g++" "clang++")
  local ld_candidates=("ld" "gold" "lld")

  local cc cxx ld_bin

  for cc in "${cc_candidates[@]}"; do
    if command -v "$cc" >/dev/null 2>&1; then
      adm_meta_set "tool.cc" "$cc"
      log_info "CC: $cc"
      break
    fi
  done

  for cxx in "${cxx_candidates[@]}"; do
    if command -v "$cxx" >/dev/null 2>&1; then
      adm_meta_set "tool.cxx" "$cxx"
      log_info "CXX: $cxx"
      break
    fi
  done

  for ld_bin in "${ld_candidates[@]}"; do
    if command -v "$ld_bin" >/dev/null 2>&1; then
      adm_meta_set "tool.ld" "$ld_bin"
      log_info "LD: $ld_bin"
      break
    fi
  done
}

detect_misc_tools() {
  log_info "Detectando ferramentas adicionais"

  for t in ar as nm strip objdump objcopy; do
    if command -v "$t" >/dev/null 2>&1; then
      adm_meta_set "tool.$t" "$(command -v "$t")"
    fi
  done

  # Lista de ferramentas opcionais
  local opt_tools=(cmake ninja meson scons pkg-config)
  local t
  for t in "${opt_tools[@]}"; do
    if command -v "$t" >/dev/null 2>&1; then
      adm_meta_set "tool.optional.$t" "$(command -v "$t")"
    fi
  done
}

write_detected_tools_info() {
  local path
  path="$(adm_meta_path "$TOOLS_INFO_NAME")"

  log_info "Gravando resumo de ferramentas em $path"

  {
    echo "# Ferramentas detectadas"
    echo "# Gerado por detect-optimizations.sh em $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo

    echo "CC=$(adm_meta_get tool.cc 2>/dev/null || echo gcc)"
    echo "CXX=$(adm_meta_get tool.cxx 2>/dev/null || echo g++)"
    echo "LD=$(adm_meta_get tool.ld 2>/dev/null || echo ld)"

    echo "AR=$(adm_meta_get tool.ar 2>/dev/null || echo ar)"
    echo "AS=$(adm_meta_get tool.as 2>/dev/null || echo as)"
    echo "NM=$(adm_meta_get tool.nm 2>/dev/null || echo nm)"
    echo "STRIP=$(adm_meta_get tool.strip 2>/dev/null || echo strip)"
    echo "OBJDUMP=$(adm_meta_get tool.objdump 2>/dev/null || echo objdump)"
    echo "OBJCOPY=$(adm_meta_get tool.objcopy 2>/dev/null || echo objcopy)"

  } >"$path"

  adm_meta_set "detected-tools.path" "$path"
}

write_optimization_profile() {
  write_detected_tools_info

  local path
  path="$(adm_meta_path "$OPT_PROFILE_NAME")"

  log_info "Criando perfil de otimização em $path"

  local arch cflags makeflags
  arch="$(adm_meta_get cpu.arch 2>/dev/null || echo unknown)"
  cflags="$(adm_meta_get build.default.cflags 2>/dev/null || echo "-O2 -pipe")"
  makeflags="$(adm_meta_get build.default.makeflags 2>/dev/null || echo "-j1")"

  cat >"$path" <<EOF
# Perfil de otimização gerado automaticamente
ARCH="$arch"
CFLAGS="$cflags"
MAKEFLAGS="$makeflags"

# Ajustes adicionais podem ser feitos manualmente.
EOF

  adm_meta_set "optimization.profile.path" "$path"
}

main "$@"
