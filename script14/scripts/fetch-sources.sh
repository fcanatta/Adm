#!/usr/bin/env bash
# shellcheck shell=bash
#
# fetch-sources.sh
# Baixa e prepara fontes a partir dos metadados do pacote.
#
# Convenção de metadados (arquivo: repo/<cat>/<pkg>/metadados):
#   NAME=pkg
#   VERSION=1.0
#   SRC_URI=https://...
#   SRC_ARCHIVE=pkg-1.0.tar.xz
#   SRC_SHA256=...
#
# Uso:
#   fetch-sources.sh <categoria> <pacote>
#   fetch-sources.sh --all       # varre todo o repo

set -Eeuo pipefail

ROOT_DIR="/usr/src/adm"
SCRIPTS_DIR="$ROOT_DIR/scripts"
SOURCES_DIR="$ROOT_DIR/sources"
REPO_DIR="$ROOT_DIR/repo"

# shellcheck source=/usr/src/adm/scripts/lib/common.sh
. "$SCRIPTS_DIR/lib/common.sh"
# shellcheck source=/usr/src/adm/scripts/lib/meta.sh
. "$SCRIPTS_DIR/lib/meta.sh"
# shellcheck source=/usr/src/adm/scripts/lib/hooks.sh
. "$SCRIPTS_DIR/lib/hooks.sh"

PATCH_ENGINE="$SCRIPTS_DIR/patch-engine.sh"

usage() {
  cat <<EOF
Uso:
  fetch-sources.sh <categoria> <pacote>
  fetch-sources.sh --all

Opções:
  --all    Varre todo o repositório e baixa as fontes de todos os pacotes.
EOF
}

ensure_sources_dir() {
  adm_mkdir_safe "$SOURCES_DIR"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

download_file() {
  local url="$1"
  local dest="$2"

  log_info "Baixando fontes de: $url"
  if have_cmd curl; then
    curl -L -o "$dest" "$url"
  elif have_cmd wget; then
    wget -O "$dest" "$url"
  else
    adm_die 1 "Nem curl nem wget disponíveis."
  fi
}

verify_sha256() {
  local file="$1"
  local expected="$2"

  [[ -z "$expected" ]] && {
    log_warn "Sem SHA256 esperado para $file; pulando verificação."
    return 0
  }

  if ! have_cmd sha256sum; then
    log_warn "sha256sum não encontrado; não é possível verificar $file."
    return 0
  fi

  local got
  got="$(sha256sum "$file" | awk '{print $1}')"

  if [[ "$got" != "$expected" ]]; then
    adm_die 1 "SHA256 incorreto para $file (esperado: $expected, obtido: $got)"
  fi

  log_info "SHA256 ok para $file"
}

extract_archive() {
  local archive="$1"
  local dest_dir="$2"

  adm_mkdir_safe "$dest_dir"

  log_info "Extraindo $archive em $dest_dir"

  case "$archive" in
    *.tar.gz|*.tgz)   tar -xzf "$archive" -C "$dest_dir" ;;
    *.tar.bz2)        tar -xjf "$archive" -C "$dest_dir" ;;
    *.tar.xz)         tar -xJf "$archive" -C "$dest_dir" ;;
    *.zip)            unzip -q "$archive" -d "$dest_dir" ;;
    *)
      adm_die 1 "Formato de arquivo desconhecido: $archive"
      ;;
  esac
}

process_one_package() {
  local category="$1"
  local package="$2"

  local pkg_root="$REPO_DIR/$category/$package"
  local meta_file="$pkg_root/metadados"

  if [[ ! -r "$meta_file" ]]; then
    adm_die 1 "Metadados não encontrados para $category/$package: $meta_file"
  fi

  log_info "Processando metadados de $category/$package"

  local NAME VERSION SRC_URI SRC_ARCHIVE SRC_SHA256

  NAME="$(adm_read_config_var "$meta_file" "NAME")"
  VERSION="$(adm_read_config_var "$meta_file" "VERSION")"
  SRC_URI="$(adm_read_config_var "$meta_file" "SRC_URI")"
  SRC_ARCHIVE="$(adm_read_config_var "$meta_file" "SRC_ARCHIVE")"
  SRC_SHA256="$(adm_read_config_var "$meta_file" "SRC_SHA256")"

  [[ -z "$NAME" || -z "$VERSION" || -z "$SRC_URI" ]] && \
    adm_die 1 "Metadados incompletos em $meta_file"

  if [[ -z "$SRC_ARCHIVE" ]]; then
    SRC_ARCHIVE="$(basename "$SRC_URI")"
  fi

  ensure_sources_dir

  local archive_path="$SOURCES_DIR/$SRC_ARCHIVE"
  local src_dir="$SOURCES_DIR/${NAME}-${VERSION}"

  adm_run_hooks "pre_fetch" "$package"

  if [[ -f "$archive_path" ]]; then
    log_info "Arquivo de fontes já existe: $archive_path"
  else
    download_file "$SRC_URI" "$archive_path"
  fi

  verify_sha256 "$archive_path" "$SRC_SHA256"

  if [[ -d "$src_dir" ]]; then
    log_info "Diretório de fontes já existe, removendo: $src_dir"
    rm -rf "$src_dir"
  fi

  extract_archive "$archive_path" "$SOURCES_DIR"

  # Caso o tarball crie um diretório com nome diferente, não vamos adivinhar;
  # assumimos que a convenção é NAME-VERSION. Se não for, o metadados pode ter
  # outra chave no futuro (EXTRACT_DIR, por exemplo).

  if [[ ! -d "$src_dir" ]]; then
    log_warn "Diretório $src_dir não existe após extração; pode ser necessário ajustar metadados."
  fi

  # Aplica patches
  if [[ -x "$PATCH_ENGINE" ]]; then
    "$PATCH_ENGINE" "$category" "$package" "$VERSION" "$src_dir"
  else
    log_warn "patch-engine.sh não encontrado em $PATCH_ENGINE; pulando patches."
  fi

  adm_run_hooks "post_fetch" "$package"

  # Registra meta
  adm_meta_set "source.$package.archive" "$archive_path"
  adm_meta_set "source.$package.dir" "$src_dir"
  adm_meta_set "source.$package.version" "$VERSION"
}

fetch_all() {
  log_info "Varredura de todos os pacotes em $REPO_DIR"

  local category package
  for category in "$REPO_DIR"/*; do
    [[ -d "$category" ]] || continue
    category="$(basename "$category")"

    for package in "$REPO_DIR/$category"/*; do
      [[ -d "$package" ]] || continue
      package="$(basename "$package")"

      process_one_package "$category" "$package"
    done
  done
}

main() {
  adm_log_init "$ROOT_DIR/logs" "fetch-sources.log"
  task_start "fetch-sources"

  if (($# == 1)) && [[ "$1" == "--all" ]]; then
    fetch_all
    task_ok "fetch-sources --all concluído."
    return 0
  fi

  if (($# != 2)); then
    usage
    adm_die 1 "Parâmetros inválidos."
  fi

  process_one_package "$1" "$2"
  task_ok "Fontes preparadas para $1/$2."
}

main "$@"
