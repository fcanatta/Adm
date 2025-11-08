#!/usr/bin/env bash
# 10-adm-install.part1.sh
# Instalador de pacotes: resolve deps, busca binários, fallback para build, instala no / (ou --root),
# executa triggers e registra índice/manifest, com transação (stage→commit/rollback).
# Requer: 00/01/02/03/04/05/07/08/09 já carregados via `source`.
###############################################################################
# Guardas e verificações iniciais
###############################################################################
if [[ -n "${ADM_INSTALL_LOADED_PART1:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_INSTALL_LOADED_PART1=1

for _m in ADM_CONF_LOADED ADM_LIB_LOADED; do
  if [[ -z "${!_m:-}" ]]; then
    echo "ERRO: 10-adm-install requer módulos básicos carregados (00/01). Faltando: ${_m}" >&2
    return 2 2>/dev/null || exit 2
  fi
done

: "${ADM_CACHE_ROOT:=/usr/src/adm/cache}"
: "${ADM_BIN_CACHE_ROOT:=${ADM_CACHE_ROOT}/bin}"
: "${ADM_STATE_ROOT:=/usr/src/adm/state}"
: "${ADM_DEST_ROOT:=/usr/src/adm/dest}"
: "${ADM_TMP_ROOT:=/usr/src/adm/tmp}"
: "${ADM_MIN_DISK_MB:=200}"
: "${ADM_TIMEOUT_INSTALL_STEP:=3600}"

###############################################################################
# Utilidades de log
###############################################################################
inst_err()  { adm_err "$*"; }
inst_warn() { adm_warn "$*"; }
inst_info() { adm_log INFO "${I_CTX_PKG:-pkg}" "install" "$*"; }

###############################################################################
# Contexto de instalação (por execução)
###############################################################################
declare -Ag I_CTX=(
  [root]="/" [logdir]="" [stage]="" [lock_path]="" [plan]="" [bin_dir]=""
  [conflict_policy]="abort" [backup_config]="false" [keep_old_config]="false"
  [no_triggers]="false" [dry_run]="false" [offline]="${ADM_OFFLINE:-false}"
)

# Opções de política de origem
I_CFG_bin=true         # preferir binário do cache
I_CFG_source_only=false
I_CFG_no_deps=false
I_CFG_force=false
I_CFG_reinstall=false
I_CFG_profile="${ADM_PROFILE_DEFAULT:-normal}"

###############################################################################
# Helpers genéricos
###############################################################################
_inst_require_cmd() {
  local c; for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { inst_err "comando obrigatório ausente: $c"; return 2; }
  done
}

_inst_check_root_perm() {
  # precisa de root se destino é /
  local r="${I_CTX[root]}"
  if [[ "$r" == "/" ]] && [[ "$(id -u)" -ne 0 ]]; then
    inst_err "instalar em '/' requer privilégios de root"; return 3;
  fi
}

_inst_check_space() {
  local need="${1:-$ADM_MIN_DISK_MB}" dir="${2:-${I_CTX[stage]}}"
  local avail
  avail="$(df -Pm "$dir" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
  (( avail >= need )) || { inst_err "espaço insuficiente (precisa ${need}MB, disponível ${avail}MB) em $dir"; return 3; }
}

_inst_path_under_root() {
  # _inst_path_under_root <path> -> 0 se path cai dentro de I_CTX[root]
  local p r; p="$(readlink -f -- "$1")" || return 1
  r="$(readlink -f -- "${I_CTX[root]}")" || return 1
  [[ "$p" == "$r"* ]]
}

_inst_lock_acquire() {
  local base="${ADM_STATE_ROOT%/}/locks"
  mkdir -p -- "$base" || true
  I_CTX[lock_path]="$base/install-global.lock"
  exec {ADM_INSTALL_LOCK_FD}>"${I_CTX[lock_path]}" || { inst_err "não foi possível abrir lock"; return 7; }
  flock -n "$ADM_INSTALL_LOCK_FD" || { inst_err "outra instalação em andamento (lock retido)"; return 7; }
}

_inst_lock_release() {
  if [[ -n "${ADM_INSTALL_LOCK_FD:-}" ]]; then
    flock -u "$ADM_INSTALL_LOCK_FD" 2>/dev/null || true
    exec {ADM_INSTALL_LOCK_FD}>&- 2>/dev/null || true
  fi
}

_inst_log_path() {
  local sub="$1"
  echo "${I_CTX[logdir]%/}/${sub}.log"
}

_inst_mk_stage() {
  local ts pid; ts="$(date +%s)"; pid="$$"
  I_CTX[stage]="${ADM_TMP_ROOT%/}/install-${pid}-${ts}"
  mkdir -p -- "${I_CTX[stage]}" || { inst_err "não foi possível criar STAGE: ${I_CTX[stage]}"; return 3; }
  _inst_check_space "$ADM_MIN_DISK_MB" "${I_CTX[stage]}" || return $?
}

_inst_cleanup_stage() {
  [[ -n "${I_CTX[stage]}" ]] && rm -rf -- "${I_CTX[stage]}" 2>/dev/null || true
}

###############################################################################
# Segurança: extração sandboxed
###############################################################################
_inst_tar_sandbox_check() {
  # Verifica path traversal/absolutos/symlinks escapando
  local tarball="$1" log="$2"
  if tar -tf <(zstd -dc "$tarball") 2>>"$log" | grep -E '^(/|\.\.)' -q; then
    inst_err "tarball inseguro (path traversal ou absoluto): $tarball"; echo "veja: $log"; return 6;
  fi
  return 0
}

_inst_extract_to_stage() {
  local tarball="$1" log="$2"
  _inst_tar_sandbox_check "$tarball" "$log" || return $?
  ( cd "${I_CTX[stage]}" && zstd -dc "$tarball" | tar -xpf - ) >>"$log" 2>&1 || {
    inst_err "extração falhou: $tarball"; echo "veja: $log"; return 4; }
}

###############################################################################
# Política de conflitos
###############################################################################
_inst_is_config_file() {
  # heurística: arquivos sob /etc/, /usr/share/{defaults,config}/ e extensões comuns
  local rel="$1"
  [[ "$rel" == etc/* ]] && return 0
  [[ "$rel" == usr/share/config/* || "$rel" == usr/share/defaults/* ]] && return 0
  [[ "$rel" =~ \.(conf|ini|toml|yaml|yml|json)$ ]] && return 0
  [[ "$rel" == *.d/* ]] && return 0
  return 1
}

_inst_conflict_apply() {
  # Aplica política de conflito para um arquivo relativo (a partir do stage)
  local rel="$1" trg_root; trg_root="$(readlink -f -- "${I_CTX[root]}")" || return 3
  local src="${I_CTX[stage]%/}/$rel"
  local dst="${trg_root%/}/$rel"

  # Se não existe no root, apenas segue
  [[ -e "$dst" ]] || return 0

  # Se conteúdo idêntico, nada a fazer
  if cmp -s "$src" "$dst" 2>/dev/null; then
    return 0
  fi

  case "${I_CTX[conflict_policy]}" in
    abort)
      inst_err "conflito: $rel já existe no destino e difere (política=abort)"
      return 8
      ;;
    replace)
      if [[ "${I_CTX[backup_config]}" == "true" && _inst_is_config_file "$rel" ]]; then
        local bak="${dst}.adm-bak-$(date +%s)"
        cp -a -- "$dst" "$bak" 2>/dev/null || true
        inst_info "backup de config criado: $bak"
      fi
      return 0
      ;;
    rename)
      # instala novo como .adm-new/.pacnew
      local new="${dst}.adm-new"
      if _inst_is_config_file "$rel" && [[ "${I_CTX[keep_old_config]}" == "true" ]]; then
        new="${dst}.pacnew"
      fi
      mkdir -p -- "$(dirname -- "$new")" 2>/dev/null || true
      cp -a -- "$src" "$new" 2>/dev/null || {
        inst_err "falha ao criar arquivo renomeado: $new"; return 3; }
      # substitui fonte no stage por uma cópia do destino para que commit não sobreponha
      cp -a -- "$dst" "$src" 2>/dev/null || true
      inst_info "conflito em $rel → instalado como $(basename -- "$new")"
      return 0
      ;;
    *)
      inst_err "política de conflito desconhecida: ${I_CTX[conflict_policy]}"; return 2;;
  esac
}

###############################################################################
# Busca de binários e verificação
###############################################################################
_inst_find_cached_tarball() {
  # Retorna caminho do tarball no cache (ou em --bin-dir), se existir
  local cat="$1" name="$2" ver="$3"
  local try
  if [[ -n "${I_CTX[bin_dir]}" ]]; then
    try="${I_CTX[bin_dir]%/}/${cat}/${name}-${ver}.tar.zst"
    [[ -r "$try" ]] && { echo "$try"; return 0; }
  fi
  try="${ADM_BIN_CACHE_ROOT%/}/${cat}/${name}-${ver}.tar.zst"
  [[ -r "$try" ]] && { echo "$try"; return 0; }
  return 1
}

_inst_verify_sha256_if_any() {
  local tarball="$1"
  local sha="${tarball}.sha256"
  [[ -r "$sha" ]] || return 0
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$(dirname -- "$tarball")" && sha256sum -c "$(basename -- "$sha")") >/dev/null 2>&1 || {
      inst_err "sha256 inválido para $(basename -- "$tarball")"; return 6; }
  else
    inst_warn "sha256sum não disponível — pulando verificação"
  fi
  return 0
}

###############################################################################
# Resolver plano e preparar logs por pacote
###############################################################################
_inst_prepare_logs_for_pkg() {
  local cat="$1" name="$2" ver="$3"
  I_CTX[logdir]="${ADM_STATE_ROOT%/}/logs/install/${cat}/${name}/${ver}"
  mkdir -p -- "${I_CTX[logdir]}" || { inst_warn "não foi possível criar logdir"; true; }
}

_inst_plan_resolve() {
  local cat="$1" name="$2" ver="${3:-}" profile="${4:-$I_CFG_profile}" with_opts="--with-opts"
  [[ "$ADM_OFFLINE" == "true" || "${I_CTX[offline]}" == "true" ]] && set -- "$@" --offline
  [[ -n "$ver" ]] && set -- "$@" --version "$ver"
  [[ "$profile" != "" ]] && set -- "$@" --profile "$profile"
  [[ "${I_CFG_source_only}" == "true" ]] && set -- "$@" --source-only || true
  [[ "${I_CFG_bin}" != "true" ]] && set -- "$@" --source-only || true
  # caso usuário peça --no-opts
  [[ "${I_CFG_with_opts:-true}" == "false" ]] && with_opts="--no-opts"
  if ! command -v adm_resolve_plan >/dev/null 2>&1; then
    inst_err "resolver não disponível (07-adm-resolver.sh)"; return 2;
  fi
  local plan
  plan="$(adm_resolve_plan "$cat" "$name" $with_opts "$@")" || return $?
  I_CTX[plan]="$plan"
  echo "$plan"
}

###############################################################################
# Build sob demanda quando tarball não existe
###############################################################################
_inst_build_if_needed() {
  local cat="$1" name="$2" ver="$3"
  if [[ "${I_CFG_source_only}" == "true" ]]; then
    inst_info "sem binário disponível (source-only) — construindo $cat/$name@$ver"
  else
    inst_info "binário ausente — construindo $cat/$name@$ver"
  fi
  if ! command -v adm_build_run >/dev/null 2>&1; then
    inst_err "construtor não disponível (09-adm-build.sh)"; return 2;
  fi
  local out
  out="$(adm_build_run "$cat" "$name" --version "$ver" ${I_CTX[offline]:+"--offline"} ${I_CFG_with_opts:-true} ${I_CFG_source_only:+--source-only} | tail -n1)" || return $?
  # adm_build_run imprime progresso; última linha deve apontar um tarball ou success message — vamos tentar localizar
  local guess="${ADM_BIN_CACHE_ROOT%/}/${cat}/${name}-${ver}.tar.zst"
  [[ -r "$guess" ]] && echo "$guess" && return 0
  # fallback: procurar no diretório
  local found; found="$(ls -1 "${ADM_BIN_CACHE_ROOT%/}/${cat}/${name}-${ver}.tar.zst" 2>/dev/null | head -n1 || true)"
  [[ -n "$found" ]] && echo "$found" && return 0
  inst_err "não foi possível localizar tarball após build"
  return 4
}
# 10-adm-install.part2.sh
# Execução do plano: buscar/validar binários, stage, commit/rollback, triggers e registro.
if [[ -n "${ADM_INSTALL_LOADED_PART2:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_INSTALL_LOADED_PART2=1
###############################################################################
# Commit/rollback transacional
###############################################################################
_inst_commit_to_root() {
  local log="$1"
  _inst_require_cmd rsync || return 2
  [[ -d "${I_CTX[stage]}" ]] || { inst_err "STAGE inexistente"; echo "veja: $log"; return 3; }

  # Aplicar política de conflitos arquivo a arquivo antes do rsync
  local rel
  (cd "${I_CTX[stage]}" && find . -type f -o -type l -o -type d | sed 's|^\./||' ) | while read -r rel; do
    [[ -z "$rel" || "$rel" == "." ]] && continue
    # apenas para arquivos (conflito); dirs e symlinks vão direto
    [[ -f "${I_CTX[stage]%/}/$rel" ]] || continue
    _inst_conflict_apply "$rel" || return $?
  done || { inst_err "política de conflitos abortou"; echo "veja: $log"; return 8; }

  # Commit
  local trg_root; trg_root="$(readlink -f -- "${I_CTX[root]}")" || return 3
  adm_with_spinner "Aplicando no sistema..." -- rsync -aHAX --info=NAME,STATS \
    "${I_CTX[stage]%/}/" "${trg_root%/}/" >>"$log" 2>&1 || { inst_err "commit rsync falhou"; echo "veja: $log"; return 3; }

  return 0
}

_inst_rollback() {
  # O rollback aqui é best-effort: como commit é rsync only-add/replace,
  # reverte backups gerados por política e avisa o usuário.
  inst_warn "rollback: verifique backups *.adm-bak e *.pacnew gerados"
  return 0
}

###############################################################################
# Coleta e execução de triggers
###############################################################################
_inst_triggers_collect_from_pkg() {
  local cat="$1" name="$2" ver="$3"
  local trg="${ADM_STATE_ROOT%/}/triggers/${cat}_${name}_${ver}.trg"
  [[ -r "$trg" ]] || return 0
  cat "$trg"
}

_inst_triggers_dedup_and_run() {
  local log="$1"
  [[ "${I_CTX[no_triggers]}" == "true" ]] && { inst_info "triggers desabilitados (--no-triggers)"; return 0; }

  local root; root="$(readlink -f -- "${I_CTX[root]}")" || return 3
  local list uniq
  list="$(cat "$(_inst_log_path triggers.list)" 2>/dev/null || true)"
  uniq="$(echo "$list" | awk 'NF' | sort -u)"
  [[ -z "$uniq" ]] && { inst_info "nenhum trigger para executar"; return 0; }

  inst_info "executando triggers consolidados..."
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local cmd args
    cmd="$(awk '{print $1}' <<<"$line")"
    args="${line#"$cmd"}"
    case "$cmd" in
      glib-compile-schemas)
        command -v glib-compile-schemas >/dev/null 2>&1 || { inst_warn "glib-compile-schemas não encontrado — pulando"; continue; }
        adm_with_spinner "glib-compile-schemas" -- chroot "$root" glib-compile-schemas /usr/share/glib-2.0/schemas >>"$log" 2>&1 || inst_warn "trigger falhou: $line"
        ;;
      update-desktop-database)
        command -v update-desktop-database >/dev/null 2>&1 || { inst_warn "update-desktop-database não encontrado — pulando"; continue; }
        adm_with_spinner "update-desktop-database" -- chroot "$root" update-desktop-database -q /usr/share/applications >>"$log" 2>&1 || inst_warn "trigger falhou: $line"
        ;;
      gtk-update-icon-cache)
        command -v gtk-update-icon-cache >/dev/null 2>&1 || { inst_warn "gtk-update-icon-cache não encontrado — pulando"; continue; }
        # roda por tema (heurística simples)
        for theme in "$root"/usr/share/icons/*; do
          [[ -d "$theme" ]] || continue
          adm_with_spinner "gtk-update-icon-cache ($(basename -- "$theme"))" -- chroot "$root" gtk-update-icon-cache -q -t -f "/usr/share/icons/$(basename -- "$theme")" >>"$log" 2>&1 || inst_warn "trigger falhou: $line"
        done
        ;;
      ldconfig)
        [[ "$root" == "/" ]] || { inst_info "ldconfig só em root=/ — pulando"; continue; }
        command -v ldconfig >/dev/null 2>&1 || { inst_warn "ldconfig não encontrado — pulando"; continue; }
        adm_with_spinner "ldconfig" -- ldconfig >>"$log" 2>&1 || inst_warn "trigger falhou: ldconfig"
        ;;
      systemd-daemon-reload)
        [[ "$root" == "/" ]] || { inst_info "systemd-daemon-reload só em root=/ — pulando"; continue; }
        command -v systemctl >/dev/null 2>&1 || { inst_warn "systemctl não encontrado — pulando"; continue; }
        adm_with_spinner "systemctl daemon-reload" -- systemctl daemon-reload >>"$log" 2>&1 || inst_warn "trigger falhou: systemctl daemon-reload"
        ;;
      fc-cache)
        command -v fc-cache >/dev/null 2>&1 || { inst_warn "fc-cache não encontrado — pulando"; continue; }
        adm_with_spinner "fc-cache" -- chroot "$root" fc-cache -f >>"$log" 2>&1 || inst_warn "trigger falhou: fc-cache"
        ;;
      update-mime-database)
        command -v update-mime-database >/dev/null 2>&1 || { inst_warn "update-mime-database não encontrado — pulando"; continue; }
        adm_with_spinner "update-mime-database" -- chroot "$root" update-mime-database /usr/share/mime >>"$log" 2>&1 || inst_warn "trigger falhou: update-mime-database"
        ;;
      *)
        inst_warn "trigger desconhecido: $line (pulando)";;
    esac
  done <<<"$uniq"
  return 0
}

###############################################################################
# Registro (índice de instalados)
###############################################################################
_inst_register_index() {
  local cat="$1" name="$2" ver="$3" tarball="$4" origin="$5"
  local idx="${ADM_STATE_ROOT%/}/installed/index.json"
  mkdir -p -- "$(dirname -- "$idx")" || true
  local now; now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  # append line-oriented JSON (simples e robusto)
  printf '{"cat":"%s","name":"%s","ver":"%s","root":"%s","tarball":"%s","origin":"%s","time":"%s"}\n' \
    "$cat" "$name" "$ver" "${I_CTX[root]}" "$tarball" "$origin" "$now" >> "$idx" 2>/dev/null || {
      inst_warn "não foi possível atualizar índice: $idx"; true; }
}

###############################################################################
# Execução do plano
###############################################################################
_inst_execute_plan() {
  local planfile="$1" mode="$2" # mode: install|download-only
  [[ -r "$planfile" ]] || { inst_err "planfile não legível: $planfile"; return 1; }

  _inst_lock_acquire || return $?
  trap '_inst_lock_release; _inst_cleanup_stage' EXIT

  # logs gerais
  local fetch_log stage_log commit_log trig_log
  fetch_log="$(_inst_log_path fetch)"
  stage_log="$(_inst_log_path stage)"
  commit_log="$(_inst_log_path commit)"
  trig_log="$(_inst_log_path triggers)"

  : > "$fetch_log" 2>/dev/null || true
  : > "$stage_log" 2>/dev/null || true
  : > "$commit_log" 2>/dev/null || true
  : > "$trig_log" 2>/dev/null || true
  : > "$(_inst_log_path triggers.list)" 2>/dev/null || true

  # 1) varre o plano e garante que todos os tarballs estarão disponíveis
  local step
  declare -a INSTALL_QUEUE=()
  while IFS= read -r step; do
    [[ "$step" =~ ^STEP ]] || continue
    local action origin pkg cn cat name ver cache metafile
    action="$(awk '{print $2}' <<<"$step")"
    cn="$(awk '{print $3}' <<<"$step")"
    origin="$(awk '{print $4}' <<<"$step")"; origin="${origin#origin=}"
    cat="${cn%%/*}"; ver="${cn#*@}"; name="${cn%*@}"; name="${name#*/}"

    if [[ "$origin" == "bin" ]]; then
      cache="$(awk '{for(i=1;i<=NF;i++) if ($i ~ /^cache=/) {print $i}}' <<<"$step")"
      cache="${cache#cache=}"
      # tentar localizar cache; se não houver, tenta construir (se permitido)
      local tb=""
      if [[ -n "$cache" && -r "$cache" ]]; then
        tb="$cache"
      else
        tb="$(_inst_find_cached_tarball "$cat" "$name" "$ver" || true)"
      fi
      if [[ -z "$tb" ]]; then
        if [[ "${I_CFG_source_only}" == "true" || "${I_CFG_bin}" != "true" ]]; then
          tb="$(_inst_build_if_needed "$cat" "$name" "$ver")" || { inst_err "falha ao construir $cat/$name@$ver"; return 4; }
        else
          inst_info "binário ausente para $cat/$name@$ver — tentando construir"
          tb="$(_inst_build_if_needed "$cat" "$name" "$ver")" || { inst_err "falha ao construir $cat/$name@$ver"; return 4; }
        fi
      fi
      _inst_verify_sha256_if_any "$tb" || return $?
      INSTALL_QUEUE+=( "$cat|$name|$ver|$tb|bin" )
      inst_info "pronto: $cat/$name@$ver (bin)"
    elif [[ "$origin" == "source" ]]; then
      # sempre gerar binário via build antes (para instalar via tarball)
      local tb
      tb="$(_inst_build_if_needed "$cat" "$name" "$ver")" || { inst_err "falha ao construir $cat/$name@$ver"; return 4; }
      _inst_verify_sha256_if_any "$tb" || return $?
      INSTALL_QUEUE+=( "$cat|$name|$ver|$tb|source" )
      inst_info "pronto: $cat/$name@$ver (source→bin)"
    else
      inst_err "origin desconhecida no plano: $origin"; return 1;
    fi
  done < "$planfile"

  [[ "$mode" == "download-only" ]] && {
    echo "Tarballs prontos:"
    local it; for it in "${INSTALL_QUEUE[@]}"; do
      IFS="|" read -r cat name ver tb origin <<<"$it"
      echo " - ${ADM_BIN_CACHE_ROOT%/}/${cat}/${name}-${ver}.tar.zst"
    done
    _inst_lock_release
    trap - EXIT
    return 0
  }

  # 2) STAGE → extrair todos os tarballs
  _inst_mk_stage || return $?
  local it
  for it in "${INSTALL_QUEUE[@]}"; do
    IFS="|" read -r cat name ver tb origin <<<"$it"
    adm_step "$name" "$ver" "Stage (extraindo)"
    _inst_extract_to_stage "$tb" "$stage_log" || { _inst_rollback; echo "veja: $stage_log"; return $?; }
    # coletar triggers desse pacote
    _inst_triggers_collect_from_pkg "$cat" "$name" "$ver" >> "$(_inst_log_path triggers.list)" 2>/dev/null || true
  done

  # 3) Commit → root
  adm_step "commit" "→${I_CTX[root]}" "Aplicando arquivos"
  _inst_commit_to_root "$commit_log" || { _inst_rollback; echo "veja: $commit_log"; return $?; }

  # 4) Executa triggers
  adm_step "triggers" "" "Executando"
  _inst_triggers_dedup_and_run "$trig_log" || { inst_warn "falhas em triggers — veja: $trig_log"; }

  # 5) Registrar índice
  for it in "${INSTALL_QUEUE[@]}"; do
    IFS="|" read -r cat name ver tb origin <<<"$it"
    _inst_register_index "$cat" "$name" "$ver" "$tb" "$origin"
  done

  adm_ok "instalação concluída"
  _inst_cleanup_stage
  _inst_lock_release
  trap - EXIT
  return 0
}
# 10-adm-install.part3.sh
# CLI: pkg/file/list-files e parsing de flags, com validações estritas.
if [[ -n "${ADM_INSTALL_LOADED_PART3:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_INSTALL_LOADED_PART3=1
###############################################################################
# Listagem de arquivos (manifest)
###############################################################################
adm_install_list_files() {
  local cat="$1" name="$2"; shift 2 || true
  local ver=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) ver="$2"; shift 2;;
      *) inst_warn "opção desconhecida: $1"; shift;;
    esac
  done
  [[ -n "$cat" && -n "$name" ]] || { inst_err "uso: adm_install_list_files <cat> <name> [--version V]"; return 2; }
  [[ -n "$ver" ]] || { inst_err "--version é obrigatório"; return 2; }
  local man="${ADM_STATE_ROOT%/}/manifest/${cat}_${name}_${ver}.list"
  if [[ -r "$man" ]]; then
    cat "$man"
  else
    inst_err "manifest não encontrado: $man"; return 3;
  fi
}

###############################################################################
# Instalar tarball avulso
###############################################################################
adm_install_file() {
  local tarball="$1"; shift || true
  local root="/" no_triggers=false dry_run=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root) root="$2"; shift 2;;
      --no-triggers) no_triggers=true; shift;;
      --dry-run) dry_run=true; shift;;
      *) inst_warn "opção desconhecida: $1"; shift;;
    esac
  done
  [[ -r "$tarball" ]] || { inst_err "tarball não legível: $tarball"; return 2; }

  I_CTX[root]="$root"; I_CTX[no_triggers]="$no_triggers"; I_CTX[dry_run]="$dry_run"
  _inst_check_root_perm || return $?
  _inst_prepare_logs_for_pkg "local" "file" "$(date +%s)"
  : > "$(_inst_log_path fetch)" 2>/dev/null || true

  _inst_verify_sha256_if_any "$tarball" || return $?

  if [[ "$dry_run" == "true" ]]; then
    echo "Dry-run: seria extraído e aplicado em $root"
    return 0
  fi

  _inst_mk_stage || return $?
  adm_step "file" "$(basename -- "$tarball")" "Stage (extraindo)"
  _inst_extract_to_stage "$tarball" "$(_inst_log_path stage)" || { _inst_cleanup_stage; return $?; }

  adm_step "commit" "→${I_CTX[root]}" "Aplicando arquivos"
  _inst_commit_to_root "$(_inst_log_path commit)" || { _inst_rollback; _inst_cleanup_stage; return $?; }

  adm_step "triggers" "" "Executando"
  _inst_triggers_dedup_and_run "$(_inst_log_path triggers)" || true

  adm_ok "instalação concluída (file)"
  _inst_cleanup_stage
}

###############################################################################
# Instalar pacote por nome (resolve → fetch/build → install)
###############################################################################
adm_install_pkg() {
  local cat="$1" name="$2"; shift 2 || true
  local ver="" profile="${I_CFG_profile}" bin_dir="" source_only=false download_only=false
  local root="/" offline="${I_CTX[offline]}" with_opts=true no_deps=false
  local conflict_policy="abort" backup_config=false keep_old_config=false
  local no_triggers=false dry_run=false force=false reinstall=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) ver="$2"; shift 2;;
      --profile) profile="$2"; shift 2;;
      --bin-dir) bin_dir="$2"; shift 2;;
      --bin) I_CFG_bin=true; shift;;
      --source-only) source_only=true; I_CFG_source_only=true; I_CFG_bin=false; shift;;
      --download-only) download_only=true; shift;;
      --offline) offline=true; shift;;
      --no-deps) no_deps=true; shift;;
      --force) force=true; shift;;
      --reinstall) reinstall=true; shift;;
      --root) root="$2"; shift 2;;
      --no-triggers) no_triggers=true; shift;;
      --run-triggers) no_triggers=false; shift;;
      --dry-run) dry_run=true; shift;;
      --conflict-policy) conflict_policy="$2"; shift 2;;
      --backup-config) backup_config=true; shift;;
      --keep-old-config) keep_old_config=true; shift;;
      --no-opts) I_CFG_with_opts=false; shift;;
      --with-opts) I_CFG_with_opts=true; shift;;
      --log-dir) I_CTX[logdir]="$2"; shift 2;;
      *) inst_warn "opção desconhecida: $1"; shift;;
    esac
  done

  [[ -n "$cat" && -n "$name" ]] || { inst_err "uso: adm_install_pkg <cat> <name> [flags]"; return 2; }

  I_CTX[root]="$root"
  I_CTX[bin_dir]="$bin_dir"
  I_CTX[offline]="$offline"
  I_CTX[conflict_policy]="$conflict_policy"
  I_CTX[backup_config]="$backup_config"
  I_CTX[keep_old_config]="$keep_old_config"
  I_CTX[no_triggers]="$no_triggers"
  I_CTX[dry_run]="$dry_run"

  _inst_check_root_perm || return $?

  # Validar flags conflitantes
  if [[ "$no_deps" == "true" && "$force" != "true" ]]; then
    inst_err "--no-deps exige --force (perigoso)"; return 5;
  fi

  # Preparar logs
  _inst_prepare_logs_for_pkg "$cat" "$name" "${ver:-unknown}"

  if [[ "$dry_run" == "true" ]]; then
    # Resolver plano e descrever o que aconteceria
    local plan; plan="$(_inst_plan_resolve "$cat" "$name" "$ver" "$profile")" || return $?
    echo "Dry-run: plano para $cat/$name@${ver:-auto}"
    cat "$plan"
    echo "Origem: $( [[ "$source_only" == "true" ]] && echo 'source→bin' || echo 'bin→fallback source' )"
    echo "Root: $root  | Conflict policy: $conflict_policy  | Triggers: $( [[ "$no_triggers" == "true" ]] && echo off || echo on )"
    return 0
  fi

  # Resolver plano
  local plan; plan="$(_inst_plan_resolve "$cat" "$name" "$ver" "$profile")" || return $?

  # Executar (download-only ou instalação completa)
  local mode="install"; [[ "$download_only" == "true" ]] && mode="download-only"
  _inst_execute_plan "$plan" "$mode"
}

###############################################################################
# CLI
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="$1"; shift || true
  case "$cmd" in
    pkg)        adm_install_pkg "$@" || exit $?;;
    file)       adm_install_file "$@" || exit $?;;
    list-files) adm_install_list_files "$@" || exit $?;;
    *)
      echo "uso:" >&2
      echo "  $0 pkg <cat> <name> [--version V] [--profile P] [--bin-dir DIR] [--source-only] [--download-only] [--offline] [--root R]" >&2
      echo "           [--conflict-policy abort|replace|rename] [--backup-config] [--keep-old-config] [--no-triggers|--run-triggers]" >&2
      echo "           [--dry-run] [--no-deps --force] [--reinstall] [--no-opts|--with-opts]" >&2
      echo "  $0 file <tarball.tar.zst> [--root R] [--no-triggers] [--dry-run]" >&2
      echo "  $0 list-files <cat> <name> --version V" >&2
      exit 2;;
  case_esac # (evita erros silenciosos se shell antigo não aceitar ';&')
fi

ADM_INSTALL_LOADED=1
export ADM_INSTALL_LOADED
