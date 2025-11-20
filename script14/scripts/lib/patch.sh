#!/usr/bin/env bash
# shellcheck shell=bash
#
# Aplicação de séries de patches.

set -Eeuo pipefail

# shellcheck source=/usr/src/adm/scripts/lib/common.sh
. "/usr/src/adm/scripts/lib/common.sh"

adm_apply_patch_file() {
  local patch_file="$1"
  local target_dir="${2:-.}"

  adm_check_command patch

  if [[ ! -r "$patch_file" ]]; then
    adm_die 1 "Patch não encontrado: $patch_file"
  fi

  log_info "Aplicando patch: $patch_file em $target_dir"

  # Tenta -p1, depois -p0, depois -p2
  local pflag
  for pflag in -p1 -p0 -p2; do
    if patch --dry-run "$pflag" -d "$target_dir" -i "$patch_file" >/dev/null 2>&1; then
      if patch "$pflag" -d "$target_dir" -i "$patch_file"; then
        log_info "Patch aplicado com $pflag: $patch_file"
        return 0
      else
        log_warn "Falha na aplicação do patch com $pflag: $patch_file"
      fi
    fi
  done

  adm_die 1 "Não foi possível aplicar o patch: $patch_file"
}

adm_apply_patch_series() {
  local patch_dir="$1"
  local target_dir="${2:-.}"

  if [[ ! -d "$patch_dir" ]]; then
    log_info "Diretório de patches inexistente, ignorando: $patch_dir"
    return 0
  fi

  log_info "Aplicando série de patches em $patch_dir"

  local patch
  # Ordena alfabeticamente para garantir ordem determinística
  for patch in "$(ls -1 "$patch_dir"/*.patch 2>/dev/null | sort)"; do
    [[ -e "$patch" ]] || continue
    adm_apply_patch_file "$patch" "$target_dir"
  done
}
