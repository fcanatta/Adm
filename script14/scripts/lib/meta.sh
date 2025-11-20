#!/usr/bin/env bash
# shellcheck shell=bash
#
# Acesso ao diretório de metadados /usr/src/adm/meta

set -Eeuo pipefail

# shellcheck source=/usr/src/adm/scripts/lib/common.sh
. "/usr/src/adm/scripts/lib/common.sh"

ADM_META_DIR_DEFAULT="${ADM_META_DIR_DEFAULT:-/usr/src/adm/meta}"

adm_meta_dir() {
  printf '%s\n' "${ADM_META_DIR:-$ADM_META_DIR_DEFAULT}"
}

adm_meta_init() {
  local dir
  dir="$(adm_meta_dir)"
  adm_mkdir_safe "$dir"
}

adm_meta_path() {
  local name="$1"
  printf '%s/%s' "$(adm_meta_dir)" "$name"
}

adm_meta_set() {
  local name="$1"; shift
  local value="$*"
  adm_meta_init
  local path
  path="$(adm_meta_path "$name")"
  printf '%s\n' "$value" >"$path"
  log_info "Meta gravado: $path"
}

adm_meta_append() {
  local name="$1"; shift
  local value="$*"
  adm_meta_init
  local path
  path="$(adm_meta_path "$name")"
  printf '%s\n' "$value" >>"$path"
}

adm_meta_get() {
  local name="$1"
  local path
  path="$(adm_meta_path "$name")"
  [[ -r "$path" ]] || return 1
  cat "$path"
}

adm_meta_exists() {
  local name="$1"
  local path
  path="$(adm_meta_path "$name")"
  [[ -e "$path" ]]
}
