#!/usr/bin/env sh
# adm-install.sh — Instalador unificado (DESTDIR/pacotes) com staging, backup, rollback.
# POSIX sh; compatível com dash/ash/bash.
set -u
# =========================
# 0) Config & defaults
# =========================
: "${ADM_ROOT:=/usr/src/adm}"
: "${ADM_LOG_COLOR:=auto}"
: "${ADM_STAGE:=host}"
: "${ADM_PIPELINE:=install}"

BIN_DIR="$ADM_ROOT/bin"
REG_BUILD_DIR="$ADM_ROOT/registry/build"
REG_INSTALL_DIR="$ADM_ROOT/registry/install"
LOG_DIR="$ADM_ROOT/logs/install"
REPO_DIR="$ADM_ROOT/repo"

# Contexto & flags
SUBCMD=""
FROM_DESTDIR=""
FROM_PKG=""
FROM_DIR=""
SIG_FILE=""
NAME=""
VERSION=""
CATEGORY="misc"
DEPS_MODE="resolve" # resolve|ignore
CONFLICTS="strict"  # strict|warn|off
BACKUP="on"         # on|off
DRYRUN=0
YES=0
STAGE_USE=""
PROFILES_IN=""
TIMEOUT=0

# =========================
# 1) Cores + logging fallback
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
_c_mag(){ [ $_color_on -eq 1 ] && printf '\033[35;1m'; }  # estágio rosa
_c_yel(){ [ $_color_on -eq 1 ] && printf '\033[33;1m'; }  # path amarelo
_c_gry(){ [ $_color_on -eq 1 ] && printf '\033[38;5;244m';}

have_adm_log=0
command -v adm_log_info >/dev/null 2>&1 && have_adm_log=1

_ts(){ date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([0-9][0-9]\)$/:\1/'; }
_ctx(){
  st="${ADM_STAGE:-host}"; pipe="${ADM_PIPELINE:-install}"; path="${PWD:-/}"
  if [ $_color_on -eq 1 ]; then
    printf "("; _c_mag; printf "%s" "$st"; _rst; _c_gry; printf ":%s" "$pipe"; _rst
    printf " path="; _c_yel; printf "%s" "$path"; _rst; printf ")"
  else
    printf "(%s:%s path=%s)" "$st" "$pipe" "$path"
  fi
}
say(){
  lvl="$1"; shift; msg="$*"
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

# =========================
# 2) Utils gerais (FS, exec, hash)
# =========================
ensure_dirs(){
  for d in "$REG_BUILD_DIR" "$REG_INSTALL_DIR" "$LOG_DIR" "$REPO_DIR"; do
    [ -d "$d" ] || mkdir -p "$d" || die "não foi possível criar: $d"
  done
}
lower(){ printf "%s" "$1" | tr 'A-Z' 'a-z'; }
trim(){ printf "%s" "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
sha256_file(){ command -v sha256sum >/dev/null 2>&1 || die "sha256sum ausente"; sha256sum "$1" | awk '{print $1}'; }

safe_rm_rf(){
  p="$1"
  [ -n "$p" ] || { say ERROR "safe_rm_rf: caminho vazio"; return 1; }
  case "$p" in /|"") say ERROR "safe_rm_rf: caminho proibido: $p"; return 1;; esac
  rm -rf -- "$p" 2>/dev/null || { say WARN "falha ao remover $p"; return 1; }
  return 0
}

with_timeout(){
  t="$1"; shift
  if [ "$t" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
    timeout "$t" "$@"
  else
    "$@"
  fi
}

# Hooks (no-op seguro)
run_hook(){
  name="$1"
  m_pkg="$ADM_ROOT/metafile/${CATEGORY:-misc}/${NAME:-_}/hooks/${name}.sh"
  m_cat="$ADM_ROOT/metafile/_hooks/${name}.sh"
  m_stage="$ADM_ROOT/metafile/stage/${ADM_STAGE}/hooks/${name}.sh"
  for h in "$m_pkg" "$m_stage" "$m_cat"; do
    [ -f "$h" ] || continue
    say INFO "hook: $name → $h"
    sh "$h" "$NAME" "$VERSION" "$ADM_STAGE" || { say ERROR "hook falhou ($name) rc=$? em $h"; return 1; }
    return 0
  done
  say DEBUG "hook ausente: $name (ok)"; return 0
}

# Exec no host ou via stage (mantemos compatibilidade futura)
exec_host_or_stage(){
  if [ -n "$STAGE_USE" ]; then
    [ -x "$BIN_DIR/adm-stage.sh" ] || die "adm-stage.sh necessário para --stage"
    "$BIN_DIR/adm-stage.sh" exec --stage "$STAGE_USE" -- "$@"
  else
    "$@"
  fi
}

# =========================
# 3) CLI
# =========================
usage(){
  cat <<'EOF'
Uso: adm-install.sh <subcomando> [opções]

Subcomandos:
  install        Instala no /
  uninstall      Remove do /
  upgrade        Atualiza (instala nova versão e trata órfãos)
  verify         Valida integridade/assinatura sem instalar
  plan           Mostra o plano (dry-run)
  rollback       Reverte a última instalação (backup)

Fontes (uma):
  --from-destdir DIR
  --from-pkg FILE        (.tar.zst|.tar.xz|.tar|.deb|.rpm)
  --from-dir DIR         (árvore já na estrutura de /)

Opções comuns:
  --name NAME --version VER --category CAT
  --sig FILE.sig|.minisig       # para verify/install/upgrade
  --deps resolve|ignore         # padrão resolve (best-effort)
  --check-conflicts strict|warn|off   # padrão strict
  --backup on|off              # padrão on
  --dry-run                    # plano sem tocar no /
  --yes                        # confirma automaticamente
  --stage {0|1|2}              # chroot do stage
  --profile PERF[,..]          # exporta perfis antes de hooks
  --timeout SECS               # tempo máximo por etapa
EOF
}

parse_args(){
  [ $# -ge 1 ] || { usage; exit 10; }
  SUBCMD="$1"; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --from-destdir) shift; FROM_DESTDIR="$1";;
      --from-pkg) shift; FROM_PKG="$1";;
      --from-dir) shift; FROM_DIR="$1";;
      --sig) shift; SIG_FILE="$1";;
      --name) shift; NAME="$1";;
      --version) shift; VERSION="$1";;
      --category) shift; CATEGORY="$1";;
      --deps) shift; DEPS_MODE="$(lower "$1")";;
      --check-conflicts) shift; CONFLICTS="$(lower "$1")";;
      --backup) shift; BACKUP="$(lower "$1")";;
      --dry-run) DRYRUN=1;;
      --yes) YES=1;;
      --stage) shift; STAGE_USE="$1"; ADM_STAGE="stage$STAGE_USE";;
      --profile) shift; PROFILES_IN="$1";;
      --timeout) shift; TIMEOUT="$1";;
      -h|--help|help) usage; exit 0;;
      *) say ERROR "argumento desconhecido: $1"; usage; exit 10;;
    esac
    shift || true
  done
  # valida fonte única
  cnt=0; [ -n "$FROM_DESTDIR" ] && cnt=$((cnt+1)); [ -n "$FROM_PKG" ] && cnt=$((cnt+1)); [ -n "$FROM_DIR" ] && cnt=$((cnt+1))
  [ $cnt -eq 1 ] || { say ERROR "especifique exatamente UMA fonte"; exit 10; }
}

# =========================
# 4) Perfis & ambiente
# =========================
load_profile_env(){
  if [ -x "$BIN_DIR/adm-profile.sh" ]; then
    [ -n "$PROFILES_IN" ] && "$BIN_DIR/adm-profile.sh" set "$PROFILES_IN" >/dev/null 2>&1 || true
    eval "$("$BIN_DIR/adm-profile.sh" export 2>/dev/null)" || say WARN "adm-profile export falhou; seguindo"
  else
    say WARN "adm-profile.sh não encontrado — seguindo sem perfis"
  fi
}

# =========================
# 5) Extração da fonte para staging efêmero
# =========================
mk_staging_root(){
  st="$(mktemp -d 2>/dev/null || echo "/tmp/adm-staging-$$")"
  mkdir -p "$st/root" "$st/meta" || { safe_rm_rf "$st"; die "não foi possível criar staging"; }
  printf "%s" "$st"
}

extract_pkg_to_dir(){
  pkg="$1"; outdir="$2"
  mkdir -p "$outdir" || return 20
  case "$pkg" in
    *.deb)
      say STEP "Extraindo .deb"
      if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "$pkg" "$outdir" || return 20
      else
        command -v ar >/dev/null 2>&1 || { say ERROR "ar ausente para .deb"; return 21; }
        tmp="$outdir/.deb.$$"; mkdir -p "$tmp" || return 20
        (cd "$tmp" && ar x "$pkg") || return 20
        data="$(ls "$tmp"/data.tar.* 2>/dev/null | head -n1 || true)"
        [ -n "$data" ] || { say ERROR "data.tar.* não encontrado"; return 20; }
        case "$data" in
          *.zst) zstd -dc "$data" | (cd "$outdir" && tar xf -) || return 20;;
          *.xz)  xz -dc "$data" | (cd "$outdir" && tar xf -) || return 20;;
          *.gz)  gzip -dc "$data" | (cd "$outdir" && tar xf -) || return 20;;
          *.tar) (cd "$outdir" && tar xf "$data") || return 20;;
          *)     say ERROR "formato desconhecido: $data"; return 20;;
        esac
        rm -rf "$tmp" 2>/dev/null || true
      fi
      ;;
    *.rpm)
      say STEP "Extraindo .rpm"
      if command -v rpm2cpio >/dev/null 2>&1; then
        rpm2cpio "$pkg" | (cd "$outdir" && cpio -idm 2>/dev/null) || return 20
      else
        say ERROR "rpm2cpio ausente"; return 21
      fi
      ;;
    *.tar|*.tar.xz|*.txz|*.tar.gz|*.tgz|*.tar.zst|*.tzst)
      say STEP "Extraindo tar.*"
      case "$pkg" in
        *.tar.zst|*.tzst) zstd -dc "$pkg" | (cd "$outdir" && tar xf -) || return 20;;
        *.tar.xz|*.txz)  (cd "$outdir" && tar xJf "$pkg") || return 20;;
        *.tar.gz|*.tgz)  (cd "$outdir" && tar xzf "$pkg") || return 20;;
        *.tar)           (cd "$outdir" && tar xf "$pkg") || return 20;;
      esac
      ;;
    *)
      say ERROR "tipo de pacote não suportado: $pkg"; return 10;;
  esac
  say OK
}

stage_from_source(){
  # retorna path do staging (com root/ e meta/)
  st="$(mk_staging_root)" || exit 20
  case 1 in
    1)
      if [ -n "$FROM_DESTDIR" ]; then
        [ -d "$FROM_DESTDIR" ] || { say ERROR "DESTDIR inexistente: $FROM_DESTDIR"; safe_rm_rf "$st"; exit 20; }
        say STEP "Preparando staging a partir de DESTDIR"
        (cd "$FROM_DESTDIR" && tar cf - .) | (cd "$st/root" && tar xf -) || { safe_rm_rf "$st"; exit 20; }
      elif [ -n "$FROM_PKG" ]; then
        [ -f "$FROM_PKG" ] || { say ERROR "arquivo inexistente: $FROM_PKG"; safe_rm_rf "$st"; exit 20; }
        extract_pkg_to_dir "$FROM_PKG" "$st/root" || { safe_rm_rf "$st"; exit 20; }
      elif [ -n "$FROM_DIR" ]; then
        [ -d "$FROM_DIR" ] || { say ERROR "diretório inexistente: $FROM_DIR"; safe_rm_rf "$st"; exit 20; }
        say STEP "Preparando staging a partir de diretório"
        (cd "$FROM_DIR" && tar cf - .) | (cd "$st/root" && tar xf -) || { safe_rm_rf "$st"; exit 20; }
      fi
      ;;
  esac
  echo "$st"
}

# =========================
# 6) Identidade (name/version) & manifests
# =========================
infer_name_version(){
  # tenta inferir a partir do pacote ou caminhos padrão
  if [ -z "$NAME" ] || [ -z "$VERSION" ]; then
    if [ -n "$FROM_PKG" ]; then
      base="$(basename "$FROM_PKG")"
      # tenta padrões foo-1.2.3.* ou foo_1.2.deb/rpm
      if printf "%s" "$base" | grep -Eq '^[A-Za-z0-9._+-]+[_-][0-9]'; then
        nm="$(printf "%s" "$base" | sed 's/\.[^.]*$//' | sed 's/_/ /;s/-/ /' | awk '{print $1}')"
        vr="$(printf "%s" "$base" | sed 's/\.[^.]*$//' | sed 's/.*[_-]\([0-9][A-Za-z0-9._+-]*\)$/\1/')"
        [ -z "$NAME" ] && NAME="$nm"
        [ -z "$VERSION" ] && VERSION="$vr"
      fi
    fi
  fi
  [ -n "$NAME" ] || NAME="pkg"
  [ -n "$VERSION" ] || VERSION="0"
}

emit_manifest(){
  root="$1"; out="$2"
  : >"$out" || return 20
  find "$root" -mindepth 1 -type f -o -type l 2>/dev/null | while read -r f; do
    rel="${f#$root}"
    h="-"; [ -f "$f" ] && h="$(sha256_file "$f" 2>/dev/null || echo -)"
    st="$(stat -c '%a %u:%g %Y' "$f" 2>/dev/null || echo '000 0:0 0')"
    printf "%s\t%s\t%s\n" "$rel" "$h" "$st" >>"$out" || true
  done
}

emit_install_meta(){
  dir="$1"; out="$2"
  {
    echo "NAME=$NAME"
    echo "VERSION=$VERSION"
    echo "CATEGORY=$CATEGORY"
    echo "STAGE=$ADM_STAGE"
    echo "TIMESTAMP=$(_ts)"
    echo "SOURCE=$( [ -n "$FROM_PKG" ] && echo "pkg:$FROM_PKG" || [ -n "$FROM_DESTDIR" ] && echo "destdir:$FROM_DESTDIR" || echo "dir:$FROM_DIR")"
  } >"$out" 2>/dev/null || true
}
# =========================
# 7) Verificação de assinatura/integridade
# =========================
verify_signature_if_any(){
  [ -n "$SIG_FILE" ] || return 0
  [ -f "$SIG_FILE" ] || { say ERROR "assinatura não encontrada: $SIG_FILE"; return 22; }
  [ -n "$FROM_PKG" ] || { say ERROR "--sig exige --from-pkg"; return 10; }
  say STEP "Verificando assinatura de $FROM_PKG"
  case "$SIG_FILE" in
    *.sig)
      command -v gpg >/dev/null 2>&1 || { say ERROR "gpg ausente"; return 22; }
      gpg --verify "$SIG_FILE" "$FROM_PKG" >/dev/null 2>&1 || { say ERROR "assinatura GPG inválida"; return 22; }
      say INFO "assinatura GPG OK"
      ;;
    *.minisig)
      command -v minisign >/dev/null 2>&1 || { say ERROR "minisign ausente"; return 22; }
      minisign -V -m "$FROM_PKG" -x "$SIG_FILE" >/dev/null 2>&1 || { say ERROR "assinatura Minisign inválida"; return 22; }
      say INFO "assinatura Minisign OK"
      ;;
    *) say WARN "extensão de assinatura desconhecida: $SIG_FILE";;
  esac
  say OK
}

verify_integrity_repo_if_possible(){
  # best-effort: se o pacote existir no REPO_DIR com sha256sums.txt, confere hash
  [ -n "$FROM_PKG" ] || return 0
  sums="$REPO_DIR/sha256sums.txt"
  [ -f "$sums" ] || return 0
  bn="$(basename "$FROM_PKG")"
  h_repo="$(awk "\$2==\"$bn\"{print \$1}" "$sums" 2>/dev/null | head -n1)"
  [ -n "$h_repo" ] || return 0
  say STEP "Verificando hash de repositório"
  h_local="$(sha256_file "$FROM_PKG" 2>/dev/null || echo -)"
  [ "$h_repo" = "$h_local" ] || { say ERROR "hash divergente para $bn"; return 22; }
  say OK
}

# =========================
# 8) Dependências (best-effort)
# =========================
check_deps_best_effort(){
  [ "$DEPS_MODE" = "resolve" ] || { say INFO "deps ignoradas (--deps ignore)"; return 0; }
  # tenta obter depends.resolved do build registry
  depfile="$REG_BUILD_DIR/${NAME}-${VERSION}/depends.resolved"
  [ -f "$depfile" ] || { say DEBUG "depends.resolved ausente (ok)"; return 0; }
  missing=""
  while read -r line; do
    dep="$(printf "%s" "$line" | sed 's/[[:space:]].*$//')"
    [ -z "$dep" ] && continue
    # checagem simples: existe alguma instalação do dep?
    anydep="$(ls -1 "$REG_INSTALL_DIR" 2>/dev/null | grep -E "^${dep}-" || true)"
    [ -n "$anydep" ] || missing="${missing}${missing:+ }$dep"
  done <"$depfile"
  if [ -n "$missing" ]; then
    say WARN "dependências possivelmente ausentes: $missing"
    [ $YES -eq 1 ] || { printf "Continuar mesmo assim? (yes/no): "; read ans || ans="no"; [ "$ans" = "yes" ] || return 22; }
  fi
  return 0
}

# =========================
# 9) Conflicts/Plan/Backup/Apply
# =========================
compute_conflicts(){
  root="$1"    # staging root
  mani="$2"    # staging manifest
  : >"$mani" || return 20
  conflicts=0
  find "$root" -mindepth 1 -type f -o -type l 2>/dev/null | while read -r f; do
    rel="${f#$root}"
    dst="/$rel"
    # registra manifest do staging
    h="-"; [ -f "$f" ] && h="$(sha256_file "$f" 2>/dev/null || echo -)"
    st="$(stat -c '%a %u:%g %Y' "$f" 2>/dev/null || echo '000 0:0 0')"
    printf "%s\t%s\t%s\n" "$rel" "$h" "$st" >>"$mani" || true
    # conflito?
    if [ -e "$dst" ] || [ -L "$dst" ]; then
      if [ "$CONFLICTS" = "off" ]; then :; else
        if [ -f "$dst" ]; then
          hdst="$(sha256_file "$dst" 2>/dev/null || echo -)"
          [ "$hdst" = "$h" ] || conflicts=1
        else
          conflicts=1
        fi
      fi
    fi
  done
  return $conflicts
}

print_plan(){
  root="$1"
  say STEP "Plano de instalação (dry-run=$DRYRUN)"
  create=0; update=0
  find "$root" -mindepth 1 -type f -o -type l 2>/dev/null | while read -r f; do
    rel="${f#$root}"
    dst="/$rel"
    if [ -e "$dst" ] || [ -L "$dst" ]; then
      printf "UPDATE %s\n" "$dst"; update=$((update+1))
    else
      printf "CREATE %s\n" "$dst"; create=$((create+1))
    fi
  done
  say INFO "create=$create update=$update"
  say OK
}

backup_if_needed(){
  root="$1"; outdir="$2"
  [ "$BACKUP" = "on" ] || { say INFO "backup desativado"; return 0; }
  mkdir -p "$outdir" || return 20
  say STEP "Criando backup dos arquivos que serão sobrescritos"
  find "$root" -mindepth 1 -type f -o -type l 2>/dev/null | while read -r f; do
    rel="${f#$root}"
    dst="/$rel"
    if [ -e "$dst" ] || [ -L "$dst" ]; then
      bd="$outdir$(dirname "$rel")"
      mkdir -p "$bd" 2>/dev/null || true
      cp -a -- "$dst" "$outdir/$rel" 2>/dev/null || true
    fi
  done
  say OK
}

apply_to_root(){
  root="$1"
  # Confirmação
  if [ $YES -ne 1 ]; then
    printf "Aplicar %s-%s em / ? (yes/no): " "$NAME" "$VERSION"
    read ans || ans="no"
    [ "$ans" = "yes" ] || { say ERROR "abandonado pelo usuário"; return 20; }
  fi
  say STEP "Aplicando ao /"
  if [ $DRYRUN -eq 1 ]; then
    say INFO "dry-run: não copiando; apenas plano"
    say OK; return 0
  fi
  (cd "$root" && tar cf - .) | (cd / && tar xpf -) || { say ERROR "falha ao copiar para /"; return 20; }
  say OK
}

write_install_registry(){
  instdir="$REG_INSTALL_DIR/${NAME}-${VERSION}"
  mkdir -p "$instdir" || return 20
  # manifest final (após aplicado)
  mani_final="$instdir/install.manifest"
  : >"$mani_final" || return 20
  awk -F'\t' '{print $1}' "$1" | while read -r rel; do
    f="/$rel"
    if [ -e "$f" ] || [ -L "$f" ]; then
      h="-"; [ -f "$f" ] && h="$(sha256_file "$f" 2>/dev/null || echo -)"
      st="$(stat -c '%a %u:%g %Y' "$f" 2>/dev/null || echo '000 0:0 0')"
      printf "%s\t%s\t%s\n" "$rel" "$h" "$st" >>"$mani_final" || true
    fi
  done
  # meta e plano de undo
  emit_install_meta "/" "$instdir/install.meta" || true
  printf "%s\n" "backup_dir=$2" >"$instdir/undo.plan" 2>/dev/null || true
  say INFO "registrado em $instdir"
}

# =========================
# 10) Uninstall & Rollback & Upgrade
# =========================
uninstall_from_registry(){
  [ -n "$NAME" ] && [ -n "$VERSION" ] || { say ERROR "nome/versão necessários"; return 10; }
  instdir="$REG_INSTALL_DIR/${NAME}-${VERSION}"
  mani="$instdir/install.manifest"
  [ -f "$mani" ] || { say ERROR "manifest ausente: $mani"; return 20; }
  run_hook "pre_uninstall" || true
  say STEP "Uninstall de ${NAME}-${VERSION}"
  if [ $DRYRUN -eq 1 ]; then
    awk -F'\t' '{print "/"$1}' "$mani"
    say OK; return 0
  fi
  rc_all=0
  awk -F'\t' '{print $1}' "$mani" | while read -r rel; do
    f="/$rel"
    if [ -e "$f" ] || [ -L "$f" ]; then
      rm -f -- "$f" 2>/dev/null || { say WARN "não foi possível remover: $f"; rc_all=1; }
      d="$(dirname "$f")"
      while [ "$d" != "/" ] && rmdir "$d" 2>/dev/null; do d="$(dirname "$d")"; done
    fi
  done
  [ ${rc_all:-0} -eq 0 ] || { say WARN "uninstall concluiu com avisos"; }
  run_hook "post_uninstall" || true
  say OK
}

rollback_last(){
  [ -n "$NAME" ] && [ -n "$VERSION" ] || { say ERROR "nome/versão necessários"; return 10; }
  instdir="$REG_INSTALL_DIR/${NAME}-${VERSION}"
  plan="$instdir/undo.plan"
  [ -f "$plan" ] || { say ERROR "undo.plan ausente: $plan"; return 25; }
  bdir="$(awk -F'=' '/^backup_dir=/{print $2}' "$plan" | head -n1)"
  [ -n "$bdir" ] && [ -d "$bdir" ] || { say ERROR "backup inexistente: $bdir"; return 25; }
  say STEP "Rollback usando $bdir"
  if [ $DRYRUN -eq 1 ]; then
    say INFO "dry-run: restauraria $bdir → /"
    say OK; return 0
  fi
  (cd "$bdir" && tar cf - .) | (cd / && tar xpf -) || { say ERROR "falha ao restaurar backup"; return 25; }
  say OK
}

upgrade_install_then_cleanup_orphans(){
  # requer staging_manifest (novo) em $1 e nome/versão antiga em $2 (opcional).
  newmani="$1"
  oldver="$2"
  oldmani=""
  if [ -n "$oldver" ]; then
    oldmani="$REG_INSTALL_DIR/${NAME}-${oldver}/install.manifest"
  else
    # tenta detectar a mais recente instalada com mesmo NAME
    oldmani="$(ls -1 "$REG_INSTALL_DIR" 2>/dev/null | grep -E "^${NAME}-" | sort | tail -n1)"
    [ -n "$oldmani" ] && oldmani="$REG_INSTALL_DIR/$oldmani/install.manifest"
  fi
  [ -f "$oldmani" ] || { say INFO "nenhuma versão anterior detectada (ok)"; return 0; }
  say STEP "Removendo órfãos da versão anterior"
  awk -F'\t' '{print $1}' "$oldmani" | sort >"/tmp/.old.lst.$$"
  awk -F'\t' '{print $1}' "$newmani" | sort >"/tmp/.new.lst.$$"
  orf="$(comm -23 "/tmp/.old.lst.$$" "/tmp/.new.lst.$$" || true)"
  if [ -z "$orf" ]; then
    say INFO "sem órfãos"
  else
    echo "$orf" | while read -r rel; do
      f="/$rel"
      if [ -e "$f" ] || [ -L "$f" ]; then
        if [ $DRYRUN -eq 1 ]; then
          printf "ORPHAN_RM %s\n" "$f"
        else
          rm -f -- "$f" 2>/dev/null || say WARN "não foi possível remover órfão: $f"
        fi
      fi
    done
  fi
  rm -f "/tmp/.old.lst.$$" "/tmp/.new.lst.$$" 2>/dev/null || true
  say OK
}
# =========================
# 11) Subcomandos
# =========================
cmd_verify(){
  parse_args "$@"
  ensure_dirs
  infer_name_version
  verify_signature_if_any || exit $?
  verify_integrity_repo_if_possible || exit $?
  st="$(stage_from_source)" || exit 20
  # gerar manifest provisório para relatório
  emit_manifest "$st/root" "$st/meta/staging.manifest" || { safe_rm_rf "$st"; exit 20; }
  say INFO "arquivos no pacote:"
  awk -F'\t' '{print $1}' "$st/meta/staging.manifest" | sed 's/^/  /'
  safe_rm_rf "$st" || true
  say INFO "verify concluído"
}

cmd_plan(){
  parse_args "$@"
  ensure_dirs
  infer_name_version
  st="$(stage_from_source)" || exit 20
  compute_conflicts "$st/root" "$st/meta/staging.manifest"
  rc=$?
  print_plan "$st/root"
  if [ $rc -ne 0 ] && [ "$CONFLICTS" = "strict" ]; then
    say ERROR "conflitos detectados (strict). Ajuste --check-conflicts ou habilite backup."
    safe_rm_rf "$st" || true
    exit 21
  fi
  safe_rm_rf "$st" || true
  say INFO "plan concluído"
}

cmd_install(){
  parse_args "$@"
  ensure_dirs
  load_profile_env
  infer_name_version
  [ "$(id -u)" -eq 0 ] || { say ERROR "precisa de root para instalar em /"; exit 23; }

  verify_signature_if_any || exit $?
  verify_integrity_repo_if_possible || exit $?

  st="$(stage_from_source)" || exit 20
  check_deps_best_effort || { safe_rm_rf "$st"; exit 22; }

  compute_conflicts "$st/root" "$st/meta/staging.manifest"
  rc=$?
  if [ $rc -ne 0 ]; then
    case "$CONFLICTS" in
      strict) say ERROR "conflitos detectados (strict)"; safe_rm_rf "$st"; exit 21;;
      warn)   say WARN "conflitos detectados (warn)";;
      off)    :;;
    esac
  fi

  print_plan "$st/root"

  # backup
  bdir="$REG_INSTALL_DIR/${NAME}-${VERSION}/backup"
  [ "$BACKUP" = "on" ] && backup_if_needed "$st/root" "$bdir"

  run_hook "pre_install" || true
  apply_to_root "$st/root" || { safe_rm_rf "$st"; exit 20; }
  run_hook "post_install" || true

  write_install_registry "$st/meta/staging.manifest" "$bdir" || { safe_rm_rf "$st"; exit 20; }
  safe_rm_rf "$st" || true

  # pós-instalação padrão (opcional via hooks específicos)
  run_hook "post_ldconfig" || true
  run_hook "post_systemd" || true
  run_hook "post_initramfs" || true

  say INFO "install concluído"
}

cmd_uninstall(){
  parse_args "$@"
  ensure_dirs
  [ "$(id -u)" -eq 0 ] || { say ERROR "precisa de root para desinstalar"; exit 23; }
  [ -n "$NAME" ] && [ -n "$VERSION" ] || { say ERROR "use --name e --version"; exit 10; }
  uninstall_from_registry || exit $?
  say INFO "uninstall concluído"
}

cmd_rollback(){
  parse_args "$@"
  ensure_dirs
  [ "$(id -u)" -eq 0 ] || { say ERROR "precisa de root para rollback"; exit 23; }
  [ -n "$NAME" ] && [ -n "$VERSION" ] || { say ERROR "use --name e --version"; exit 10; }
  rollback_last || exit $?
  say INFO "rollback concluído"
}

cmd_upgrade(){
  # upgrade = install da nova versão + remoção de órfãos da anterior
  parse_args "$@"
  ensure_dirs
  load_profile_env
  infer_name_version
  [ "$(id -u)" -eq 0 ] || { say ERROR "precisa de root para upgrade"; exit 23; }

  verify_signature_if_any || exit $?
  verify_integrity_repo_if_possible || exit $?

  st="$(stage_from_source)" || exit 20
  compute_conflicts "$st/root" "$st/meta/staging.manifest"
  rc=$?
  if [ $rc -ne 0 ] && [ "$CONFLICTS" = "strict" ]; then
    say ERROR "conflitos detectados (strict)"; safe_rm_rf "$st"; exit 21
  fi

  bdir="$REG_INSTALL_DIR/${NAME}-${VERSION}/backup"
  [ "$BACKUP" = "on" ] && backup_if_needed "$st/root" "$bdir"
  run_hook "pre_install" || true
  apply_to_root "$st/root" || { safe_rm_rf "$st"; exit 20; }
  run_hook "post_install" || true

  write_install_registry "$st/meta/staging.manifest" "$bdir" || { safe_rm_rf "$st"; exit 20; }
  # tenta descobrir versão antiga e limpar órfãos
  upgrade_install_then_cleanup_orphans "$st/meta/staging.manifest" "" || true
  safe_rm_rf "$st" || true
  run_hook "post_upgrade" || true
  say INFO "upgrade concluído"
}

# =========================
# 12) Main
# =========================
main(){
  _color_setup
  case "${1:-}" in
    install)   cmd_install "$@";;
    uninstall) cmd_uninstall "$@";;
    upgrade)   cmd_upgrade "$@";;
    verify)    cmd_verify "$@";;
    plan)      cmd_plan "$@";;
    rollback)  cmd_rollback "$@";;
    -h|--help|help|"") usage; exit 0;;
    *) say ERROR "subcomando desconhecido: $1"; usage; exit 10;;
  esac
}

main "$@"
