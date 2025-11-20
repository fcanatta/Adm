#!/usr/bin/env bash
# shellcheck shell=bash
#
# Centraliza PATH, CFLAGS, LDFLAGS, MAKEFLAGS e outras variáveis.
#
# Modo de uso:
#   source environment-wrapper.sh       # para carregar env no shell atual
#   environment-wrapper.sh comando ...  # para executar com env aplicado

set -Eeuo pipefail

ROOT_DIR="/usr/src/adm"
SCRIPTS_DIR="$ROOT_DIR/scripts"

# shellcheck source=/usr/src/adm/scripts/lib/common.sh
. "$SCRIPTS_DIR/lib/common.sh"
# shellcheck source=/usr/src/adm/scripts/lib/meta.sh
. "$SCRIPTS_DIR/lib/meta.sh"

apply_env() {
  # Diretórios padrão
  export ADM_ROOT="$ROOT_DIR"
  export ADM_SCRIPTS="$ROOT_DIR/scripts"
  export ADM_SOURCES="$ROOT_DIR/sources"
  export ADM_BUILD="$ROOT_DIR/build"
  export ADM_CACHE="$ROOT_DIR/cache"
  export ADM_LOGS="$ROOT_DIR/logs"
  export ADM_META="$ROOT_DIR/meta"
  export ADM_INTEL="$ROOT_DIR/intelligence"
  export ADM_PROFILES="$ROOT_DIR/profiles"

  # PATH base (scripts + toolchain futuro)
  local new_path
  new_path="$ADM_SCRIPTS:$ADM_BUILD/toolchain/bin:$PATH"
  export PATH="$new_path"

  # Carrega perfil de otimização se existir
  local opt_file
  opt_file="$(adm_meta_get optimization.profile.path 2>/dev/null || true)"
  if [[ -n "$opt_file" && -r "$opt_file" ]]; then
    # shellcheck disable=SC1090
    . "$opt_file"
  fi

  # Exporta CFLAGS, MAKEFLAGS se vieram do perfil
  [[ -n "${CFLAGS:-}" ]]   && export CFLAGS
  [[ -n "${MAKEFLAGS:-}" ]] && export MAKEFLAGS

  # Linker flags podem ser derivados de variáveis de meta no futuro
  # por enquanto, deixamos um default suave
  : "${LDFLAGS:=-Wl,-O1}"
  export LDFLAGS

  # Registra no log
  adm_log_init "$ADM_LOGS" "environment-wrapper.log"
  log_info "Ambiente de build inicializado (PATH, CFLAGS, MAKEFLAGS, LDFLAGS)."
}

main() {
  apply_env

  # Se não houver argumentos, apenas aplica env (para uso via `source`)
  if (($# == 0)); then
    return 0
  fi

  # Caso contrário, executa o comando passado com env aplicado
  log_info "Executando comando com env ADM: $*"
  exec "$@"
}

# Detecção se foi sourced ou executado
# Se $0 == bash/zsh, provavelmente foi via source; se for arquivo, foi exec.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
else
  # Foi "sourceado": apenas aplica env, sem rodar comando.
  apply_env
fi
