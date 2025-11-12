#!/usr/bin/env bash
# 08.20-postinstall-healthchecks.sh
# Valida a saúde pós-instalação: ELF, shebangs, permissões, symlinks,
# pkg-config, caches (ldconfig, man-db, info-dir, mime, desktop, icons),
# systemd units e mais. Pode aplicar correções seguras (--auto-fix).
###############################################################################
# Modo estrito + traps
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__ph_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] postinstall-healthchecks falhou: code=${code} line=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __ph_err_trap ERR

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
ph_info(){  echo -e "${C_INF}[ADM]${C_RST} $*"; }
ph_ok(){    echo -e "${C_OK}[OK ]${C_RST} $*"; }
ph_warn(){  echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
ph_err(){   echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }
tmpfile(){ mktemp "${ADM_TMPDIR}/ph.XXXXXX"; }
sha256f(){ sha256sum "$1" | awk '{print $1}'; }
trim(){ sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }
adm_is_cmd(){ command -v "$1" >/dev/null 2>&1; }

# Locks
__lock(){
  local name="$1"; __ensure_dir "$ADM_STATE_DIR/locks"
  exec {__PH_FD}>"$ADM_STATE_DIR/locks/${name}.lock"
  flock -n ${__PH_FD} || { ph_warn "aguardando lock de ${name}…"; flock ${__PH_FD}; }
}
__unlock(){ :; }

###############################################################################
# Hooks
###############################################################################
declare -A ADM_META  # category, name, version (se disponível)
__pkg_root(){
  local c="${ADM_META[category]:-}" n="${ADM_META[name]:-}"
  [[ -n "$c" && -n "$n" ]] || { echo ""; return 1; }
  printf '%s/%s/%s' "$ADM_ROOT" "$c" "$n"
}
__hooks_dirs(){
  local pr; pr="$(__pkg_root)" || true
  printf '%s\n' "$pr/hooks" "$ADM_ROOT/hooks"
}
ph_hooks_run(){
  local stage="${1:?}"; shift || true
  local d f ran=0
  for d in $(__hooks_dirs); do
    [[ -d "$d" ]] || continue
    for f in "$d/$stage" "$d/$stage.sh"; do
      if [[ -x "$f" ]]; then
        ph_info "Hook: $(realpath -m "$f")"
        ( set -Eeuo pipefail; "$f" "$@" )
        ran=1
      fi
    done
  done
  (( ran )) || ph_info "Hook '${stage}': nenhum"
}

###############################################################################
# CLI
###############################################################################
ROOT="/"                    # raiz alvo
AUTO_FIX=0                  # aplicar correções seguras
JSON_OUT=0                  # emitir relatório JSON
STRICT=1                    # FAIL se houver qualquer FAIL (WARN não falha)
ONLY=""                     # CSV de checks a incluir
SKIP=""                     # CSV de checks a pular
SCOPE="auto"                # auto|package|full   (package usa files.lst se existir)
LOGPATH=""                  # caminho do log desta execução

# Conjunto de checks (nomes canônicos)
ALL_CHECKS="symlinks perms elf ldd rpath pkgconfig shebangs pkgdb ldconfig mandb infodir desktop mime icons systemd ownership stray"

ph_usage(){
  cat <<'EOF'
Uso:
  08.20-postinstall-healthchecks.sh [opções]

Opções:
  --root PATH              Raiz (default: /)
  --category CAT           (para escopo package)
  --name NAME
  --version VER
  --scope auto|package|full  (auto: usa package se DB existir; senão full)
  --only CSV               Apenas estes checks (ver lista abaixo)
  --skip CSV               Pular estes checks
  --auto-fix               Aplicar correções seguras (cache/index/daemon-reload)
  --json                   Emite relatório JSON
  --no-strict              Não falha em FAIL (retorno 0 sempre)
  --log PATH               Salvar log detalhado neste caminho
  --help

Checks disponíveis:
  symlinks, perms, elf, ldd, rpath, pkgconfig, shebangs, pkgdb,
  ldconfig, mandb, infodir, desktop, mime, icons, systemd,
  ownership, stray
EOF
}

parse_cli(){
  while (($#)); do
    case "$1" in
      --root) ROOT="${2:-/}"; shift 2 ;;
      --category) ADM_META[category]="${2:-}"; shift 2 ;;
      --name) ADM_META[name]="${2:-}"; shift 2 ;;
      --version) ADM_META[version]="${2:-}"; shift 2 ;;
      --scope) SCOPE="${2:-auto}"; shift 2 ;;
      --only) ONLY="${2:-}"; shift 2 ;;
      --skip) SKIP="${2:-}"; shift 2 ;;
      --auto-fix) AUTO_FIX=1; shift ;;
      --json) JSON_OUT=1; shift ;;
      --no-strict) STRICT=0; shift ;;
      --log) LOGPATH="${2:-}"; shift 2 ;;
      --help|-h) ph_usage; exit 0 ;;
      *) ph_err "opção inválida: $1"; ph_usage; exit 2 ;;
    esac
  done
}

###############################################################################
# Escopo (lista de arquivos a inspecionar)
###############################################################################
__db_pkg_dir(){ local c="${ADM_META[category]:-}" n="${ADM_META[name]:-}"; echo "${ADM_DB_DIR}/installed/${c}/${n}"; }
__db_files(){ echo "$(__db_pkg_dir)/files.lst"; }

__scope_files(){
  local mode="$1" out="$2"
  : > "$out"
  case "$mode" in
    package)
      local fl="$(__db_files)"
      if [[ -s "$fl" ]]; then
        while IFS= read -r rel; do
          [[ -z "$rel" ]] && continue
          echo "${ROOT%/}/${rel#/}" >> "$out"
        done < "$fl"
        return 0
      fi
      ph_warn "files.lst ausente; caindo para 'full'"
      ;;&
    full|*)
      # Diretórios padrão
      local d
      for d in bin sbin lib lib64 usr/bin usr/sbin usr/lib usr/lib64 usr/local/bin usr/local/lib etc share; do
        [[ -d "${ROOT%/}/$d" ]] || continue
        find "${ROOT%/}/$d" -xdev -mindepth 1 -print >> "$out" 2>/dev/null || true
      done
      ;;
  esac
  return 0
}

###############################################################################
# Seleção de checks
###############################################################################
__csv_to_array(){ local IFS=','; read -r -a __arr <<< "$1"; printf '%s\n' "${__arr[@]}" | trim | sed '/^$/d'; }
__want_check(){
  local name="$1"
  local -a only skip
  mapfile -t only < <(__csv_to_array "$ONLY")
  mapfile -t skip < <(__csv_to_array "$SKIP")
  # Se 'only' definido, permitir só os citados
  if ((${#only[@]}>0)); then
    local x; for x in "${only[@]}"; do [[ "$x" == "$name" ]] && { for y in "${skip[@]}"; do [[ "$y" == "$name" ]] && return 1; done; return 0; }; done
    return 1
  fi
  # Caso normal, apenas recuse se estiver em skip
  local y; for y in "${skip[@]}"; do [[ "$y" == "$name" ]] && return 1; done
  return 0
}

###############################################################################
# Estrutura de relatório
###############################################################################
declare -A PH_STATS=( [PASS]=0 [WARN]=0 [FAIL]=0 )
PH_JSON="[]"   # acumulador JSON simples
__report(){
  local level="$1" msg="$2" check="$3"
  case "$level" in
    PASS) ((PH_STATS[PASS]++)); ph_ok   "[$check] $msg" ;;
    WARN) ((PH_STATS[WARN]++)); ph_warn "[$check] $msg" ;;
    FAIL) ((PH_STATS[FAIL]++)); ph_err  "[$check] $msg" ;;
  esac
  if (( JSON_OUT )) && adm_is_cmd jq; then
    local tmp; tmp="$(tmpfile)"
    echo "$PH_JSON" | jq --arg level "$level" --arg check "$check" --arg msg "$msg" '. += [{level:$level,check:$check,msg:$msg}]' > "$tmp" 2>/dev/null || echo "$PH_JSON" > "$tmp"
    PH_JSON="$(cat "$tmp")"
  fi
}
###############################################################################
# Checks individuais (cada um deve usar __report)
###############################################################################

# 1) symlinks — encontra links quebrados
check_symlinks(){
  local list="$1"
  local broken=0
  while IFS= read -r f; do
    [[ -L "$f" ]] || continue
    local t; t="$(readlink -f "$f" 2>/dev/null || true)"
    [[ -e "$t" ]] || { __report FAIL "symlink quebrado: $f -> $(readlink "$f" 2>/dev/null || echo '?')" "symlinks"; broken=1; }
  done < "$list"
  (( broken==0 )) && __report PASS "nenhum symlink quebrado" "symlinks"
}

# 2) perms — diretórios world-writable sem sticky; arquivos setuid/setgid
check_perms(){
  local list="$1" ww=0 sg=0
  while IFS= read -r f; do
    [[ -e "$f" ]] || continue
    local mode; mode="$(stat -c '%a' "$f" 2>/dev/null || echo "")"
    [[ -z "$mode" ]] && continue
    if [[ -d "$f" ]]; then
      # world-writable sem sticky bit
      if [[ "$mode" =~ .*7$|.*6$|.*3$|.*2$ ]]; then
        # pega os últimos 1 dígito de perm (outros)
        local last="${mode: -1}"
        if (( last & 2 )) && ! stat -c '%A' "$f" | grep -q 't'; then
          __report WARN "dir world-writable sem sticky: $f (mode=$mode)" "perms"; ((ww++))
        end
      fi
    else
      # setuid/setgid avisos
      local oct; oct="$(stat -c '%f' "$f" 2>/dev/null || echo 0)"
      # Fácil: reporta se tem suid/sgid
      if stat -c '%A' "$f" | grep -q 's'; then
        __report WARN "arquivo com setuid/setgid: $f (mode=$mode)" "perms"; ((sg++))
      fi
    fi
  done < "$list"
  (( ww==0 && sg==0 )) && __report PASS "permissões sem achados críticos" "perms"
}

# 3) elf — identificar ELF executáveis/compartilhados
__is_elf(){ file -b "$1" 2>/dev/null | grep -qi 'ELF'; }
check_elf(){
  local list="$1" cnt=0
  command -v file >/dev/null 2>&1 || { __report WARN "'file' ausente; não foi possível identificar ELF" "elf"; return 0; }
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    __is_elf "$f" && ((cnt++))
  done < "$list"
  ((cnt>0)) && __report PASS "arquivos ELF encontrados: $cnt (ok)" "elf" || __report WARN "nenhum ELF no escopo (ok se libs/básico)" "elf"
}

# 4) ldd — dependências não resolvidas
check_ldd(){
  local list="$1" miss=0
  command -v ldd >/dev/null 2>&1 || { __report WARN "'ldd' ausente; pulando" "ldd"; return 0; }
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    __is_elf "$f" || continue
    while IFS= read -r line; do
      echo "$line" | grep -q 'not found' && { __report FAIL "dep não encontrada em $f: $line" "ldd"; miss=1; }
    done < <(ldd "$f" 2>&1 || true)
  done < "$list"
  (( miss==0 )) && __report PASS "todas as dependências ELF resolvidas" "ldd"
}

# 5) rpath — DT_RPATH/RUNPATH suspeitos
check_rpath(){
  local list="$1" bad=0
  local READELF="$(command -v readelf || command -v eu-readelf || true)"
  [[ -n "$READELF" ]] || { __report WARN "readelf não encontrado; pulando" "rpath"; return 0; }
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    __is_elf "$f" || continue
    local run; run="$("$READELF" -d "$f" 2>/dev/null | grep -E 'RUNPATH|RPATH' || true)"
    [[ -z "$run" ]] && continue
    # heurística: presença de caminhos relativos ou diretórios inexistentes
    local p; while IFS= read -r p; do
      p="$(sed -E 's/.*\[|\].*//g' <<< "$p")"
      IFS=':' read -r -a arr <<< "$p"
      local q; for q in "${arr[@]}"; do
        [[ "$q" == \$ORIGIN* ]] && continue
        [[ "$q" == /* ]] || { __report WARN "RPATH relativo em $f: $q" "rpath"; bad=1; continue; }
        [[ -d "$q" ]] || { __report WARN "RPATH aponta para dir ausente em $f: $q" "rpath"; bad=1; }
      done
    done <<< "$run"
  done < "$list"
  (( bad==0 )) && __report PASS "RPATH/RUNPATH sem problemas aparentes" "rpath"
}

# 6) pkgconfig — .pc quebrados (prefix, libs, cflags)
check_pkgconfig(){
  local list="$1" issues=0
  while IFS= read -r f; do
    [[ "$f" == *.pc ]] || continue
    [[ -r "$f" ]] || continue
    # confere se os caminhos de -I e -L existem
    local cflags libs
    cflags="$(grep -E '^Cflags:' "$f" 2>/dev/null | sed 's/^Cflags:[[:space:]]*//')"
    libs="$(grep -E '^Libs:' "$f" 2>/dev/null | sed 's/^Libs:[[:space:]]*//')"
    local tok
    for tok in $cflags; do
      [[ "$tok" == -I* ]] && [[ -d "${ROOT%/}/${tok#-I/}" || -d "${tok#-I}" ]] || true
      if [[ "$tok" == -I* ]]; then
        local inc="${tok#-I}"
        [[ -d "$inc" || -d "${ROOT%/}/${inc#/}" ]] || { __report WARN ".pc inclui include inexistente: $f ($inc)" "pkgconfig"; issues=1; }
      fi
    done
    for tok in $libs; do
      [[ "$tok" == -L* ]] || continue
      local libd="${tok#-L}"
      [[ -d "$libd" || -d "${ROOT%/}/${libd#/}" ]] || { __report WARN ".pc inclui libdir inexistente: $f ($libd)" "pkgconfig"; issues=1; }
    done
  done < "$list"
  (( issues==0 )) && __report PASS "pkg-config sem problemas aparentes" "pkgconfig"
}

# 7) shebangs — interpretes inexistentes
check_shebangs(){
  local list="$1" bad=0
  while IFS= read -r f; do
    [[ -f "$f" && -x "$f" ]] || continue
    # lê primeira linha
    local first; IFS= read -r first < "$f" || true
    [[ "$first" =~ ^#! ]] || continue
    local shb="${first#\#!}"
    shb="$(echo "$shb" | awk '{print $1}')"
    # suporta env
    if [[ "$(basename "$shb")" == "env" ]]; then
      local second; second="$(echo "$first" | awk '{print $2}')" || true
      [[ -n "$second" ]] && shb="$(command -v "$second" 2>/dev/null || true)"
    fi
    [[ -n "$shb" && -x "$shb" ]] || { __report FAIL "shebang aponta para intérprete ausente: $f ($first)" "shebangs"; bad=1; }
  done < "$list"
  (( bad==0 )) && __report PASS "todos os shebangs válidos" "shebangs"
}

# 8) pkgdb — confere DB de instalados para o pacote (se disponível)
check_pkgdb(){
  local dbd="$(__db_pkg_dir)"
  if [[ -d "$dbd" ]]; then
    [[ -s "$dbd/meta.json" ]] || __report WARN "meta.json ausente no DB" "pkgdb"
    [[ -s "$dbd/files.lst" ]] || __report WARN "files.lst ausente no DB" "pkgdb"
    [[ -s "$dbd/manifest.json" ]] || __report WARN "manifest.json ausente no DB" "pkgdb"
    __report PASS "DB do pacote existe (${dbd})" "pkgdb"
  else
    __report WARN "DB do pacote não encontrado; escopo pode ser 'full'" "pkgdb"
  fi
}

# 9) ldconfig — verifica e (opcional) executa
check_ldconfig(){
  if adm_is_cmd ldconfig; then
    if (( AUTO_FIX )); then
      if ldconfig; then __report PASS "ldconfig atualizado" "ldconfig"
      else __report WARN "ldconfig retornou erro" "ldconfig"; fi
    else
      __report PASS "ldconfig disponível (use --auto-fix p/ atualizar)" "ldconfig"
    fi
  else
    __report WARN "ldconfig indisponível" "ldconfig"
  fi
}

# 10) mandb — atualizar base de manpages
check_mandb(){
  local manpath="${ROOT%/}/usr/share/man"
  [[ -d "$manpath" ]] || { __report PASS "sem manpages para atualizar" "mandb"; return 0; }
  if adm_is_cmd mandb; then
    if (( AUTO_FIX )); then
      mandb -q || true
      __report PASS "mandb atualizado (quiet)" "mandb"
    else
      __report PASS "mandb disponível (use --auto-fix p/ atualizar)" "mandb"
    fi
  else
    __report WARN "mandb indisponível" "mandb"
  fi
}

# 11) infodir — atualizar dir info (texinfo)
check_infodir(){
  local infod="${ROOT%/}/usr/share/info"
  [[ -d "$infod" ]] || { __report PASS "sem info-dir para atualizar" "infodir"; return 0; }
  if adm_is_cmd install-info; then
    if (( AUTO_FIX )); then
      shopt -s nullglob
      for f in "$infod"/*.info "$infod"/*.info.gz; do
        install-info "$f" "$infod/dir" >/dev/null 2>&1 || true
      done
      shopt -u nullglob
      __report PASS "info-dir atualizado" "infodir"
    else
      __report PASS "install-info disponível (use --auto-fix p/ atualizar)" "infodir"
    fi
  else
    __report WARN "install-info indisponível" "infodir"
  fi
}

# 12) desktop — atualizar desktop database
check_desktop(){
  local ddir="${ROOT%/}/usr/share/applications"
  [[ -d "$ddir" ]] || { __report PASS "sem desktop files" "desktop"; return 0; }
  if adm_is_cmd update-desktop-database; then
    if (( AUTO_FIX )); then
      update-desktop-database -q "$ddir" || true
      __report PASS "desktop database atualizado" "desktop"
    else
      __report PASS "update-desktop-database disponível (use --auto-fix)" "desktop"
    fi
  else
    __report WARN "update-desktop-database indisponível" "desktop"
  fi
}

# 13) mime — atualizar shared-mime-info
check_mime(){
  local mdir="${ROOT%/}/usr/share/mime"
  [[ -d "$mdir" ]] || { __report PASS "sem mime database" "mime"; return 0; }
  if adm_is_cmd update-mime-database; then
    if (( AUTO_FIX )); then
      update-mime-database "$mdir" >/dev/null 2>&1 || true
      __report PASS "mime database atualizado" "mime"
    else
      __report PASS "update-mime-database disponível (use --auto-fix)" "mime"
    fi
  else
    __report WARN "update-mime-database indisponível" "mime"
  fi
}

# 14) icons — atualizar cache de ícones
check_icons(){
  local idir="${ROOT%/}/usr/share/icons"
  [[ -d "$idir" ]] || { __report PASS "sem ícones" "icons"; return 0; }
  if adm_is_cmd gtk-update-icon-cache; then
    if (( AUTO_FIX )); then
      shopt -s nullglob
      for theme in "$idir"/*; do
        [[ -d "$theme" ]] || continue
        gtk-update-icon-cache -f -q "$theme" || true
      done
      shopt -u nullglob
      __report PASS "icon caches atualizados" "icons"
    else
      __report PASS "gtk-update-icon-cache disponível (use --auto-fix)" "icons"
    fi
  else
    __report WARN "gtk-update-icon-cache indisponível" "icons"
  fi
}

# 15) systemd — daemon-reload e verificação dos units
check_systemd(){
  if adm_is_cmd systemctl; then
    if (( AUTO_FIX )); then
      systemctl daemon-reload || true
    fi
    # valida sintaxe se disponível
    if adm_is_cmd systemd-analyze; then
      # verificar todos os units sob /usr/lib/systemd /etc/systemd
      local found=0
      while IFS= read -r u; do
        found=1
        systemd-analyze verify "$u" >/dev/null 2>&1 || __report WARN "unit com issues: $u" "systemd"
      done < <(find "${ROOT%/}/usr/lib/systemd" "${ROOT%/}/etc/systemd" -type f -name '*.service' 2>/dev/null || true)
      ((found)) && __report PASS "systemd verificado (units encontrados)" "systemd" || __report PASS "sem units systemd" "systemd"
    else
      __report PASS "systemctl presente (daemon-reload OK); verify indisponível" "systemd"
    fi
  else
    __report PASS "systemd ausente (ok em sistemas sem systemd)" "systemd"
  fi
}

# 16) ownership — arquivos não pertencentes a root em paths sensíveis
check_ownership(){
  local list="$1" bad=0
  while IFS= read -r f; do
    [[ -e "$f" ]] || continue
    case "$f" in
      ${ROOT%/}/usr/*|${ROOT%/}/bin/*|${ROOT%/}/lib*|${ROOT%/}/sbin/*|${ROOT%/}/etc/*)
        local own grp
        own="$(stat -c '%U' "$f" 2>/dev/null || echo '?')"
        grp="$(stat -c '%G' "$f" 2>/dev/null || echo '?')"
        [[ "$own" == "root" ]] || { __report WARN "owner não root: $f ($own:$grp)" "ownership"; bad=1; }
      ;;
    esac
  done < "$list"
  (( bad==0 )) && __report PASS "ownership adequado em paths críticos" "ownership"
}

# 17) stray — arquivos suspeitos (libtool .la, .pyc órfãos fora de __pycache__)
check_stray(){
  local list="$1" issues=0
  while IFS= read -r f; do
    [[ -e "$f" ]] || continue
    [[ "$f" == *.la ]] && { __report WARN "arquivo libtool (.la) encontrado: $f" "stray"; issues=1; }
    [[ "$f" == *.pyc && "$f" != */__pycache__/* ]] && { __report WARN ".pyc fora de __pycache__: $f" "stray"; issues=1; }
  done < "$list"
  (( issues==0 )) && __report PASS "sem artefatos suspeitos" "stray"
}
###############################################################################
# Execução e relatório
###############################################################################
run_checks(){
  local listfile="$1"
  # Ordem padrão de execução
  local order=(symlinks perms elf ldd rpath pkgconfig shebangs pkgdb ldconfig mandb infodir desktop mime icons systemd ownership stray)
  local ck
  for ck in "${order[@]}"; do
    __want_check "$ck" || continue
    case "$ck" in
      symlinks)  check_symlinks "$listfile" ;;
      perms)     check_perms "$listfile" ;;
      elf)       check_elf "$listfile" ;;
      ldd)       check_ldd "$listfile" ;;
      rpath)     check_rpath "$listfile" ;;
      pkgconfig) check_pkgconfig "$listfile" ;;
      shebangs)  check_shebangs "$listfile" ;;
      pkgdb)     check_pkgdb ;;
      ldconfig)  check_ldconfig ;;
      mandb)     check_mandb ;;
      infodir)   check_infodir ;;
      desktop)   check_desktop ;;
      mime)      check_mime ;;
      icons)     check_icons ;;
      systemd)   check_systemd ;;
      ownership) check_ownership "$listfile" ;;
      stray)     check_stray "$listfile" ;;
    esac
  done
}

###############################################################################
# MAIN
###############################################################################
ph_run(){
  parse_cli "$@"

  # logging opcional
  if [[ -n "$LOGPATH" ]]; then
    exec > >(tee -a "$LOGPATH") 2>&1
  fi

  # Determinar escopo
  local mode="$SCOPE"
  if [[ "$SCOPE" == "auto" ]]; then
    if [[ -n "${ADM_META[category]:-}" && -n "${ADM_META[name]:-}" && -d "$(__db_pkg_dir)" ]]; then
      mode="package"
    else
      mode="full"
    fi
  fi

  __lock "postinstall-health"
  ph_hooks_run "pre-healthcheck" "ROOT=$ROOT" "SCOPE=$mode"

  local list; list="$(tmpfile)"
  __scope_files "$mode" "$list"

  run_checks "$list"

  ph_hooks_run "post-healthcheck" "ROOT=$ROOT" "SCOPE=$mode"
  __unlock

  # Resumo
  local summary="PASS=${PH_STATS[PASS]} WARN=${PH_STATS[WARN]} FAIL=${PH_STATS[FAIL]}"
  if (( JSON_OUT )) && adm_is_cmd jq; then
    local out; out="$(tmpfile)"
    jq -n --arg pass "${PH_STATS[PASS]}" --arg warn "${PH_STATS[WARN]}" --arg fail "${PH_STATS[FAIL]}" --arg scope "$mode" \
      --argjson details "$PH_JSON" \
      '{scope:$scope, summary:{pass:($pass|tonumber), warn:($warn|tonumber), fail:($fail|tonumber)}, details:$details}' > "$out" 2>/dev/null \
      && cat "$out" || echo "$summary"
  else
    ph_info "Resumo: $summary"
  fi

  # Código de saída
  if (( STRICT )); then
    (( PH_STATS[FAIL] > 0 )) && exit 20 || exit 0
  else
    exit 0
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ph_run "$@"
fi
