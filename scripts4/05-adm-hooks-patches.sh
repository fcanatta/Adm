#!/usr/bin/env bash
# 05-adm-hooks-patches.part1.sh
# Execução de hooks e aplicação de patches; chroot helpers para bootstrap.
# Requer: 00-adm-config.sh, 01-adm-lib.sh, 04-adm-metafile.sh
###############################################################################
# Guardas e pré-requisitos
###############################################################################
if [[ -n "${ADM_HOOKS_LOADED_PART1:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_HOOKS_LOADED_PART1=1

if [[ -z "${ADM_CONF_LOADED:-}" ]]; then
  echo "ERRO: 05-adm-hooks-patches requer 00-adm-config.sh carregado." >&2
  return 2 2>/dev/null || exit 2
fi
if [[ -z "${ADM_LIB_LOADED:-}" ]]; then
  echo "ERRO: 05-adm-hooks-patches requer 01-adm-lib.sh carregado." >&2
  return 2 2>/dev/null || exit 2
fi
if [[ -z "${ADM_META_LOADED:-}" ]]; then
  echo "AVISO: 05-adm-hooks-patches foi carregado antes do 04-adm-metafile.sh; " \
       "funções que dependem de ADM_META_* exigem adm_meta_load/_pkg." >&2
fi

###############################################################################
# Configurações/Políticas (com defaults)
###############################################################################
: "${ADM_HOOK_TIMEOUT:=600}"        # 0 = sem timeout
: "${ADM_PATCH_STRATEGY:=auto}"     # auto|git|patch
: "${ADM_BOOTSTRAP_CHROOT:=false}"  # true|false
# Lista padrão de bind mounts ao entrar no chroot:
: "${ADM_CHROOT_BIND:=proc sys dev devpts run}"

###############################################################################
# Helpers internos de caminhos
###############################################################################
_hp_err()  { adm_err "$*"; }
_hp_warn() { adm_warn "$*"; }
_hp_info() { adm_log INFO "${ADM_META_NAME:-}" "hooks" "$*"; }

_hp_pkg_head() {
  local cat="${ADM_META_CAT:-}" name="${ADM_META_NAME:-}" ver="${ADM_META_VERSION:-}"
  local head=""
  if [[ -n "$cat" && -n "$name" && -n "$ver" ]]; then
    head="[$cat/$name $ver]"
  elif [[ -n "$name" && -n "$ver" ]]; then
    head="[$name $ver]"
  elif [[ -n "$name" ]]; then
    head="[$name]"
  fi
  printf "%s" "$head"
}

_hp_global_hooks_root()   { printf "%s/hooks" "$ADM_ROOT"; }
_hp_category_hooks_root() {
  local cat="${ADM_META_CAT:-}"
  [[ -z "$cat" ]] && { printf ""; return 0; }
  printf "%s/%s/.hooks" "${ADM_META_ROOT%/}" "$cat"
}
_hp_package_hooks_root()  {
  local base="${ADM_META_BASEDIR:-}"
  [[ -z "$base" ]] && { printf ""; return 0; }
  printf "%s/hooks" "${base%/}"
}

###############################################################################
# Coleta de hooks (ordem: global → categoria → pacote; arquivo .sh antes do .d)
###############################################################################
adm_hooks__collect() {
  # adm_hooks__collect <hook_name>
  local hook="$1"
  [[ -z "$hook" ]] && { _hp_err "hooks_collect: hook vazio"; return 2; }

  local roots=()
  roots+=( "$(_hp_global_hooks_root)" )
  local catdir; catdir="$(_hp_category_hooks_root)"; [[ -n "$catdir" ]] && roots+=( "$catdir" )
  local pkgdir; pkgdir="$(_hp_package_hooks_root)";  [[ -n "$pkgdir" ]] && roots+=( "$pkgdir" )

  local list=() r
  for r in "${roots[@]}"; do
    [[ -d "$r" ]] || continue
    # arquivo único
    if [[ -f "$r/${hook}.sh" ]]; then
      list+=( "$r/${hook}.sh" )
    fi
    # diretório .d
    if [[ -d "$r/${hook}.d" ]]; then
      local f
      shopt -s nullglob
      for f in "$r/${hook}.d"/*.sh; do
        list+=( "$f" )
      done
      shopt -u nullglob
      # ordenar lexicograficamente
      IFS=$'\n' list=($(printf "%s\n" "${list[@]}" | awk 'NF' | sort -u))
      IFS=' '
    fi
  done

  # imprime 1 por linha
  local x
  for x in "${list[@]}"; do
    printf "%s\n" "$x"
  done
  return 0
}

adm_hooks_have() {
  # adm_hooks_have <hook_name>
  local hook="$1"
  [[ -z "$hook" ]] && { _hp_err "hooks_have: hook vazio"; return 2; }
  local any
  any="$(adm_hooks__collect "$hook")" || return $?
  [[ -n "$any" ]]
}

adm_hooks_list() {
  # adm_hooks_list <hook_name>
  local hook="$1"
  [[ -z "$hook" ]] && { _hp_err "hooks_list: hook vazio"; return 2; }
  adm_hooks__collect "$hook"
}

###############################################################################
# Execução de um único script de hook com timeout/lock/log
###############################################################################
adm_hooks__run_one() {
  # adm_hooks__run_one <hook_name> <script_path>
  local hook="$1" script="$2"
  [[ -z "$hook" || -z "$script" ]] && { _hp_err "run_one: parâmetros ausentes"; return 2; }
  [[ -f "$script" ]] || { _hp_warn "hook ausente: $script (ignorado)"; return 1; }
  [[ -r "$script" ]] || { _hp_err "hook sem permissão de leitura: $script"; return 3; }

  local lock="hook-${ADM_META_NAME:-pkg}-${hook}"
  local cmd=( bash -euo pipefail "$script" )

  # Timeout se configurado e 'timeout' disponível
  local runner=( )
  if [[ "${ADM_HOOK_TIMEOUT}" -gt 0 ]] && command -v timeout >/dev/null 2>&1; then
    runner=( timeout --preserve-status --kill-after=5s "${ADM_HOOK_TIMEOUT}" )
  fi

  # Exporta ambiente mínimo para hooks
  export ADM_HOOK_NAME="$hook"
  export JOBS="${ADM_JOBS:-1}"

  adm_with_lock "$lock" -- bash -c '
    set -euo pipefail
    hook="$1"; script="$2"
    shift 2
    head="'"$(_hp_pkg_head)"'"
    adm_step "'"${ADM_META_NAME:-$ADM_LOG_PKG}"'" "'"${ADM_META_VERSION:-$ADM_LOG_VER}"'" "hook '$hook': $script"
    # Se não for executável, rodar com bash explicitamente (já fazemos)
    if [[ ! -x "$script" ]]; then
      true # apenas informativo
    fi
    # Execução com spinner
    adm_with_spinner "executando hook: $script" -- '"${runner[@]}"' '"${cmd[@]}"'
  ' bash "$hook" "$script"
}

###############################################################################
# Execução de todos os hooks de um ponto
###############################################################################
adm_hooks_run() {
  # adm_hooks_run <hook_name> [--allow-missing]
  local hook="$1"; shift || true
  [[ -z "$hook" ]] && { _hp_err "hooks_run: hook vazio"; return 2; }
  local allow_missing="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --allow-missing) allow_missing="true"; shift ;;
      *) _hp_warn "hooks_run: opção desconhecida $1 (ignorada)"; shift ;;
    esac
  done

  local scripts rc=0 had_any=0 s
  scripts="$(adm_hooks__collect "$hook")" || return $?
  if [[ -z "$scripts" ]]; then
    if [[ "$allow_missing" == "true" ]]; then
      _hp_info "nenhum hook encontrado para '$hook' (ok)"
      return 0
    fi
    _hp_warn "nenhum hook encontrado para '$hook'"
    return 1
  fi

  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    had_any=1
    if ! adm_hooks__run_one "$hook" "$s"; then
      rc=$?
      _hp_err "hook '$hook' falhou: $s (rc=$rc)"
      return $rc
    fi
  done <<< "$scripts"

  [[ $had_any -eq 1 ]] || { [[ "$allow_missing" == "true" ]] && return 0 || return 1; }
  return 0
}

###############################################################################
# Patches: listagem e aplicação
###############################################################################
adm_patches_list() {
  # Lista a ordem efetiva de patches (series > *.patch|*.diff)
  local pdir; pdir="$(adm_meta_patches_dir)"
  [[ -z "$pdir" ]] && { echo ""; return 0; }

  local series="${pdir%/}/series"
  if [[ -f "$series" ]]; then
    # Leitura do series (ignora linhas vazias/comentários)
    awk 'NF && $0 !~ /^[[:space:]]*#/' "$series" | sed 's/[[:space:]]*$//'
    return 0
  fi
  # Fallback: ordenar lexicograficamente
  local f; shopt -s nullglob
  for f in "$pdir"/*.patch "$pdir"/*.diff; do
    [[ -f "$f" ]] && printf "%s\n" "$f"
  done
  shopt -u nullglob
  return 0
}

# Tenta aplicar um patch com git apply; se --dry-run, apenas checa.
_hp_patch_try_git() {
  # _hp_patch_try_git <patch_file> [--reverse] [--dry-run]
  local pf="$1"; shift || true
  local reverse="false" dry="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reverse) reverse="true"; shift ;;
      --dry-run) dry="true"; shift ;;
      *) break ;;
    esac
  done
  command -v git >/dev/null 2>&1 || return 2
  local args=( )
  [[ "$reverse" == "true" ]] && args+=( -R )
  if [[ "$dry" == "true" ]]; then
    git apply --check "${args[@]}" -- "$pf" >>"$ADM_LOG_CURRENT" 2>&1
  else
    git apply "${args[@]}" -- "$pf" >>"$ADM_LOG_CURRENT" 2>&1
  fi
  return $?
}

# Detecta -p adequado para 'patch' e aplica (ou checa com --dry-run)
_hp_patch_try_patch() {
  # _hp_patch_try_patch <patch_file> [--reverse] [--dry-run]
  local pf="$1"; shift || true
  local reverse="false" dry="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reverse) reverse="true"; shift ;;
      --dry-run) dry="true"; shift ;;
      *) break ;;
    esac
  done
  command -v patch >/dev/null 2>&1 || return 2
  local plevel
  for plevel in 1 2 0; do
    if [[ "$dry" == "true" ]]; then
      patch -p"$plevel" ${reverse:+-R} --dry-run < "$pf" >>"$ADM_LOG_CURRENT" 2>&1
    else
      patch -p"$plevel" ${reverse:+-R} < "$pf" >>"$ADM_LOG_CURRENT" 2>&1
    fi
    local rc=$?
    if [[ $rc -eq 0 ]]; then
      echo "$plevel"
      return 0
    fi
  done
  return 1
}

adm_patches_apply() {
  # adm_patches_apply [--reverse] [--dry-run]
  local reverse="false" dry="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reverse) reverse="true"; shift ;;
      --dry-run) dry="true"; shift ;;
      *) _hp_warn "patches_apply: opção desconhecida $1"; shift ;;
    esac
  done
  local pdir; pdir="$(adm_meta_patches_dir)"
  [[ -z "$pdir" ]] && { _hp_info "sem diretório de patches (ok)"; return 0; }

  adm_step "${ADM_META_NAME:-$ADM_LOG_PKG}" "${ADM_META_VERSION:-$ADM_LOG_VER}" "Aplicando patches"
  local list; list="$(adm_patches_list)"
  [[ -z "$list" ]] && { _hp_info "nenhum patch para aplicar"; return 0; }

  local pf
  while IFS= read -r pf; do
    [[ -z "$pf" ]] && continue
    # Se listagem veio do 'series' sem caminho absoluto, prefixa pdir
    [[ -f "$pf" ]] || pf="${pdir%/}/$pf"
    [[ -f "$pf" ]] || { _hp_err "patch não encontrado: $pf"; return 4; }

    adm_with_spinner "patch: $(basename -- "$pf")" -- bash -c '
      set -euo pipefail
      pf="$1"; reverse="$2"; dry="$3"; strat="'"$ADM_PATCH_STRATEGY"'"
      # Preferência de estratégia
      if [[ "$strat" == "git" || "$strat" == "auto" ]]; then
        if _hp_patch_try_git "$pf" ${reverse:+--reverse} ${dry:+--dry-run}; then
          exit 0
        elif [[ "$strat" == "git" ]]; then
          _hp_err "git apply falhou para $pf"
          exit 4
        fi
      fi
      # patch(1) com detecção de -pN
      if plevel="$(_hp_patch_try_patch "$pf" ${reverse:+--reverse} ${dry:+--dry-run})"; then
        exit 0
      fi
      _hp_err "falha ao aplicar patch (git/patch) em $pf"
      exit 4
    ' bash "$pf" "$reverse" "$dry" || return $?
  done <<< "$list"

  adm_ok "patches aplicados"
  return 0
}
# 05-adm-hooks-patches.part2.sh
# Continuação: bootstrap (chroot), run_for_stage, e utilidades finais.
if [[ -n "${ADM_HOOKS_LOADED_PART2:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_HOOKS_LOADED_PART2=1
###############################################################################
# CHROOT helpers para bootstrap
###############################################################################
_hp_mount_one() {
  # _hp_mount_one <rootfs> <what>  (what in: proc sys dev devpts run)
  local root="$1" what="$2"
  local target
  case "$what" in
    proc)   target="$root/proc";   mountpoint -q "$target" || mount -t proc proc "$target" ;;
    sys)    target="$root/sys";    mountpoint -q "$target" || mount --rbind /sys "$target" ;;
    dev)    target="$root/dev";    mountpoint -q "$target" || mount --rbind /dev "$target" ;;
    devpts) target="$root/dev/pts"; mountpoint -q "$target" || mount --rbind /dev/pts "$target" ;;
    run)    target="$root/run";    mountpoint -q "$target" || mount --rbind /run "$target" ;;
    *) return 2 ;;
  esac
}

_hp_umount_one() {
  # _hp_umount_one <rootfs> <what> (ordem inversa)
  local root="$1" what="$2" target
  case "$what" in
    devpts) target="$root/dev/pts" ;;
    proc)   target="$root/proc" ;;
    sys)    target="$root/sys" ;;
    dev)    target="$root/dev" ;;
    run)    target="$root/run" ;;
    *) return 2 ;;
  esac
  if mountpoint -q "$target"; then
    umount -R "$target" 2>/dev/null || umount "$target" 2>/dev/null || true
  fi
}

adm_bootstrap_enter_chroot() {
  # adm_bootstrap_enter_chroot <rootfs> [--mount-proc --mount-sys --mount-dev --mount-devpts --mount-run]
  local root="$1"; shift || true
  [[ -z "$root" ]] && { adm_err "enter_chroot: rootfs ausente"; return 2; }
  [[ -d "$root" ]] || { adm_err "enter_chroot: rootfs inexistente: $root"; return 3; }
  [[ "$root" != "/" ]] || { adm_err "enter_chroot: rootfs não pode ser /"; return 5; }

  # Politica: requer root para mount/chroot
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    adm_err "enter_chroot: requer root para montar/chroot"
    return 5
  fi

  # Garante diretórios básicos
  mkdir -p "$root"/{proc,sys,dev,dev/pts,run,etc} 2>/dev/null || true

  local want=()
  local opt
  if [[ $# -eq 0 ]]; then
    # pega da política padrão
    for opt in $ADM_CHROOT_BIND; do want+=( "$opt" ); done
  else
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --mount-proc)   want+=( proc ); shift ;;
        --mount-sys)    want+=( sys ); shift ;;
        --mount-dev)    want+=( dev ); shift ;;
        --mount-devpts) want+=( devpts ); shift ;;
        --mount-run)    want+=( run ); shift ;;
        *) adm_warn "enter_chroot: opção desconhecida $1 (ignorada)"; shift ;;
      esac
    done
  fi

  local w
  for w in "${want[@]}"; do
    if ! _hp_mount_one "$root" "$w"; then
      adm_err "enter_chroot: falha ao montar $w"
      return 3
    fi
  done

  # DNS: garantir resolv.conf
  if [[ ! -e "$root/etc/resolv.conf" ]]; then
    cp -a /etc/resolv.conf "$root/etc/resolv.conf" 2>/dev/null || true
  fi

  adm_ok "chroot preparado em $root"
  return 0
}

adm_bootstrap_run_in_chroot() {
  # adm_bootstrap_run_in_chroot <rootfs> -- cmd ...
  local root="$1"; shift || true
  [[ "$1" == "--" ]] || { adm_err "run_in_chroot: uso: <rootfs> -- cmd ..."; return 2; }
  shift
  [[ -z "$root" || ! -d "$root" ]] && { adm_err "run_in_chroot: rootfs inválido"; return 2; }
  [[ "${EUID:-$(id -u)}" -ne 0 ]] && { adm_err "run_in_chroot: requer root"; return 5; }

  # Exporta ambiente mínimo (não vaza segredos, apenas variáveis úteis)
  local envfile; envfile="$(adm_mktemp_dir env)/env.list" || return 3
  {
    printf 'export ADM_ROOT=%q\n' "$ADM_ROOT"
    printf 'export ADM_SYS_PREFIX=%q\n' "$ADM_SYS_PREFIX"
    printf 'export ADM_JOBS=%q\n' "${ADM_JOBS:-1}"
    printf 'export PROFILE=%q\n' "${PROFILE:-$ADM_PROFILE_DEFAULT}"
    printf 'export PKG_NAME=%q\n' "${PKG_NAME:-}"
    printf 'export PKG_VERSION=%q\n' "${PKG_VERSION:-}"
    printf 'export PKG_CATEGORY=%q\n' "${PKG_CATEGORY:-}"
  } > "$envfile"

  adm_with_spinner "[chroot] executando: $*" -- chroot "$root" /bin/sh -c ". '$envfile'; exec $*"
}

adm_bootstrap_leave_chroot() {
  # adm_bootstrap_leave_chroot <rootfs>
  local root="$1"
  [[ -z "$root" || ! -d "$root" ]] && { adm_err "leave_chroot: rootfs inválido"; return 2; }
  [[ "${EUID:-$(id -u)}" -ne 0 ]] && { adm_err "leave_chroot: requer root"; return 5; }

  local order=( devpts run dev sys proc )
  local w
  for w in "${order[@]}"; do
    _hp_umount_one "$root" "$w" || true
  done
  adm_ok "chroot desmontado em $root"
  return 0
}

###############################################################################
# Hooks para bootstrap (por stage)
###############################################################################
adm_hooks_run_for_stage() {
  # adm_hooks_run_for_stage <stageN> <hook_name>
  local stage="$1" hook="$2"
  [[ -z "$stage" || -z "$hook" ]] && { adm_err "hooks_for_stage: parâmetros ausentes"; return 2; }
  export ADM_STAGE="$stage"
  if [[ "$ADM_BOOTSTRAP_CHROOT" == "true" && -n "${PKG_ROOTFS:-}" && -d "$PKG_ROOTFS" ]]; then
    # Rodar hook dentro do chroot? A descoberta de scripts é no host; execução via chroot:
    local scripts; scripts="$(adm_hooks__collect "$hook")" || return $?
    [[ -z "$scripts" ]] && { adm_warn "nenhum hook '$hook' para $stage"; return 1; }
    local s rc=0
    while IFS= read -r s; do
      [[ -z "$s" ]] && continue
      # Copia script para /tmp do chroot para execução isolada
      local tdir="$PKG_ROOTFS/tmp/adm-hooks"
      mkdir -p "$tdir" 2>/dev/null || true
      local base="$(basename -- "$s")"
      cp -f -- "$s" "$tdir/$base" || { adm_err "falha ao copiar hook para chroot: $s"; return 3; }
      chmod 0755 "$tdir/$base" 2>/dev/null || true
      if ! adm_bootstrap_run_in_chroot "$PKG_ROOTFS" -- "/bin/bash -euo pipefail /tmp/adm-hooks/$base"; then
        rc=$?
        adm_err "hook '$hook' (stage=$stage) falhou no chroot (rc=$rc)"
        return $rc
      fi
    done <<< "$scripts"
    return 0
  else
    adm_hooks_run "$hook"
  fi
}

###############################################################################
# Conveniências para etapas citadas no fluxo
###############################################################################
# Alias úteis que podem ser chamados pelo orquestrador:
adm_hooks_pre_fetch()       { adm_hooks_run pre-fetch       --allow-missing; }
adm_hooks_post_fetch()      { adm_hooks_run post-fetch      --allow-missing; }
adm_hooks_pre_unack()       { adm_hooks_run pre-unpack      --allow-missing; }  # retrocompat
adm_hooks_pre_unpack()      { adm_hooks_run pre-unpack      --allow-missing; }
adm_hooks_post_unpack()     { adm_hooks_run post-unpack     --allow-missing; }
adm_hooks_pre_prepare()     { adm_hooks_run pre-prepare     --allow-missing; }
adm_hooks_post_prepare()    { adm_hooks_run post-prepare    --allow-missing; }
adm_hooks_pre_configure()   { adm_hooks_run pre-configure   --allow-missing; }
adm_hooks_post_configure()  { adm_hooks_run post-configure  --allow-missing; }
adm_hooks_pre_build()       { adm_hooks_run pre-build       --allow-missing; }
adm_hooks_post_build()      { adm_hooks_run post-build      --allow-missing; }
adm_hooks_pre_test()        { adm_hooks_run pre-test        --allow-missing; }
adm_hooks_post_test()       { adm_hooks_run post-test       --allow-missing; }
adm_hooks_pre_install()     { adm_hooks_run pre-install     --allow-missing; }
adm_hooks_post_install()    { adm_hooks_run post-install    --allow-missing; }
adm_hooks_pre_package()     { adm_hooks_run pre-package     --allow-missing; }
adm_hooks_post_package()    { adm_hooks_run post-package    --allow-missing; }
adm_hooks_pre_register()    { adm_hooks_run pre-register    --allow-missing; }
adm_hooks_post_register()   { adm_hooks_run post-register   --allow-missing; }
adm_hooks_pre_uninstall()   { adm_hooks_run pre-uninstall   --allow-missing; }
adm_hooks_post_uninstall()  { adm_hooks_run post-uninstall  --allow-missing; }
adm_hooks_pre_update()      { adm_hooks_run pre-update      --allow-missing; }
adm_hooks_post_update()     { adm_hooks_run post-update     --allow-missing; }
adm_hooks_pre_clean()       { adm_hooks_run pre-clean       --allow-missing; }
adm_hooks_post_clean()      { adm_hooks_run post-clean      --allow-missing; }

# Patches aliases (para integração com orquestrador)
adm_hooks_apply_patches()   { adm_hooks_pre_prepare; adm_patches_apply; local rc=$?; adm_hooks_post_prepare; return $rc; }

###############################################################################
# Execução direta (mini CLI de teste)
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  sub="${1:-}"; shift || true
  case "$sub" in
    list)   adm_hooks_list "$1" ;;
    run)    adm_hooks_run "$@" ;;
    plist)  adm_patches_list ;;
    patch)  adm_patches_apply "$@" ;;
    chenter) adm_bootstrap_enter_chroot "$@" ;;
    chrun)   adm_bootstrap_run_in_chroot "$@" ;;
    chleave) adm_bootstrap_leave_chroot "$@" ;;
    stage)   adm_hooks_run_for_stage "$@" ;;
    *)
      echo "uso:" >&2
      echo "  $0 list <hook>" >&2
      echo "  $0 run <hook> [--allow-missing]" >&2
      echo "  $0 plist" >&2
      echo "  $0 patch [--reverse] [--dry-run]" >&2
      echo "  $0 chenter <rootfs> [--mount-proc|--mount-sys|--mount-dev|--mount-devpts|--mount-run]" >&2
      echo "  $0 chrun <rootfs> -- <cmd...>" >&2
      echo "  $0 chleave <rootfs>" >&2
      echo "  $0 stage <stageN> <hook>" >&2
      ;;
  esac
fi

###############################################################################
# Marcar como carregado
###############################################################################
ADM_HOOKS_LOADED=1
export ADM_HOOKS_LOADED
