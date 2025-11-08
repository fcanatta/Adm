#!/usr/bin/env bash
# 99-adm-cli.part1.sh
# CLI unificado "adm" para todo o ecossistema ADM.
###############################################################################
# Guardas e pré-requisitos
###############################################################################
if [[ -n "${ADM_CLI_LOADED_PART1:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_CLI_LOADED_PART1=1

# Exige módulos base já carregados (config/lib).
for _m in ADM_CONF_LOADED ADM_LIB_LOADED; do
  if [[ -z "${!_m:-}" ]]; then
    echo "ERRO: 99-adm-cli requer módulos básicos carregados (00/01). Faltando: ${_m}" >&2
    return 2 2>/dev/null || exit 2
  fi
done

: "${ADM_SCRIPTS_DIR:=/usr/src/adm/scripts}"
: "${ADM_STATE_ROOT:=/usr/src/adm/state}"
: "${ADM_TMP_ROOT:=/usr/src/adm/tmp}"
: "${ADM_META_ROOT:=/usr/src/adm/metafile}"
: "${ADM_CACHE_ROOT:=/usr/src/adm/cache}"

cli_err()  { adm_err "$*"; }
cli_warn() { adm_warn "$*"; }
cli_log()  { adm_log INFO "adm" "${C_CTX:-}" "$*"; }
cli_ok()   { adm_ok "$*"; }
cli_step() { adm_step "adm" "${C_CTX:-}" "$*"; }

###############################################################################
# Contexto e defaults
###############################################################################
declare -Ag CLI=(
  [root]="/"
  [dry_run]="false"
  [json]="false"
  [verbose]="false"
  [color]="auto"
  [profile]=""
)
declare -Ag P=() # paths
P[logdir]="${ADM_STATE_ROOT}/logs/adm"
mkdir -p -- "${P[logdir]}" || true
P[log_cli]="${P[logdir]}/adm-cli.log"

###############################################################################
# Utilidades
###############################################################################
_cli_realpath() {
  if command -v realpath >/dev/null 2>&1; then realpath -m -- "$1"; else
    (cd "$(dirname -- "$1")" 2>/dev/null && echo "$(pwd -P)/$(basename -- "$1")") 2>/dev/null || echo "$1"
  fi
}

_cli_sanitize_name() {
  # Aceita letras, números, -, _, ., / e @
  local s="$1"
  [[ "$s" =~ ^[a-zA-Z0-9._@/-]+$ ]] || return 1
  return 0
}

_cli_has_cmd() { command -v "$1" >/dev/null 2>&1; }

_cli_script() {  # retorna caminho do script ou vazio
  local f="$1"
  local p="${ADM_SCRIPTS_DIR%/}/${f}"
  [[ -x "$p" ]] && { echo "$p"; return 0; }
  [[ -r "$p" ]] && { echo "$p"; return 0; }
  echo ""
}

_cli_supports_flag() { # _cli_supports_flag <script> <flag>
  local s="$1" flag="$2"
  # Heurística: procura flag no arquivo (sem garantir semântica)
  grep -q -- "$flag" "$s" 2>/dev/null
}

_cli_log_invocation() {
  printf '%s | user=%s subcmd=%s args=%s\n' "$(date -u +'%F %T')" "${SUDO_USER:-$USER}@$(hostname)" "$1" "$2" >> "${P[log_cli]}" 2>/dev/null || true
}

_cli_dry_run_header() {
  [[ "${CLI[dry_run]}" == "true" ]] && printf "[DRY-RUN] "
}

# Execução com dry-run global:
# - Se o script alvosuporta --simulate/--dry-run/--yes, repassa.
# - Se não suporta, apenas imprime o comando que seria executado (retorna 0 com aviso).
_cli_run_or_simulate() { # _cli_run_or_simulate <script> <sub> [args...]
  local script="$1"; shift
  local sub="$1"; shift || true
  local -a argv=("$@")

  # dry-run propagation matrix (por heurística de flags já implementadas nos módulos):
  if [[ "${CLI[dry_run]}" == "true" ]]; then
    if _cli_supports_flag "$script" "--simulate"; then
      argv+=( --simulate )
    elif _cli_supports_flag "$script" "--dry-run"; then
      argv+=( --dry-run )
    elif _cli_supports_flag "$script" "--yes"; then
      # Comandos destrutivos exigem --yes; mas em DRY não executamos.
      :
    else
      # Não suporta: simula
      printf "%s%s %s %s\n" "$(_cli_dry_run_header)" "$script" "$sub" "${argv[*]}" >&2
      cli_warn "subcomando não suporta dry-run; simulado apenas"
      return 0
    fi
  fi

  [[ "${CLI[verbose]}" == "true" ]] && printf "%s%s %s %s\n" "$(_cli_dry_run_header)" "$script" "$sub" "${argv[*]}" >&2

  _cli_log_invocation "$(basename -- "$script") $sub" "${argv[*]}"
  "$script" "$sub" "${argv[@]}"
}

###############################################################################
# Helper / ajuda
###############################################################################
_adm_usage() {
  cat <<'EOF'
adm — CLI unificado do ADM

USO:
  adm <subcomando> [opções] [args]
  adm help [<subcomando>]
  adm tui
  adm search <texto> [--json]
  adm info <cat>/<name>[@ver] [--installed|--available] [--json]

FLAGS GLOBAIS:
  --root DIR         : define raiz (chroot/stage)
  --dry-run          : simula operações (imprime o que faria)
  --json             : saída em JSON quando aplicável
  --profile NAME     : ativa um profile (via 14-adm-profile)
  --verbose          : mostra comandos delegados
  --color=auto|always|never

SUBCOMANDOS:
  cache, download, metafile, hooks, analyze, resolve, helpers,
  build, install, uninstall, bootstrap, update, profile,
  pack, registry, clean, mkinitramfs, tui, search, info

Exemplos:
  adm search curl
  adm info net/curl
  adm build net/curl --dry-run
  adm install net/curl
  adm clean run --level deep --days 30 --dry-run
  adm mkinitramfs build --kver 6.10.7 --uki

"adm help <subcomando>" para detalhes de um subcomando.
EOF
}

_adm_help_sub() {
  local sc="$1"
  case "$sc" in
    ""|all) _adm_usage;;
    cache) cat <<'EOF'
adm cache ... → 02-adm-cache.sh
  subcomandos típicos: ls, stat, purge, get, put
  flags comuns: --root DIR, --json, --dry-run
EOF
;;
    download) cat <<'EOF'
adm download ... → 03-adm-download.sh
  protocolos: http(s), ftp, git, rsync, file://
  flags: --dest DIR, --concurrency N, --retry N, --digest sha256, --root DIR, --dry-run
EOF
;;
    metafile) cat <<'EOF'
adm metafile ... → 04-adm-metafile.sh
  parse, validar, mostrar, editar seguro
  flags: --root DIR, --json
EOF
;;
    hooks) cat <<'EOF'
adm hooks ... → 05-adm-hooks-patches.sh
  listar e executar hooks por etapa, aplicar/reverter patches
  flags: --root DIR, --stage {pre,post,...}, --dry-run
EOF
;;
    analyze) cat <<'EOF'
adm analyze ... → 06-adm-analyze.sh
  detecta build-system, compilers, libs e dependências
  flags: --root DIR, --json
EOF
;;
    resolve) cat <<'EOF'
adm resolve ... → 07-adm-resolver.sh
  resolve dependências (metafile + analyze) e produz plano
  flags: --root DIR, --json
EOF
;;
    helpers) cat <<'EOF'
adm helpers ... → 08-adm-build-system-helpers.sh
  prepara envs por build_type (cmake, meson, cargo, etc.)
EOF
;;
    build) cat <<'EOF'
adm build ... → 09-adm-build.sh
  orquestra construção, destdir, empacota e registra
  flags: --root DIR, --profile NAME, --json, --dry-run
EOF
;;
    install) cat <<'EOF'
adm install ... → 10-adm-install.sh
  instala de source ou binário; resolve dependências
  flags: --root DIR, --bin /dir, --json
EOF
;;
    uninstall) cat <<'EOF'
adm uninstall ... → 11-adm-uninstall.sh
  remoção segura + órfãos + hooks uninstall
  flags: --root DIR, --purge, --orphans, --yes
EOF
;;
    bootstrap) cat <<'EOF'
adm bootstrap ... → 12-adm-bootstrap.sh
  cria stage0..3, rootfs e toolchain
  flags: --stage N, --root DIR, --json
EOF
;;
    update) cat <<'EOF'
adm update ... → 13-adm-update.sh
  busca upstream e cria update metafile
  flags: --root DIR, --json
EOF
;;
    profile) cat <<'EOF'
adm profile ... → 14-adm-profile.sh
  criar/gerenciar profiles: aggressive, minimal, normal
EOF
;;
    pack) cat <<'EOF'
adm pack ... → 15-adm-pack.sh
  empacota em tar.zst com manifest/index/triggers
  flags: --root DIR, --json, --dry-run
EOF
;;
    registry) cat <<'EOF'
adm registry ... → 16-adm-registry.sh
  add/remove/info/list/files/owner/deps/rdeps/orphans/verify/history/export/import/hold/gc
  flags: --root DIR, --json
EOF
;;
    clean) cat <<'EOF'
adm clean ... → 17-adm-clean.sh
  limpa tmp/src/bin/logs/bootstrap/registry
  flags: run|report|quarantine|prune-bin|rotate-logs + --level, --days, --keep, --size-limit, --only, --root, --simulate/--yes
EOF
;;
    mkinitramfs) cat <<'EOF'
adm mkinitramfs ... → 18-adm-mkinitramfs.sh
  build/install/list/verify/purge; UKI/assinatura
  flags: --kver, --root, --modules, --luks, --lvm, --mdraid, --btrfs, --zfs, --microcode, --compress, --uki, --sign, --update-grub
EOF
;;
    *) echo "Subcomando desconhecido: $sc"; return 2;;
  esac
}
# 99-adm-cli.part2.sh
# Busca, info, TUI e roteamento para scripts
if [[ -n "${ADM_CLI_LOADED_PART2:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_CLI_LOADED_PART2=1
###############################################################################
# Parsing de flags globais
###############################################################################
_adm_parse_global_flags() {
  # Somente consome flags globais até o primeiro token não-flag (subcomando)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root) CLI[root]="$2"; shift 2;;
      --dry-run) CLI[dry_run]="true"; shift;;
      --json|--print-json) CLI[json]="true"; shift;;
      --profile) CLI[profile]="$2"; shift 2;;
      --verbose) CLI[verbose]="true"; shift;;
      --color=always|--color=auto|--color=never) CLI[color]="${1#--color=}"; shift;;
      --help|-h) _adm_usage; return 1;;
      help|tui|search|info|cache|download|metafile|hooks|analyze|resolve|helpers|build|install|uninstall|bootstrap|update|profile|pack|registry|clean|mkinitramfs|version)
        # subcomando encontrado — para aqui
        return 0;;
      *) break;;
    esac
  done
  return 0
}

###############################################################################
# Busca em metafiles
###############################################################################
_adm_search() { # adm search <texto> [--json]
  local q="" json="${CLI[json]}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json|--print-json) json="true"; shift;;
      *) q="${q:-$1}"; shift;;
    esac
  done
  [[ -n "$q" ]] || { cli_err "uso: adm search <texto> [--json]"; return 1; }
  local base="${ADM_META_ROOT}"
  [[ -d "$base" ]] || { cli_err "metafiles não encontrados em ${base}"; return 3; }

  if [[ "$json" == "true" ]]; then
    echo -n '['; local first=true
  fi

  while IFS= read -r -d '' mf; do
    local dir; dir="$(dirname -- "$mf")"
    local cat; cat="$(echo "$dir" | awk -F"${base}/" '{print $2}' | cut -d/ -f1)"
    local name; name="$(basename -- "$dir")"
    local version build_type desc homepage
    version="$(grep -E '^version=' "$mf" 2>/dev/null | head -n1 | cut -d= -f2-)"
    build_type="$(grep -E '^build_type=' "$mf" 2>/dev/null | head -n1 | cut -d= -f2-)"
    desc="$(grep -E '^description=' "$mf" 2>/dev/null | head -n1 | cut -d= -f2-)"
    homepage="$(grep -E '^homepage=' "$mf" 2>/dev/null | head -n1 | cut -d= -f2-)"

    # filtro texto
    if ! (echo "$name $cat $version $build_type $desc $homepage" | grep -qi -- "$q"); then
      continue
    fi

    if [[ "$json" == "true" ]]; then
      $first || echo -n ','
      printf '{"category":%q,"name":%q,"version":%q,"build_type":%q,"description":%q,"metafile":%q}' \
        "$cat" "$name" "$version" "$build_type" "$desc" "$mf"
      first=false
    else
      printf "%s/%s  v%s  [%s]\n  %s\n  %s\n" "$cat" "$name" "${version:-?}" "${build_type:-?}" "${desc:-}" "${homepage:-}"
      echo
    fi
  done < <(find "$base" -type f -name metafile -print0)

  if [[ "$json" == "true" ]]; then
    echo ']'
  fi
}

###############################################################################
# Info do programa: consolida metafile + registry + cache binário
###############################################################################
_adm_info() { # adm info <cat>/<name>[@ver] [--installed|--available] [--json]
  local q="" mode="all" json="${CLI[json]}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --installed) mode="installed"; shift;;
      --available) mode="available"; shift;;
      --json|--print-json) json="true"; shift;;
      *) q="${q:-$1}"; shift;;
    esac
  done
  [[ -n "$q" ]] || { cli_err "uso: adm info <cat>/<name>[@ver] [--installed|--available] [--json]"; return 1; }
  _cli_sanitize_name "$q" || { cli_err "nome inválido: $q"; return 4; }

  local cat="${q%%/*}" rest="${q#*/}" name="${rest%%@*}" ver="${rest#*@}"
  [[ "$ver" == "$rest" ]] && ver=""

  local mf="${ADM_META_ROOT}/${cat}/${name}/metafile"
  [[ -r "$mf" ]] || { cli_warn "metafile não encontrado: $mf"; }

  local version build_type desc homepage rdeps bdeps odeps
  version="$(grep -E '^version=' "$mf" 2>/dev/null | head -n1 | cut -d= -f2-)"
  build_type="$(grep -E '^build_type=' "$mf" 2>/dev/null | head -n1 | cut -d= -f2-)"
  desc="$(grep -E '^description=' "$mf" 2>/dev/null | head -n1 | cut -d= -f2-)"
  homepage="$(grep -E '^homepage=' "$mf" 2>/dev/null | head -n1 | cut -d= -f2-)"
  rdeps="$(grep -E '^run_deps=' "$mf" 2>/dev/null | cut -d= -f2-)"
  bdeps="$(grep -E '^build_deps=' "$mf" 2>/dev/null | cut -d= -f2-)"
  odeps="$(grep -E '^opt_deps=' "$mf" 2>/dev/null | cut -d= -f2-)"

  # Registry (se módulo disponível)
  local reg_info="" reg_vers="" inst_files=""
  if _cli_has_cmd adm_registry_info; then
    if [[ -z "$ver" ]]; then
      reg_info="$(adm_registry_info "${cat}/${name}" 2>/dev/null || true)"
    else
      reg_info="$(adm_registry_info "${cat}/${name}@${ver}" 2>/dev/null || true)"
    fi
    reg_vers="$(adm_registry_list "${cat}/${name}" 2>/dev/null | awk -F': ' '{print $2}' || true)"
    inst_files="$(adm_registry_files "${cat}/${name}" 2>/dev/null || true)"
  fi

  # Cache binário disponível
  local binroot="${ADM_CACHE_ROOT}/bin/${cat}/${name}"
  local bin_list=""
  [[ -d "$binroot" ]] && bin_list="$(ls -1 "${binroot}/${name}-"*.tar.* 2>/dev/null | xargs -r -I{} basename "{}")"

  if [[ "$json" == "true" ]]; then
    printf '{'
    printf '"category":%q,"name":%q,' "$cat" "$name"
    printf '"metafile":{"version":%q,"build_type":%q,"description":%q,"homepage":%q,"run_deps":%q,"build_deps":%q,"opt_deps":%q},' \
      "${version:-}" "${build_type:-}" "${desc:-}" "${homepage:-}" "${rdeps:-}" "${bdeps:-}" "${odeps:-}"
    printf '"registry":{"versions":%q},' "${reg_vers:-}"
    printf '"cache_bin":{"files":%q}' "${bin_list:-}"
    printf '}\n'
  else
    echo "== ${cat}/${name} =="
    echo "metafile:"
    echo "  version     : ${version:-?}"
    echo "  build_type  : ${build_type:-?}"
    echo "  run_deps    : ${rdeps:-}"
    echo "  build_deps  : ${bdeps:-}"
    echo "  opt_deps    : ${odeps:-}"
    [[ -n "$homepage" ]] && echo "  homepage    : $homepage"
    [[ -n "$desc" ]] && echo "  description : $desc"
    echo
    echo "registry:"
    echo "  versions    : ${reg_vers:-<nenhuma>}"
    echo
    echo "cache bin:"
    echo "  tarballs    :"
    if [[ -n "$bin_list" ]]; then
      echo "$bin_list" | sed 's/^/    - /'
    else
      echo "    <nenhum>"
    fi
  fi
  return 0
}

###############################################################################
# TUI com fallback (gum → fzf → dialog/whiptail)
###############################################################################
_adm_tui() {
  local has_gum=false has_fzf=false has_dialog=false
  _cli_has_cmd gum && has_gum=true
  _cli_has_cmd fzf && has_fzf=true
  (_cli_has_cmd dialog || _cli_has_cmd whiptail) && has_dialog=true

  local pick=""
  local menu=("Buscar programa" "Info de programa" "Build" "Install" "Uninstall" "Resolve deps"
              "Registry (órfãos/verify)" "Clean (quick/deep/purge)" "Bootstrap (stages)"
              "mkinitramfs (build/list/verify)" "Sair")

  if $has_gum; then
    pick="$(printf "%s\n" "${menu[@]}" | gum choose --header "ADM — Menu" --cursor.foreground="212" 2>/dev/null || true)"
  elif $has_fzf; then
    pick="$(printf "%s\n" "${menu[@]}" | fzf --prompt="ADM> " --height=80% --border 2>/dev/null || true)"
  elif $has_dialog; then
    local out; out="$(mktemp)"; local i=1; local items=()
    for m in "${menu[@]}"; do items+=("$i" "$m"); i=$((i+1)); done
    if _cli_has_cmd dialog; then
      dialog --menu "ADM — Menu" 20 70 12 "${items[@]}" 2> "$out" || { rm -f "$out"; return 1; }
    else
      whiptail --menu "ADM — Menu" 20 70 12 "${items[@]}" 2> "$out" || { rm -f "$out"; return 1; }
    fi
    local sel; sel="$(cat "$out" 2>/dev/null || true)"; rm -f "$out"
    pick="${menu[$((sel-1))]}"
  else
    cli_err "TUI requer gum, fzf ou dialog/whiptail"; return 2
  fi

  case "$pick" in
    "Buscar programa")
      read -r -p "Texto: " txt || true
      adm search "$txt"
      ;;
    "Info de programa")
      read -r -p "cat/name[@ver]: " id || true
      adm info "$id"
      ;;
    "Build")
      read -r -p "cat/name[@ver]: " id || true
      adm build "$id" ${CLI[dry_run]:+"--dry-run"}
      ;;
    "Install")
      read -r -p "cat/name[@ver]: " id || true
      adm install "$id"
      ;;
    "Uninstall")
      read -r -p "cat/name[@ver]: " id || true
      adm uninstall "$id"
      ;;
    "Resolve deps")
      read -r -p "cat/name[@ver]: " id || true
      adm resolve "$id" --json
      ;;
    "Registry (órfãos/verify)")
      echo "1) órfãos  2) verify pacote"
      read -r -p "Escolha: " op || true
      if [[ "$op" == "1" ]]; then
        adm registry orphans
      else
        read -r -p "cat/name[@ver]: " id || true
        adm registry verify "$id"
      fi
      ;;
    "Clean (quick/deep/purge)")
      echo "level: quick/deep/purge"
      read -r -p "Level: " lv || true
      adm clean run --level "${lv:-quick}" ${CLI[dry_run]:+"--simulate"}
      ;;
    "Bootstrap (stages)")
      echo "stage: 0..3"
      read -r -p "Stage: " st || true
      adm bootstrap run --stage "${st:-1}"
      ;;
    "mkinitramfs (build/list/verify)")
      echo "1) build 2) list 3) verify"
      read -r -p "Escolha: " op || true
      case "$op" in
        1) read -r -p "KVER: " kv || true; adm mkinitramfs build --kver "$kv" ;;
        2) adm mkinitramfs list ;;
        3) read -r -p "KVER ou caminho: " kv || true; adm mkinitramfs verify "$kv" --strict ;;
      esac
      ;;
    *) :;;
  esac
}
# 99-adm-cli.part3.sh
# Roteamento de subcomandos e main()
if [[ -n "${ADM_CLI_LOADED_PART3:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_CLI_LOADED_PART3=1
###############################################################################
# Roteadores
###############################################################################
_adm_route_to_script() { # _adm_route_to_script <scriptfile> <sub> [args...]
  local scr="$1"; shift
  local sub="$1"; shift || true
  local path; path="$(_cli_script "$scr")"
  [[ -n "$path" ]] || { cli_err "script não encontrado: ${scr}"; return 5; }
  # Injeta --root quando faz sentido (heurística por presença da flag no script)
  local -a argv=("$sub" "$@")
  if [[ -n "${CLI[root]}" && "${CLI[root]}" != "/" ]] && _cli_supports_flag "$path" "--root"; then
    argv+=( --root "${CLI[root]}" )
  fi
  _cli_run_or_simulate "$path" "${argv[@]}"
}

# Subcomandos de alto nível
adm_search_cmd()  { shift || true; _adm_search "$@"; }
adm_info_cmd()    { shift || true; _adm_info "$@"; }
adm_tui_cmd()     { _adm_tui; }

adm_cache_cmd()       { _adm_route_to_script "02-adm-cache.sh"       "$@"; }
adm_download_cmd()    { _adm_route_to_script "03-adm-download.sh"    "$@"; }
adm_metafile_cmd()    { _adm_route_to_script "04-adm-metafile.sh"    "$@"; }
adm_hooks_cmd()       { _adm_route_to_script "05-adm-hooks-patches.sh" "$@"; }
adm_analyze_cmd()     { _adm_route_to_script "06-adm-analyze.sh"     "$@"; }
adm_resolve_cmd()     { _adm_route_to_script "07-adm-resolver.sh"    "$@"; }
adm_helpers_cmd()     { _adm_route_to_script "08-adm-build-system-helpers.sh" "$@"; }
adm_build_cmd()       { _adm_route_to_script "09-adm-build.sh"       "$@"; }
adm_install_cmd()     { _adm_route_to_script "10-adm-install.sh"     "$@"; }
adm_uninstall_cmd()   { _adm_route_to_script "11-adm-uninstall.sh"   "$@"; }
adm_bootstrap_cmd()   { _adm_route_to_script "12-adm-bootstrap.sh"   "$@"; }
adm_update_cmd()      { _adm_route_to_script "13-adm-update.sh"      "$@"; }
adm_profile_cmd()     { _adm_route_to_script "14-adm-profile.sh"     "$@"; }
adm_pack_cmd()        { _adm_route_to_script "15-adm-pack.sh"        "$@"; }
adm_registry_cmd()    { _adm_route_to_script "16-adm-registry.sh"    "$@"; }
adm_clean_cmd()       { _adm_route_to_script "17-adm-clean.sh"       "$@"; }
adm_mkinitramfs_cmd() { _adm_route_to_script "18-adm-mkinitramfs.sh" "$@"; }

###############################################################################
# Main
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # Parse flags globais
  _adm_parse_global_flags "$@" || exit $?
  # Expõe profile ativo (se informado)
  if [[ -n "${CLI[profile]}" ]]; then
    if _cli_script "14-adm-profile.sh" >/dev/null; then
      ADM_PROFILE_ACTIVE="${CLI[profile]}" export ADM_PROFILE_ACTIVE
      # Melhor esforço: aplicar o profile antes de executar comandos
      "${ADM_SCRIPTS_DIR}/14-adm-profile.sh" apply --name "${CLI[profile]}" >/dev/null 2>&1 || true
    else
      cli_warn "script de profiles ausente; ignorando --profile"
    fi
  fi

  # Descobre subcomando (primeiro token não-flag global)
  sub="$1"; shift || true

  case "$sub" in
    ""|help|-h|--help)  if [[ -n "$1" ]]; then _adm_help_sub "$1"; else _adm_usage; fi; exit $?;;
    version|--version)  echo "ADM CLI $(date -u +%Y.%m.%d)"; exit 0;;
    tui)                adm_tui_cmd "$@"; exit $?;;
    search)             adm_search_cmd "$sub" "$@"; exit $?;;
    info)               adm_info_cmd "$sub" "$@"; exit $?;;
    cache)              adm_cache_cmd "$@"; exit $?;;
    download)           adm_download_cmd "$@"; exit $?;;
    metafile)           adm_metafile_cmd "$@"; exit $?;;
    hooks)              adm_hooks_cmd "$@"; exit $?;;
    analyze)            adm_analyze_cmd "$@"; exit $?;;
    resolve)            adm_resolve_cmd "$@"; exit $?;;
    helpers)            adm_helpers_cmd "$@"; exit $?;;
    build)              adm_build_cmd "$@"; exit $?;;
    install)            adm_install_cmd "$@"; exit $?;;
    uninstall)          adm_uninstall_cmd "$@"; exit $?;;
    bootstrap)          adm_bootstrap_cmd "$@"; exit $?;;
    update)             adm_update_cmd "$@"; exit $?;;
    profile)            adm_profile_cmd "$@"; exit $?;;
    pack)               adm_pack_cmd "$@"; exit $?;;
    registry)           adm_registry_cmd "$@"; exit $?;;
    clean)              adm_clean_cmd "$@"; exit $?;;
    mkinitramfs)        adm_mkinitramfs_cmd "$@"; exit $?;;
    *)
      cli_warn "subcomando desconhecido: $sub"
      _adm_usage
      exit 1;;
  esac
fi

ADM_CLI_LOADED=1
export ADM_CLI_LOADED
