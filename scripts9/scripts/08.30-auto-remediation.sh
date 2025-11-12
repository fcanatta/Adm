#!/usr/bin/env bash
# 08.30-auto-remediation.sh
# Aplica correções seguras com base no relatório do 08.20-postinstall-healthchecks.sh.

###############################################################################
# Modo estrito + traps
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__ar_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] auto-remediation falhou: code=${code} line=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __ar_err_trap ERR

###############################################################################
# Caminhos, logging, utilitários
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_LOG_DIR="${ADM_LOG_DIR:-${ADM_STATE_DIR}/logs}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"
ADM_DB_DIR="${ADM_DB_DIR:-${ADM_ROOT}/db}"
BACKUP_ROOT="${BACKUP_ROOT:-${ADM_STATE_DIR}/backups}"

__ensure_dir(){
  local d="$1" mode="${2:-0755}" owner="${3:-root}" group="${4:-root}"
  if [[ ! -d "$d" ]]; then
    if command -v install >/dev/null 2>&1; then
      if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
        sudo install -d -m "$mode" -o "$owner" -g "$group" "$d"
      else
        install -d -m "$mode" -o "$owner" -g "$group" "$d"
      fi
    else
      mkdir -p "$d"; chmod "$mode" "$d"; chown "$owner:$group" "$d" || true
    fi
  fi
}
__ensure_dir "$ADM_STATE_DIR"; __ensure_dir "$ADM_LOG_DIR"; __ensure_dir "$ADM_TMPDIR"; __ensure_dir "$ADM_DB_DIR"; __ensure_dir "$BACKUP_ROOT"

# Cores
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RST="$(tput sgr0)"; C_OK="$(tput setaf 2)"; C_WRN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INF="$(tput setaf 6)"; C_BD="$(tput bold)"
else
  C_RST=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""; C_BD=""
fi
ar_info(){  echo -e "${C_INF}[ADM]${C_RST} $*"; }
ar_ok(){    echo -e "${C_OK}[OK ]${C_RST} $*"; }
ar_warn(){  echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
ar_err(){   echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }
tmpfile(){ mktemp "${ADM_TMPDIR}/ar.XXXXXX"; }
sha256f(){ sha256sum "$1" | awk '{print $1}'; }
adm_is_cmd(){ command -v "$1" >/dev/null 2>&1; }

# Locks
__lock(){
  local name="$1"; __ensure_dir "$ADM_STATE_DIR/locks"
  exec {__AR_FD}>"$ADM_STATE_DIR/locks/${name}.lock"
  flock -n ${__AR_FD} || { ar_warn "aguardando lock de ${name}…"; flock ${__AR_FD}; }
}
__unlock(){ :; }

###############################################################################
# Hooks
###############################################################################
declare -A ADM_META  # opcional: category, name, version
__pkg_root(){
  local c="${ADM_META[category]:-}" n="${ADM_META[name]:-}"
  [[ -n "$c" && -n "$n" ]] || { echo ""; return 1; }
  printf '%s/%s/%s' "$ADM_ROOT" "$c" "$n"
}
__hooks_dirs(){
  local pr; pr="$(__pkg_root)" || true
  printf '%s\n' "$pr/hooks" "$ADM_ROOT/hooks"
}
ar_hooks_run(){
  local stage="${1:?}"; shift || true
  local d f ran=0
  for d in $(__hooks_dirs); do
    [[ -d "$d" ]] || continue
    for f in "$d/$stage" "$d/$stage.sh"; do
      if [[ -x "$f" ]]; then
        ar_info "Hook: $(realpath -m "$f")"
        ( set -Eeuo pipefail; "$f" "$@" )
        ran=1
      fi
    done
  done
  (( ran )) || ar_info "Hook '${stage}': nenhum"
}

###############################################################################
# CLI
###############################################################################
ROOT="/"                   # raiz alvo
MODE="ask"                 # auto|ask|plan
DRYRUN=0
FROM_JSON=""               # caminho para JSON do 08.20
RUN_HEALTHCHECKS=0         # gerar JSON internamente
SNAPSHOT_BEFORE=0          # cria snapshot antes das alterações
JSON_OUT=0                 # emitir plano/resultados em JSON
SELECT=""                  # CSV de fixers a aplicar (filtro)
SKIP=""                    # CSV de fixers a pular
LOGPATH=""                 # log desta execução
declare -A AR_STATS=( [APPLIED]=0 [SKIPPED]=0 [FAILED]=0 )

# Fixers canônicos (mapeiam checks → ações)
ALL_FIXERS="symlinks perms ldconfig mandb infodir desktop mime icons systemd shebangs pkgconfig rpath ownership stray"

ar_usage(){
  cat <<'EOF'
Uso:
  08.30-auto-remediation.sh [opções]

Opções:
  --root PATH                Raiz (default /)
  --mode auto|ask|plan       auto=aplica sem perguntar; ask=confirma; plan=gera plano e sai
  --dry-run                  Simula correções (não altera)
  --from-json FILE           Usa JSON do 08.20-postinstall-healthchecks.sh
  --run-healthchecks         Executa 08.20 para gerar JSON (requer jq)
  --snapshot-before          Tira snapshot antes de aplicar (07.20-rollback-snapshots.sh)
  --json                     Emite plano/resultado em JSON
  --select CSV               Aplica somente estes fixers
  --skip CSV                 Ignora estes fixers
  --category CAT --name NAME --version VER   (para hooks/contexto)
  --log PATH                 Salvar log desta execução
  --help
Fixers:
  symlinks, perms, ldconfig, mandb, infodir, desktop, mime, icons,
  systemd, shebangs, pkgconfig, rpath, ownership, stray
EOF
}

parse_cli(){
  while (($#)); do
    case "$1" in
      --root) ROOT="${2:-/}"; shift 2 ;;
      --mode) MODE="${2:-ask}"; shift 2 ;;
      --dry-run) DRYRUN=1; shift ;;
      --from-json) FROM_JSON="${2:-}"; shift 2 ;;
      --run-healthchecks) RUN_HEALTHCHECKS=1; shift ;;
      --snapshot-before) SNAPSHOT_BEFORE=1; shift ;;
      --json) JSON_OUT=1; shift ;;
      --select) SELECT="${2:-}"; shift 2 ;;
      --skip) SKIP="${2:-}"; shift 2 ;;
      --category) ADM_META[category]="${2:-}"; shift 2 ;;
      --name) ADM_META[name]="${2:-}"; shift 2 ;;
      --version) ADM_META[version]="${2:-}"; shift 2 ;;
      --log) LOGPATH="${2:-}"; shift 2 ;;
      --help|-h) ar_usage; exit 0 ;;
      *) ar_err "opção inválida: $1"; ar_usage; exit 2 ;;
    esac
  done
  case "$MODE" in auto|ask|plan) : ;; *) ar_err "--mode inválido"; exit 2 ;; esac
}

###############################################################################
# Saúde / JSON de entrada
###############################################################################
__generate_health_json(){
  adm_is_cmd jq || { ar_err "jq necessário para --run-healthchecks"; return 2; }
  local out; out="$(tmpfile)"
  local script="${ADM_ROOT}/scripts/08.20-postinstall-healthchecks.sh"
  [[ -x "$script" ]] || { ar_err "script 08.20 não encontrado: $script"; return 2; }
  # scope auto usa DB se houver
  "$script" --root "$ROOT" --scope auto --json > "$out"
  echo "$out"
}

__load_json(){
  local path="$1"
  [[ -r "$path" ]] || { ar_err "JSON não legível: $path"; return 2; }
  cat "$path"
}

###############################################################################
# Plano de correções
###############################################################################
__csv_to_arr(){ local IFS=','; read -r -a arr <<< "$1"; printf '%s\n' "${arr[@]}" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | sed '/^$/d'; }
__selected(){
  local name="$1"
  local -a sel; mapfile -t sel < <(__csv_to_arr "$SELECT")
  local -a skp; mapfile -t skp < <(__csv_to_arr "$SKIP")
  if ((${#sel[@]}>0)); then
    local x; for x in "${sel[@]}"; do [[ "$x" == "$name" ]] && { for y in "${skp[@]}"; do [[ "$y" == "$name" ]] && return 1; done; return 0; }; done
    return 1
  fi
  local y; for y in "${skp[@]}"; do [[ "$y" == "$name" ]] && return 1; done
  return 0
}

# Constrói um plano (lista JSON) a partir do relatório do 08.20
build_plan_from_json(){
  local json="$1"
  adm_is_cmd jq || { ar_err "jq é necessário para processar o relatório"; exit 2; }
  # Mapeia cada detalhe -> tarefa de fixer
  # Regras básicas:
  # - symlinks FAIL → fix_symlinks (recriar/limpar quebrados)
  # - ldd FAIL → apenas avisa (não resolvemos dependência automaticamente), roda ldconfig
  # - rpath WARN → fix_rpath
  # - pkgconfig WARN → fix_pkgconfig
  # - shebangs FAIL → fix_shebangs
  # - {ldconfig,mandb,infodir,desktop,mime,icons} → respectivos fixers
  # - systemd WARN/PASS → se WARN, tentar daemon-reload + verify
  # - perms/ownership/stray WARN → respectivos fixers conservadores
  local tmp; tmp="$(tmpfile)"
  jq -r '
    .details[] |
    {level, check, msg} |
    select((.level=="FAIL") or (.level=="WARN")) |
    . as $d |
    if .check=="symlinks" and (.level=="FAIL") then {fixer:"symlinks", reason:$d.msg}
    elif .check=="ldd" and (.level=="FAIL") then {fixer:"ldconfig", reason:$d.msg}
    elif .check=="rpath" then {fixer:"rpath", reason:$d.msg}
    elif .check=="pkgconfig" then {fixer:"pkgconfig", reason:$d.msg}
    elif .check=="shebangs" and (.level=="FAIL") then {fixer:"shebangs", reason:$d.msg}
    elif .check=="mandb" then {fixer:"mandb", reason:$d.msg}
    elif .check=="infodir" then {fixer:"infodir", reason:$d.msg}
    elif .check=="desktop" then {fixer:"desktop", reason:$d.msg}
    elif .check=="mime" then {fixer:"mime", reason:$d.msg}
    elif .check=="icons" then {fixer:"icons", reason:$d.msg}
    elif .check=="systemd" then {fixer:"systemd", reason:$d.msg}
    elif .check=="perms" then {fixer:"perms", reason:$d.msg}
    elif .check=="ownership" then {fixer:"ownership", reason:$d.msg}
    elif .check=="stray" then {fixer:"stray", reason:$d.msg}
    else empty end
  ' <<< "$json" > "$tmp"
  # de-duplicar por fixer
  local uniq; uniq="$(tmpfile)"
  awk -F'\t' '{print $0}' "$tmp" | sort -u > "$uniq"
  # Embala em JSON
  local plan; plan="$(tmpfile)"
  echo "[]" > "$plan"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local f reason
    f="$(jq -n --argjson o "$line" '$o' 2>/dev/null || echo "")"
    [[ -n "$f" ]] || continue
    echo "$f"
  done < <(jq -c . "$uniq") | jq -s '.' 2>/dev/null
}

###############################################################################
# Backups e snapshot
###############################################################################
__backup_file(){
  local src="$1"
  local ts="${TS_BACKUP:?}"
  local dst="${BACKUP_ROOT}/${ts}${src}"
  __ensure_dir "$(dirname "$dst")"
  if [[ -e "$src" ]]; then
    if (( DRYRUN )); then ar_info "(dry-run) backup de $src → $dst"; else cp --reflink=auto -a "$src" "$dst"; fi
  fi
}
__maybe_snapshot(){
  (( SNAPSHOT_BEFORE )) || return 0
  local ss="${ADM_ROOT}/scripts/07.20-rollback-snapshots.sh"
  [[ -x "$ss" ]] || { ar_warn "snapshot solicitado mas 07.20 não encontrado"; return 0; }
  ar_info "Criando snapshot pré-mudanças…"
  "$ss" create --root "$ROOT" --label "auto-remediation $(date -u +%FT%TZ)" || ar_warn "snapshot retornou erro"
}

###############################################################################
# Aplicadores (fixers)
###############################################################################
fix_symlinks(){
  ar_hooks_run "pre-fix-symlinks"
  local fixed=0 removed=0
  # Reescaneia symlinks sob ROOT procurando quebrados
  while IFS= read -r -d '' link; do
    local target; target="$(readlink "$link" 2>/dev/null || true)"
    local abs="$(readlink -f "$link" 2>/dev/null || true)"
    [[ -e "$abs" ]] && continue
    # tentativa 1: se target for absoluto e existir sob ROOT, reconstruir relativo
    if [[ "$target" == /* && -e "${ROOT%/}$target" ]]; then
      local relbase; relbase="$(dirname "$link")"
      local relpath; relpath="$(realpath --relative-to="$relbase" "${ROOT%/}$target" 2>/dev/null || echo "$target")"
      __backup_file "$link"
      if (( DRYRUN )); then ar_info "(dry-run) ln -snf '$relpath' '$link'"
      else ln -snf "$relpath" "$link"; fi
      ((fixed++))
    else
      # sem alvo conhecido: remover symlink quebrado
      __backup_file "$link"
      if (( DRYRUN )); then ar_info "(dry-run) rm -f '$link'"; else rm -f "$link"; fi
      ((removed++))
    fi
  done < <(find "${ROOT%/}" -xdev -type l -print0 2>/dev/null)
  ar_hooks_run "post-fix-symlinks" "FIXED=$fixed" "REMOVED=$removed"
  ar_ok "symlinks: corrigidos=$fixed removidos=$removed"
}

fix_ldconfig(){
  if adm_is_cmd ldconfig; then
    if (( DRYRUN )); then ar_info "(dry-run) ldconfig"; else ldconfig || ar_warn "ldconfig retornou erro"; fi
    ar_ok "ldconfig atualizado"
  else
    ar_warn "ldconfig indisponível; nada a fazer"
  fi
}

fix_mandb(){
  local manpath="${ROOT%/}/usr/share/man"
  [[ -d "$manpath" ]] || { ar_info "sem manpages"; return 0; }
  if adm_is_cmd mandb; then
    if (( DRYRUN )); then ar_info "(dry-run) mandb -q"; else mandb -q || true; fi
    ar_ok "mandb atualizado"
  else
    ar_warn "mandb indisponível"
  fi
}

fix_infodir(){
  local infod="${ROOT%/}/usr/share/info"
  [[ -d "$infod" ]] || { ar_info "sem info-dir"; return 0; }
  if adm_is_cmd install-info; then
    shopt -s nullglob
    for f in "$infod"/*.info "$infod"/*.info.gz; do
      if (( DRYRUN )); then ar_info "(dry-run) install-info '$f' '$infod/dir'"
      else install-info "$f" "$infod/dir" >/dev/null 2>&1 || true; fi
    done
    shopt -u nullglob
    ar_ok "info-dir atualizado"
  else
    ar_warn "install-info indisponível"
  fi
}

fix_desktop(){
  local ddir="${ROOT%/}/usr/share/applications"
  [[ -d "$ddir" ]] || { ar_info "sem desktop files"; return 0; }
  if adm_is_cmd update-desktop-database; then
    if (( DRYRUN )); then ar_info "(dry-run) update-desktop-database -q '$ddir'"
    else update-desktop-database -q "$ddir" || true; fi
    ar_ok "desktop database atualizado"
  else
    ar_warn "update-desktop-database indisponível"
  fi
}

fix_mime(){
  local mdir="${ROOT%/}/usr/share/mime"
  [[ -d "$mdir" ]] || { ar_info "sem mime database"; return 0; }
  if adm_is_cmd update-mime-database; then
    if (( DRYRUN )); then ar_info "(dry-run) update-mime-database '$mdir'"
    else update-mime-database "$mdir" >/dev/null 2>&1 || true; fi
    ar_ok "mime database atualizado"
  else
    ar_warn "update-mime-database indisponível"
  fi
}

fix_icons(){
  local idir="${ROOT%/}/usr/share/icons"
  [[ -d "$idir" ]] || { ar_info "sem ícones"; return 0; }
  if adm_is_cmd gtk-update-icon-cache; then
    shopt -s nullglob
    for theme in "$idir"/*; do
      [[ -d "$theme" ]] || continue
      if (( DRYRUN )); then ar_info "(dry-run) gtk-update-icon-cache -f -q '$theme'"
      else gtk-update-icon-cache -f -q "$theme" || true; fi
    done
    shopt -u nullglob
    ar_ok "icon caches atualizados"
  else
    ar_warn "gtk-update-icon-cache indisponível"
  fi
}

fix_systemd(){
  if adm_is_cmd systemctl; then
    if (( DRYRUN )); then
      ar_info "(dry-run) systemctl daemon-reload"
    else
      systemctl daemon-reload || ar_warn "daemon-reload retornou erro"
    fi
    if adm_is_cmd systemd-analyze; then
      while IFS= read -r u; do
        if (( DRYRUN )); then ar_info "(dry-run) systemd-analyze verify '$u'"
        else systemd-analyze verify "$u" >/dev/null 2>&1 || ar_warn "unit com issues: $u"; fi
      done < <(find "${ROOT%/}/usr/lib/systemd" "${ROOT%/}/etc/systemd" -type f -name '*.service' 2>/dev/null || true)
    fi
    ar_ok "systemd atualizado"
  else
    ar_info "systemd ausente; nada a fazer"
  fi
}

fix_shebangs(){
  ar_hooks_run "pre-fix-shebangs"
  local changed=0
  while IFS= read -r -d '' f; do
    [[ -f "$f" && -x "$f" ]] || continue
    local first; IFS= read -r first < "$f" || true
    [[ "$first" =~ ^#! ]] || continue
    local interpreter="${first#\#!}"; interpreter="$(echo "$interpreter" | awk '{print $1}')"
    local use=""
    if [[ "$(basename "$interpreter")" == "env" ]]; then
      local lang; lang="$(echo "$first" | awk '{print $2}')" || true
      [[ -n "$lang" ]] && use="$(command -v "$lang" 2>/dev/null || true)"
    else
      use="$interpreter"
    fi
    # Se não existe, tentar mapear linguagens comuns
    if [[ -z "$use" || ! -x "$use" ]]; then
      case "$first" in
        *python*) use="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)" ;;
        *bash*)   use="$(command -v bash 2>/dev/null || true)" ;;
        *sh*)     use="$(command -v sh 2>/dev/null || true)" ;;
        *perl*)   use="$(command -v perl 2>/dev/null || true)" ;;
        *ruby*)   use="$(command -v ruby 2>/dev/null || true)" ;;
      esac
    fi
    [[ -n "$use" && -x "$use" ]] || { ar_warn "sem intérprete válido para $f ($first)"; continue; }
    # Reescrever para /usr/bin/env <lang> quando possível
    local langbin="$(basename "$use")"
    local newshe="#!/usr/bin/env ${langbin}"
    if (( DRYRUN )); then
      ar_info "(dry-run) atualizar shebang de '$f' → '$newshe'"
    else
      __backup_file "$f"
      { echo "$newshe"; tail -n +2 "$f"; } > "${f}.tmp" && cat "${f}.tmp" > "$f" && rm -f "${f}.tmp"
      chmod +x "$f"
    fi
    ((changed++))
  done < <(find "${ROOT%/}/usr" "${ROOT%/}/bin" -xdev -type f -perm -0100 -print0 2>/dev/null || true)
  ar_hooks_run "post-fix-shebangs" "CHANGED=$changed"
  ar_ok "shebangs: atualizados=$changed"
}

fix_pkgconfig(){
  ar_hooks_run "pre-fix-pkgconfig"
  local fixed=0
  while IFS= read -r -d '' pc; do
    [[ -r "$pc" ]] || continue
    local before="$(sha256f "$pc")"
    # Corrige prefix incorreto contendo paths temporários/DESTDIR repetido
    local prefix line newpc; prefix="$(grep -E '^prefix=' "$pc" 2>/dev/null || true)"
    newpc="$(tmpfile)"
    cp -f "$pc" "$newpc"
    # Remover ocorrências de ROOT duplicado tipo // ou /destdir/tmp…
    sed -i -E "s#${ROOT%/}${ROOT%/}#${ROOT%/}#g" "$newpc"
    # Validar -I e -L
    local changed=0
    while read -r line; do
      [[ "$line" == Cflags:* || "$line" == Libs:* ]] || continue
      for tok in $line; do
        if [[ "$tok" == -I* ]]; then
          local inc="${tok#-I}"
          [[ -d "$inc" || -d "${ROOT%/}/${inc#/}" ]] || { changed=1; }
        elif [[ "$tok" == -L* ]]; then
          local libd="${tok#-L}"
          [[ -d "$libd" || -d "${ROOT%/}/${libd#/}" ]] || { changed=1; }
        fi
      done
    done < "$pc"
    if (( changed )); then
      # Heurística: substituir prefix para /usr se o arquivo reside em /usr/lib/pkgconfig
      if [[ "$pc" == ${ROOT%/}/usr/lib/pkgconfig/* || "$pc" == ${ROOT%/}/usr/share/pkgconfig/* ]]; then
        sed -i -E 's#^prefix=.*#prefix=/usr#g' "$newpc"
      fi
    fi
    local after="$(sha256f "$newpc")"
    if [[ "$before" != "$after" ]]; then
      __backup_file "$pc"
      if (( DRYRUN )); then ar_info "(dry-run) atualizar '$pc'"
      else mv -f "$newpc" "$pc"; fi
      ((fixed++))
    else
      rm -f "$newpc" || true
    fi
  done < <(find "${ROOT%/}/usr/lib/pkgconfig" "${ROOT%/}/usr/share/pkgconfig" -type f -name '*.pc' -print0 2>/dev/null || true)
  ar_hooks_run "post-fix-pkgconfig" "FIXED=$fixed"
  ar_ok "pkgconfig: ajustados=$fixed"
}

fix_rpath(){
  ar_hooks_run "pre-fix-rpath"
  local fixed=0 skipped=0
  local tool=""
  if adm_is_cmd patchelf; then tool="patchelf"
  elif adm_is_cmd chrpath; then tool="chrpath"
  else ar_warn "patchelf/chrpath indisponíveis; não é possível ajustar RPATH"; return 0
  fi
  # Alvos: ELF sob /usr/bin /usr/lib* /lib*
  while IFS= read -r -d '' f; do
    file -b "$f" 2>/dev/null | grep -qi 'ELF' || continue
    local cur=""
    if [[ "$tool" == "patchelf" ]]; then
      cur="$(patchelf --print-rpath "$f" 2>/dev/null || echo "")"
    else
      cur="$(chrpath -l "$f" 2>/dev/null | sed -E 's/.*R.*PATH=//')"
    fi
    [[ -z "$cur" ]] && { ((skipped++)); continue; }
    # Remove caminhos relativos e inexistentes; mantém $ORIGIN
    IFS=':' read -r -a arr <<< "$cur"
    local new=() p
    for p in "${arr[@]}"; do
      [[ "$p" == '$ORIGIN'* ]] && { new+=( "$p" ); continue; }
      [[ "$p" == /* ]] || continue
      [[ -d "$p" ]] || continue
      new+=( "$p" )
    done
    local joined; joined="$(IFS=':'; echo "${new[*]}")"
    [[ "$joined" == "$cur" ]] && { ((skipped++)); continue; }
    __backup_file "$f"
    if (( DRYRUN )); then
      ar_info "(dry-run) ${tool} --set-rpath '$joined' '$f'"
    else
      if [[ "$tool" == "patchelf" ]]; then patchelf --set-rpath "$joined" "$f"
      else chrpath -r "$joined" "$f" >/dev/null 2>&1; fi
    fi
    ((fixed++))
  done < <(find "${ROOT%/}/usr/bin" "${ROOT%/}/usr/lib" "${ROOT%/}/usr/lib64" "${ROOT%/}/lib" "${ROOT%/}/lib64" -type f -perm -0100 -print0 2>/dev/null || true)
  ar_hooks_run "post-fix-rpath" "FIXED=$fixed" "SKIPPED=$skipped"
  ar_ok "rpath: ajustados=$fixed ignorados=$skipped"
}

fix_perms(){
  ar_hooks_run "pre-fix-perms"
  local sticky=0
  while IFS= read -r -d '' d; do
    # se world-writable e sem sticky, aplicar sticky
    local pm; pm="$(stat -c '%a' "$d" 2>/dev/null || echo "")"
    [[ -z "$pm" ]] && continue
    local last="${pm: -1}"
    if (( (last & 2) == 2 )); then
      if (( DRYRUN )); then ar_info "(dry-run) chmod +t '$d'"
      else chmod +t "$d"; fi
      ((sticky++))
    fi
  done < <(find "${ROOT%/}/var/tmp" "${ROOT%/}/tmp" -maxdepth 1 -type d -print0 2>/dev/null || true)
  ar_hooks_run "post-fix-perms" "STICKY=$sticky"
  ar_ok "perms: sticky aplicado em $sticky diretórios"
}

fix_ownership(){
  ar_hooks_run "pre-fix-ownership"
  local fixed=0
  while IFS= read -r -d '' f; do
    [[ -e "$f" ]] || continue
    local own grp; own="$(stat -c '%U' "$f" 2>/dev/null || echo '?')"; grp="$(stat -c '%G' "$f" 2>/dev/null || echo '?')"
    [[ "$own" == "root" ]] && continue
    __backup_file "$f"
    if (( DRYRUN )); then ar_info "(dry-run) chown root:root '$f'"
    else chown root:root "$f"; fi
    ((fixed++))
  done < <(find "${ROOT%/}/usr" "${ROOT%/}/bin" "${ROOT%/}/lib" "${ROOT%/}/lib64" "${ROOT%/}/sbin" "${ROOT%/}/etc" -xdev -print0 2>/dev/null || true)
  ar_hooks_run "post-fix-ownership" "FIXED=$fixed"
  ar_ok "ownership: ajustados=$fixed"
}

fix_stray(){
  ar_hooks_run "pre-fix-stray"
  local removed=0
  while IFS= read -r -d '' f; do
    __backup_file "$f"
    if (( DRYRUN )); then ar_info "(dry-run) rm -f '$f'"; else rm -f "$f"; fi
    ((removed++))
  done < <(find "${ROOT%/}" -xdev \( -name '*.la' -o -name '*.pyc' ! -path '*/__pycache__/*' \) -print0 2>/dev/null || true)
  ar_hooks_run "post-fix-stray" "REMOVED=$removed"
  ar_ok "stray: removidos=$removed"
}
###############################################################################
# Execução do plano
###############################################################################
apply_fixer(){
  local name="$1"
  __selected "$name" || { ar_info "fixer '$name' ignorado por filtro"; ((AR_STATS[SKIPPED]++)); return 0; }
  case "$name" in
    symlinks)  fix_symlinks ;;
    perms)     fix_perms ;;
    ldconfig)  fix_ldconfig ;;
    mandb)     fix_mandb ;;
    infodir)   fix_infodir ;;
    desktop)   fix_desktop ;;
    mime)      fix_mime ;;
    icons)     fix_icons ;;
    systemd)   fix_systemd ;;
    shebangs)  fix_shebangs ;;
    pkgconfig) fix_pkgconfig ;;
    rpath)     fix_rpath ;;
    ownership) fix_ownership ;;
    stray)     fix_stray ;;
    *) ar_warn "fixer desconhecido: $name"; ((AR_STATS[SKIPPED]++)); return 0 ;;
  esac
  ((AR_STATS[APPLIED]++))
}

prompt_yes_no(){
  local msg="$1" def="${2:-y}"
  local ans
  read -r -p "$msg [y/n] (default: $def): " ans || ans="$def"
  [[ -z "$ans" ]] && ans="$def"
  [[ "$ans" =~ ^[Yy]$|^yes$|^Y$ ]]
}

run_plan(){
  local plan_json="$1"    # array de objetos {fixer, reason}
  adm_is_cmd jq || { ar_err "jq requerido para executar plano"; exit 2; }
  local fixers; fixers=($(jq -r '.[].fixer' <<< "$plan_json" | sort -u))
  (( ${#fixers[@]} )) || { ar_info "nada a corrigir"; return 0; }

  ar_info "Fixers planejados: ${fixers[*]}"

  case "$MODE" in
    plan)
      if (( JSON_OUT )); then
        jq -n --arg root "$ROOT" --arg mode "$MODE" --argjson plan "$plan_json" \
          '{root:$root, mode:$mode, plan:$plan}'
      else
        echo "Plano:"
        jq -r '.[] | "- \(.fixer): \(.reason)"' <<< "$plan_json"
      fi
      return 0
      ;;
    ask)
      echo "Plano:"
      jq -r '.[] | "- \(.fixer): \(.reason)"' <<< "$plan_json"
      prompt_yes_no "Aplicar correções?" "y" || { ar_info "abortado pelo usuário"; return 0; }
      ;;
    auto) : ;;
  esac

  __maybe_snapshot
  local f
  for f in "${fixers[@]}"; do
    ar_info "Aplicando: $f"
    apply_fixer "$f" || ((AR_STATS[FAILED]++))
  done
}

###############################################################################
# MAIN
###############################################################################
ar_run(){
  parse_cli "$@"

  # logging opcional
  if [[ -n "$LOGPATH" ]]; then
    exec > >(tee -a "$LOGPATH") 2>&1
  fi

  __lock "auto-remediation"
  ar_hooks_run "pre-remediate" "ROOT=$ROOT" "MODE=$MODE"

  # timestamp p/ backups
  TS_BACKUP="$(date -u +%Y%m%d-%H%M%S)"

  local json_in=""
  if [[ -n "$FROM_JSON" ]]; then
    json_in="$(__load_json "$FROM_JSON")"
  elif (( RUN_HEALTHCHECKS )); then
    local gen; gen="$(__generate_health_json)"; json_in="$(cat "$gen")"
  else
    ar_err "Forneça --from-json ou --run-healthchecks"
  fi

  # Planejamento
  local plan_json; plan_json="$(build_plan_from_json "$json_in")"
  run_plan "$plan_json"

  ar_hooks_run "post-remediate" "ROOT=$ROOT" \
    "APPLIED=${AR_STATS[APPLIED]}" "SKIPPED=${AR_STATS[SKIPPED]}" "FAILED=${AR_STATS[FAILED]}"
  __unlock

  # Relatório final
  if (( JSON_OUT )) && adm_is_cmd jq; then
    jq -n --arg applied "${AR_STATS[APPLIED]}" --arg skipped "${AR_STATS[SKIPPED]}" --arg failed "${AR_STATS[FAILED]}" \
      '{result:{applied:($applied|tonumber), skipped:($skipped|tonumber), failed:($failed|tonumber)}}'
  else
    ar_info "Resultado: APPLIED=${AR_STATS[APPLIED]} SKIPPED=${AR_STATS[SKIPPED]} FAILED=${AR_STATS[FAILED]}"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ar_run "$@"
fi
