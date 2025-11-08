#!/usr/bin/env sh
# adm-fetch.sh — Baixador universal do sistema ADM
# POSIX sh; compatível com dash/ash/bash. Sem dependências obrigatórias.
set -u
# =========================
# 0) Config e defaults
# =========================
: "${ADM_ROOT:=/usr/src/adm}"
: "${ADM_STAGE:=host}"
: "${ADM_PIPELINE:=fetch}"
: "${ADM_LOG_COLOR:=auto}"
: "${ADM_FETCH_JOBS:=0}"           # 0 = auto (min(4, nproc))
: "${ADM_FETCH_TIMEOUT:=300}"      # segundos por item
: "${ADM_FETCH_RETRIES:=3}"
: "${ADM_FETCH_FORCE:=0}"
: "${ADM_FETCH_NO_RESUME:=0}"
: "${ADM_FETCH_PREFER:=tarball}"   # tarball|clone
: "${ADM_FETCH_INSECURE:=0}"

CACHE_DIR="$ADM_ROOT/cache"
# =========================
# 1) Cores + log (fallback se adm-log.sh não estiver sourceado)
# =========================
_is_tty(){ [ -t 1 ]; }
_color_on=0
_color_setup(){
  if [ "${ADM_LOG_COLOR}" = "never" ] || [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ]; then
    _color_on=0
  elif [ "${ADM_LOG_COLOR}" = "always" ] || _is_tty; then
    _color_on=1
  else
    _color_on=0
  fi
}
_b(){ [ $_color_on -eq 1 ] && printf '\033[1m'; }
_rst(){ [ $_color_on -eq 1 ] && printf '\033[0m'; }
_c_mag(){ [ $_color_on -eq 1 ] && printf '\033[35;1m'; } # estágio rosa bold
_c_yel(){ [ $_color_on -eq 1 ] && printf '\033[33;1m'; } # path amarelo bold
_c_gry(){ [ $_color_on -eq 1 ] && printf '\033[38;5;244m'; }

have_adm_log=0
command -v adm_log_info >/dev/null 2>&1 && have_adm_log=1

ts(){ date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([0-9][0-9]\)$/:\1/'; }
ctx(){
  _stage="${ADM_STAGE:-host}"; _pipe="${ADM_PIPELINE:-fetch}"
  _path="${WORK_DIR:-$PWD}"
  if [ $_color_on -eq 1 ]; then
    printf "("; _c_mag; printf "%s" "$_stage"; _rst
    _c_gry; printf ":%s" "$_pipe"; _rst
    printf " path="; _c_yel; printf "%s" "$_path"; _rst; printf ")"
  else
    printf "(%s:%s path=%s)" "$_stage" "$_pipe" "$_path"
  fi
}
say(){
  lvl="$1"; shift; msg="$*"
  if [ $have_adm_log -eq 1 ]; then
    case "$lvl" in
      INFO) adm_log_info  "$msg";;
      WARN) adm_log_warn  "$msg";;
      ERROR)adm_log_error "$msg";;
      STEP) adm_log_step_start "$msg" >/dev/null;;
      OK)   adm_log_step_ok;;
      DEBUG)adm_log_debug "$msg";;
      *)    adm_log_info "$msg";;
    esac
  else
    _color_setup
    case "$lvl" in
      INFO) t="[INFO]";; WARN) t="[WARN]";; ERROR) t="[ERROR]";; STEP) t="[STEP]";; OK) t="[ OK ]";; DEBUG) t="[DEBUG]";;
      *) t="[$lvl]";;
    esac
    printf "%s [%s] %s %s\n" "$t" "$(ts)" "$(ctx)" "$msg"
  fi
}
die(){ say ERROR "$*"; exit 40; }

# =========================
# 2) Util: hash, tools, helpers
# =========================
sha256_file(){
  f="$1"; command -v sha256sum >/dev/null 2>&1 || die "sha256sum não encontrado"
  sha256sum "$f" | awk '{print $1}'
}
nproc_auto(){
  if command -v nproc >/dev/null 2>&1; then nproc
  else echo 2; fi
}
jobs_auto(){
  if [ "$ADM_FETCH_JOBS" -gt 0 ]; then echo "$ADM_FETCH_JOBS"; return; fi
  n="$(nproc_auto)"; [ "$n" -gt 4 ] && n=4
  echo "$n"
}
have_curl(){ command -v curl >/dev/null 2>&1; }
have_wget(){ command -v wget >/dev/null 2>&1; }

# =========================
# 3) Parse do metafile KEY=VALUE
# =========================
NAME=""; VERSION=""; SOURCES=""; SHA256SUMS=""
parse_metafile(){
  mf="$1"; [ -f "$mf" ] || { say ERROR "metafile não encontrado: $mf"; exit 10; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue;;
      NAME=*) NAME="${line#NAME=}";;
      VERSION=*) VERSION="${line#VERSION=}";;
      SOURCES=*) SOURCES="${line#SOURCES=}";;
      SHA256SUMS=*) SHA256SUMS="${line#SHA256SUMS=}";;
      *) :;;
    esac
  done < "$mf"
  [ -n "$NAME" ] || { say ERROR "NAME ausente no metafile"; exit 10; }
  [ -n "$VERSION" ] || { say ERROR "VERSION ausente no metafile"; exit 10; }
  [ -n "$SOURCES" ] || { say ERROR "SOURCES ausente no metafile"; exit 10; }
  [ -n "$SHA256SUMS" ] || { say ERROR "SHA256SUMS ausente no metafile"; exit 10; }

  # Tokeniza por espaço
  set -- $SOURCES; i=0; SRC_LIST=""
  for s in "$@"; do i=$((i+1)); SRC_LIST="${SRC_LIST}${SRC_LIST:+
}$s"; done
  set -- $SHA256SUMS; j=0; SUM_LIST=""
  for h in "$@"; do j=$((j+1)); SUM_LIST="${SUM_LIST}${SUM_LIST:+
}$h"; done
  if [ "$i" -ne "$j" ]; then
    say ERROR "cardinalidade mismatch: SOURCES($i) vs SHA256SUMS($j)"
    exit 10
  fi
}

# =========================
# 4) Cache, lock e manifest
# =========================
WORK_DIR=""
MANIFEST=""
SUMMARY=""
LOCKFILE=""
prepare_cache(){
  WORK_DIR="$CACHE_DIR/${NAME}-${VERSION}"
  mkdir -p "$WORK_DIR" || { say ERROR "não foi possível criar cache $WORK_DIR"; exit 30; }
  LOCKFILE="$WORK_DIR/.lock"
  exec 9>"$LOCKFILE" || { say ERROR "falha ao abrir lock $LOCKFILE"; exit 30; }
  if command -v flock >/dev/null 2>&1; then
    flock -n 9 || { say ERROR "outro processo está usando o cache ($LOCKFILE)"; exit 30; }
  fi
  MANIFEST="$WORK_DIR/manifest.fetch"
  SUMMARY="$WORK_DIR/manifest.summary"
  : >"$MANIFEST" || { say ERROR "não foi possível criar $MANIFEST"; exit 30; }
  : >"$SUMMARY"  || { say ERROR "não foi possível criar $SUMMARY";  exit 30; }
}

manifest_append(){
  # evita corrida: escreve em temp e concatena
  tmp="$WORK_DIR/.mf.$$.$RANDOM"
  printf "%s\n" "$1" >"$tmp" || true
  cat "$tmp" >>"$MANIFEST" 2>/dev/null || true
  rm -f "$tmp" 2>/dev/null || true
}

# =========================
# 5) Expansão de aliases e tipo
# =========================
expand_alias(){
  src="$1"
  case "$src" in
    github://*@*)
      owner_repo="${src#github://}"; owner_repo="${owner_repo%@*}"; ref="${src##*@}"
      echo "https://codeload.github.com/${owner_repo}/tar.gz/${ref}"
      return;;
    gitlab://*@*)
      owner_repo="${src#gitlab://}"; owner_repo="${owner_repo%@*}"; ref="${src##*@}"
      repo="${owner_repo##*/}"
      echo "https://gitlab.com/${owner_repo}/-/archive/${ref}/${repo}-${ref}.tar.gz"
      return;;
    sourceforge://*)
      path="${src#sourceforge://}"
      echo "https://downloads.sourceforge.net/project/${path}"
      return;;
    *) echo "$src"; return;;
  esac
}
detect_type(){
  u="$1"
  case "$u" in
    git+*@"*"|git+*@*) echo "git";;
    git+*) echo "git";;
    http://*|https://*) echo "http";;
    ftp://*) echo "ftp";;
    rsync://*) echo "rsync";;
    file://*) [ -d "${u#file://}" ] && echo "dir" || echo "file";;
    dir://*) echo "dir";;
    *) echo "http";; # default
  esac
}

basename_url(){
  u="$1"
  b="${u##*/}"
  [ -n "$b" ] && echo "$b" || echo "download"
}

# =========================
# 6) Downloaders
# =========================
dl_http(){
  url="$1"; dst="$2"
  insecure=""
  [ "$ADM_FETCH_INSECURE" -eq 1 ] && insecure="--insecure"
  resume=""
  [ "$ADM_FETCH_NO_RESUME" -eq 0 ] && resume="-C -"
  proxy=""
  [ -n "${ADM_FETCH_PROXY:-}" ] && proxy="--proxy $ADM_FETCH_PROXY"

  if have_curl; then
    # shellcheck disable=SC2086
    curl -fsSL --connect-timeout 20 --max-time "$ADM_FETCH_TIMEOUT" $insecure $proxy -o "$dst.part" "$url"
  elif have_wget; then
    # shellcheck disable=SC2086
    wget -O "$dst.part" --timeout="$ADM_FETCH_TIMEOUT" $([ "$ADM_FETCH_NO_RESUME" -eq 0 ] && echo "-c") $([ "$ADM_FETCH_INSECURE" -eq 1 ] && echo "--no-check-certificate") $([ -n "${ADM_FETCH_PROXY:-}" ] && echo "--execute=http_proxy=$ADM_FETCH_PROXY --execute=https_proxy=$ADM_FETCH_PROXY") "$url"
  else
    say ERROR "nem curl nem wget encontrados"
    return 127
  fi
}

dl_ftp(){
  dl_http "$@"
}

dl_rsync(){
  url="$1"; dst="$2"
  rsync -av --partial "$url" "$dst.part" >/dev/null 2>&1
}

dl_git(){
  spec="$1"; dir="$2"
  proto="${spec#git+}"; ref=""
  case "$proto" in
    *@*) ref="${proto##*@}"; proto="${proto%@*}";;
  esac
  depth="--depth=1"
  [ "$ADM_FETCH_PREFER" = "clone" ] || depth="--depth=1"
  rm -rf "$dir.part" 2>/dev/null || true
  git clone $depth "$proto" "$dir.part" >/dev/null 2>&1 || return 1
  if [ -n "$ref" ]; then
    (cd "$dir.part" && git checkout -q "$ref") >/dev/null 2>&1 || return 1
  fi
}

cp_file(){
  src="$1"; dst="$2"
  cp -f "$src" "$dst.part" >/dev/null 2>&1
}
cp_dir(){
  src="$1"; dst="$2"
  # espelha diretório; mantém como diretório
  rm -rf "$dst.part" 2>/dev/null || true
  mkdir -p "$dst.part" || return 1
  (cd "$src" && tar cf - .) | (cd "$dst.part" && tar xf -) || return 1
}

# =========================
# 7) Worker de item (com retries)
# =========================
process_item(){
  idx="$1"; src="$2"; sum="$3"
  orig="$src"
  src="$(expand_alias "$src")"
  typ="$(detect_type "$src")"
  say STEP "fetch[$idx] tipo=$typ src=$orig → $src"

  case "$typ" in
    http|ftp)
      name="$(basename_url "$src")"; target="$WORK_DIR/$name";;
    rsync)
      name="$(basename_url "$src")"; target="$WORK_DIR/$name";;
    file)
      name="$(basename_url "$src")"; target="$WORK_DIR/$name";;
    dir)
      # manter diretório
      name="dir-$(printf "%s" "${src#dir://}" | md5sum 2>/dev/null | awk '{print $1}')"
      [ -n "$name" ] || name="dir-$(date +%s)"
      target="$WORK_DIR/$name";;
    git)
      repo="$(printf "%s" "$src" | sed 's#.*/##;s/\.git.*$//')"
      ref="$(printf "%s" "$src" | awk -F'@' 'NF>1{print $NF}')"
      [ -n "$ref" ] || ref="HEAD"
      name="git-${repo}-${ref}"
      target="$WORK_DIR/$name";;
    *) name="item-$idx"; target="$WORK_DIR/$name";;
  esac

  # REUSED
  if [ "$ADM_FETCH_FORCE" -ne 1 ] && [ "$typ" != "git" ] && [ "$typ" != "dir" ] && [ -f "$target" ] && [ "$sum" != "-" ]; then
    cur="$(sha256_file "$target")"
    if [ "$cur" = "$sum" ]; then
      manifest_append "ITEM_${idx}_SOURCE=$orig
ITEM_${idx}_LOCAL=$target
ITEM_${idx}_TYPE=$typ
ITEM_${idx}_STATUS=REUSED
ITEM_${idx}_SHA256=$cur
ITEM_${idx}_SIZE=$(wc -c <"$target" 2>/dev/null || echo 0)
"
      say OK
      return 0
    fi
  fi

  # retries
  attempt=0
  ok=0
  while [ $attempt -lt "$ADM_FETCH_RETRIES" ]; do
    attempt=$((attempt+1))
    case "$typ" in
      http|ftp) dl_http "$src" "$target" ;;
      rsync)    dl_rsync "$src" "$target" ;;
      git)      dl_git "$src" "$target" ;;
      file)     cp_file "${src#file://}" "$target" ;;
      dir)      cp_dir  "${src#dir://}" "$target" ;;
      *)        dl_http "$src" "$target" ;;
    esac
    rc=$?
    if [ $rc -eq 0 ]; then ok=1; break; fi
    sleep $((attempt*2))
  done

  if [ $ok -ne 1 ]; then
    manifest_append "ITEM_${idx}_SOURCE=$orig
ITEM_${idx}_LOCAL=$target
ITEM_${idx}_TYPE=$typ
ITEM_${idx}_STATUS=FAILED
ITEM_${idx}_SHA256=-
ITEM_${idx}_SIZE=0
"
    say ERROR "falha ao obter item $idx ($orig)"
    return 20
  fi

  # Finaliza .part → definitivo
  if [ "$typ" = "git" ] || [ "$typ" = "dir" ]; then
    mv -f "$target.part" "$target" 2>/dev/null || true
  else
    mv -f "$target.part" "$target" 2>/dev/null || true
  fi

  # Verificação de integridade
  size=0; sha="-"; commid="-"
  if [ "$typ" = "git" ]; then
    if [ -d "$target/.git" ]; then
      commid="$(cd "$target" && git rev-parse HEAD 2>/dev/null || echo "-")"
      size=$(du -sk "$target" 2>/dev/null | awk '{print $1*1024}')
    fi
  elif [ "$typ" = "dir" ]; then
    size=$(du -sk "$target" 2>/dev/null | awk '{print $1*1024}')
  else
    size=$(wc -c <"$target" 2>/dev/null || echo 0)
    if [ "$sum" != "-" ]; then
      sha="$(sha256_file "$target")"
      if [ "$sha" != "$sum" ]; then
        manifest_append "ITEM_${idx}_SOURCE=$orig
ITEM_${idx}_LOCAL=$target
ITEM_${idx}_TYPE=$typ
ITEM_${idx}_STATUS=FAILED
ITEM_${idx}_SHA256=$sha
ITEM_${idx}_SIZE=$size
"
        say ERROR "sha256 mismatch no item $idx"
        return 21
      fi
    fi
  fi

  manifest_append "ITEM_${idx}_SOURCE=$orig
ITEM_${idx}_LOCAL=$target
ITEM_${idx}_TYPE=$typ
ITEM_${idx}_STATUS=OK
ITEM_${idx}_SHA256=${sha}
ITEM_${idx}_COMMID=${commid}
ITEM_${idx}_SIZE=${size}
"
  say OK
  return 0
}

# =========================
# 8) Execução (paralelo/serial)
# =========================
run_plan(){
  jobs="$(jobs_auto)"
  say INFO "iniciando fetch: jobs=$jobs timeout=${ADM_FETCH_TIMEOUT}s retries=${ADM_FETCH_RETRIES} prefer=${ADM_FETCH_PREFER}"
  [ "$ADM_FETCH_INSECURE" -eq 1 ] && say WARN "TLS INSEGURO ATIVADO (--insecure)"

  idx=0
  # construir lista numerada
  PLAN=""
  a="$SRC_LIST"; b="$SUM_LIST"
  # Itera linha a linha
  i=0
  printf "%s\n" "$a" | while IFS= read -r s || [ -n "$s" ]; do
    i=$((i+1))
    h="$(printf "%s\n" "$b" | sed -n "${i}p")"
    printf "%s %s\n" "$s" "$h"
  done >"$WORK_DIR/.plan"

  # Filtro --only (ex.: "1,3,5")
  if [ -n "${ONLY_INDEXES:-}" ]; then
    tmp="$WORK_DIR/.plan.only"
    : >"$tmp"
    IFS=','; set -- $ONLY_INDEXES; IFS=' '
    for k in "$@"; do sed -n "${k}p" "$WORK_DIR/.plan" >>"$tmp"; done
    mv -f "$tmp" "$WORK_DIR/.plan"
  fi

  if command -v xargs >/dev/null 2>&1; then
    # xargs paralelo
    seq=0
    cat "$WORK_DIR/.plan" | nl -ba | \
    xargs -n3 -P "$jobs" sh -c '
      idx="$1"; src="$2"; sum="$3"
      shift 3
      '"$(printf '%s' "$(command -v "$0")")"' __worker "$idx" "$src" "$sum"
    ' sh
    rc=$?
  else
    # serial fallback
    rc=0
    nl -ba "$WORK_DIR/.plan" | while read -r idx src sum; do
      "$0" __worker "$idx" "$src" "$sum" || rc=$?
    done
  fi
  return ${rc:-0}
}

# =========================
# 9) CLI e fluxo principal
# =========================
usage(){
  cat <<'EOF'
Uso: adm-fetch.sh <metafile> [opções]
Opções:
  --parallel N         Força paralelismo (override ADM_FETCH_JOBS)
  --force              Rebaixa tudo (ignora REUSED)
  --no-resume          Desativa retomada de downloads
  --insecure           Desabilita verificação TLS (gera WARN)
  --prefer-tarball     Para github/gitlab, força tarball (padrão)
  --prefer-clone       Para github/gitlab, força clone git
  --only INDEXES       Baixa apenas índices (ex.: "1,3,5")
  --dry-run            Não baixa, apenas mostra plano
  --timeout SECS       Timeout por item (default 300)
  --retries N          Tentativas por item (default 3)
  --proxy URL          Proxy http(s) específico
EOF
}
main(){
  _color_setup
  metafile=""
  ONLY_INDEXES=""
  DRY_RUN=0

  # Parse args
  while [ $# -gt 0 ]; do
    case "$1" in
      --parallel) shift; [ $# -ge 1 ] || die "faltou N após --parallel"; ADM_FETCH_JOBS="$1";;
      --force) ADM_FETCH_FORCE=1;;
      --no-resume) ADM_FETCH_NO_RESUME=1;;
      --insecure) ADM_FETCH_INSECURE=1;;
      --prefer-tarball) ADM_FETCH_PREFER="tarball";;
      --prefer-clone)   ADM_FETCH_PREFER="clone";;
      --only) shift; [ $# -ge 1 ] || die "faltou lista após --only"; ONLY_INDEXES="$1";;
      --dry-run) DRY_RUN=1;;
      --timeout) shift; [ $# -ge 1 ] || die "faltou SECS após --timeout"; ADM_FETCH_TIMEOUT="$1";;
      --retries) shift; [ $# -ge 1 ] || die "faltou N após --retries"; ADM_FETCH_RETRIES="$1";;
      --proxy) shift; [ $# -ge 1 ] || die "faltou URL após --proxy"; ADM_FETCH_PROXY="$1";;
      -h|--help|help) usage; exit 0;;
      __worker) shift; process_item "$@"; exit $?;;
      *)
        if [ -z "$metafile" ]; then metafile="$1"; else die "argumento inesperado: $1"; fi
        ;;
    esac
    shift || true
  done

  [ -n "$metafile" ] || { usage; exit 10; }

  parse_metafile "$metafile"
  prepare_cache

  say INFO "metafile: $metafile"
  say INFO "pacote: ${NAME}-${VERSION}"
  say INFO "cache: $WORK_DIR"

  if [ "$DRY_RUN" -eq 1 ]; then
    # apenas mostra plano
    i=0
    printf "%s\n" "$SRC_LIST" | while IFS= read -r s || [ -n "$s" ]; do
      i=$((i+1))
      h="$(printf "%s\n" "$SUM_LIST" | sed -n "${i}p")"
      exp="$(expand_alias "$s")"
      typ="$(detect_type "$exp")"
      printf " [%02d] %-6s %s\n" "$i" "$typ" "$exp"
    done
    exit 0
  fi

  start_ts="$(date +%s)"
  run_plan
  rc=$?

  ok_count=$(grep -c '^ITEM_.*_STATUS=OK$' "$MANIFEST" 2>/dev/null || echo 0)
  fail_count=$(grep -c '^ITEM_.*_STATUS=FAILED$' "$MANIFEST" 2>/dev/null || echo 0)
  reused_count=$(grep -c '^ITEM_.*_STATUS=REUSED$' "$MANIFEST" 2>/dev/null || echo 0)
  end_ts="$(date +%s)"
  dur=$((end_ts - start_ts))

  {
    echo "NAME=${NAME}"
    echo "VERSION=${VERSION}"
    echo "CACHE=${WORK_DIR}"
    echo "OK=${ok_count}"
    echo "REUSED=${reused_count}"
    echo "FAILED=${fail_count}"
    echo "DURATION_SEC=${dur}"
    echo "TIMESTAMP=$(ts)"
  } >>"$SUMMARY" 2>/dev/null || true

  if [ "$fail_count" -gt 0 ] || [ $rc -ne 0 ]; then
    say ERROR "fetch concluído com falhas (ok=$ok_count reused=$reused_count fail=$fail_count) duração=${dur}s"
    exit ${rc:-20}
  fi
  say INFO "fetch concluído (ok=$ok_count reused=$reused_count) duração=${dur}s"
  exit 0
}

main "$@"
