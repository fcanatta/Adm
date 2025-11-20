#!/usr/bin/env bash
# shellcheck shell=bash
#
# patch-engine.sh
# Aplica série de patches de um pacote em um diretório de fontes.

set -Eeuo pipefail

ROOT_DIR="/usr/src/adm"
SCRIPTS_DIR="$ROOT_DIR/scripts"

# shellcheck source=/usr/src/adm/scripts/lib/common.sh
. "$SCRIPTS_DIR/lib/common.sh"
# shellcheck source=/usr/src/adm/scripts/lib/patch.sh
. "$SCRIPTS_DIR/lib/patch.sh"
# shellcheck source=/usr/src/adm/scripts/lib/hooks.sh
. "$SCRIPTS_DIR/lib/hooks.sh"
# shellcheck source=/usr/src/adm/scripts/lib/meta.sh
. "$SCRIPTS_DIR/lib/meta.sh"

usage() {
  cat <<EOF
Uso: patch-engine.sh <categoria> <pacote> <versão> <dir_fontes>

Exemplo:
  patch-engine.sh base bash 5.2 /usr/src/adm/sources/bash-5.2
EOF
}

main() {
  adm_log_init "$ROOT_DIR/logs" "patch-engine.log"

  if (($# != 4)); then
    usage
    adm_die 1 "Parâmetros inválidos."
  fi

  local category="$1"
  local package="$2"
  local version="$3"
  local src_dir="$4"

  if [[ ! -d "$src_dir" ]]; then
    adm_die 1 "Diretório de fontes não encontrado: $src_dir"
  fi

  local pkg_root="$ROOT_DIR/repo/$category/$package"
  local patch_dir="$pkg_root/patch"

  log_info "Patch-engine: categoria=$category pacote=$package versão=$version"
  log_info "  fontes: $src_dir"
  log_info "  patches: $patch_dir"

  adm_run_hooks "pre_patch" "$package"

  if [[ -d "$patch_dir" ]]; then
    adm_apply_patch_series "$patch_dir" "$src_dir"
  else
    log_info "Nenhum diretório de patches encontrado para $package; nada a fazer."
  fi

  adm_run_hooks "post_patch" "$package"

  adm_meta_set "last-patch.$package" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  log_info "Patch-engine concluído para $package-$version"
}

main "$@"
