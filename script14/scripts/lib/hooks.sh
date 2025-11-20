#!/usr/bin/env bash
# shellcheck shell=bash
#
# Execução de hooks (pre_*, post_*) em diretórios de hook.

set -Eeuo pipefail

# shellcheck source=/usr/src/adm/scripts/lib/common.sh
. "/usr/src/adm/scripts/lib/common.sh"

ADM_HOOKS_ROOT="${ADM_HOOKS_ROOT:-/usr/src/adm/hooks}"

# Exemplo de convenção:
#   ${ADM_HOOKS_ROOT}/${context}/${phase}_*.sh
# context: nome do pacote, ou "global", etc.
# phase:   pre_fetch, post_fetch, pre_build, post_build, pre_install, ...

adm_hooks_dir() {
  local context="$1"
  printf '%s/%s' "$ADM_HOOKS_ROOT" "$context"
}

adm_run_hooks() {
  local phase="$1"
  local context="${2:-global}"

  local dir
  dir="$(adm_hooks_dir "$context")"

  [[ -d "$dir" ]] || {
    log_info "Nenhum hook para fase '$phase' em contexto '$context'"
    return 0
  }

  log_info "Executando hooks '$phase' para contexto '$context' em '$dir'"

  local hook
  # shellcheck disable=SC2231
  for hook in "$dir/$phase"_*.sh; do
    [[ -e "$hook" ]] || continue
    if [[ ! -x "$hook" ]]; then
      log_warn "Hook não executável: $hook (ajustando permissão)"
      chmod +x "$hook" || log_warn "Falha ao dar permissão +x em $hook"
    fi
    log_info "Rodando hook: $hook"
    "$hook" || adm_die 1 "Hook falhou: $hook"
  done
}
