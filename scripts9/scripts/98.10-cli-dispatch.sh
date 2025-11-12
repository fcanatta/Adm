#!/usr/bin/env bash
# 98.10-cli-dispatch.sh — CLI unificada do ADM
# High-level:
#   - install <nome|cat/nome> [flags de deps]
#   - search, info, run, list-commands, help, TUI
# Evoluções no install:
#   • Resolve grafo + fecho de deps (run / opt / build)
#   • Verifica faltantes e FALHA (relatório) se houver
#   • Ordena por toposort (fallback interno se script faltar)
#   • Pula pacotes já instalados (a menos de --rebuild/--force)
#   • Propaga --dry-run e logs limpos; sem erros silenciosos

set -Eeuo pipefail
IFS=$'\n\t'

###############################################################################
# Pathing & Constantes
###############################################################################
CMD_NAME="${CMD_NAME:-adm}"

ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_SCRIPTS="${ADM_SCRIPTS:-${ADM_ROOT}/scripts}"
ADM_META_DIR="${ADM_META_DIR:-${ADM_ROOT}/metafiles}"
ADM_DB_DIR="${ADM_DB_DIR:-${ADM_ROOT}/db}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_LOG_DIR="${ADM_LOG_DIR:-${ADM_STATE_DIR}/logs}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"
GRAPH_DIR="${GRAPH_DIR:-${ADM_DB_DIR}/graph}"
UPDATE_DIR="${UPDATE_DIR:-${ADM_ROOT}/update}"

SCRIPT_TRACKER="${SCRIPT_TRACKER:-${ADM_SCRIPTS}/10.10-update-upstream-tracker.sh}"
SCRIPT_BULK="${SCRIPT_BULK:-${ADM_SCRIPTS}/10.20-bulk-update-planner.sh}"
SCRIPT_DEPS_GRAPH="${SCRIPT_DEPS_GRAPH:-${ADM_SCRIPTS}/06.10-resolve-deps-graph.sh}"
SCRIPT_TOPOSORT="${SCRIPT_TOPOSORT:-${ADM_SCRIPTS}/06.20-order-toposort-strategy.sh}"
SCRIPT_PARSE_META="${SCRIPT_PARSE_META:-${ADM_SCRIPTS}/02.10-parse-validate-metafile.sh}"
SCRIPT_SCHEMA_MIN="${SCRIPT_SCHEMA_MIN:-${ADM_SCRIPTS}/02.20-schema-guard-minimal.sh}"
SCRIPT_FETCH="${SCRIPT_FETCH:-${ADM_SCRIPTS}/03.10-hooks-fetch-verify.sh}"
SCRIPT_REMOTE="${SCRIPT_REMOTE:-${ADM_SCRIPTS}/03.20-remote-providers-ext.sh}"
SCRIPT_EXTRACT="${SCRIPT_EXTRACT:-${ADM_SCRIPTS}/04.10-extract-detect.sh}"
SCRIPT_HEUR="${SCRIPT_HEUR:-${ADM_SCRIPTS}/04.20-source-heuristics-matrix.sh}"
SCRIPT_BUILD="${SCRIPT_BUILD:-${ADM_SCRIPTS}/05.10-applypatches-build.sh}"
SCRIPT_KERNEL="${SCRIPT_KERNEL:-${ADM_SCRIPTS}/05.20-kernel-firmware-specials.sh}"
SCRIPT_PACK="${SCRIPT_PACK:-${ADM_SCRIPTS}/07.10-package-bincache.sh}"
SCRIPT_SNAP="${SCRIPT_SNAP:-${ADM_SCRIPTS}/07.20-rollback-snapshots.sh}"
SCRIPT_INSTALL="${SCRIPT_INSTALL:-${ADM_SCRIPTS}/08.10-install-register-verify.sh}"
SCRIPT_POST="${SCRIPT_POST:-${ADM_SCRIPTS}/08.20-postinstall-healthchecks.sh}"
SCRIPT_REMED="${SCRIPT_REMED:-${ADM_SCRIPTS}/08.30-auto-remediation.sh}"
SCRIPT_UNINST_GC="${SCRIPT_UNINST_GC:-${ADM_SCRIPTS}/09.10-uninstall-gc.sh}"
SCRIPT_ORPH_REVD="${SCRIPT_ORPH_REVD:-${ADM_SCRIPTS}/09.20-orphans-revdeps-recalc.sh}"

for d in "$ADM_STATE_DIR" "$ADM_LOG_DIR" "$ADM_TMPDIR"; do
  [[ -d "$d" ]] || mkdir -p "$d"
done

###############################################################################
# Cores, logging, utils
###############################################################################
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RST="$(tput sgr0)"; C_BD="$(tput bold)"
  C_OK="$(tput setaf 2)"; C_WRN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INF="$(tput setaf 6)"
else
  C_RST=""; C_BD=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""
fi
log_i(){ echo -e "${C_INF}[${CMD_NAME}]${C_RST} $*"; }
log_ok(){ echo -e "${C_OK}[OK]${C_RST} $*"; }
log_w(){ echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
log_e(){ echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }
tmpfile(){ mktemp "${ADM_TMPDIR}/adm.XXXXXX"; }
adm_is_cmd(){ command -v "$1" >/dev/null 2>&1; }

__cli_err_trap(){ local c=$? l=${BASH_LINENO[0]:-?} f=${FUNCNAME[1]:-MAIN}; echo "[ERR] ${CMD_NAME} falhou: code=$c line=$l func=$f" 1>&2 || true; exit "$c"; }
trap __cli_err_trap ERR

###############################################################################
# Logo & UI
###############################################################################
ADM_LOGO=$'
   ___    ____  __  ___
  / _ |  / __ \/  |/  /  ADM
 / __ | / /_/ / /|_/ /   Advanced (from scratch) Manager
/_/ |_| \____/_/  /_/    build • install • update • repair
'
print_logo(){ echo -e "${C_BD}${ADM_LOGO}${C_RST}"; }

ui_dialog(){
  if adm_is_cmd dialog; then echo "dialog"
  elif adm_is_cmd whiptail; then echo "whiptail"
  else echo ""
  fi
}
ui_fzf(){ adm_is_cmd fzf && echo "fzf" || echo ""; }

menu_tui(){
  local ui; ui="$(ui_dialog)"
  if [[ -n "$ui" ]]; then
    local cmd=( "$ui" --title "ADM - Unified CLI" --cancel-label "Sair" --menu "Escolha uma ação" 20 78 10
      1 "Instalar programa por nome"
      2 "Procurar programa"
      3 "Informações de um programa"
      4 "Atualizações (planejar em lote)"
      5 "Recalcular grafo/órfãos"
      6 "Listar comandos low-level"
      7 "Abrir shell do ADM (scripts dir)"
    )
    local choice; choice=$("${cmd[@]}" 2>&1 >/dev/tty) || return 1
    case "$choice" in
      1) tui_install_flow ;;
      2) tui_search_flow ;;
      3) tui_info_flow ;;
      4) tui_bulk_update_flow ;;
      5) tui_graph_scan_flow ;;
      6) sub_list_commands ;;
      7) (cd "$ADM_SCRIPTS"; ${SHELL:-/bin/bash}) ;;
    esac
    return 0
  fi
  print_logo
  echo "1) Instalar  2) Procurar  3) Info  4) Bulk Update  5) Recalcular Grafo  6) List Commands  7) Shell  0) Sair"
  read -r -p "> " ans || return 1
  case "$ans" in
    1) tui_install_flow ;;
    2) tui_search_flow ;;
    3) tui_info_flow ;;
    4) tui_bulk_update_flow ;;
    5) tui_graph_scan_flow ;;
    6) sub_list_commands ;;
    7) (cd "$ADM_SCRIPTS"; ${SHELL:-/bin/bash}) ;;
    *) return 0 ;;
  esac
}

###############################################################################
# Helpers de metafile/DB
###############################################################################
mf_path_of(){
  local ref="$1"
  if [[ "$ref" != */* ]]; then
    local found
    found="$(find "$ADM_META_DIR" -mindepth 2 -maxdepth 2 -type f -name metafile -path "*/${ref}/metafile" -printf '%h\n' 2>/dev/null | sed 's#^.*/metafiles/##' | head -n 2)"
    local n; n="$(echo "$found" | wc -l || echo 0)"
    (( n==1 )) && { echo "${ADM_META_DIR}/${found}/metafile"; return 0; }
    return 1
  else
    echo "${ADM_META_DIR}/${ref}/metafile"
  fi
}
installed_pkg_dir(){ local ref="$1"; echo "${ADM_DB_DIR}/installed/${ref}"; }
is_installed(){ local ref="$1"; [[ -d "$(installed_pkg_dir "$ref")" ]]; }
mf_read_kv(){ local mf="$1" key="$2"; grep -E "^${key}=" "$mf" 2>/dev/null | head -n1 | sed -E "s/^${key}=//"; }

search_metafiles(){
  local q="$1"
  LC_ALL=C grep -RHi --include=metafile -E "$q" "$ADM_META_DIR" 2>/dev/null \
    | sed -E 's#^.*/metafiles/([^/]+/[^/]+)/metafile:.*#\1#g' | sort -u
}
###############################################################################
# HELP e listagem de scripts low-level
###############################################################################
show_full_help(){
  print_logo
  cat <<'HLP'
Uso (high-level):
  adm install <nome|cat/nome> [opções de deps] [opções de execução]
  adm search <texto>
  adm info <nome|cat/nome>
  adm run <script> [args...]
  adm list-commands
  adm help
  adm                 # abre o menu TUI

Opções de dependências para "install":
  --all-deps                Incluir run + opt + build
  --with-opt                Incluir deps opcionais
  --with-build              Incluir deps de build
  --no-optional             Alias de não usar --with-opt (padrão)
  --fail-on-missing         (default) Falha se houver dependências faltantes
  --allow-missing           Prossegue mesmo com faltantes (não recomendado)

Opções de execução para "install":
  --rebuild                 Recompilar mesmo se instalado
  --force                   Força reconstrução/instalação
  --dry-run                 Simula pipeline (sem efeitos)
  --json                    Saída JSON resumida do plano de instalação
  --log PATH                Log adicional desta sessão de install

Outros:
  --root PATH               Raiz alvo quando aplicável
HLP

  echo
  echo "${C_BD}Comandos low-level disponíveis:${C_RST}"
  sub_list_commands
}

list_scripts(){
  find "$ADM_SCRIPTS" -maxdepth 1 -type f -perm -0100 -printf '%f\n' 2>/dev/null | sort -V
}
sub_list_commands(){
  local s
  for s in $(list_scripts); do
    echo -e "${C_INF}•${C_RST} $s"
  done
  echo
  echo "${C_BD}Usages dos scripts:${C_RST}"
  for s in $(list_scripts); do
    local p="${ADM_SCRIPTS}/${s}"
    echo -e "${C_OK}== ${s}${C_RST}"
    if "$p" --help >/dev/null 2>&1; then
      "$p" --help | sed -e '1,120!d'
    else
      head -n 60 "$p" 2>/dev/null | sed -n '1,60p'
    fi
    echo
  done
}

###############################################################################
# High-level: SEARCH e INFO
###############################################################################
adm_search(){
  local q="$1"
  [[ -n "$q" ]] || { log_e "Informe um termo para search"; return 2; }
  local byname; byname="$(find "$ADM_META_DIR" -mindepth 2 -maxdepth 2 -type d -name "*${q}*" -printf '%P\n' 2>/dev/null || true)"
  local bydesc; bydesc="$(grep -RHi --include=metafile -E "description=.*${q}.*" "$ADM_META_DIR" 2>/dev/null \
                           | sed -E 's#^.*/metafiles/([^/]+/[^/]+)/metafile:.*#\1#g' | sort -u || true)"
  printf "%s\n%s\n" "$byname" "$bydesc" | sed '/^$/d' | sort -u
}
adm_info(){
  local ref="$1"
  [[ -n "$ref" ]] || { log_e "Informe <nome|cat/nome>"; return 2; }
  local mf; mf="$(mf_path_of "$ref" 2>/dev/null || true)"
  if [[ -z "$mf" && "$ref" == */* ]]; then mf="${ADM_META_DIR}/${ref}/metafile"; fi
  [[ -r "$mf" ]] || { log_e "Metafile não encontrado para '$ref'"; return 2; }
  local cat name; cat="$(echo "$mf" | sed -E 's#^.*/metafiles/([^/]+)/[^/]+/metafile$#\1#')" || true
  name="$(mf_read_kv "$mf" name)"; [[ -n "$name" ]] || name="${ref##*/}"
  local ver homepage desc rdeps=""
  ver="$(mf_read_kv "$mf" version)"
  homepage="$(mf_read_kv "$mf" homepage)"
  desc="$(mf_read_kv "$mf" description)"
  local full="${cat}/${name}"
  local state="não instalado"; is_installed "$full" && state="instalado"
  if [[ -r "${GRAPH_DIR}/revdeps.json" ]] && adm_is_cmd jq; then
    rdeps="$(jq -r --arg k "$full" '.[$k][]?' "${GRAPH_DIR}/revdeps.json" 2>/dev/null || true)"
  fi
  print_logo
  echo "${C_BD}${full}${C_RST}  —  ${desc:-"(sem descrição)"}"
  echo "Versão: ${ver:-?}   Estado: ${state}"
  echo "Homepage: ${homepage:-?}"
  echo "Metafile: ${mf}"
  if [[ -n "$rdeps" ]]; then
    echo "Revdeps:"; echo "$rdeps" | sed 's/^/  - /'
  fi
  if is_installed "$full"; then
    local fl="${ADM_DB_DIR}/installed/${full}/files.lst"
    [[ -r "$fl" ]] && echo "Arquivos: $(wc -l < "$fl" 2>/dev/null) itens"
  fi
}

tui_search_flow(){
  local ui; ui="$(ui_dialog)"
  local q; if [[ -n "$ui" ]]; then q=$($ui --inputbox "Buscar por:" 10 60 2>&1 >/dev/tty) || return 1
           else read -r -p "Buscar por: " q || return 1; fi
  adm_search "$q"
}
tui_info_flow(){
  local ui; ui="$(ui_dialog)"
  local q; if [[ -n "$ui" ]]; then q=$($ui --inputbox "Programa (nome ou cat/nome):" 10 60 2>&1 >/dev/tty) || return 1
           else read -r -p "Programa: " q || return 1; fi
  adm_info "$q"
}
###############################################################################
# High-level: INSTALL avançado (fecho de dependências real)
###############################################################################
# Flags internas de instalação
INSTALL_WITH_OPT=0
INSTALL_WITH_BUILD=0
INSTALL_ALL_DEPS=0
INSTALL_ALLOW_MISSING=0
INSTALL_REBUILD=0
INSTALL_FORCE=0
INSTALL_DRYRUN=0
INSTALL_JSON=0
INSTALL_LOGFILE=""
INSTALL_ROOT="/"

# parse flags do subcomando install
parse_install_flags(){
  while (($#)); do
    case "$1" in
      --all-deps) INSTALL_ALL_DEPS=1; INSTALL_WITH_OPT=1; INSTALL_WITH_BUILD=1; shift ;;
      --with-opt) INSTALL_WITH_OPT=1; shift ;;
      --with-build) INSTALL_WITH_BUILD=1; shift ;;
      --no-optional) INSTALL_WITH_OPT=0; shift ;;
      --allow-missing) INSTALL_ALLOW_MISSING=1; shift ;;
      --fail-on-missing) INSTALL_ALLOW_MISSING=0; shift ;;
      --rebuild) INSTALL_REBUILD=1; shift ;;
      --force) INSTALL_FORCE=1; shift ;;
      --dry-run) INSTALL_DRYRUN=1; shift ;;
      --json) INSTALL_JSON=1; shift ;;
      --log) INSTALL_LOGFILE="${2:-}"; shift 2 ;;
      --root) INSTALL_ROOT="${2:-/}"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  echo "$@"
}

# toposort interno caso 06.20 não esteja disponível
_toposort_closure(){
  local deps_json="$1" targets_file="$2" out="$3"
  adm_is_cmd jq || { cat "$targets_file" > "$out"; return 0; }
  # constrói subgrafo com deps apenas entre o conjunto-alvo
  local map; map="$(tmpfile)"; echo "{}" > "$map"
  while IFS= read -r p; do
    local keep; keep="$(tmpfile)"; : > "$keep"
    local deps; deps="$(jq -r --arg k "$p" '.[$k][]?' "$deps_json" 2>/dev/null || true)"
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      grep -qx -- "$d" "$targets_file" && echo "$d" >> "$keep" || true
    done <<< "$deps"
    local arr; arr="$(tmpfile)"
    jq -R -s 'split("\n")|map(select(length>0))' "$keep" > "$arr"
    jq --arg k "$p" --slurpfile v "$arr" '.[$k] = $v[0]' "$map" > "${map}.n" 2>/dev/null || echo "{}" > "${map}.n"
    mv -f "${map}.n" "$map"
  done < "$targets_file"
  # Kahn simples
  local indeg; indeg="$(tmpfile)"
  jq -r 'to_entries[] | "\(.key)\t\(.value|length)"' "$map" > "$indeg"
  local order=()
  while :; do
    local zeros; zeros="$(awk -F'\t' '$2==0{print $1}' "$indeg")"
    [[ -z "$zeros" ]] && break
    while IFS= read -r z; do
      order+=( "$z" )
      awk -F'\t' -v z="$z" '$1!=z{print $0}' "$indeg" > "${indeg}.n" && mv -f "${indeg}.n" "$indeg"
      local tmp; tmp="$(tmpfile)"
      jq --arg z "$z" 'to_entries | map({key:.key, value:(.value - [$z])}) | from_entries' "$map" > "$tmp"
      mv -f "$tmp" "$map"
      jq -r 'to_entries[] | "\(.key)\t\(.value|length)"' "$map" > "$indeg"
    done <<< "$zeros"
  done
  local rest; rest="$(awk -F'\t' '{print $1}' "$indeg")"
  printf "%s\n" "${order[@]}" | sed '/^$/d' > "$out"
  printf "%s\n" $rest | sed '/^$/d' | sort -u >> "$out"
}

# constrói fecho de deps para um alvo (usa 09.20 scan + deps.json)
_build_dep_closure(){
  local target="$1" chosen="$2"  # chosen: run/opt/build controle já refletido no deps.json após scan
  adm_is_cmd jq || { echo "$target" > "$chosen"; return 0; }

  local deps="${GRAPH_DIR}/deps.json"
  [[ -r "$deps" ]] || { echo "$target" > "$chosen"; return 0; }

  # BFS a partir do target seguindo deps
  declare -A seen; : > "$chosen"
  local queue=("$target")
  seen["$target"]=1
  echo "$target" >> "$chosen"
  while ((${#queue[@]})); do
    local cur="${queue[0]}"; queue=("${queue[@]:1}")
    local nxt; nxt="$(jq -r --arg k "$cur" '.[$k][]?' "$deps" 2>/dev/null || true)"
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      if [[ -z "${seen[$d]:-}" ]]; then
        seen["$d"]=1
        queue+=("$d")
        echo "$d" >> "$chosen"
      fi
    done <<< "$nxt"
  done
  sort -u -o "$chosen" "$chosen"
}

# instala 1 pacote (pipeline fetch→build→package→install→checks)
_install_one_pkg(){
  local pkg="$1" pmf="$2"
  local cat="${pkg%%/*}" name="${pkg##*/}"

  if (( INSTALL_DRYRUN )); then
    log_i "(dry-run) pipeline para $pkg"
    return 0
  fi

  # fetch & verify
  log_i "Fetch & verify: $pkg"
  "$SCRIPT_FETCH" --category "$cat" --name "$name" --metafile "$pmf" --verify --fetch || { log_e "Falha em fetch/verify ($pkg)"; return 5; }

  log_i "Extract & detect: $pkg"
  "$SCRIPT_EXTRACT" --category "$cat" --name "$name" --metafile "$pmf" --detect || { log_e "Falha em extract/detect ($pkg)"; return 6; }
  "$SCRIPT_HEUR"   --category "$cat" --name "$name" --metafile "$pmf" --json >/dev/null || true

  log_i "Build: $pkg"
  "$SCRIPT_BUILD" --category "$cat" --name "$name" --metafile "$pmf" ${INSTALL_FORCE:+--force} || { log_e "Falha na construção ($pkg)"; return 7; }

  log_i "Package/cache: $pkg"
  "$SCRIPT_PACK"  --category "$cat" --name "$name" --metafile "$pmf" --package || true

  log_i "Install & register: $pkg"
  "$SCRIPT_INSTALL" --category "$cat" --name "$name" --metafile "$pmf" --root "$INSTALL_ROOT" || { log_e "Falha na instalação ($pkg)"; return 8; }

  log_i "Healthchecks: $pkg"
  "$SCRIPT_POST" --category "$cat" --name "$name" --json >/dev/null || true

  log_i "Auto-remediation (se necessário): $pkg"
  "$SCRIPT_REMED" --category "$cat" --name "$name" --run-healthchecks --mode auto >/dev/null || true
}

# fluxo principal do install
install_program(){
  local ref="$1"; shift || true
  [[ -n "$ref" ]] || { log_e "Informe <nome> ou <cat/nome>"; return 2; }

  # flags do install
  local rest; rest="$(parse_install_flags "$@")"; set -- $rest

  # descobrir metafile
  local metaf
  if [[ "$ref" == */* ]]; then
    metaf="${ADM_META_DIR}/${ref}/metafile"
  else
    metaf="$(mf_path_of "$ref")" || { log_e "Não foi possível inferir categoria para '$ref'"; return 2; }
    ref="$(echo "$metaf" | sed -E 's#^.*/metafiles/([^/]+/[^/]+)/metafile$#\1#')"
  fi
  [[ -r "$metaf" ]] || { log_e "Metafile não legível: $metaf"; return 2; }
  local cat="${ref%%/*}" name="${ref##*/}"

  # logging opcional
  if [[ -n "$INSTALL_LOGFILE" ]]; then
    exec > >(tee -a "$INSTALL_LOGFILE") 2>&1
  fi
  log_i "Instalação solicitada: ${cat}/${name}"

  # schema mínimo + parse
  if ! "$SCRIPT_SCHEMA_MIN" --file "$metaf" >/dev/null 2>&1; then
    log_e "Schema mínimo inválido para $ref"; return 3
  fi
  "$SCRIPT_PARSE_META" --file "$metaf" --json >/dev/null || true

  # 1) recalcular grafo (inclui seleção de deps)
  local scan_args=( "scan" )
  (( INSTALL_ALL_DEPS )) && scan_args+=( "--all-deps" )
  (( INSTALL_WITH_OPT )) && scan_args+=( "--with-opt" )
  (( INSTALL_WITH_BUILD )) && scan_args+=( "--with-build" )
  "$SCRIPT_ORPH_REVD" "${scan_args[@]}" >/dev/null

  # 2) checar faltantes (scoped ao fecho)
  local chosen; chosen="$(tmpfile)"; : > "$chosen"
  _build_dep_closure "$ref" "$chosen"
  local miss_json="${GRAPH_DIR}/missing.json"
  local missing_scoped; missing_scoped="$(tmpfile)"; : > "$missing_scoped"
  if [[ -r "$miss_json" ]] && adm_is_cmd jq; then
    # mantém apenas faltantes que pertencem ao fecho
    jq -r '.[]' "$miss_json" 2>/dev/null | while read -r m; do
      grep -qx -- "$m" "$chosen" 2>/dev/null && echo "$m" >> "$missing_scoped" || true
    done
  fi
  if [[ -s "$missing_scoped" && $INSTALL_ALLOW_MISSING -eq 0 ]]; then
    log_e "Dependências faltantes detectadas no fecho:"
    sed 's/^/  - /' "$missing_scoped" 1>&2 || true
    echo
    echo "Sugestão: adicione os metafiles faltantes ou instale-os antes; ou use --allow-missing (não recomendado)."
    return 10
  fi

  # 3) ordenar (toposort) — prefere 06.20, senão interno
  local order; order="$(tmpfile)"
  if [[ -x "$SCRIPT_TOPOSORT" ]]; then
    # utiliza script de toposort se existir, limitado ao fecho
    # script pode aceitar --closure-file; se não aceitar, cai no interno
    if "$SCRIPT_TOPOSORT" --closure-file "$chosen" --json >/dev/null 2>&1; then
      "$SCRIPT_TOPOSORT" --closure-file "$chosen" --print-order > "$order"
    else
      _toposort_closure "${GRAPH_DIR}/deps.json" "$chosen" "$order"
    fi
  else
    _toposort_closure "${GRAPH_DIR}/deps.json" "$chosen" "$order"
  fi

  # 4) executar pipeline para cada pacote (pulando já instalados salvo --rebuild)
  local installed_skipped=0 built=0
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    local pmf="${ADM_META_DIR}/${pkg}/metafile"
    [[ -r "$pmf" ]] || { log_e "Metafile ausente para $pkg"; return 4; }
    if is_installed "$pkg" && (( INSTALL_REBUILD==0 )); then
      log_i "Já instalado: $pkg (skip)"
      ((installed_skipped++))
      continue
    fi
    _install_one_pkg "$pkg" "$pmf" || return $?
    ((built++))
  done < "$order"

  if (( INSTALL_JSON )); then
    if adm_is_cmd jq; then
      jq -n --arg target "$ref" --arg root "$INSTALL_ROOT" \
        --argjson built "$built" --argjson skipped "$installed_skipped" \
        '{target:$target, root:$root, built:$built, skipped:$skipped, status:"ok"}'
    else
      echo "target=$ref root=$INSTALL_ROOT built=$built skipped=$installed_skipped status=ok"
    fi
  fi
  log_ok "Instalação concluída: alvo=$ref construídos=$built pulados=$installed_skipped (dry-run=$INSTALL_DRYRUN)"
}

###############################################################################
# Bulk update, grafo e dispatcher genérico
###############################################################################
tui_install_flow(){
  local query ui; ui="$(ui_dialog)"
  if [[ -n "$ui" ]]; then
    query=$($ui --inputbox "Nome do programa (ou parte):" 10 60 2>&1 >/dev/tty) || return 1
  else
    read -r -p "Nome do programa: " query || return 1
  fi
  local results; results="$(tmpfile)"
  adm_search "$query" > "$results" || true
  local choice
  if [[ -n "$ui" ]]; then
    local items=()
    while IFS= read -r r; do items+=( "$r" "metafile" ); done < "$results"
    [[ ${#items[@]} -gt 0 ]] || { log_w "Nada encontrado."; return 1; }
    choice=$($ui --menu "Escolha" 20 70 12 "${items[@]}" 2>&1 >/dev/tty) || return 1
    # flags rápidas
    local inc_opt=$($ui --yesno "Incluir deps opcionais?" 8 45 2>&1 >/dev/tty; echo $?)
    local inc_build=$($ui --yesno "Incluir deps de build?" 8 45 2>&1 >/dev/tty; echo $?)
    install_program "$choice" $([[ "$inc_opt" == "0" ]] && echo --with-opt) $([[ "$inc_build" == "0" ]] && echo --with-build)
  else
    local fzf; fzf="$(ui_fzf)"
    if [[ -n "$fzf" ]]; then
      choice="$(cat "$results" | fzf --prompt="Instalar> " || true)"
    else
      cat "$results"; read -r -p "Escolha (cat/nome): " choice || return 1
    fi
    read -r -p "Incluir opcionais? [y/N] " yn1 || true
    read -r -p "Incluir deps de build? [y/N] " yn2 || true
    install_program "$choice" $([[ "$yn1" =~ ^[Yy]$ ]] && echo --with-opt) $([[ "$yn2" =~ ^[Yy]$ ]] && echo --with-build)
  fi
}

tui_bulk_update_flow(){
  local ui; ui="$(ui_dialog)"
  if [[ -n "$ui" ]]; then
    local cats=$($ui --inputbox "Categorias (CSV, ex.: libs,apps) — deixe vazio para todas:" 10 70 2>&1 >/dev/tty) || return 1
    local prerel=$($ui --yesno "Incluir pré-releases?" 8 50 2>&1 >/dev/tty; echo $?)
    local apply=$($ui --yesno "Gerar metafiles de update automaticamente (apply)?" 8 65 2>&1 >/dev/tty; echo $?)
    "$SCRIPT_BULK" ${cats:+--categories "$cats"} $([[ "$prerel" == "0" ]] && echo "--include-prerelease") $([[ "$apply" == "0" ]] && echo "--apply") --json
  else
    read -r -p "Categorias CSV (vazio= todas): " cats || true
    read -r -p "Incluir pré-releases? [y/N] " yn || true
    read -r -p "Aplicar (gerar metafiles)? [y/N] " ap || true
    "$SCRIPT_BULK" ${cats:+--categories "$cats"} $([[ "$yn" =~ ^[Yy]$ ]] && echo "--include-prerelease") $([[ "$ap" =~ ^[Yy]$ ]] && echo "--apply") --json
  fi
}

tui_graph_scan_flow(){
  "$SCRIPT_ORPH_REVD" scan
  "$SCRIPT_ORPH_REVD" stats
  "$SCRIPT_ORPH_REVD" list-orphans | sed 's/^/  - /'
}

sub_run_script(){
  local scr="${1:-}"; [[ -n "$scr" ]] || { log_e "Informe <script>"; return 2; }
  shift || true
  [[ -x "${ADM_SCRIPTS}/${scr}" ]] || { log_e "Script não encontrado: ${scr}"; return 2; }
  exec "${ADM_SCRIPTS}/${scr}" "$@"
}

###############################################################################
# CLI parsing
###############################################################################
usage_short(){
  cat <<EOF
Uso:
  ${CMD_NAME} install <nome|cat/nome> [--all-deps|--with-opt|--with-build] [--rebuild] [--dry-run] [--json]
  ${CMD_NAME} search <texto>
  ${CMD_NAME} info <nome|cat/nome>
  ${CMD_NAME} run <script> [args...]
  ${CMD_NAME} list-commands
  ${CMD_NAME} help
  ${CMD_NAME}            # abre o menu TUI
EOF
}

main(){
  local cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    clear || true
    print_logo
    menu_tui || exit 0
    exit 0
  fi
  shift || true

  case "$cmd" in
    help|-h|--help) show_full_help ;;
    list-commands)  sub_list_commands ;;
    run)            sub_run_script "${1:-}" "${@:2}" ;;
    search)         adm_search "${1:-}";;
    info)           adm_info "${1:-}";;
    install)        install_program "${1:-}" "${@:2}";;
    *) log_w "Comando inválido: $cmd"; echo; usage_short; exit 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
