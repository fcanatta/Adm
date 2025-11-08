#!/usr/bin/env sh
# adm-clean.sh — Limpador seguro/esperto do ecossistema ADM
# POSIX sh; compatível com dash/ash/bash.
# # ver o que dá para limpar
# adm-clean.sh ls
# simular limpeza profunda de cache e destdirs
# adm-clean.sh dryrun cache build --all
# limpeza segura padrão
# adm-clean.sh cache logs build --all registry --vacuum
# remover órfãos de pacotes e reindexar o repositório
# adm-clean.sh orphans --pkgs --fix --yes
# adm-clean.sh repo --reindex
# desmontar binds presos e apagar stage1 por completo
# adm-clean.sh stage --purge-mounts --nuke 1 --yes
set -u
# =========================
# 0) Config & defaults
# =========================
: "${ADM_ROOT:=/usr/src/adm}"
: "${ADM_LOG_COLOR:=auto}"
: "${ADM_STAGE:=host}"
: "${ADM_PIPELINE:=clean}"

BIN_DIR="$ADM_ROOT/bin"
BUILD_DIR="$ADM_ROOT/build"
CACHE_DIR="$ADM_ROOT/cache"
REG_DIR="$ADM_ROOT/registry"
REPO_DIR="$ADM_ROOT/repo"
LOG_DIR="$ADM_ROOT/logs"
STAGE_BASE="$ADM_ROOT"
TOOLCHAIN_DIR="$ADM_ROOT/toolchain"
LOCK_DIR="$ADM_ROOT/locks"
LOCK_FILE="$LOCK_DIR/clean.lock"

JSON=0
YES=0
VERBOSE=0
DRYRUN=0

# =========================
# 1) Cores + logging (fallback se adm-log.sh não existir)
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
_c_mag(){ [ $_color_on -eq 1 ] && printf '\033[35;1m'; }  # estágio rosa bold
_c_yel(){ [ $_color_on -eq 1 ] && printf '\033[33;1m'; }  # caminho amarelo bold
_c_gry(){ [ $_color_on -eq 1 ] && printf '\033[38;5;244m';}

have_adm_log=0
command -v adm_log_info >/dev/null 2>&1 && have_adm_log=1

_ts(){ date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([0-9][0-9]\)$/:\1/'; }
_ctx(){
  st="${ADM_STAGE:-host}"; pipe="${ADM_PIPELINE:-clean}"; path="${PWD:-/}"
  if [ $_color_on -eq 1 ]; then
    printf "("; _c_mag; printf "%s" "$st"; _rst; _c_gry; printf ":%s" "$pipe"; _rst
    printf " path="; _c_yel; printf "%s" "$path"; _rst; printf ")"
  else
    printf "(%s:%s path=%s)" "$st" "$pipe" "$path"
  fi
}
say(){
  lvl="$1"; shift; msg="${*:-}"
  if [ $have_adm_log -eq 1 ]; then
    case "$lvl" in
      INFO)  adm_log_info  "$msg";;
      WARN)  adm_log_warn  "$msg";;
      ERROR) adm_log_error "$msg";;
      STEP)  adm_log_step_start "$msg" >/dev/null;;
      OK)    adm_log_step_ok;;
      DEBUG) adm_log_debug "$msg";;
      *)     adm_log_info "$msg";;
    esac
  else
    _color_setup
    case "$lvl" in
      INFO) t="[INFO]";; WARN) t="[WARN]";; ERROR) t="[ERROR]";; STEP) t="[STEP]";; OK) t="[ OK ]";; DEBUG) t="[DEBUG]";;
      *) t="[$lvl]";;
    esac
    printf "%s [%s] %s %s\n" "$t" "$(_ts)" "$(_ctx)" "$msg"
  fi
}
die(){ say ERROR "$*"; exit 40; }

ensure_dirs(){
  for d in "$CACHE_DIR" "$BUILD_DIR" "$REG_DIR" "$REPO_DIR" "$LOG_DIR" "$LOCK_DIR"; do
    [ -d "$d" ] || mkdir -p "$d" || die "não foi possível criar: $d"
  done
}

# =========================
# 2) Utils
# =========================
lower(){ printf "%s" "$1" | tr 'A-Z' 'a-z'; }
trim(){ printf "%s" "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
human(){ num="${1:-0}"; awk -v n="$num" 'BEGIN{ split("B KB MB GB TB",u); i=1; while(n>=1024 && i<5){n/=1024;i++} printf("%.1f %s", n, u[i]) }'; }

size_of(){
  p="$1"; [ -e "$p" ] || { echo 0; return; }
  if command -v du >/dev/null 2>&1; then du -sb "$p" 2>/dev/null | awk '{print $1}'; else echo 0; fi
}

safe_rm_rf(){
  p="$1"
  [ -n "$p" ] || { say ERROR "safe_rm_rf: caminho vazio"; return 1; }
  case "$p" in /|"") say ERROR "safe_rm_rf: caminho proibido: $p"; return 1;; esac
  if [ $DRYRUN -eq 1 ]; then
    _c_yel; printf "[dry-run] remover: %s\n" "$p"; _rst
    return 0
  fi
  rm -rf -- "$p" 2>/dev/null || { say WARN "falha ao remover $p"; return 1; }
  return 0
}

confirm_or_die(){
  [ $YES -eq 1 ] && return 0
  printf "%s Prosseguir? [y/N] " "$1" 1>&2
  read -r ans || ans="n"
  case "$(lower "$(trim "$ans")")" in y|yes) return 0;; *) say WARN "cancelado pelo usuário"; exit 20;; esac
}

lock_acquire(){
  ensure_dirs
  if [ -f "$LOCK_FILE" ]; then
    say ERROR "já existe uma limpeza em andamento ($LOCK_FILE)"; exit 22
  fi
  echo "$$ $(date +%s)" > "$LOCK_FILE" 2>/dev/null || die "não foi possível criar lock"
}

lock_release(){
  [ -f "$LOCK_FILE" ] && rm -f "$LOCK_FILE" 2>/dev/null || true
}

# =========================
# 3) Ajuda / CLI
# =========================
usage(){
  cat <<'EOF'
Uso:
  adm-clean.sh ls
  adm-clean.sh dryrun [alvo...]
  adm-clean.sh cache [--aggressive] [--max-age D] [--keep N] [--yes] [--json]
  adm-clean.sh logs  [--max-age D] [--size-limit MB] [--yes]
  adm-clean.sh build [--all|--work|--destdir|--pkg-tmp] [--yes]
  adm-clean.sh registry [--vacuum | --fix-links] [--yes]
  adm-clean.sh repo [--reindex] [--prune-unindexed] [--yes]
  adm-clean.sh orphans [--files|--pkgs|--backups] [--fix] [--yes]
  adm-clean.sh stage [--purge-mounts] [--nuke {0|1|2|all}] [--yes]
  adm-clean.sh toolchain [--purge-intermediates] [--nuke] [--yes]
  adm-clean.sh everything [--safe | --deep] [--yes]

Opções comuns:
  --yes (não interativo), --json, --verbose, --dry-run
EOF
}

parse_common(){
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) YES=1;;
      --json) JSON=1;;
      --verbose) VERBOSE=$((VERBOSE+1));;
      --dry-run) DRYRUN=1;;
      *) echo "$1";;
    esac
    shift || true
  done
}

# =========================
# 4) Coleta de candidatos (ls)
# =========================
list_candidates(){
  ensure_dirs
  say STEP "Coletando candidatos à limpeza"
  total=0

  can_build_work=""
  for d in "$BUILD_DIR"/*/work 2>/dev/null; do [ -d "$d" ] && can_build_work="$can_build_work\n$d"; done
  can_build_dest=""
  for d in "$BUILD_DIR"/*/destdir 2>/dev/null; do [ -d "$d" ] && can_build_dest="$can_build_dest\n$d"; done
  can_build_pkgtmp=""
  for d in "$BUILD_DIR"/*/pkg/tmp 2>/dev/null; do [ -d "$d" ] && can_build_pkgtmp="$can_build_pkgtmp\n$d"; done

  can_cache=""
  for c in "$CACHE_DIR"/* 2>/dev/null; do [ -d "$c" ] && can_cache="$can_cache\n$c"; done

  can_logs=""
  for l in "$LOG_DIR"/* 2>/dev/null; do [ -d "$l" ] && can_logs="$can_logs\n$l"; done

  can_stages=""
  for s in "$STAGE_BASE"/stage? 2>/dev/null; do [ -d "$s" ] && can_stages="$can_stages\n$s"; done

  summarize(){
    label="$1"; list="$2"
    [ -n "$list" ] || return 0
    echo "$list" | sed '/^[[:space:]]*$/d' | while read -r p; do
      sz="$(size_of "$p")"; total=$((total+sz))
      printf "%-12s %10s  " "[$label]" "$(human "$sz")"
      _c_yel; printf "%s\n" "$p"; _rst
    done
  }

  summarize "work"    "$can_build_work"
  summarize "destdir" "$can_build_dest"
  summarize "pkg-tmp" "$can_build_pkgtmp"
  summarize "cache"   "$can_cache"
  summarize "logs"    "$can_logs"
  summarize "stage"   "$can_stages"

  say INFO "Total estimado: $(human "$total")"
  [ $JSON -eq 1 ] && printf '{"estimated_bytes":%s}\n' "$total" || true
  say OK
}

# =========================
# 5) Dry-run detalhado
# =========================
cmd_dryrun(){
  DRYRUN=1
  rem="$(parse_common "$@")"; set -- $rem
  [ $# -gt 0 ] || { # se vazio, simula tudo básico
    set -- cache build --all logs registry --vacuum
  }
  say STEP "DRY-RUN — nenhuma alteração será feita"
  # Encaminha para subcomandos com --dry-run ativo
  sub=""
  while [ $# -gt 0 ]; do
    case "$1" in
      cache)      shift; cmd_cache "$@" ; break;;
      logs)       shift; cmd_logs "$@" ; break;;
      build)      shift; cmd_build "$@" ; break;;
      registry)   shift; cmd_registry "$@" ; break;;
      repo)       shift; cmd_repo "$@" ; break;;
      orphans)    shift; cmd_orphans "$@" ; break;;
      stage)      shift; cmd_stage "$@" ; break;;
      toolchain)  shift; cmd_toolchain "$@" ; break;;
      everything) shift; cmd_everything "$@" ; break;;
      *) usage; exit 10;;
    esac
  done
}
# =========================
# 6) cache
# =========================
cmd_cache(){
  AGG=0; MAX_AGE=30; KEEP=1
  rem="$(parse_common "$@")"; set -- $rem
  while [ $# -gt 0 ]; do
    case "$1" in
      --aggressive) AGG=1;;
      --max-age) shift; MAX_AGE="${1:-30}";;
      --keep) shift; KEEP="${1:-1}";;
      *) say ERROR "arg desconhecido em cache: $1"; exit 10;;
    esac; shift || true
  done

  ensure_dirs
  say STEP "Limpeza de cache (aggressive=$AGG, max-age=$MAX_AGE, keep=$KEEP)"

  now="$(date +%s)"
  cutoff=$((MAX_AGE*24*3600))

  removed=0; kept=0; bytes=0
  for d in "$CACHE_DIR"/* 2>/dev/null; do
    [ -d "$d" ] || continue
    bn="$(basename "$d")"
    # heurística de referência: mantém se houver manifest.fetch ou update/sources.list recente
    ref1="$d/manifest.fetch"
    ref2="$ADM_ROOT/update" # referências globais
    recent=0
    [ -f "$ref1" ] && recent=1
    # idade do diretório
    mtime="$(stat -c %Y "$d" 2>/dev/null || echo "$now")"
    age=$((now - mtime))
    if [ $AGG -eq 1 ]; then
      if [ $age -gt $cutoff ]; then
        sz="$(size_of "$d")"; bytes=$((bytes+sz))
        safe_rm_rf "$d" && removed=$((removed+1)) || true
      else
        kept=$((kept+1))
      fi
    else
      if [ $recent -eq 0 ] && [ $age -gt $cutoff ]; then
        sz="$(size_of "$d")"; bytes=$((bytes+sz))
        safe_rm_rf "$d" && removed=$((removed+1)) || true
      else
        kept=$((kept+1))
      fi
    fi
  done

  say INFO "cache: removed=$removed kept=$kept freed=$(human "$bytes")"
  [ $removed -eq 0 ] && [ $DRYRUN -eq 0 ] && exit 20 || true
  say OK
}

# =========================
# 7) logs
# =========================
cmd_logs(){
  MAX_AGE=30; SIZE_LIMIT_MB=0
  rem="$(parse_common "$@")"; set -- $rem
  while [ $# -gt 0 ]; do
    case "$1" in
      --max-age) shift; MAX_AGE="${1:-30}";;
      --size-limit) shift; SIZE_LIMIT_MB="${1:-0}";;
      *) say ERROR "arg desconhecido em logs: $1"; exit 10;;
    esac; shift || true
  done
  ensure_dirs
  say STEP "Rotação/expurgo de logs (max-age=$MAX_AGE dias; size-limit=${SIZE_LIMIT_MB}MB)"

  now="$(date +%s)"
  cutoff=$((MAX_AGE*24*3600))
  freed=0; removed=0

  for ldir in "$LOG_DIR"/* 2>/dev/null; do
    [ -d "$ldir" ] || continue
    # sempre preserva o log de hoje
    today="$(date +%Y-%m-%d)"
    for f in "$ldir"/* 2>/dev/null; do
      [ -f "$f" ] || continue
      echo "$f" | grep -q "$today" && continue
      mt="$(stat -c %Y "$f" 2>/dev/null || echo "$now")"
      age=$((now - mt))
      if [ $age -gt $cutoff ]; then
        sz="$(size_of "$f")"; freed=$((freed+sz))
        safe_rm_rf "$f" && removed=$((removed+1)) || true
      fi
    done
    # limite por tamanho total do diretório
    if [ "$SIZE_LIMIT_MB" -gt 0 ]; then
      dirsz="$(size_of "$ldir")"
      lim=$((SIZE_LIMIT_MB*1024*1024))
      if [ "$dirsz" -gt "$lim" ]; then
        # remove os mais antigos até atingir o limite
        for f in $(ls -1t "$ldir" 2>/dev/null | sed -n '1!p' | sed "s#^#$ldir/#"); do
          [ -f "$f" ] || continue
          dirsz="$(size_of "$ldir")"
          [ "$dirsz" -le "$lim" ] && break
          sz="$(size_of "$f")"; freed=$((freed+sz))
          safe_rm_rf "$f" && removed=$((removed+1)) || true
        done
      fi
    fi
  done

  say INFO "logs: removed=$removed freed=$(human "$freed")"
  [ $removed -eq 0 ] && [ $DRYRUN -eq 0 ] && exit 20 || true
  say OK
}

# =========================
# 8) build
# =========================
cmd_build(){
  WORK=0; DESTDIR=0; PKGTMP=0; ALL=0
  rem="$(parse_common "$@")"; set -- $rem
  while [ $# -gt 0 ]; do
    case "$1" in
      --work) WORK=1;;
      --destdir) DESTDIR=1;;
      --pkg-tmp) PKGTMP=1;;
      --all) ALL=1;;
      --yes) YES=1;; # handled in parse_common também
      *) say ERROR "arg desconhecido em build: $1"; exit 10;;
    esac; shift || true
  done
  [ $ALL -eq 1 ] && { WORK=1; DESTDIR=1; PKGTMP=1; }
  [ $WORK -eq 0 ] && [ $DESTDIR -eq 0 ] && [ $PKGTMP -eq 0 ] && { say WARN "nenhum alvo selecionado (use --all|--work|--destdir|--pkg-tmp)"; exit 20; }

  ensure_dirs
  say STEP "Limpeza de build (work=$WORK destdir=$DESTDIR pkg-tmp=$PKGTMP)"
  freed=0; removed=0

  for pkgdir in "$BUILD_DIR"/* 2>/dev/null; do
    [ -d "$pkgdir" ] || continue
    [ $WORK -eq 1 ]    && [ -d "$pkgdir/work" ]    && { sz="$(size_of "$pkgdir/work")"; freed=$((freed+sz)); safe_rm_rf "$pkgdir/work" && removed=$((removed+1)) || true; }
    if [ $DESTDIR -eq 1 ] && [ -d "$pkgdir/destdir" ]; then
      # só remove destdir se já existir manifest de build (assume empacotado)
      bbase="$(basename "$pkgdir")"
      if [ -f "$REG_DIR/build/$bbase/build.manifest" ]; then
        sz="$(size_of "$pkgdir/destdir")"; freed=$((freed+sz))
        safe_rm_rf "$pkgdir/destdir" && removed=$((removed+1)) || true
      fi
    fi
    [ $PKGTMP -eq 1 ] && [ -d "$pkgdir/pkg/tmp" ] && { sz="$(size_of "$pkgdir/pkg/tmp")"; freed=$((freed+sz)); safe_rm_rf "$pkgdir/pkg/tmp" && removed=$((removed+1)) || true; }
  done

  say INFO "build: removed=$removed freed=$(human "$freed")"
  [ $removed -eq 0 ] && [ $DRYRUN -eq 0 ] && exit 20 || true
  say OK
}

# =========================
# 9) registry
# =========================
cmd_registry(){
  VACUUM=0; FIX=0
  rem="$(parse_common "$@")"; set -- $rem
  while [ $# -gt 0 ]; do
    case "$1" in
      --vacuum) VACUUM=1;;
      --fix-links) FIX=1;;
      *) say ERROR "arg desconhecido em registry: $1"; exit 10;;
    esac; shift || true
  done
  ensure_dirs
  say STEP "Registry (vacuum=$VACUUM fix-links=$FIX)"

  # VACUUM: remove entradas inválidas (sem manifest/meta)
  removed=0; freed=0
  if [ $VACUUM -eq 1 ]; then
    for scope in build install pipeline kinit; do
      for d in "$REG_DIR/$scope"/* 2>/dev/null; do
        [ -d "$d" ] || continue
        case "$scope" in
          build)   mani="$d/build.manifest"; meta="$d/build.meta";;
          install) mani="$d/install.manifest"; meta="$d/install.meta";;
          pipeline) mani=""; meta="";; # pipeline é flexível, não apagar aqui
          kinit)   mani=""; meta="$d/kinit.meta";;
        esac
        ok=1
        [ -n "$mani" ] && [ ! -f "$mani" ] && ok=0
        [ -n "$meta" ] && [ ! -f "$meta" ] && ok=0
        if [ $ok -eq 0 ]; then
          sz="$(size_of "$d")"; freed=$((freed+sz))
          safe_rm_rf "$d" && removed=$((removed+1)) || true
        fi
      done
    done
  fi

  # FIX-LINKS: tentar `adm-registry.sh check-links`
  if [ $FIX -eq 1 ]; then
    if [ -x "$BIN_DIR/adm-registry.sh" ]; then
      if [ $DRYRUN -eq 1 ]; then
        say INFO "[dry-run] executaria: adm-registry.sh check-links"
      else
        "$BIN_DIR/adm-registry.sh" check-links >/dev/null 2>&1 || say WARN "check-links retornou erro"
      fi
    else
      say WARN "adm-registry.sh não encontrado para fix-links"
    fi
  fi

  say INFO "registry: removed=$removed freed=$(human "$freed")"
  [ $removed -eq 0 ] && [ $FIX -eq 0 ] && [ $DRYRUN -eq 0 ] && exit 20 || true
  say OK
}

# =========================
# 10) repo
# =========================
cmd_repo(){
  REINDEX=0; PRUNE=0
  rem="$(parse_common "$@")"; set -- $rem
  while [ $# -gt 0 ]; do
    case "$1" in
      --reindex) REINDEX=1;;
      --prune-unindexed) PRUNE=1;;
      *) say ERROR "arg desconhecido em repo: $1"; exit 10;;
    esac; shift || true
  done
  ensure_dirs
  say STEP "Repositório (reindex=$REINDEX prune-unindexed=$PRUNE)"

  if [ $REINDEX -eq 1 ]; then
    if [ -x "$BIN_DIR/adm-registry.sh" ]; then
      if [ $DRYRUN -eq 1 ]; then
        say INFO "[dry-run] executaria: adm-registry.sh repo index --dir $REPO_DIR"
      else
        "$BIN_DIR/adm-registry.sh" repo index --dir "$REPO_DIR" >/dev/null 2>&1 || say WARN "repo index retornou erro"
      fi
    else
      # fallback reindex simples
      sums="$REPO_DIR/sha256sums.txt"; idx="$REPO_DIR/index.json"
      [ $DRYRUN -eq 1 ] && { say INFO "[dry-run] reindex fallback em $REPO_DIR"; } || {
        : >"$sums"; printf "[\n" >"$idx"; first=1
        for f in "$REPO_DIR"/*.tar.* "$REPO_DIR"/*.deb "$REPO_DIR"/*.rpm 2>/dev/null; do
          [ -e "$f" ] || continue
          bn="$(basename "$f")"; sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
          if command -v sha256sum >/dev/null 2>&1; then h="$(sha256sum "$f" | awk '{print $1}')"; else h="-"; fi
          echo "$h  $bn" >>"$sums"
          [ $first -eq 1 ] || printf ",\n" >>"$idx"; first=0
          printf "  {\"file\":\"%s\",\"size\":%s,\"sha256\":\"%s\",\"timestamp\":\"%s\"}" "$bn" "$sz" "$h" "$(_ts)" >>"$idx"
        done
        printf "\n]\n" >>"$idx"
      }
    fi
  fi

  if [ $PRUNE -eq 1 ]; then
    [ $YES -eq 1 ] || confirm_or_die "Remover pacotes não indexados no repo?"
    sums="$REPO_DIR/sha256sums.txt"
    if [ ! -f "$sums" ]; then
      say WARN "sha256sums.txt ausente — nada a podar"
    else
      removed=0; freed=0
      for f in "$REPO_DIR"/*.tar.* "$REPO_DIR"/*.deb "$REPO_DIR"/*.rpm 2>/dev/null; do
        [ -e "$f" ] || continue
        bn="$(basename "$f")"
        if ! grep -q " $bn\$" "$sums" 2>/dev/null; then
          sz="$(size_of "$f")"; freed=$((freed+sz))
          safe_rm_rf "$f" && removed=$((removed+1)) || true
        fi
      done
      say INFO "repo: removed=$removed freed=$(human "$freed")"
    fi
  fi
  say OK
}
# =========================
# 11) orphans
# =========================
# Constrói lista de arquivos "pertencentes" a algum pacote a partir dos manifests
build_owned_set(){
  tmp="${1:-/tmp/adm-owned.$$}"
  : >"$tmp"
  for mani in "$REG_DIR"/install/*/install.manifest 2>/dev/null; do
    [ -f "$mani" ] || continue
    awk -F'\t' 'NF>=1{print "/"$1}' "$mani" 2>/dev/null >>"$tmp"
  done
  sort -u "$tmp" -o "$tmp" 2>/dev/null || true
  echo "$tmp"
}

is_whitelisted_path(){
  p="$1"
  case "$p" in
    /home/*|/root/*|/tmp/*|/var/tmp/*|/proc/*|/sys/*|/dev/*|/run/*) return 0;;
    /mnt/*|/media/*|/lost+found|/boot/*) return 0;;
    # arquivos de VCS
    */.git/*|*/.svn/*|*/.hg/*) return 0;;
    *) return 1;;
  esac
}

cmd_orphans(){
  MODE_FILES=0; MODE_PKGS=0; MODE_BACKUPS=0; FIX=0
  rem="$(parse_common "$@")"; set -- $rem
  while [ $# -gt 0 ]; do
    case "$1" in
      --files) MODE_FILES=1;;
      --pkgs) MODE_PKGS=1;;
      --backups) MODE_BACKUPS=1;;
      --fix) FIX=1;;
      *) say ERROR "arg desconhecido em orphans: $1"; exit 10;;
    esac; shift || true
  done
  ensure_dirs
  [ $MODE_FILES -eq 0 ] && [ $MODE_PKGS -eq 0 ] && [ $MODE_BACKUPS -eq 0 ] && { say WARN "selecione --files|--pkgs|--backups"; exit 10; }

  if [ $MODE_FILES -eq 1 ]; then
    say STEP "Órfãos em / (arquivos não pertencentes a nenhum manifest)"
    owned="$(build_owned_set)"
    tmp_ls="$(mktemp 2>/dev/null || echo "/tmp/adm-ls.$$")"
    # lista conservadora: /bin /sbin /usr /lib /etc /opt (exclui whitelist)
    find /bin /sbin /usr /lib /etc /opt -xdev -type f 2>/dev/null | sort -u >"$tmp_ls"
    removed=0; show=0; freed=0
    while read -r f; do
      is_whitelisted_path "$f" && continue
      grep -qxF "$f" "$owned" 2>/dev/null && continue
      # candidato órfão
      _c_yel; printf "órfão: %s\n" "$f"; _rst
      show=$((show+1))
      if [ $FIX -eq 1 ]; then
        [ $YES -eq 1 ] || confirm_or_die "Remover órfão $f ?"
        sz="$(size_of "$f")"; freed=$((freed+sz))
        safe_rm_rf "$f" && removed=$((removed+1)) || true
      fi
    done <"$tmp_ls"
    rm -f "$tmp_ls" "$owned" 2>/dev/null || true
    say INFO "orphans(files): encontrados=$show removidos=$removed freed=$(human "$freed")"
    [ $show -eq 0 ] && [ $DRYRUN -eq 0 ] && exit 20 || true
  fi

  if [ $MODE_PKGS -eq 1 ]; then
    say STEP "Órfãos de pacotes no repo/registry"
    sums="$REPO_DIR/sha256sums.txt"
    if [ ! -f "$sums" ]; then
      say WARN "sha256sums.txt ausente"
    else
      for f in "$REPO_DIR"/*.tar.* "$REPO_DIR"/*.deb "$REPO_DIR"/*.rpm 2>/dev/null; do
        [ -e "$f" ] || continue
        bn="$(basename "$f")"
        grep -q " $bn\$" "$sums" 2>/dev/null || _c_yel && printf "não indexado: %s\n" "$bn" && _rst
      done
    fi
    say OK
  fi

  if [ $MODE_BACKUPS -eq 1 ]; then
    say STEP "Backups antigos (/usr/src/adm/registry/kinit/*/backups)"
    removed=0; freed=0; listed=0
    for d in "$REG_DIR/kinit"/*/backups 2>/dev/null; do
      [ -d "$d" ] || continue
      # mantém 3 mais recentes
      list="$(ls -1t "$d"/boot-* 2>/dev/null || true)"
      c=0
      echo "$list" | while read -r f; do
        [ -n "$f" ] || continue
        c=$((c+1))
        if [ $c -le 3 ]; then
          listed=$((listed+1))
          continue
        fi
        _c_yel; printf "backup antigo: %s\n" "$f"; _rst
        if [ $FIX -eq 1 ]; then
          [ $YES -eq 1 ] || confirm_or_die "Remover backup antigo $f ?"
          sz="$(size_of "$f")"; freed=$((freed+sz))
          safe_rm_rf "$f" && removed=$((removed+1)) || true
        fi
      done
    done
    say INFO "orphans(backups): removidos=$removed freed=$(human "$freed")"
  fi
  say OK
}

# =========================
# 12) stage
# =========================
umount_if_mounted(){
  m="$1"
  mount | grep -q " on $m " 2>/dev/null || return 0
  if [ $DRYRUN -eq 1 ]; then _c_yel; printf "[dry-run] umount %s\n" "$m"; _rst; return 0; fi
  umount -lf "$m" 2>/dev/null || say WARN "falha ao desmontar $m"
}

cmd_stage(){
  PURGE_MOUNTS=0; NUKE=""
  rem="$(parse_common "$@")"; set -- $rem
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge-mounts) PURGE_MOUNTS=1;;
      --nuke) shift; NUKE="${1:-}";;
      *) say ERROR "arg desconhecido em stage: $1"; exit 10;;
    esac; shift || true
  done

  ensure_dirs
  say STEP "Stage (purge-mounts=$PURGE_MOUNTS nuke=${NUKE:-no})"

  if [ $PURGE_MOUNTS -eq 1 ]; then
    for s in 0 1 2; do
      root="$STAGE_BASE/stage$s/root"
      [ -d "$root" ] || continue
      for d in "$root"/{dev,proc,sys,run,tmp} 2>/dev/null; do
        [ -e "$d" ] || continue
        umount_if_mounted "$d"
      done
      umount_if_mounted "$root" || true
    done
  fi

  if [ -n "$NUKE" ]; then
    [ "$NUKE" = "all" ] && targets="0 1 2" || targets="$NUKE"
    [ $YES -eq 1 ] || confirm_or_die "Remover completamente stage(s): $targets ?"
    for s in $targets; do
      root="$STAGE_BASE/stage$s"
      [ -d "$root" ] || continue
      sz="$(size_of "$root")"
      safe_rm_rf "$root" || true
      say INFO "stage$s removido (liberado $(human "$sz"))"
    done
  fi
  say OK
}

# =========================
# 13) toolchain
# =========================
cmd_toolchain(){
  PURGE_I=0; NUKE=0
  rem="$(parse_common "$@")"; set -- $rem
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge-intermediates) PURGE_I=1;;
      --nuke) NUKE=1;;
      *) say ERROR "arg desconhecido em toolchain: $1"; exit 10;;
    esac; shift || true
  done

  ensure_dirs
  say STEP "Toolchain (purge-intermediates=$PURGE_I nuke=$NUKE)"
  if [ $PURGE_I -eq 1 ]; then
    removed=0; freed=0
    for d in "$TOOLCHAIN_DIR"/* 2>/dev/null; do
      [ -d "$d" ] || continue
      for w in "$d"/build "$d"/work "$d"/tmp 2>/dev/null; do
        [ -d "$w" ] || continue
        sz="$(size_of "$w")"; freed=$((freed+sz))
        safe_rm_rf "$w" && removed=$((removed+1)) || true
      done
    done
    say INFO "toolchain (intermediários): removed=$removed freed=$(human "$freed")"
  fi

  if [ $NUKE -eq 1 ]; then
    [ $YES -eq 1 ] || confirm_or_die "APAGAR TODA a árvore de toolchain em $TOOLCHAIN_DIR ?"
    sz="$(size_of "$TOOLCHAIN_DIR")"
    safe_rm_rf "$TOOLCHAIN_DIR" || true
    say INFO "toolchain removido (liberado $(human "$sz"))"
  fi
  say OK
}

# =========================
# 14) everything (operações compostas)
# =========================
cmd_everything(){
  MODE="safe"
  rem="$(parse_common "$@")"; set -- $rem
  while [ $# -gt 0 ]; do
    case "$1" in
      --safe) MODE="safe";;
      --deep) MODE="deep";;
      *) say ERROR "arg desconhecido em everything: $1"; exit 10;;
    esac; shift || true
  done

  ensure_dirs
  say STEP "Everything ($MODE)"
  if [ "$MODE" = "safe" ]; then
    cmd_build --all --dry-run >/dev/null 2>&1; cmd_cache --dry-run >/dev/null 2>&1
    cmd_registry --vacuum --dry-run >/dev/null 2>&1
    cmd_logs --dry-run >/dev/null 2>&1
    [ $YES -eq 1 ] || confirm_or_die "Executar limpeza SAFE?"
    DRYRUN=0; cmd_build --all --yes
    cmd_cache --yes
    cmd_registry --vacuum --yes
    cmd_logs --yes
  else
    cmd_build --all --dry-run >/dev/null 2>&1; cmd_cache --aggressive --dry-run >/dev/null 2>&1
    cmd_orphans --files --dry-run >/dev/null 2>&1
    cmd_repo --prune-unindexed --dry-run >/dev/null 2>&1
    [ $YES -eq 1 ] || confirm_or_die "Executar limpeza DEEP (pode remover muito)?"
    DRYRUN=0; cmd_build --all --yes
    cmd_cache --aggressive --yes
    cmd_orphans --files --fix --yes
    cmd_repo --prune-unindexed --yes
  fi
  say OK
}

# =========================
# 15) ls (wrapper)
# =========================
cmd_ls(){
  rem="$(parse_common "$@")"; set -- $rem
  list_candidates
}

# =========================
# 16) Main dispatcher com lock
# =========================
main(){
  _color_setup
  ensure_dirs
  sub="${1:-}"; shift || true
  case "$sub" in
    ls)         cmd_ls "$@";;
    dryrun)     cmd_dryrun "$@";;
    cache)      lock_acquire; trap 'lock_release' EXIT INT TERM; cmd_cache "$@";;
    logs)       lock_acquire; trap 'lock_release' EXIT INT TERM; cmd_logs "$@";;
    build)      lock_acquire; trap 'lock_release' EXIT INT TERM; cmd_build "$@";;
    registry)   lock_acquire; trap 'lock_release' EXIT INT TERM; cmd_registry "$@";;
    repo)       lock_acquire; trap 'lock_release' EXIT INT TERM; cmd_repo "$@";;
    orphans)    lock_acquire; trap 'lock_release' EXIT INT TERM; cmd_orphans "$@";;
    stage)      lock_acquire; trap 'lock_release' EXIT INT TERM; cmd_stage "$@";;
    toolchain)  lock_acquire; trap 'lock_release' EXIT INT TERM; cmd_toolchain "$@";;
    everything) lock_acquire; trap 'lock_release' EXIT INT TERM; cmd_everything "$@";;
    -h|--help|help|"") usage; exit 0;;
    *) say ERROR "subcomando desconhecido: $sub"; usage; exit 10;;
  esac
}

main "$@"
