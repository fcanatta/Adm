#!/usr/bin/env bash
# 09.10-uninstall-gc.sh
# Desinstalação segura baseada no DB + GC de órfãos/caches.
###############################################################################
# Modo estrito + traps
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__ug_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] uninstall-gc falhou: code=${code} line=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __ug_err_trap ERR

###############################################################################
# Caminhos, logging, utilitários
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_LOG_DIR="${ADM_LOG_DIR:-${ADM_STATE_DIR}/logs}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"
ADM_DB_DIR="${ADM_DB_DIR:-${ADM_ROOT}/db}"

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
__ensure_dir "$ADM_STATE_DIR"; __ensure_dir "$ADM_LOG_DIR"; __ensure_dir "$ADM_TMPDIR"; __ensure_dir "$ADM_DB_DIR"

# Cores
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RST="$(tput sgr0)"; C_OK="$(tput setaf 2)"; C_WRN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INF="$(tput setaf 6)"; C_BD="$(tput bold)"
else
  C_RST=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""; C_BD=""
fi
ug_info(){  echo -e "${C_INF}[ADM]${C_RST} $*"; }
ug_ok(){    echo -e "${C_OK}[OK ]${C_RST} $*"; }
ug_warn(){  echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
ug_err(){   echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }
tmpfile(){ mktemp "${ADM_TMPDIR}/ug.XXXXXX"; }
sha256f(){ sha256sum "$1" | awk '{print $1}'; }
adm_is_cmd(){ command -v "$1" >/dev/null 2>&1; }

# Locks
__lock(){
  local name="$1"; __ensure_dir "$ADM_STATE_DIR/locks"
  exec {__UG_FD}>"$ADM_STATE_DIR/locks/${name}.lock"
  flock -n ${__UG_FD} || { ug_warn "aguardando lock de ${name}…"; flock ${__UG_FD}; }
}
__unlock(){ :; }  # FD fecha na saída

###############################################################################
# Hooks
###############################################################################
declare -A ADM_META  # category, name, version (opcional)
__pkg_root(){
  local c="${ADM_META[category]:-}" n="${ADM_META[name]:-}"
  [[ -n "$c" && -n "$n" ]] || { echo ""; return 1; }
  printf '%s/%s/%s' "$ADM_ROOT" "$c" "$n"
}
__hooks_dirs(){
  local pr; pr="$(__pkg_root)" || true
  printf '%s\n' "$pr/hooks" "$ADM_ROOT/hooks"
}
ug_hooks_run(){
  local stage="${1:?}"; shift || true
  local d f ran=0
  for d in $(__hooks_dirs); do
    [[ -d "$d" ]] || continue
    for f in "$d/$stage" "$d/$stage.sh"; do
      if [[ -x "$f" ]]; then
        ug_info "Hook: $(realpath -m "$f")"
        ( set -Eeuo pipefail; "$f" "$@" )
        ran=1
      fi
    done
  done
  (( ran )) || ug_info "Hook '${stage}': nenhum"
}

###############################################################################
# CLI
###############################################################################
CMD=""                      # uninstall|gc|purge|list-files|whatowns
ROOT="/"                    # raiz alvo
DRYRUN=0
PURGE=0                     # remove também config/dados
KEEP_CONFIG=0               # mantém arquivos *.conf e em /etc
FORCE=0                     # força ação mesmo com riscos (use com cautela)
JSON_OUT=0                  # saída JSON em listagens
LOGPATH=""                  # arquivo de log
ORPHAN_DEPTH=3              # profundidade máxima de remoção de diretórios vazios

# Identificação do pacote
ADM_META[category]=""
ADM_META[name]=""
ADM_META[version]=""

ug_usage(){
  cat <<'EOF'
Uso:
  09.10-uninstall-gc.sh <comando> [opções]

Comandos:
  uninstall            Desinstala um pacote (usa DB de instalados)
  purge                Desinstala + remove configs/dados associados
  gc                   Coleta de lixo: órfãos, symlinks quebrados, dirs vazios, caches
  list-files           Lista arquivos instalados por um pacote
  whatowns <arquivo>   Diz qual pacote (ou quais) possui o arquivo

Opções:
  --root PATH          Raiz alvo (default: /)
  --category CAT       Categoria do pacote
  --name NAME          Nome do pacote
  --version VER        Versão (opcional; se omitida, usa diretório em uso)
  --dry-run            Simula
  --purge              (em uninstall) remove também configs/dados
  --keep-config        Mantém /etc e *.conf (tem precedência sobre --purge)
  --force              Ignora alguns bloqueios de segurança (cuidado!)
  --json               Saída JSON quando aplicável
  --log PATH           Salva log detalhado
  --orphan-depth N     Níveis para remoção de diretórios vazios (default 3)
  --help
EOF
}

parse_cli(){
  [[ $# -ge 1 ]] || { ug_usage; exit 2; }
  CMD="$1"; shift
  local pos=()
  while (($#)); do
    case "$1" in
      --root) ROOT="${2:-/}"; shift 2 ;;
      --category) ADM_META[category]="${2:-}"; shift 2 ;;
      --name) ADM_META[name]="${2:-}"; shift 2 ;;
      --version) ADM_META[version]="${2:-}"; shift 2 ;;
      --dry-run) DRYRUN=1; shift ;;
      --purge) PURGE=1; shift ;;
      --keep-config) KEEP_CONFIG=1; shift ;;
      --force) FORCE=1; shift ;;
      --json) JSON_OUT=1; shift ;;
      --log) LOGPATH="${2:-}"; shift 2 ;;
      --orphan-depth) ORPHAN_DEPTH="${2:-3}"; shift 2 ;;
      --help|-h) ug_usage; exit 0 ;;
      *) pos+=("$1"); shift ;;
    esac
  done
  POSITIONAL=("${pos[@]}")
  case "$CMD" in
    uninstall|purge|gc|list-files|whatowns) : ;;
    *) ug_err "comando inválido: $CMD"; ug_usage; exit 2 ;;
  esac
}

###############################################################################
# DB e helpers de pacote
###############################################################################
__db_pkg_dir(){ local c="${ADM_META[category]}" n="${ADM_META[name]}"; [[ -n "$c" && -n "$n" ]] || { echo ""; return 1; }; echo "${ADM_DB_DIR}/installed/${c}/${n}"; }
__db_files(){ echo "$(__db_pkg_dir)/files.lst"; }
__db_meta(){ echo "$(__db_pkg_dir)/meta.json"; }
__db_manifest(){ echo "$(__db_pkg_dir)/manifest.json"; }

__require_root(){
  [[ $EUID -eq 0 ]] || { ug_err "requer root para desinstalar"; exit 1; }
}

__safe_under_root(){
  local path="$1"
  local abs; abs="$(realpath -m "$path")"
  local base; base="$(realpath -m "$ROOT")"
  [[ "$abs" == "$base"* ]]
}

__deny_dangerous_prefix(){
  local p="$1"
  case "$p" in
    "/"|"/usr"|"/usr/bin"|"/usr/lib"|"/usr/lib64"|"/bin"|"/lib"|"/lib64")
      ug_err "prefixo perigoso para remoção: $p"; return 1 ;;
  esac
  return 0
}

__others_own_file(){
  # retorna 0 se algum outro pacote também lista o arquivo
  local file="$1" c="${ADM_META[category]}" n="${ADM_META[name]}"
  local owner_count=0
  if compgen -G "${ADM_DB_DIR}/installed/*/*/files.lst" >/dev/null; then
    while IFS= read -r fl; do
      [[ "$fl" == "$(__db_files)" ]] && continue
      grep -qx -- "${file}" "$fl" 2>/dev/null && ((owner_count++))
      (( owner_count>0 )) && break || true
    done < <(find "${ADM_DB_DIR}/installed" -type f -name 'files.lst' -print 2>/dev/null)
  fi
  (( owner_count>0 ))
}

__list_package_files(){
  local fl="$(__db_files)"
  [[ -s "$fl" ]] || { ug_err "files.lst ausente ou vazio para $(__db_pkg_dir)"; return 2; }
  # paths são relativos a ROOT no DB (começam com '/')
  cat "$fl"
}
###############################################################################
# Núcleo de desinstalação
###############################################################################
__remove_file(){
  local f="$1"
  __safe_under_root "${ROOT%/}/${f#/}" || { ug_err "caminho fora de --root: $f"; return 2; }
  local abs="${ROOT%/}/${f#/}"
  [[ -e "$abs" || -L "$abs" ]] || { ug_warn "ausente: $f"; return 0; }

  # proteção de configs
  if (( KEEP_CONFIG )); then
    case "$f" in
      /etc/*|*.conf) ug_info "mantendo config: $f (KEEP_CONFIG)"; return 0 ;;
    esac
  fi

  # se compartilhado por outros pacotes, não remove
  if __others_own_file "$f"; then
    ug_info "compartilhado: $f (mantido)"
    return 0
  fi

  # não apagar diretório aqui; tratar depois
  if [[ -d "$abs" && ! -L "$abs" ]]; then
    ug_info "adiando diretório: $f"
    echo "$abs" >> "$DIRS_QUEUE"
    return 0
  fi

  if (( DRYRUN )); then
    echo "(dry-run) rm -f '$abs'"
  else
    rm -f -- "$abs"
  fi
}

__remove_dirs_queue(){
  local depth="${1:-$ORPHAN_DEPTH}"
  [[ -s "$DIRS_QUEUE" ]] || return 0
  # Ordena por profundidade decrescente para remover filhos antes
  awk '{print length($0) "\t" $0}' "$DIRS_QUEUE" | sort -rn | cut -f2- | while read -r d; do
    __safe_under_root "$d" || continue
    __deny_dangerous_prefix "$d" || continue
    # só remove se vazio
    if [[ -d "$d" ]]; then
      local lvl=0 cur="$d"
      while (( lvl < depth )); do
        if [[ -d "$cur" && -z "$(ls -A "$cur" 2>/dev/null || true)" ]]; then
          if (( DRYRUN )); then
            echo "(dry-run) rmdir '$cur'"
          else
            rmdir --ignore-fail-on-non-empty "$cur" 2>/dev/null || true
          fi
        fi
        cur="$(dirname "$cur")"; ((lvl++))
      done
    fi
  done
}

__uninstall_package(){
  __require_root
  __lock "uninstall"
  ug_hooks_run "pre-uninstall" "ROOT=$ROOT" "CATEGORY=${ADM_META[category]}" "NAME=${ADM_META[name]}" "VERSION=${ADM_META[version]}"

  local db="$(__db_pkg_dir)"
  [[ -d "$db" ]] || { ug_err "pacote não encontrado no DB: $db"; __unlock; return 2; }

  # lista de arquivos a remover
  local list; list="$(tmpfile)"
  __list_package_files > "$list"

  # fila de diretórios
  DIRS_QUEUE="$(tmpfile)"

  # remoção
  local f removed=0 kept=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if (( PURGE )); then
      # em purge, KEEP_CONFIG ainda tem precedência
      : # comportamento já respeitado em __remove_file
    fi
    __remove_file "$f" && ((removed++)) || ((kept++))
  done < "$list"

  # tentar remover diretórios vazios
  __remove_dirs_queue "$ORPHAN_DEPTH"

  # limpa DB do pacote (só se não for dry-run)
  if (( DRYRUN )); then
    echo "(dry-run) limpar DB de $db"
  else
    rm -f "$db/files.lst" "$db/manifest.json" "$db/.installed" 2>/dev/null || true
    # se vazio, remover diretório do pacote/categoria
    rmdir "$db" 2>/dev/null || true
    rmdir "$(dirname "$db")" 2>/dev/null || true
  fi

  ug_hooks_run "post-uninstall" "ROOT=$ROOT" "CATEGORY=${ADM_META[category]}" "NAME=${ADM_META[name]}"

  __unlock
  ug_ok "Desinstalação concluída. removidos=$removed mantidos=$kept (dry-run=$DRYRUN)"
}

###############################################################################
# GC de órfãos e caches
###############################################################################
__gc_orphans(){
  __lock "gc"
  ug_hooks_run "pre-gc" "ROOT=$ROOT"

  local removed=0 fixed=0

  # 1) symlinks quebrados
  while IFS= read -r -d '' l; do
    local tgt; tgt="$(readlink -f "$l" 2>/dev/null || true)"
    [[ -e "$tgt" ]] && continue
    if (( DRYRUN )); then echo "(dry-run) rm -f '$l'"; else rm -f "$l"; fi
    ((removed++))
  done < <(find "${ROOT%/}" -xdev -type l -print0 2>/dev/null)

  # 2) arquivos libtool .la & .pyc fora de __pycache__
  while IFS= read -r -d '' f; do
    if (( DRYRUN )); then echo "(dry-run) rm -f '$f'"; else rm -f "$f"; fi
    ((removed++))
  done < <(find "${ROOT%/}" -xdev \( -name '*.la' -o -name '*.pyc' ! -path '*/__pycache__/*' \) -print0 2>/dev/null)

  # 3) diretórios vazios sob /usr/local, /usr, /var/{lib,cache}, /etc (conservador)
  DIRS_QUEUE="$(tmpfile)"
  while IFS= read -r -d '' d; do
    echo "$d" >> "$DIRS_QUEUE"
  done < <(find "${ROOT%/}/usr" "${ROOT%/}/usr/local" "${ROOT%/}/var/lib" "${ROOT%/}/var/cache" "${ROOT%/}/etc" -xdev -type d -empty -print0 2>/dev/null || true)
  __remove_dirs_queue "$ORPHAN_DEPTH"

  # 4) caches e bancos de dados
  if adm_is_cmd ldconfig; then
    if (( DRYRUN )); then echo "(dry-run) ldconfig"; else ldconfig || ug_warn "ldconfig retornou erro"; fi
  fi
  if adm_is_cmd mandb && [[ -d "${ROOT%/}/usr/share/man" ]]; then
    if (( DRYRUN )); then echo "(dry-run) mandb -q"; else mandb -q || true; fi
  fi
  if adm_is_cmd install-info && [[ -d "${ROOT%/}/usr/share/info" ]]; then
    shopt -s nullglob
    for i in "${ROOT%/}"/usr/share/info/*.info*; do
      if (( DRYRUN )); then echo "(dry-run) install-info '$i' '${ROOT%/}/usr/share/info/dir'"
      else install-info "$i" "${ROOT%/}/usr/share/info/dir" >/dev/null 2>&1 || true; fi
    done
    shopt -u nullglob
  fi
  if adm_is_cmd update-desktop-database && [[ -d "${ROOT%/}/usr/share/applications" ]]; then
    if (( DRYRUN )); then echo "(dry-run) update-desktop-database -q '${ROOT%/}/usr/share/applications'"
    else update-desktop-database -q "${ROOT%/}/usr/share/applications" || true; fi
  fi
  if adm_is_cmd update-mime-database && [[ -d "${ROOT%/}/usr/share/mime" ]]; then
    if (( DRYRUN )); then echo "(dry-run) update-mime-database '${ROOT%/}/usr/share/mime'"
    else update-mime-database "${ROOT%/}/usr/share/mime" >/dev/null 2>&1 || true; fi
  fi
  if adm_is_cmd gtk-update-icon-cache && [[ -d "${ROOT%/}/usr/share/icons" ]]; then
    shopt -s nullglob
    for th in "${ROOT%/}"/usr/share/icons/*; do
      [[ -d "$th" ]] || continue
      if (( DRYRUN )); then echo "(dry-run) gtk-update-icon-cache -f -q '$th'"
      else gtk-update-icon-cache -f -q "$th" || true; fi
    done
    shopt -u nullglob
  fi
  if adm_is_cmd systemctl; then
    if (( DRYRUN )); then echo "(dry-run) systemctl daemon-reload"; else systemctl daemon-reload || true; fi
  fi

  ug_hooks_run "post-gc" "ROOT=$ROOT"
  __unlock
  ug_ok "GC concluído. removidos=$removed (dry-run=$DRYRUN)"
}
###############################################################################
# Ferramentas auxiliares: list-files e whatowns
###############################################################################
ug_list_files(){
  local fl="$(__db_files)"
  [[ -s "$fl" ]] || { ug_err "files.lst ausente para $(__db_pkg_dir)"; return 2; }
  if (( JSON_OUT )) && adm_is_cmd jq; then
    jq -n --arg category "${ADM_META[category]}" --arg name "${ADM_META[name]}" --arg version "${ADM_META[version]}" \
      --argfile files <(jq -R -s 'split("\n")|map(select(length>0))' "$fl") \
      '{category:$category,name:$name,version:$version,files:$files}'
  else
    cat "$fl"
  fi
}

ug_what_owns(){
  local target="${POSITIONAL[0]:-}"
  [[ -n "$target" ]] || { ug_err "whatowns requer um caminho absoluto"; return 2; }
  [[ "$target" == /* ]] || { ug_err "passe caminho absoluto"; return 2; }
  local rel="${target#$ROOT}"
  [[ "$rel" == /* ]] || rel="/$rel"
  local matches=0
  if compgen -G "${ADM_DB_DIR}/installed/*/*/files.lst" >/dev/null; then
    while IFS= read -r fl; do
      if grep -qx -- "$rel" "$fl" 2>/dev/null; then
        matches=1
        local pkgdir; pkgdir="$(dirname "$fl")"
        local cat; cat="$(basename "$(dirname "$pkgdir")")"
        local nam; nam="$(basename "$pkgdir")"
        if (( JSON_OUT )) && adm_is_cmd jq; then
          jq -n --arg category "$cat" --arg name "$nam" --arg file "$rel" '{category:$category,name:$name,file:$file}'
        else
          echo "$cat/$nam owns $rel"
        fi
      fi
    done < <(find "${ADM_DB_DIR}/installed" -type f -name 'files.lst' -print 2>/dev/null)
  fi
  (( matches )) || { ug_warn "nenhum dono encontrado para $rel"; return 1; }
}

###############################################################################
# MAIN
###############################################################################
ug_run(){
  parse_cli "$@"

  # logging opcional
  if [[ -n "$LOGPATH" ]]; then
    exec > >(tee -a "$LOGPATH") 2>&1
  fi

  case "$CMD" in
    uninstall|purge)
      (( PURGE )) || [[ "$CMD" != "purge" ]] || PURGE=1
      # checagem de metadados
      local miss=0
      for k in category name; do
        [[ -n "${ADM_META[$k]:-}" ]] || { ug_err "metadado ausente: $k"; miss=1; }
      done
      (( miss==0 )) || exit 3
      __uninstall_package
      ;;
    gc)
      __gc_orphans
      ;;
    list-files)
      local miss=0
      for k in category name; do
        [[ -n "${ADM_META[$k]:-}" ]] || { ug_err "metadado ausente: $k"; miss=1; }
      done
      (( miss==0 )) || exit 3
      ug_list_files
      ;;
    whatowns)
      ug_what_owns
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ug_run "$@"
fi
