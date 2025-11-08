#!/usr/bin/env sh
# adm-pack.sh — Reempacotamento, assinatura, verificação e repositórios
# POSIX sh; compatível com dash/ash/bash.
# adm-pack.sh pack --from-destdir /usr/src/adm/build/foo-1.0/destdir \
# --name foo --version 1.0 --category libs --format deb
# adm-pack.sh pack --from-pkg ./foo_1.0_amd64.deb --format zst
# adm-pack.sh convert --in ./bar-1.0.rpm --format zst
# adm-pack.sh repo index --dir /usr/src/adm/build/foo-1.0/pkg
# adm-pack.sh repo verify --dir /usr/src/adm/build/foo-1.0/pkg
set -u
# =========================
# 0) Config & defaults
# =========================
: "${ADM_ROOT:=/usr/src/adm}"
: "${ADM_LOG_COLOR:=auto}"
: "${ADM_STAGE:=host}"
: "${ADM_PIPELINE:=pack}"

BIN_DIR="$ADM_ROOT/bin"
REG_BUILD_DIR="$ADM_ROOT/registry/build"
LOG_DIR="$ADM_ROOT/logs/pack"
REPO_DIR="$ADM_ROOT/repo"

NAME=""; VERSION=""; CATEGORY="misc"
OUT_DIR=""
VERBOSE=0
YES=0
REGEN_MANIFEST=0
DET=0
ZSTD_LVL=19
XZ_LVL=9
FORMAT="zst"

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
_c_mag(){ [ $_color_on -eq 1 ] && printf '\033[35;1m'; }
_c_yel(){ [ $_color_on -eq 1 ] && printf '\033[33;1m'; }
_c_gry(){ [ $_color_on -eq 1 ] && printf '\033[38;5;244m';}

have_adm_log=0
command -v adm_log_info >/dev/null 2>&1 && have_adm_log=1

_ts(){ date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([0-9][0-9]\)$/:\1/'; }
_ctx(){
  st="${ADM_STAGE:-host}"; pipe="${ADM_PIPELINE:-pack}"; path="${PWD:-/}"
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

ensure_dirs(){
  for d in "$REG_BUILD_DIR" "$LOG_DIR" "$REPO_DIR"; do
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

# =========================
# 2) CLI
# =========================
usage(){
  cat <<'EOF'
Uso: adm-pack.sh <subcomando> [opções]

Subcomandos:
  pack --from-destdir DIR [--out-dir DIR] [--format zst|xz|tar|deb|rpm]
       [--zstd-level N] [--xz-level N] [--deterministic] [--split-debug] [--keep-strip]
       [--name NAME] [--version VER] [--category CAT] [--regen-manifest]
  pack --from-pkg FILE [--out-dir DIR] [--format zst|xz|tar]
  sign --pkg FILE [--gpg-key KEYID] [--minisign-key PATH]
  verify --pkg FILE [--sig FILE.sig|FILE.minisig]
  repo index --dir DIR [--out DIR] [--gpg-key KEYID] [--minisign-key PATH]
  repo verify --dir DIR
  convert --in FILE --format zst|xz|tar|deb|rpm [--zstd-level N] [--xz-level N] [--deterministic]
Opções comuns:
  --name NAME --version VER --category CAT
  --out-dir DIR      Destino dos artefatos
  --verbose          Logs detalhados
  --yes              Não interativo
EOF
}

# parsing comum
parse_common(){
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) shift; NAME="$1";;
      --version) shift; VERSION="$1";;
      --category) shift; CATEGORY="$1";;
      --out-dir) shift; OUT_DIR="$1";;
      --zstd-level) shift; ZSTD_LVL="$1";;
      --xz-level) shift; XZ_LVL="$1";;
      --format) shift; FORMAT="$(lower "$1")";;
      --deterministic) DET=1;;
      --regen-manifest) REGEN_MANIFEST=1;;
      --verbose) VERBOSE=1;;
      --yes) YES=1;;
      *) echo "$1";;  # retorna args remanescentes ao caller
    esac
    shift || true
  done
}

# helpers de compactação
tar_from_dir_zst(){
  dir="$1"; out="$2"; lvl="${3:-$ZSTD_LVL}"
  command -v zstd >/dev/null 2>&1 || { say ERROR "zstd ausente"; return 23; }
  (cd "$dir" && tar --numeric-owner ${DET:+--mtime="@0"} -cf - .) | zstd -q -"${lvl}" -T0 -o "$out" || return 23
}
tar_from_dir_xz(){
  dir="$1"; out="$2"; lvl="${3:-$XZ_LVL}"
  command -v xz >/dev/null 2>&1 || { say ERROR "xz ausente"; return 23; }
  (cd "$dir" && tar --numeric-owner ${DET:+--mtime="@0"} -cf - .) | xz -"${lvl}" -c > "$out" || return 23
}
tar_from_dir_plain(){
  dir="$1"; out="$2"
  (cd "$dir" && tar --numeric-owner ${DET:+--mtime="@0"} -cf "$out" .) || return 23
}

# =========================
# 3) Manifest / Meta
# =========================
emit_manifest(){
  dest="$1"
  mani="$dest.manifest"
  say STEP "Gerando manifest de $dest → $mani"
  : >"$mani" || return 23
  find "$dest" -mindepth 1 -type f -o -type l 2>/dev/null | while read -r f; do
    rel="${f#$dest}"
    h="-"; [ -f "$f" ] && h="$(sha256_file "$f" 2>/dev/null || echo -)"
    st="$(stat -c '%a %u:%g %Y' "$f" 2>/dev/null || echo '000 0:0 0')"
    printf "%s\t%s\t%s\n" "$rel" "$h" "$st" >>"$mani" || true
  done
  say OK
}

emit_build_meta(){
  dest="$1"; out="$2"
  {
    echo "NAME=$NAME"
    echo "VERSION=$VERSION"
    echo "CATEGORY=$CATEGORY"
    echo "STAGE=$ADM_STAGE"
    echo "SIZE_BYTES=$(du -sk "$dest" 2>/dev/null | awk '{print $1*1024}')"
    echo "TIMESTAMP=$(_ts)"
  } >"$out" 2>/dev/null || true
}

# =========================
# 4) Extração de .deb / .rpm / tar.*
# =========================
extract_pkg_to_dir(){
  pkg="$1"; outdir="$2"
  mkdir -p "$outdir" || return 20
  case "$pkg" in
    *.deb)
      say STEP "Extraindo .deb"
      if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "$pkg" "$outdir" || return 20
      else
        # fallback manual: ar + data.tar.*
        command -v ar >/dev/null 2>&1 || { say ERROR "ar não encontrado p/ .deb"; return 21; }
        tmpd="$outdir/.deb.$$"; mkdir -p "$tmpd" || return 20
        (cd "$tmpd" && ar x "$pkg") || return 20
        data="$(ls "$tmpd"/data.tar.* 2>/dev/null | head -n1 || true)"
        [ -n "$data" ] || { say ERROR "data.tar.* não encontrado em $pkg"; return 20; }
        case "$data" in
          *.zst) zstd -dc "$data" | (cd "$outdir" && tar xf -) || return 20;;
          *.xz)  xz -dc "$data" | (cd "$outdir" && tar xf -) || return 20;;
          *.gz)  gzip -dc "$data" | (cd "$outdir" && tar xf -) || return 20;;
          *.tar) (cd "$outdir" && tar xf "$data") || return 20;;
          *)     say ERROR "formato desconhecido: $data"; return 20;;
        esac
        rm -rf "$tmpd" 2>/dev/null || true
      fi
      ;;
    *.rpm)
      say STEP "Extraindo .rpm"
      if command -v rpm2cpio >/dev/null 2>&1; then
        rpm2cpio "$pkg" | (cd "$outdir" && cpio -idm 2>/dev/null) || return 20
      else
        say ERROR "rpm2cpio ausente para extrair .rpm"; return 21
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
      say ERROR "tipo de pacote não suportado para extração: $pkg"; return 10;;
  esac
  say OK
}

# =========================
# 5) Geração de .deb / .rpm a partir de DESTDIR
# =========================
mk_deb_from_destdir(){
  dest="$1"; out="$2"
  say STEP "Gerando .deb de $dest → $out"
  # preferir fpm
  if command -v fpm >/dev/null 2>&1; then
    fpm -s dir -t deb -n "$NAME" -v "$VERSION" -C "$dest" --category "$CATEGORY" --deb-compression zstd --deb-priority optional --prefix / \
      . >/dev/null 2>&1 || { say ERROR "fpm falhou ao criar .deb"; return 23; }
    mv ./*.deb "$out" 2>/dev/null || { say ERROR "não achou .deb emitido pelo fpm"; return 23; }
    say OK; return 0
  fi
  # fallback: dpkg-deb
  command -v dpkg-deb >/dev/null 2>&1 || { say ERROR "dpkg-deb ausente e fpm indisponível"; return 21; }
  tmp="$dest/.debctrl.$$"; mkdir -p "$tmp/DEBIAN" || return 23
  : >"$tmp/DEBIAN/control" || return 23
  {
    echo "Package: $NAME"
    echo "Version: $VERSION"
    echo "Section: $CATEGORY"
    echo "Priority: optional"
    echo "Architecture: $(dpkg --print-architecture 2>/dev/null || echo all)"
    echo "Maintainer: adm <root@local>"
    echo "Description: $NAME built by ADM"
  } >"$tmp/DEBIAN/control" || return 23
  (cd "$dest" && tar cf - .) | (cd "$tmp" && tar xf -) || return 23
  dpkg-deb -Zzstd --root-owner-group --build "$tmp" "$out" >/dev/null 2>&1 || { say ERROR "dpkg-deb falhou"; return 23; }
  rm -rf "$tmp" 2>/dev/null || true
  say OK
}

mk_rpm_from_destdir(){
  dest="$1"; out="$2"
  say STEP "Gerando .rpm de $dest → $out"
  # preferir fpm
  if command -v fpm >/dev/null 2>&1; then
    fpm -s dir -t rpm -n "$NAME" -v "$VERSION" -C "$dest" --category "$CATEGORY" --prefix / \
      . >/dev/null 2>&1 || { say ERROR "fpm falhou ao criar .rpm"; return 23; }
    mv ./*.rpm "$out" 2>/dev/null || { say ERROR "não achou .rpm emitido pelo fpm"; return 23; }
    say OK; return 0
  fi
  # fallback: rpmbuild
  command -v rpmbuild >/dev/null 2>&1 || { say ERROR "rpmbuild ausente e fpm indisponível"; return 21; }
  top="$(mktemp -d 2>/dev/null || echo "/tmp/adm-rpm.$$")"
  for d in BUILD RPMS SOURCES SPECS SRPMS; do mkdir -p "$top/$d"; done
  spec="$top/SPECS/$NAME.spec"
  {
    echo "Name: $NAME"
    echo "Version: $VERSION"
    echo "Release: 1"
    echo "Summary: $NAME built by ADM"
    echo "License: unknown"
    echo "Group: $CATEGORY"
    echo "BuildArch: $(rpm --eval '%{_arch}' 2>/dev/null || echo noarch)"
    echo "%description"
    echo "$NAME built by ADM"
    echo "%install"
    echo "mkdir -p %{buildroot}"
    echo "tar xf \$PWD/payload.tar -C %{buildroot}"
    echo "%files"
    echo "/"
  } >"$spec"
  (cd "$dest" && tar cf "$top/SOURCES/payload.tar" .) || { safe_rm_rf "$top"; return 23; }
  RPMBUILD="$(rpm --eval '%{_topdir}' 2>/dev/null || true)"
  rpmbuild --define "_topdir $top" -bb "$spec" >/dev/null 2>&1 || { say ERROR "rpmbuild falhou"; safe_rm_rf "$top"; return 23; }
  mv "$top"/RPMS/*/*.rpm "$out" 2>/dev/null || { say ERROR "não achou .rpm gerado"; safe_rm_rf "$top"; return 23; }
  safe_rm_rf "$top" || true
  say OK
}
# =========================
# 6) Split-debug (opcional)
# =========================
split_debug(){
  dest="$1"
  command -v objcopy >/dev/null 2>&1 || { say WARN "objcopy ausente — split-debug ignorado"; return 0; }
  say STEP "Split-debug em $dest"
  dbgroot="$dest/usr/lib/debug"
  mkdir -p "$dbgroot" || return 0
  find "$dest" -type f -perm -111 2>/dev/null | while read -r bin; do
    case "$(file -b "$bin" 2>/dev/null | tr 'A-Z' 'a-z')" in
      *executable*|*shared\ object*) :;;
      *) continue;;
    esac
    rel="${bin#$dest}"
    dbg="$dbgroot$rel.debug"
    mkdir -p "$(dirname "$dbg")" 2>/dev/null || true
    objcopy --only-keep-debug "$bin" "$dbg" 2>/dev/null || continue
    [ -n "${KEEP_STRIP:-}" ] || objcopy --strip-debug "$bin" 2>/dev/null || true
    objcopy --add-gnu-debuglink="$dbg" "$bin" 2>/dev/null || true
  done
  say OK
}

# =========================
# 7) Assinatura & verificação
# =========================
cmd_sign(){
  [ $# -ge 1 ] || { say ERROR "uso: sign --pkg FILE [--gpg-key KEYID] [--minisign-key PATH]"; exit 10; }
  PKG=""; GPGKEY=""; MSKEY=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pkg) shift; PKG="$1";;
      --gpg-key) shift; GPGKEY="$1";;
      --minisign-key) shift; MSKEY="$1";;
      --yes) YES=1;;
      --verbose) VERBOSE=1;;
      *) say ERROR "arg desconhecido: $1"; exit 10;;
    esac; shift || true
  done
  [ -f "$PKG" ] || { say ERROR "arquivo inexistente: $PKG"; exit 20; }
  say STEP "Assinando $PKG"
  if [ -n "$GPGKEY" ]; then
    command -v gpg >/dev/null 2>&1 || { say ERROR "gpg ausente"; exit 21; }
    gpg --batch --yes --local-user "$GPGKEY" --output "$PKG.sig" --detach-sign "$PKG" || { say ERROR "gpg falhou"; exit 22; }
    say INFO "GPG: $PKG.sig"
  fi
  if [ -n "$MSKEY" ]; then
    command -v minisign >/dev/null 2>&1 || { say ERROR "minisign ausente"; exit 21; }
    minisign -S -s "$MSKEY" -m "$PKG" >/dev/null 2>&1 || { say ERROR "minisign falhou"; exit 22; }
    say INFO "Minisign: $PKG.minisig"
  fi
  [ -n "$GPGKEY$MSKEY" ] || say WARN "nenhuma chave fornecida — nada assinado"
  say OK
}

cmd_verify(){
  [ $# -ge 1 ] || { say ERROR "uso: verify --pkg FILE [--sig FILE.sig|FILE.minisig]"; exit 10; }
  PKG=""; SIG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pkg) shift; PKG="$1";;
      --sig) shift; SIG="$1";;
      *) say ERROR "arg desconhecido: $1"; exit 10;;
    esac; shift || true
  done
  [ -f "$PKG" ] || { say ERROR "arquivo inexistente: $PKG"; exit 20; }
  say STEP "Verificando $PKG"
  if [ -n "$SIG" ]; then
    case "$SIG" in
      *.sig) command -v gpg >/dev/null 2>&1 || { say ERROR "gpg ausente"; exit 21; }
             gpg --verify "$SIG" "$PKG" >/dev/null 2>&1 || { say ERROR "assinatura GPG inválida"; exit 22; }
             say INFO "assinatura GPG OK";;
      *.minisig) command -v minisign >/dev/null 2>&1 || { say ERROR "minisign ausente"; exit 21; }
             minisign -V -m "$PKG" -x "$SIG" >/dev/null 2>&1 || { say ERROR "assinatura Minisign inválida"; exit 22; }
             say INFO "assinatura Minisign OK";;
      *) say WARN "extensão de assinatura desconhecida: $SIG";;
    esac
  else
    say WARN "nenhuma assinatura fornecida; verificando apenas integridade de leitura"
    dd if="$PKG" of=/dev/null bs=1M 2>/dev/null || { say ERROR "falha ao ler arquivo"; exit 22; }
  fi
  say OK
}

# =========================
# 8) Repositório local
# =========================
repo_index(){
  dir="$1"; out="${2:-$dir}"
  say STEP "Indexando repositório $dir → $out"
  mkdir -p "$out" || { say ERROR "não foi possível criar $out"; return 20; }
  idx="$out/index.json"; sums="$out/sha256sums.txt"; pkgs="$out/Packages"
  : >"$idx"; : >"$sums"; : >"$pkgs" || return 20
  printf "[\n" >"$idx"
  first=1
  for f in "$dir"/*.tar.* "$dir"/*.deb "$dir"/*.rpm 2>/dev/null; do
    [ -e "$f" ] || continue
    sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
    shas="$(sha256_file "$f" 2>/dev/null || echo -)"
    bn="$(basename "$f")"
    echo "$shas  $bn" >>"$sums"
    [ $first -eq 1 ] || printf ",\n" >>"$idx"
    first=0
    printf "  {\"file\":\"%s\",\"size\":%s,\"sha256\":\"%s\",\"timestamp\":\"%s\"}" "$bn" "$sz" "$shas" "$(_ts)" >>"$idx"
    printf "File: %s\nSize: %s\nSHA256: %s\nDate: %s\n\n" "$bn" "$sz" "$shas" "$(_ts)" >>"$pkgs"
  done
  printf "\n]\n" >>"$idx"
  say OK
}

repo_verify(){
  dir="$1"
  say STEP "Verificando repositório $dir"
  sums="$dir/sha256sums.txt"
  [ -f "$sums" ] || { say ERROR "sha256sums.txt não encontrado em $dir"; return 20; }
  ok=1
  while read -r h f; do
    [ -f "$dir/$f" ] || { say ERROR "ausente: $f"; ok=0; continue; }
    h2="$(sha256_file "$dir/$f" 2>/dev/null || echo -)"
    [ "$h" = "$h2" ] || { say ERROR "hash divergente: $f"; ok=0; }
  done <"$sums"
  [ $ok -eq 1 ] && say OK || { say ERROR "repo com inconsistências"; return 22; }
  return 0
}
# =========================
# 9) Pack (from-destdir / from-pkg) & Convert
# =========================
cmd_pack_from_destdir(){
  DESTDIR=""
  SPLITDBG=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --from-destdir) shift; DESTDIR="$1";;
      --split-debug) SPLITDBG=1;;
      --keep-strip) KEEP_STRIP=1;;
      --*) set -- $(parse_common "$@"); shift $(( $# - $# ));;
      *) say ERROR "arg desconhecido: $1"; exit 10;;
    esac; shift || true
  done
  [ -d "$DESTDIR" ] || { say ERROR "DESTDIR inexistente: $DESTDIR"; exit 20; }
  [ -n "$OUT_DIR" ] || OUT_DIR="$DESTDIR/../pkg"
  mkdir -p "$OUT_DIR" || { say ERROR "não foi possível criar $OUT_DIR"; exit 20; }
  [ -n "$NAME" ] || NAME="$(basename "$(dirname "$DESTDIR")" | sed 's/-[0-9].*$//')"
  [ -n "$VERSION" ] || VERSION="$(basename "$(dirname "$DESTDIR")" | sed 's/^.*-\([0-9].*\)$/\1/')"

  [ $REGEN_MANIFEST -eq 1 ] && emit_manifest "$DESTDIR"
  emit_build_meta "$DESTDIR" "$OUT_DIR/${NAME}-${VERSION}.meta" || true
  [ $SPLITDBG -eq 1 ] && split_debug "$DESTDIR"

  case "$FORMAT" in
    zst)
      OUT="$OUT_DIR/${NAME}-${VERSION}.tar.zst"; tar_from_dir_zst "$DESTDIR" "$OUT" "$ZSTD_LVL" || exit 23;;
    xz)
      OUT="$OUT_DIR/${NAME}-${VERSION}.tar.xz"; tar_from_dir_xz "$DESTDIR" "$OUT" "$XZ_LVL" || exit 23;;
    tar)
      OUT="$OUT_DIR/${NAME}-${VERSION}.tar"; tar_from_dir_plain "$DESTDIR" "$OUT" || exit 23;;
    deb)
      OUT="$OUT_DIR/${NAME}_${VERSION}.deb"; mk_deb_from_destdir "$DESTDIR" "$OUT" || exit 23;;
    rpm)
      OUT="$OUT_DIR/${NAME}-${VERSION}.rpm"; mk_rpm_from_destdir "$DESTDIR" "$OUT" || exit 23;;
    *) say ERROR "formato não suportado: $FORMAT"; exit 10;;
  esac
  say INFO "gerado: $OUT"
  say OK
}

cmd_pack_from_pkg(){
  PKG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from-pkg) shift; PKG="$1";;
      --*) set -- $(parse_common "$@"); shift $(( $# - $# ));;
      *) say ERROR "arg desconhecido: $1"; exit 10;;
    esac; shift || true
  done
  [ -f "$PKG" ] || { say ERROR "arquivo inexistente: $PKG"; exit 20; }
  tmp="$(mktemp -d 2>/dev/null || echo "/tmp/adm-pack.$$")"
  extract_pkg_to_dir "$PKG" "$tmp/root" || { safe_rm_rf "$tmp"; exit 20; }
  [ -n "$OUT_DIR" ] || OUT_DIR="$(dirname "$PKG")"
  case "$FORMAT" in
    zst) OUT="$OUT_DIR/$(basename "$PKG" | sed 's/\.[^.]*$//').tar.zst"; tar_from_dir_zst "$tmp/root" "$OUT" "$ZSTD_LVL" || { safe_rm_rf "$tmp"; exit 23; };;
    xz)  OUT="$OUT_DIR/$(basename "$PKG" | sed 's/\.[^.]*$//').tar.xz";  tar_from_dir_xz  "$tmp/root" "$OUT" "$XZ_LVL" || { safe_rm_rf "$tmp"; exit 23; };;
    tar) OUT="$OUT_DIR/$(basename "$PKG" | sed 's/\.[^.]*$//').tar";     tar_from_dir_plain "$tmp/root" "$OUT"        || { safe_rm_rf "$tmp"; exit 23; };;
    *) say ERROR "from-pkg suporta saída tar.* (zst|xz|tar)"; safe_rm_rf "$tmp"; exit 10;;
  esac
  safe_rm_rf "$tmp" || true
  say INFO "gerado: $OUT"
  say OK
}

cmd_convert(){
  IN=""; while [ $# -gt 0 ]; do
    case "$1" in
      --in) shift; IN="$1";;
      --*) set -- $(parse_common "$@"); shift $(( $# - $# ));;
      *) say ERROR "arg desconhecido: $1"; exit 10;;
    esac; shift || true
  done
  [ -f "$IN" ] || { say ERROR "arquivo inexistente: $IN"; exit 20; }
  tmp="$(mktemp -d 2>/dev/null || echo "/tmp/adm-conv.$$")"
  extract_pkg_to_dir "$IN" "$tmp/root" || { safe_rm_rf "$tmp"; exit 20; }
  [ -n "$OUT_DIR" ] || OUT_DIR="$(dirname "$IN")"
  base="$(basename "$IN")"
  case "$FORMAT" in
    zst) OUT="$OUT_DIR/${base%.*}.tar.zst"; tar_from_dir_zst "$tmp/root" "$OUT" "$ZSTD_LVL" || { safe_rm_rf "$tmp"; exit 23; };;
    xz)  OUT="$OUT_DIR/${base%.*}.tar.xz";  tar_from_dir_xz  "$tmp/root" "$OUT" "$XZ_LVL"  || { safe_rm_rf "$tmp"; exit 23; };;
    tar) OUT="$OUT_DIR/${base%.*}.tar";     tar_from_dir_plain "$tmp/root" "$OUT"          || { safe_rm_rf "$tmp"; exit 23; };;
    deb) [ -n "$NAME" ] || NAME="${base%.*}"; [ -n "$VERSION" ] || VERSION="0"; OUT="$OUT_DIR/${NAME}_${VERSION}.deb"; mk_deb_from_destdir "$tmp/root" "$OUT" || { safe_rm_rf "$tmp"; exit 23; };;
    rpm) [ -n "$NAME" ] || NAME="${base%.*}"; [ -n "$VERSION" ] || VERSION="0"; OUT="$OUT_DIR/${NAME}-${VERSION}.rpm"; mk_rpm_from_destdir "$tmp/root" "$OUT" || { safe_rm_rf "$tmp"; exit 23; };;
    *) say ERROR "formato não suportado: $FORMAT"; safe_rm_rf "$tmp"; exit 10;;
  esac
  safe_rm_rf "$tmp" || true
  say INFO "gerado: $OUT"
  say OK
}

# =========================
# 10) Repo CLI wrappers
# =========================
cmd_repo(){
  sub="$1"; shift || true
  case "$sub" in
    index)
      DIR=""; OUT=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --dir) shift; DIR="$1";;
          --out) shift; OUT="$1";;
          *) say ERROR "arg desconhecido: $1"; exit 10;;
        esac; shift || true
      done
      [ -d "$DIR" ] || { say ERROR "diretório inexistente: $DIR"; exit 20; }
      repo_index "$DIR" "${OUT:-$DIR}" || exit $?
      ;;
    verify)
      DIR=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --dir) shift; DIR="$1";;
          *) say ERROR "arg desconhecido: $1"; exit 10;;
        esac; shift || true
      done
      [ -d "$DIR" ] || { say ERROR "diretório inexistente: $DIR"; exit 20; }
      repo_verify "$DIR" || exit $?
      ;;
    *) say ERROR "repo subcomando desconhecido: $sub"; exit 10;;
  esac
}

# =========================
# 11) Main
# =========================
main(){
  _color_setup
  ensure_dirs
  cmd="${1:-}"; [ -n "$cmd" ] || { usage; exit 10; }
  shift || true
  case "$cmd" in
    pack)
      # decide modo a partir dos flags
      if printf "%s " "$@" | grep -q -- "--from-destdir"; then
        cmd_pack_from_destdir "$@"
      elif printf "%s " "$@" | grep -q -- "--from-pkg"; then
        cmd_pack_from_pkg "$@"
      else
        say ERROR "pack requer --from-destdir DIR ou --from-pkg FILE"; exit 10
      fi
      ;;
    sign)   cmd_sign "$@";;
    verify) cmd_verify "$@";;
    repo)   cmd_repo "$@";;
    convert) cmd_convert "$@";;
    -h|--help|help) usage;;
    *) say ERROR "subcomando desconhecido: $cmd"; usage; exit 10;;
  esac
}

main "$@"
