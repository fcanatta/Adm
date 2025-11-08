#!/usr/bin/env bash
# 11-adm-uninstall.part1.sh
# Desinstalador transacional com hooks, triggers e autoremove de órfãos.
###############################################################################
# Guardas e pré-requisitos
###############################################################################
if [[ -n "${ADM_UNINSTALL_LOADED_PART1:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_UNINSTALL_LOADED_PART1=1

for _m in ADM_CONF_LOADED ADM_LIB_LOADED; do
  if [[ -z "${!_m:-}" ]]; then
    echo "ERRO: 11-adm-uninstall requer módulos básicos carregados (00/01). Faltando: ${_m}" >&2
    return 2 2>/dev/null || exit 2
  fi
done

: "${ADM_STATE_ROOT:=/usr/src/adm/state}"
: "${ADM_TMP_ROOT:=/usr/src/adm/tmp}"
: "${ADM_CACHE_ROOT:=/usr/src/adm/cache}"
: "${ADM_MIN_DISK_MB:=200}"

# Logs & mensagens
un_err()  { adm_err "$*"; }
un_warn() { adm_warn "$*"; }
un_info() { adm_log INFO "${U_CTX_PKG:-pkg}" "uninstall" "$*"; }

###############################################################################
# Contexto global por execução
###############################################################################
declare -Ag U_CTX=(
  [root]="/" [logdir]="" [lock_path]="" [tomb]="" [dry_run]="false" [yes]="false"
  [no_hooks]="false" [no_triggers]="false" [purge_config]="false" [backup_removed]="false"
  [protect_regex]="" [keep_globs]="" [verbose]="false" [force]="false" [force_shared]="false"
)

###############################################################################
# Utilidades
###############################################################################
_un_require_cmd() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || { un_err "comando obrigatório ausente: $c"; return 2; }; done; }
_un_check_root_perm() {
  local r="${U_CTX[root]}"
  if [[ "$r" == "/" ]] && [[ "$(id -u)" -ne 0 ]]; then
    un_err "remover de '/' requer privilégios de root"; return 3;
  fi
}
_un_path_under_root() {
  local p="$1" root="$(readlink -f -- "${U_CTX[root]}")"
  local rp; rp="$(readlink -f -- "$p" 2>/dev/null)" || return 1
  [[ "$rp" == "$root"* ]]
}
_un_make_logdir_for_pkg() {
  local cat="$1" name="$2" ver="$3"
  U_CTX[logdir]="${ADM_STATE_ROOT%/}/logs/uninstall/${cat}/${name}/${ver}"
  mkdir -p -- "${U_CTX[logdir]}" || true
}
_un_log_path() { echo "${U_CTX[logdir]%/}/$1.log"; }

_un_lock_acquire() {
  local base="${ADM_STATE_ROOT%/}/locks"
  mkdir -p -- "$base" || true
  U_CTX[lock_path]="$base/uninstall-global.lock"
  exec {ADM_UNINSTALL_LOCK_FD}>"${U_CTX[lock_path]}" || { un_err "não foi possível abrir lock"; return 3; }
  flock -n "$ADM_UNINSTALL_LOCK_FD" || { un_err "outra operação de (des)instalação em andamento"; return 3; }
}
_un_lock_release() {
  if [[ -n "${ADM_UNINSTALL_LOCK_FD:-}" ]]; then
    flock -u "$ADM_UNINSTALL_LOCK_FD" 2>/dev/null || true
    exec {ADM_UNINSTALL_LOCK_FD}>&- 2>/dev/null || true
  fi
}

_un_make_tomb() {
  local ts pid; ts="$(date +%s)"; pid="$$"
  U_CTX[tomb]="${ADM_TMP_ROOT%/}/uninstall-${pid}-${ts}"
  mkdir -p -- "${U_CTX[tomb]}" || { un_err "não foi possível criar TOMB: ${U_CTX[tomb]}"; return 3; }
}

_un_cleanup_tomb() {
  [[ -n "${U_CTX[tomb]}" ]] && rm -rf -- "${U_CTX[tomb]}" 2>/dev/null || true
}

###############################################################################
# Index, manifest e ownership
###############################################################################
# Índice: JSONL com chaves: cat,name,ver,root,tarball,origin,time,reason
_un_index_path() { echo "${ADM_STATE_ROOT%/}/installed/index.json"; }
_un_manifest_path() { # cat name ver
  printf "%s/manifest/%s_%s_%s.list" "${ADM_STATE_ROOT%/}" "$1" "$2" "$3"
}
_un_triggers_path() {
  printf "%s/triggers/%s_%s_%s.trg" "${ADM_STATE_ROOT%/}" "$1" "$2" "$3"
}
_un_ownership_path() { echo "${ADM_STATE_ROOT%/}/ownership/files.jsonl"; }

_un_index_find_entry() {
  # _un_index_find_entry <cat> <name> [ver] -> imprime linha JSON e retorna 0
  local cat="$1" name="$2" ver="${3:-}"
  local idx="$(_un_index_path)"
  [[ -r "$idx" ]] || return 1
  if [[ -n "$ver" ]]; then
    awk -v c="$cat" -v n="$name" -v v="$ver" -F'[",:]' '
      $0 ~ /^{/ { line=$0 }
      $0 ~ /"cat":"'"$cat"'"/ && $0 ~ /"name":"'"$name"'"/ && $0 ~ /"ver":"'"$ver"'"/ { print line }
    ' "$idx"
    return 0
  else
    # se múltiplas versões, decidiremos depois
    awk -v c="$cat" -v n="$name" -F'[",:]' '
      $0 ~ /^{/ { line=$0 }
      $0 ~ /"cat":"'"$cat"'"/ && $0 ~ /"name":"'"$name"'"/ { print line }
    ' "$idx"
    return 0
  fi
}

_un_index_remove_entry() {
  # remove linhas correspondentes (cat,name,ver) do índice (cria arquivo temporário)
  local cat="$1" name="$2" ver="$3"
  local idx="$(_un_index_path)"
  [[ -r "$idx" ]] || return 0
  local tmp="${idx}.tmp.$$"
  awk -v c="$cat" -v n="$name" -v v="$ver" '
    BEGIN { keep=1 }
    {
      if ($0 ~ /"cat":"[^"]+"/) {
        # captura campos
        cat=""; name=""; ver="";
      }
      match($0, /"cat":"([^"]+)"/, a); if (a[1]!="") cat=a[1];
      match($0, /"name":"([^"]+)"/, b); if (b[1]!="") name=b[1];
      match($0, /"ver":"([^"]+)"/,  d); if (d[1]!="") ver=d[1];

      if (cat==c && name==n && ver==v) next; else print $0;
    }' "$idx" > "$tmp" && mv -f -- "$tmp" "$idx"
}

_un_history_append() {
  local cat="$1" name="$2" ver="$3" removed="$4" preserved="$5" force_shared="$6"
  local hist="${ADM_STATE_ROOT%/}/removed/history.jsonl"
  mkdir -p -- "$(dirname -- "$hist")" || true
  local now; now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf '{"cat":"%s","name":"%s","ver":"%s","time":"%s","removed":%s,"preserved":%s,"force_shared":%s}\n' \
    "$cat" "$name" "$ver" "$now" "${removed:-0}" "${preserved:-0}" "$( [[ "$force_shared" == "true" ]] && echo true || echo false )" >> "$hist" 2>/dev/null || true
}

_un_parse_json_field() {
  # _un_parse_json_field <json_line> <key>
  local line="$1" key="$2"
  printf "%s" "$line" | sed -nE 's/.*"'$key'":"([^"]+)".*/\1/p'
}

_un_manifest_read() {
  # _un_manifest_read <cat> <name> <ver> -> imprime entradas "type<TAB>relpath<TAB>sha?" (type=f|d|l)
  local man="$(_un_manifest_path "$1" "$2" "$3")"
  [[ -r "$man" ]] || return 1
  # duas formas possíveis: com sha256sum "hash  path" ou simples "path"
  # Tentamos detectar: se linha parece "HASH  path", transformamos para f<TAB>path<TAB>hash.
  # Caso contrário, assumimos "path" e type inferido depois (consultando FS).
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^[0-9a-fA-F]{64}[[:space:]]+.+$ ]]; then
      local hash p; hash="${line%% *}"; p="${line#* }"
      p="${p#./}"
      echo -e "f\t${p}\t${hash}"
    else
      line="${line#./}"
      echo -e "?\t${line}\t"
    fi
  done < "$man"
}

_un_ownership_remove_owner() {
  # remove este pacote (cat/name@ver) da lista de owners de um arquivo
  local path="$1" owner="$2"
  local own="$(_un_ownership_path)"
  [[ -r "$own" ]] || return 0
  local tmp="${own}.tmp.$$"
  awk -v file="$path" -v owner="$owner" '
    BEGIN { OFS=""; }
    {
      line=$0
      match($0, /"path":"([^"]+)"/, a); p=a[1]
      if (p==file) {
        # retirar owner da lista
        gsub(/"owners":\[[^]]+\]/, "&", line)
        # parse tosco: remover "owner" das ocorrências
        gsub(/"'$owner'"/, "", line)
        # limpar vírgulas duplicadas
        gsub(/,\s*,/, ",", line); gsub(/\[,/, "[", line); gsub(/,\]/, "]", line)
        print line
      } else {
        print $0
      }
    }' "$own" > "$tmp" && mv -f -- "$tmp" "$own"
}

_un_ownership_is_shared() {
  # _un_ownership_is_shared <path> <owner> -> retorna 0 se compartilhado por outro owner
  local path="$1" owner="$2"
  local own="$(_un_ownership_path)"
  [[ -r "$own" ]] || return 1
  local line
  line="$(grep -F "\"path\":\"$path\"" "$own" 2>/dev/null | head -n1 || true)"
  [[ -z "$line" ]] && return 1
  # conta quantos owners distintos existem e se algum é != owner
  local owners; owners="$(printf "%s" "$line" | sed -nE 's/.*"owners":\[(.*)\].*/\1/p')"
  [[ -z "$owners" ]] && return 1
  # remove espaços/aspas e quebra por vírgula
  owners="$(printf "%s" "$owners" | tr -d '"' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d')"
  local cnt=0 other=false
  while IFS= read -r o; do
    [[ -z "$o" ]] && continue
    cnt=$((cnt+1))
    [[ "$o" != "$owner" ]] && other=true
  done <<<"$owners"
  if (( cnt > 1 )) && [[ "$other" == "true" ]]; then
    return 0
  fi
  return 1
}

###############################################################################
# Heurísticas: config & segurança
###############################################################################
_un_is_config_file() {
  local rel="$1"
  [[ "$rel" == etc/* ]] && return 0
  [[ "$rel" == usr/share/config/* || "$rel" == usr/share/defaults/* ]] && return 0
  [[ "$rel" =~ \.(conf|ini|toml|yaml|yml|json)$ ]] && return 0
  [[ "$rel" == *".d/"* ]] && return 0
  return 1
}
_un_sha256_file() {
  local f="$1"
  command -v sha256sum >/dev/null 2>&1 || return 1
  sha256sum "$f" 2>/dev/null | awk '{print $1}'
}

_un_is_modified_config() {
  # _un_is_modified_config <root> <rel> <manifest_hash?> -> 0 se modificado
  local root="$1" rel="$2" ref="$3"
  local f="${root%/}/$rel"
  [[ -f "$f" ]] || return 1
  if [[ -n "$ref" ]]; then
    local cur; cur="$(_un_sha256_file "$f")"
    [[ -z "$cur" ]] && return 0
    [[ "$cur" != "$ref" ]] && return 0 || return 1
  else
    # sem hash de referência — conservador: considerar modificado
    return 0
  fi
}

###############################################################################
# Triggers (pós-remoção)
###############################################################################
_un_triggers_collect_for_pkg() {
  local cat="$1" name="$2" ver="$3"
  local trg="$(_un_triggers_path "$cat" "$name" "$ver")"
  [[ -r "$trg" ]] || return 0
  cat "$trg"
}

_un_triggers_run() {
  local list="$1" log="$2"
  [[ "${U_CTX[no_triggers]}" == "true" ]] && { un_info "triggers desabilitados (--no-triggers)"; return 0; }
  local root; root="$(readlink -f -- "${U_CTX[root]}")" || return 3
  local uniq; uniq="$(echo "$list" | awk 'NF' | sort -u)"
  [[ -z "$uniq" ]] && { un_info "nenhum trigger para executar"; return 0; }

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local cmd args; cmd="$(awk '{print $1}' <<<"$line")"; args="${line#"$cmd"}"
    case "$cmd" in
      glib-compile-schemas)
        command -v glib-compile-schemas >/dev/null 2>&1 || { un_warn "glib-compile-schemas não encontrado — pulando"; continue; }
        adm_with_spinner "glib-compile-schemas" -- chroot "$root" glib-compile-schemas /usr/share/glib-2.0/schemas >>"$log" 2>&1 || un_warn "trigger falhou: $line"
        ;;
      update-desktop-database)
        command -v update-desktop-database >/dev/null 2>&1 || { un_warn "update-desktop-database não encontrado — pulando"; continue; }
        adm_with_spinner "update-desktop-database" -- chroot "$root" update-desktop-database -q /usr/share/applications >>"$log" 2>&1 || un_warn "trigger falhou: $line"
        ;;
      gtk-update-icon-cache)
        command -v gtk-update-icon-cache >/dev/null 2>&1 || { un_warn "gtk-update-icon-cache não encontrado — pulando"; continue; }
        for theme in "$root"/usr/share/icons/*; do
          [[ -d "$theme" ]] || continue
          adm_with_spinner "gtk-update-icon-cache ($(basename -- "$theme"))" -- chroot "$root" gtk-update-icon-cache -q -t -f "/usr/share/icons/$(basename -- "$theme")" >>"$log" 2>&1 || un_warn "trigger falhou: $line"
        done
        ;;
      ldconfig)
        [[ "$root" == "/" ]] || { un_info "ldconfig só em root=/ — pulando"; continue; }
        command -v ldconfig >/dev/null 2>&1 || { un_warn "ldconfig não encontrado — pulando"; continue; }
        adm_with_spinner "ldconfig" -- ldconfig >>"$log" 2>&1 || un_warn "trigger falhou: ldconfig"
        ;;
      systemd-daemon-reload)
        [[ "$root" == "/" ]] || { un_info "systemd-daemon-reload só em root=/ — pulando"; continue; }
        command -v systemctl >/dev/null 2>&1 || { un_warn "systemctl não encontrado — pulando"; continue; }
        adm_with_spinner "systemctl daemon-reload" -- systemctl daemon-reload >>"$log" 2>&1 || un_warn "trigger falhou: systemctl daemon-reload"
        ;;
      fc-cache)
        command -v fc-cache >/dev/null 2>&1 || { un_warn "fc-cache não encontrado — pulando"; continue; }
        adm_with_spinner "fc-cache" -- chroot "$root" fc-cache -f >>"$log" 2>&1 || un_warn "trigger falhou: fc-cache"
        ;;
      update-mime-database)
        command -v update-mime-database >/dev/null 2>&1 || { un_warn "update-mime-database não encontrado — pulando"; continue; }
        adm_with_spinner "update-mime-database" -- chroot "$root" update-mime-database /usr/share/mime >>"$log" 2>&1 || un_warn "trigger falhou: update-mime-database"
        ;;
      *) un_warn "trigger desconhecido: $line (pulando)";;
    esac
  done <<<"$uniq"
  return 0
}

###############################################################################
# Hooks
###############################################################################
_un_hooks_run() {
  # _un_hooks_run <phase> <scope> [cat name ver]
  local phase="$1" scope="$2" cat="$3" name="$4" ver="$5"
  [[ "${U_CTX[no_hooks]}" == "true" ]] && return 0
  if ! command -v adm_hooks_run >/dev/null 2>&1; then
    un_warn "hooks não disponíveis (05-adm-hooks-patches.sh)"; return 0;
  fi
  PKG_CATEGORY="$cat" PKG_NAME="$name" PKG_VERSION="$ver" ROOT="${U_CTX[root]}"
  case "$scope" in
    system) adm_hooks_run "${phase}-uninstall-system" || { [[ "${ADM_STRICT_HOOKS:-false}" == "true" ]] && return 4 || un_warn "hook $phase-system falhou"; } ;;
    pkg)    adm_hooks_run "${phase}-uninstall-pkg"    || { [[ "${ADM_STRICT_HOOKS:-false}" == "true" ]] && return 4 || un_warn "hook $phase-pkg falhou"; } ;;
  esac
}
# 11-adm-uninstall.part2.sh
# Plano de remoção, execução transacional, e operações auxiliares.
if [[ -n "${ADM_UNINSTALL_LOADED_PART2:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_UNINSTALL_LOADED_PART2=1
###############################################################################
# Plano de remoção
###############################################################################
_un_apply_filters() {
  # _un_apply_filters <rel> -> 0 se manter para remoção; 1 se preservar
  local rel="$1"
  # protect-regex
  if [[ -n "${U_CTX[protect_regex]}" ]] && [[ "$rel" =~ ${U_CTX[protect_regex]} ]]; then
    return 1
  fi
  # keep-globs (lista separada por vírgulas)
  if [[ -n "${U_CTX[keep_globs]}" ]]; then
    IFS=',' read -r -a G <<<"${U_CTX[keep_globs]}"
    local g
    for g in "${G[@]}"; do
      [[ -z "$g" ]] && continue
      if [[ "$rel" == $g ]]; then
        return 1
      fi
    done
  fi
  return 0
}

_un_build_removal_plan() {
  # _un_build_removal_plan <cat> <name> <ver> -> usa manifest e ownership
  local cat="$1" name="$2" ver="$3"
  local root="$(readlink -f -- "${U_CTX[root]}")"
  local owner="${cat}/${name}@${ver}"

  local planlog="$(_un_log_path plan)"
  : > "$planlog" 2>/dev/null || true

  declare -ag U_PLAN_FILES=() U_PLAN_DIRS=() U_PLAN_CONFIGS=()
  declare -ag U_PLAN_SKIP_SHARED=() U_PLAN_SKIP_PROTECTED=() U_PLAN_SKIP_MISSING=()

  local entry
  while IFS=$'\t' read -r typ rel hash; do
    [[ -z "$rel" ]] && continue
    # filtro de proteção
    if ! _un_apply_filters "$rel"; then
      U_PLAN_SKIP_PROTECTED+=("$rel")
      continue
    fi
    local abs="${root%/}/$rel"

    # checar existência no destino; se não existir, apenas registrar
    if [[ ! -e "$abs" && ! -L "$abs" ]]; then
      U_PLAN_SKIP_MISSING+=("$rel")
      continue
    fi

    if _un_is_config_file "$rel"; then
      # preservar configs modificadas, a menos que --purge-config
      if [[ "${U_CTX[purge_config]}" == "true" ]]; then
        U_PLAN_CONFIGS+=("$rel|$hash")
      else
        if _un_is_modified_config "$root" "$rel" "$hash"; then
          U_PLAN_SKIP_PROTECTED+=("$rel") # preservar
        else
          U_PLAN_CONFIGS+=("$rel|$hash")
        fi
      fi
      continue
    fi

    # arquivos (inclui symlinks)
    if [[ -f "$abs" || -L "$abs" ]]; then
      # checar compartilhamento
      if _un_ownership_is_shared "$abs" "$owner"; then
        if [[ "${U_CTX[force_shared]}" == "true" && "${U_CTX[force]}" == "true" ]]; then
          U_PLAN_FILES+=("$rel")
        else
          U_PLAN_SKIP_SHARED+=("$rel")
        fi
      else
        U_PLAN_FILES+=("$rel")
      fi
      continue
    fi

    # diretórios: removeremos depois, se ficarem vazios
    if [[ -d "$abs" ]]; then
      U_PLAN_DIRS+=("$rel")
      continue
    fi
  done < <(_un_manifest_read "$cat" "$name" "$ver")

  # Ordenar diretórios por profundidade reversa para remoção posterior
  mapfile -t U_PLAN_DIRS < <(printf "%s\n" "${U_PLAN_DIRS[@]}" | awk '{ print length, $0 }' | sort -rn | cut -d" " -f2-)
  # Ordenar arquivos por profundidade (não obrigatório, ajuda logging)
  mapfile -t U_PLAN_FILES < <(printf "%s\n" "${U_PLAN_FILES[@]}" | awk '{ print length, $0 }' | sort -rn | cut -d" " -f2-)

  # Resumo
  {
    echo "Plano de remoção:"
    echo " - arquivos: ${#U_PLAN_FILES[@]}"
    echo " - configs:  ${#U_PLAN_CONFIGS[@]}"
    echo " - dirs:     ${#U_PLAN_DIRS[@]} (apenas se vazios)"
    echo " - protegidos: ${#U_PLAN_SKIP_PROTECTED[@]}"
    echo " - compartilhados ignorados: ${#U_PLAN_SKIP_SHARED[@]}"
    echo " - ausentes: ${#U_PLAN_SKIP_MISSING[@]}"
  } >>"$planlog"
  return 0
}

###############################################################################
# Execução transacional (TOMB)
###############################################################################
_un_exec_removal_with_tomb() {
  # remove arquivos da U_PLAN_FILES e configs da U_PLAN_CONFIGS
  local root="$(readlink -f -- "${U_CTX[root]}")"
  local removelog="$(_un_log_path remove)"
  : > "$removelog" 2>/dev/null || true

  # TOMB (quando backup-removed)
  if [[ "${U_CTX[backup_removed]}" == "true" ]]; then
    _un_make_tomb || return $?
  fi

  # Arquivos
  local rel abs
  for rel in "${U_PLAN_FILES[@]}"; do
    abs="${root%/}/$rel"
    if [[ "${U_CTX[backup_removed]}" == "true" ]]; then
      mkdir -p -- "$(dirname -- "${U_CTX[tomb]%/}/$rel")" 2>/dev/null || true
      if ! mv -f -- "$abs" "${U_CTX[tomb]%/}/$rel" >>"$removelog" 2>&1; then
        un_err "falha ao mover para TOMB: $abs"; echo "veja: $removelog"; return 7;
      fi
    else
      if ! rm -f -- "$abs" >>"$removelog" 2>&1; then
        un_err "falha ao remover arquivo: $abs"; echo "veja: $removelog"; return 3;
      fi
    fi
  done

  # Configs
  local cfg hash
  for ch in "${U_PLAN_CONFIGS[@]}"; do
    cfg="${ch%%|*}"; hash="${ch#*|}"
    abs="${root%/}/$cfg"
    if [[ "${U_CTX[purge_config]}" == "true" ]]; then
      if [[ "${U_CTX[backup_removed]}" == "true" ]]; then
        mkdir -p -- "$(dirname -- "${U_CTX[tomb]%/}/$cfg")" 2>/dev/null || true
        mv -f -- "$abs" "${U_CTX[tomb]%/}/$cfg" >>"$removelog" 2>&1 || true
      else
        rm -f -- "$abs" >>"$removelog" 2>&1 || true
      fi
    else
      # preservar (não remover); já foi marcado como protegido no plano se modificado
      :
    fi
  done

  # Diretórios (apenas se vazios) — múltiplas passagens
  local iter=0 changed=true
  while $changed && (( iter < 5 )); do
    changed=false
    for rel in "${U_PLAN_DIRS[@]}"; do
      abs="${root%/}/$rel"
      [[ -d "$abs" ]] || continue
      if rmdir "$abs" >>"$removelog" 2>&1; then
        changed=true
      fi
    done
    iter=$((iter+1))
  done

  return 0
}

_un_rollback() {
  if [[ -n "${U_CTX[tomb]}" && -d "${U_CTX[tomb]}" ]]; then
    un_warn "rollback: itens movidos para ${U_CTX[tomb]}; restaure manualmente conforme necessário."
  else
    un_warn "rollback: nada para restaurar (remoção direta)."
  fi
}

###############################################################################
# Atualização de índice/ownership/estado
###############################################################################
_un_update_ownership_after_removal() {
  local cat="$1" name="$2" ver="$3"
  local root="$(readlink -f -- "${U_CTX[root]}")"
  local owner="${cat}/${name}@${ver}"

  # Para cada arquivo realmente removido (U_PLAN_FILES + configs purgadas), remova owner
  local rel abs
  for rel in "${U_PLAN_FILES[@]}"; do
    abs="${root%/}/$rel"
    _un_ownership_remove_owner "$abs" "$owner"
  done
  if [[ "${U_CTX[purge_config]}" == "true" ]]; then
    local ch cfg
    for ch in "${U_PLAN_CONFIGS[@]}"; do
      cfg="${ch%%|*}"
      abs="${root%/}/$cfg"
      _un_ownership_remove_owner "$abs" "$owner"
    done
  fi
}

_un_post_state_cleanup() {
  local cat="$1" name="$2" ver="$3"
  _un_index_remove_entry "$cat" "$name" "$ver"
  local man="$(_un_manifest_path "$cat" "$name" "$ver")"
  local trg="$(_un_triggers_path "$cat" "$name" "$ver")"
  if [[ "${ADM_KEEP_REMOVED_HISTORY:-true}" == "true" ]]; then
    local dst="${ADM_STATE_ROOT%/}/removed/${cat}_${name}_${ver}"
    mkdir -p -- "$dst" || true
    [[ -r "$man" ]] && mv -f -- "$man" "$dst/" 2>/dev/null || true
    [[ -r "$trg" ]] && mv -f -- "$trg" "$dst/" 2>/dev/null || true
  else
    rm -f -- "$man" "$trg" 2>/dev/null || true
  fi
}
# 11-adm-uninstall.part3.sh
# CLI: pkg | autoremove | list | why
if [[ -n "${ADM_UNINSTALL_LOADED_PART3:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_UNINSTALL_LOADED_PART3=1
###############################################################################
# WHY (reverse deps) e LIST
###############################################################################
adm_uninstall_list() {
  local mode="${1:-all}"
  local idx="$(_un_index_path)"
  [[ -r "$idx" ]] || { un_err "índice não encontrado: $idx"; return 1; }
  case "$mode" in
    --all|all) cat "$idx";;
    --explicit|explicit) grep -F '"reason":"explicit"' "$idx" || true;;
    --deps|deps)        grep -F '"reason":"dep"' "$idx" || true;;
    *) un_err "uso: adm_uninstall_list [--all|--explicit|--deps]"; return 2;;
  esac
}

adm_uninstall_why() {
  local cat="$1" name="$2"; shift 2 || true
  local ver=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) ver="$2"; shift 2;;
      *) un_warn "opção desconhecida: $1"; shift;;
    esac
  done
  [[ -n "$cat" && -n "$name" ]] || { un_err "uso: adm_uninstall_why <cat> <name> [--version V]"; return 2; }

  # Se resolver está disponível, delega (ideal)
  if command -v adm_resolver_reverse_deps >/dev/null 2>&1; then
    adm_resolver_reverse_deps "$cat" "$name" ${ver:+--version "$ver"} || return $?
    return 0
  fi

  # Fallback: varrer manifest/índice procurando run_deps salvos (se houver cópias de metafile no estado)
  un_warn "resolver reverso não disponível — fallback simplificado"
  local idx="$(_un_index_path)"; [[ -r "$idx" ]] || return 1
  grep -F "\"${cat}\",\"name\":\"${name}\"" "$idx" >/dev/null 2>&1 || true
  echo "Who-needs: análise limitada sem resolver; use o resolver para precisão."
}

###############################################################################
# UNINSTALL PKG
###############################################################################
adm_uninstall_pkg() {
  local cat="$1" name="$2"; shift 2 || true
  local ver="" root="/" dry_run=false yes=false no_hooks=false no_triggers=false
  local purge_config=false backup_removed=false protect_regex="" keep_globs=""
  local verbose=false force=false force_shared=false logdir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) ver="$2"; shift 2;;
      --root) root="$2"; shift 2;;
      --dry-run|--pretend) dry_run=true; shift;;
      --yes) yes=true; shift;;
      --no-hooks) no_hooks=true; shift;;
      --no-triggers) no_triggers=true; shift;;
      --purge-config) purge_config=true; shift;;
      --backup-removed) backup_removed=true; shift;;
      --protect-regex) protect_regex="$2"; shift 2;;
      --keep-globs) keep_globs="$2"; shift 2;;
      --verbose) verbose=true; shift;;
      --force) force=true; shift;;
      --force-shared) force_shared=true; shift;;
      --log-dir) logdir="$2"; shift 2;;
      *) un_warn "opção desconhecida: $1"; shift;;
    esac
  done

  [[ -n "$cat" && -n "$name" ]] || { un_err "uso: adm_uninstall_pkg <cat> <name> [--version V] [flags]"; return 2; }

  U_CTX[root]="$root"; U_CTX[dry_run]="$dry_run"; U_CTX[yes]="$yes"
  U_CTX[no_hooks]="$no_hooks"; U_CTX[no_triggers]="$no_triggers"
  U_CTX[purge_config]="$purge_config"; U_CTX[backup_removed]="$backup_removed"
  U_CTX[protect_regex]="$protect_regex"; U_CTX[keep_globs]="$keep_globs"
  U_CTX[verbose]="$verbose"; U_CTX[force]="$force"; U_CTX[force_shared]="$force_shared"
  [[ -n "$logdir" ]] && U_CTX[logdir]="$logdir"

  _un_check_root_perm || return $?

  _un_lock_acquire || return $?
  trap '_un_lock_release; _un_cleanup_tomb' EXIT

  # Encontrar entrada no índice
  local lines; lines="$(_un_index_find_entry "$cat" "$name" "$ver")"
  [[ -n "$lines" ]] || { un_err "pacote não encontrado no índice: $cat/$name${ver:+@$ver}"; return 1; }

  # Se múltiplas versões e ver ausente → erro
  if [[ -z "$ver" ]]; then
    local n; n="$(printf "%s\n" "$lines" | wc -l)"
    if (( n > 1 )); then
      un_err "múltiplas versões instaladas; especifique --version"; return 2;
    fi
  fi
  local entry; entry="$(printf "%s" "$lines" | head -n1)"
  ver="$(_un_parse_json_field "$entry" "ver")"
  local idx_root="$(_un_parse_json_field "$entry" "root")"
  [[ -n "$idx_root" && "$idx_root" == "$root" ]] || { un_err "pacote foi instalado com root='$idx_root'; use --root $idx_root"; return 2; }

  _un_make_logdir_for_pkg "$cat" "$name" "$ver"

  # Hooks pré-sistema (uma vez) e pré-pacote
  _un_hooks_run pre system || { un_err "hook pre-uninstall-system falhou"; return 4; }
  _un_hooks_run pre pkg "$cat" "$name" "$ver" || { un_err "hook pre-uninstall-pkg falhou"; return 4; }

  # Construir plano (usa manifest + ownership)
  _un_build_removal_plan "$cat" "$name" "$ver" || return $?

  # Dry-run
  if [[ "$dry_run" == "true" ]]; then
    echo "Dry-run — plano para remover $cat/$name@$ver em root=$root"
    echo "  arquivos: ${#U_PLAN_FILES[@]}"
    echo "  configs:  ${#U_PLAN_CONFIGS[@]} (purge_config=$( [[ "$purge_config" == "true" ]] && echo on || echo off ))"
    echo "  dirs:     ${#U_PLAN_DIRS[@]} (apenas se vazios)"
    echo "  protegidos: ${#U_PLAN_SKIP_PROTECTED[@]}"
    echo "  compartilhados: ${#U_PLAN_SKIP_SHARED[@]} (force_shared=$( [[ "$force_shared" == "true" ]] && echo on || echo off ))"
    echo "  ausentes: ${#U_PLAN_SKIP_MISSING[@]}"
    _un_lock_release
    trap - EXIT
    return 0
  fi

  # Confirmação se não --yes
  if [[ "$yes" != "true" ]]; then
    read -r -p "Remover $cat/$name@$ver? (y/N) " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || { un_warn "cancelado pelo usuário"; _un_lock_release; trap - EXIT; return 0; }
  fi

  # Executar remoção
  adm_step "$name" "$ver" "removendo arquivos"
  _un_exec_removal_with_tomb || { _un_rollback; echo "veja: $(_un_log_path remove)"; return $?; }

  # Triggers pós-remoção (coletar do pacote + heurística não trivial fica para futuro)
  local trg_list; trg_list="$(_un_triggers_collect_for_pkg "$cat" "$name" "$ver")"
  adm_step "triggers" "" "executando"
  _un_triggers_run "$trg_list" "$(_un_log_path triggers)" || un_warn "falhas em triggers"

  # Atualizar ownership, índice e estado
  _un_update_ownership_after_removal "$cat" "$name" "$ver"
  _un_post_state_cleanup "$cat" "$name" "$ver"
  _un_history_append "$cat" "$name" "$ver" "${#U_PLAN_FILES[@]}" "${#U_PLAN_SKIP_PROTECTED[@]}" "${U_CTX[force_shared]}"

  # Hooks pós
  _un_hooks_run post pkg "$cat" "$name" "$ver" || un_warn "hook post-uninstall-pkg falhou"
  _un_hooks_run post system || un_warn "hook post-uninstall-system falhou"

  adm_ok "removido: $cat/$name@$ver"
  _un_cleanup_tomb
  _un_lock_release
  trap - EXIT
  return 0
}

###############################################################################
# AUTOREMOVE (órfãos)
###############################################################################
_un_resolver_available() {
  command -v adm_resolve_plan >/dev/null 2>&1
}

_un_load_index_all() {
  local idx="$(_un_index_path)"
  [[ -r "$idx" ]] || return 1
  cat "$idx"
}

_un_compute_orphans() {
  # Computa órfãos: retorna linhas JSON de pacotes órfãos
  local idx="$(_un_index_path)"
  [[ -r "$idx" ]] || return 1

  # separar explicit vs deps
  local explicit deps
  explicit="$(grep -F '"reason":"explicit"' "$idx" || true)"
  deps="$(grep -F '"reason":"dep"' "$idx" || true)"

  # coletar necessários (fecho transitivo) usando resolver se disponível
  declare -A NECESSARY=()

  if _un_resolver_available; then
    # para cada explicit, pedir plano e coletar cat/name@ver dos deps
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local cat name ver
      cat="$(_un_parse_json_field "$line" "cat")"
      name="$(_un_parse_json_field "$line" "name")"
      ver="$(_un_parse_json_field "$line" "ver")"
      NECESSARY["$cat/$name@$ver"]=1
      local plan
      plan="$(adm_resolve_plan "$cat" "$name" --version "$ver" --installed-only 2>/dev/null || true)"
      if [[ -n "$plan" ]]; then
        # extrair cat/name@ver das linhas STEP
        while IFS= read -r s; do
          [[ "$s" =~ ^STEP ]] || continue
          local cn; cn="$(awk '{print $3}' <<<"$s")"
          [[ -n "$cn" ]] && NECESSARY["$cn"]=1
        done <<<"$plan"
      fi
    done <<<"$explicit"
  else
    un_warn "resolver não disponível — autoremove será conservador"
    # sem resolver, consideramos apenas os explicit como necessários
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local cat name ver
      cat="$(_un_parse_json_field "$line" "cat")"
      name="$(_un_parse_json_field "$line" "name")"
      ver="$(_un_parse_json_field "$line" "ver")"
      NECESSARY["$cat/$name@$ver"]=1
    done <<<"$explicit"
  fi

  # ÓRFÃOS: deps que não estejam em NECESSARY
  local orphans=""
  while IFS= read -r dline; do
    [[ -z "$dline" ]] && continue
    local c n v key
    c="$(_un_parse_json_field "$dline" "cat")"
    n="$(_un_parse_json_field "$dline" "name")"
    v="$(_un_parse_json_field "$dline" "ver")"
    key="$c/$n@$v"
    if [[ -z "${NECESSARY[$key]:-}" ]]; then
      orphans+="$dline"$'\n'
    fi
  done <<<"$deps"

  printf "%s" "$orphans"
}

adm_uninstall_autoremove() {
  local root="/" dry_run=true yes=false keep_list="" depth=999 explicit_roots=""
  local no_hooks=false no_triggers=true purge_config=false backup_removed=false force=false force_shared=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root) root="$2"; shift 2;;
      --dry-run|--pretend) dry_run=true; shift;;
      --yes) yes=true; dry_run=false; shift;;
      --keep) keep_list="${keep_list:+$keep_list,}$2"; shift 2;;
      --depth) depth="$2"; shift 2;;
      --explicit-as-root) explicit_roots="${explicit_roots:+$explicit_roots,}$2"; shift 2;;
      --no-hooks) no_hooks=true; shift;;
      --no-triggers) no_triggers=true; shift;;
      --purge-config) purge_config=true; shift;;
      --backup-removed) backup_removed=true; shift;;
      --force) force=true; shift;;
      --force-shared) force_shared=true; shift;;
      *) un_warn "opção desconhecida: $1"; shift;;
    esac
  done

  U_CTX[root]="$root"; U_CTX[dry_run]="$dry_run"; U_CTX[yes]="$yes"
  U_CTX[no_hooks]="$no_hooks"; U_CTX[no_triggers]="$no_triggers"
  U_CTX[purge_config]="$purge_config"; U_CTX[backup_removed]="$backup_removed"
  U_CTX[force]="$force"; U_CTX[force_shared]="$force_shared"

  _un_check_root_perm || return $?
  _un_lock_acquire || return $?
  trap '_un_lock_release' EXIT

  local round=0
  while (( round < depth )); do
    round=$((round+1))
    local orphans; orphans="$(_un_compute_orphans)"
    if [[ -z "$orphans" ]]; then
      echo "autoremove: nenhum órfão encontrado (após $((round-1)) rodada(s))"
      break
    fi

    echo "Órfãos detectados (rodada $round):"
    printf "%s\n" "$orphans"

    if [[ "$dry_run" == "true" ]]; then
      echo "Dry-run: nada será removido nesta rodada."
      break
    fi

    if [[ "$yes" != "true" ]]; then
      read -r -p "Remover todos os órfãos listados? (y/N) " ans
      [[ "$ans" == "y" || "$ans" == "Y" ]] || { un_warn "cancelado pelo usuário"; break; }
    fi

    # Remover em ordem simples (ideal seria toposort reverso via resolver; se disponível, delegar)
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local c n v
      c="$(_un_parse_json_field "$line" "cat")"
      n="$(_un_parse_json_field "$line" "name")"
      v="$(_un_parse_json_field "$line" "ver")"
      adm_uninstall_pkg "$c" "$n" --version "$v" --root "$root" --yes \
        ${no_hooks:+--no-hooks} ${no_triggers:+--no-triggers} \
        ${purge_config:+--purge-config} ${backup_removed:+--backup-removed} \
        ${force:+--force} ${force_shared:+--force-shared} || {
          un_err "falha ao remover órfão $c/$n@$v — interrompendo rodada"
          _un_lock_release; trap - EXIT; return 4;
        }
    done <<<"$(printf "%s" "$orphans")"
    # continua para próxima rodada se ainda houver órfãos
  done

  _un_lock_release
  trap - EXIT
  return 0
}

###############################################################################
# CLI
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="$1"; shift || true
  case "$cmd" in
    pkg)        adm_uninstall_pkg "$@" || exit $?;;
    autoremove) adm_uninstall_autoremove "$@" || exit $?;;
    list)       adm_uninstall_list "${1:-all}" || exit $?;;
    why)        adm_uninstall_why "$@" || exit $?;;
    *)
      echo "uso:" >&2
      echo "  $0 pkg <cat> <name> [--version V] [--root R] [--dry-run|--yes] [--no-hooks] [--no-triggers] [--purge-config] [--backup-removed]" >&2
      echo "           [--protect-regex RX] [--keep-globs \"glob1,glob2\"] [--force] [--force-shared]" >&2
      echo "  $0 autoremove [--root R] [--yes] [--no-hooks] [--no-triggers] [--purge-config] [--backup-removed] [--force] [--force-shared]" >&2
      echo "  $0 list [--all|--explicit|--deps]" >&2
      echo "  $0 why <cat> <name> [--version V]" >&2
      exit 2;;
  esac
fi

ADM_UNINSTALL_LOADED=1
export ADM_UNINSTALL_LOADED
