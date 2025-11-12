#!/usr/bin/env bash
# 07.10-package-bincache.sh
# Empacota DESTDIR, verifica/assina, armazena/restaura a partir do bincache.
###############################################################################
# Modo estrito + traps
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__pbc_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] package-bincache falhou: code=${code} line=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __pbc_err_trap ERR
###############################################################################
# Caminhos, logging, utilitários
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_LOG_DIR="${ADM_LOG_DIR:-${ADM_STATE_DIR}/logs}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"
ADM_DB_DIR="${ADM_DB_DIR:-${ADM_ROOT}/db}"

PBC_CACHE_DIR="${PBC_CACHE_DIR:-${ADM_STATE_DIR}/bincache}"
PBC_PACK_DIR="${PBC_PACK_DIR:-${ADM_STATE_DIR}/packages}"     # staging de pacotes gerados
PBC_IDX_DIR="${PBC_IDX_DIR:-${ADM_STATE_DIR}/indexes}"        # índices JSON

adm_is_cmd(){ command -v "$1" >/dev/null 2>&1; }
__ensure_dir(){
  local d="$1" mode="${2:-0755}" owner="${3:-root}" group="${4:-root}"
  if [[ ! -d "$d" ]]; then
    if adm_is_cmd install; then
      if [[ $EUID -ne 0 ]] && adm_is_cmd sudo; then
        sudo install -d -m "$mode" -o "$owner" -g "$group" "$d"
      else
        install -d -m "$mode" -o "$owner" -g "$group" "$d"
      fi
    else
      mkdir -p "$d"; chmod "$mode" "$d"; chown "$owner:$group" "$d" || true
    fi
  fi
}
__ensure_dir "$ADM_STATE_DIR"; __ensure_dir "$ADM_LOG_DIR"; __ensure_dir "$ADM_TMPDIR"
__ensure_dir "$PBC_CACHE_DIR"; __ensure_dir "$PBC_PACK_DIR"; __ensure_dir "$PBC_IDX_DIR"; __ensure_dir "$ADM_DB_DIR"

# Cores simples
if [[ -t 1 ]] && adm_is_cmd tput && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RST="$(tput sgr0)"; C_OK="$(tput setaf 2)"; C_WRN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INF="$(tput setaf 6)"; C_BD="$(tput bold)"
else
  C_RST=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""; C_BD=""
fi
pbc_info(){  echo -e "${C_INF}[ADM]${C_RST} $*"; }
pbc_ok(){    echo -e "${C_OK}[OK ]${C_RST} $*"; }
pbc_warn(){  echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
pbc_err(){   echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }
tmpfile(){ mktemp "${ADM_TMPDIR}/pbc.XXXXXX"; }
trim(){ sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }

# Locks
__lock(){
  local name="$1"; __ensure_dir "$ADM_STATE_DIR/locks"
  exec {__PBC_FD}>"$ADM_STATE_DIR/locks/${name}.lock"
  flock -n ${__PBC_FD} || { pbc_warn "aguardando lock de ${name}…"; flock ${__PBC_FD}; }
}
__unlock(){ :; }  # fd fecha ao sair

# Hooks
__pkg_root(){
  local cat="${ADM_META[category]:-}" name="${ADM_META[name]:-}"
  [[ -n "$cat" && -n "$name" ]] || { echo ""; return 1; }
  printf '%s/%s/%s' "$ADM_ROOT" "$cat" "$name"
}
__hooks_dirs(){
  local pr; pr="$(__pkg_root)" || return 0
  printf '%s\n' "$pr/hooks" "$ADM_ROOT/hooks"
}
pbc_hooks_run(){
  local stage="${1:?}"; shift || true
  local d f ran=0
  for d in $(__hooks_dirs); do
    [[ -d "$d" ]] || continue
    for f in "$d/$stage" "$d/$stage.sh"; do
      if [[ -x "$f" ]]; then
        pbc_info "Hook: $(realpath -m "$f")"
        ( set -Eeuo pipefail; "$f" "$@" )
        ran=1
      fi
    done
  done
  (( ran )) || pbc_info "Hook '${stage}': nenhum"
}

###############################################################################
# CLI
###############################################################################
CMD=""                          # pack|store|restore|verify|list|gc|stats|find
DESTDIR=""                      # origem do pacote (quando pack)
OUTFMT="zst"                    # zst|xz|both
INSTALL_ROOT="/"                # root de restauração
SIGN_TOOL=""                    # minisign|gpg|none
SIGN_KEY=""                     # caminho da chave ou keyid
VERIFY_ONLY=0
RESTORE_KEY=""                  # chave do cache a restaurar
ALLOW_CONFLICTS=0
DRYRUN=0
KEEP_NUM=0                      # para GC (manter N por pacote)
GC_MAX_AGE_DAYS=0               # >0 apaga mais antigos
GC_MAX_BYTES=0                  # >0 tenta reduzir até cabe
DEDUPE=1                        # tentará reflink/hardlink quando possível
ARCH="${ARCH:-$(uname -m)}"
LIBC="${ADM_LIBC:-}"            # glibc|musl|auto(detecção via ldd)
PROFILE="${ADM_PROFILE:-normal}"

pbc_usage(){
  cat <<'EOF'
Uso:
  07.10-package-bincache.sh <comando> [opções]

Comandos:
  pack     Empacota conteúdo de DESTDIR e gera pacote(s) + manifest
  store    Armazena pacote(s) no bincache e indexa
  restore  Restaura um pacote do bincache em --root (default: /)
  verify   Verifica integridade/assinatura de um pacote
  list     Lista entradas no bincache (por pacote/chave)
  find     Busca por pacote (name/category/version) e mostra chaves
  gc       Coleta lixo do cache (políticas de idade/tamanho/keep)
  stats    Estatísticas do cache

Opções comuns:
  --category CAT          Categoria do pacote (metafile)
  --name NAME             Nome do pacote
  --version VER           Versão
  --arch ARCH             Arquitetura (auto: uname -m)
  --libc {glibc|musl|auto}  (default: auto)
  --profile {aggressive|normal|minimal}

Pack/Store:
  --destdir PATH          Diretório-fonte (staging) a empacotar
  --format {zst|xz|both}  Formatos de saída (default: zst)
  --sign {minisign|gpg}   Assinar pacote
  --key PATH|KEYID        Chave/ID para assinatura

Restore:
  --key CACHEKEY          Chave específica (cat/name@ver+…)
  --root PATH             Raiz de instalação (default: /)
  --allow-conflicts       Ignora conflitos de arquivos (override)

Verificação/Outros:
  --verify-only           Em 'restore', apenas verifica (não instala)
  --keep-last N           (gc) mantêm N versões por pacote
  --max-age-days D        (gc) remove mais antigos que D dias
  --max-size-bytes B      (gc) reduz até B bytes totais
  --no-dedupe             Desativa deduplicação (reflink/hardlink)
  --dry-run               Não altera nada, só simula
  --help
EOF
}

parse_cli(){
  [[ $# -ge 1 ]] || { pbc_usage; exit 2; }
  CMD="$1"; shift
  while (($#)); do
    case "$1" in
      --destdir) DESTDIR="${2:-}"; shift 2 ;;
      --format) OUTFMT="${2:-zst}"; shift 2 ;;
      --sign) SIGN_TOOL="${2:-}"; shift 2 ;;
      --key) SIGN_KEY="${2:-}"; shift 2 ;;
      --root) INSTALL_ROOT="${2:-/}"; shift 2 ;;
      --key=*) RESTORE_KEY="${1#*=}"; shift 1 ;;
      --key) RESTORE_KEY="${2:-}"; shift 2 ;;
      --allow-conflicts) ALLOW_CONFLICTS=1; shift ;;
      --verify-only) VERIFY_ONLY=1; shift ;;
      --category) ADM_META[category]="${2:-}"; shift 2 ;;
      --name)     ADM_META[name]="${2:-}"; shift 2 ;;
      --version)  ADM_META[version]="${2:-}"; shift 2 ;;
      --arch)     ARCH="${2:-$ARCH}"; shift 2 ;;
      --libc)     LIBC="${2:-}"; shift 2 ;;
      --profile)  PROFILE="${2:-$PROFILE}"; shift 2 ;;
      --keep-last) KEEP_NUM="${2:-0}"; shift 2 ;;
      --max-age-days) GC_MAX_AGE_DAYS="${2:-0}"; shift 2 ;;
      --max-size-bytes) GC_MAX_BYTES="${2:-0}"; shift 2 ;;
      --no-dedupe) DEDUPE=0; shift ;;
      --dry-run) DRYRUN=1; shift ;;
      --help|-h) pbc_usage; exit 0 ;;
      *) pbc_err "opção inválida: $1"; pbc_usage; exit 2 ;;
    esac
  done
  case "$CMD" in
    pack|store|restore|verify|list|stats|gc|find) : ;;
    *) pbc_err "comando inválido: $CMD"; pbc_usage; exit 2 ;;
  esac
  [[ -z "$LIBC" || "$LIBC" == "glibc" || "$LIBC" == "musl" || "$LIBC" == "auto" ]] || { pbc_err "--libc inválido"; exit 2; }
  if [[ "$LIBC" == "auto" || -z "$LIBC" ]]; then
    if ldd --version 2>&1 | grep -qi musl; then LIBC="musl"; else LIBC="glibc"; fi
  fi
}

###############################################################################
# Chave do cache e metadados
###############################################################################
declare -A ADM_META  # esperado: category name version
__require_meta(){
  local miss=0
  for k in category name version; do
    if [[ -z "${ADM_META[$k]:-}" ]]; then pbc_err "metadado ausente: $k"; miss=1; fi
  done
  ((miss==0))
}

__toolchain_fingerprint(){
  # Hash simples de ferramentas e flags que afetam ABI
  local cc="${CC:-$(command -v clang || command -v gcc || echo cc)}"
  local cxx="${CXX:-$(command -v clang++ || command -v g++ || echo c++)}"
  local ar="${AR:-$(command -v llvm-ar || command -v ar || echo ar)}"
  local ranlib="${RANLIB:-$(command -v llvm-ranlib || command -v ranlib || echo ranlib)}"
  local ld="$(command -v ld.lld || command -v ld.gold || command -v ld || echo ld)"
  local dump; dump="$(printf '%s\n' \
      "cc=$($cc --version 2>/dev/null | head -n1)" \
      "cxx=$($cxx --version 2>/dev/null | head -n1)" \
      "ar=$($ar --version 2>/dev/null | head -n1)" \
      "ranlib=$($ranlib --version 2>/dev/null | head -n1)" \
      "ld=$($ld --version 2>/dev/null | head -n1)" \
      "CFLAGS=${CFLAGS:-}" "CXXFLAGS=${CXXFLAGS:-}" "LDFLAGS=${LDFLAGS:-}" \
      "PROFILE=${PROFILE}" "LIBC=${LIBC}" "ARCH=${ARCH}" )"
  printf '%s' "$dump" | sha256sum | awk '{print $1}'
}

__cache_key(){
  __require_meta || return 1
  local cat="${ADM_META[category]}" name="${ADM_META[name]}" ver="${ADM_META[version]}"
  local tfp="$(__toolchain_fingerprint)"
  printf '%s/%s@%s+%s+%s+%s' "$cat" "$name" "$ver" "$ARCH" "$LIBC" "${PROFILE}-${tfp:0:12}"
}

__artifact_paths(){
  # imprime 4 linhas: base_dir, pkg_basename, pkg_zst, pkg_xz
  local key="$(__cache_key)" || return 1
  local base="${PBC_PACK_DIR}/${key}"
  local basefile="$(basename "$key" | tr '/' '_')"
  local zst="${base}/${basefile}.tar.zst"
  local xz="${base}/${basefile}.tar.xz"
  printf '%s\n%s\n%s\n%s\n' "$base" "$basefile" "$zst" "$xz"
}
###############################################################################
# Manifest, empacotamento e assinatura
###############################################################################
__manifest_generate(){
  local root="$1" manifest="$2"
  local tmp; tmp="$(tmpfile)"
  {
    echo "{"
    printf '  "name": %q,\n' "${ADM_META[name]}"
    printf '  "version": %q,\n' "${ADM_META[version]}"
    printf '  "category": %q,\n' "${ADM_META[category]}"
    printf '  "arch": %q,\n' "$ARCH"
    printf '  "libc": %q,\n' "$LIBC"
    printf '  "profile": %q,\n' "$PROFILE"
    printf '  "build_ts": %q,\n' "$(date -u +%FT%TZ)"
    printf '  "key": %q,\n' "$(__cache_key)"
    echo '  "files": ['
    local sep=""; while IFS= read -r -d '' f; do
      local rel="${f#"$root/"}"
      local t; t="$(stat -c '%f' "$f" 2>/dev/null || echo 0)"
      local sz; sz="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
      printf '%s    {"path":%q,"mode":"%s","size":%s}' "$sep" "$rel" "$t" "$sz"
      sep=$',\n'
    done < <(find "$root" -mindepth 1 -print0)
    echo -e '\n  ]'
    echo "}"
  } > "$tmp"
  mv -f "$tmp" "$manifest"
}

__sha256_file(){ sha256sum "$1" | awk '{print $1}'; }

pbc_pack(){
  __require_meta || { pbc_err "meta incompleto"; return 2; }
  [[ -d "$DESTDIR" ]] || { pbc_err "--destdir inválido"; return 2; }
  local base basefile zst xz; read -r base basefile zst xz < <(__artifact_paths)
  __ensure_dir "$base"

  pbc_hooks_run "pre-package" "DESTDIR=$DESTDIR"

  # Manifest
  local manifest="${base}/${basefile}.manifest.json"
  __manifest_generate "$DESTDIR" "$manifest"

  # Tar + compress
  local taro="${base}/${basefile}.tar"
  ( cd "$DESTDIR" && tar --numeric-owner --owner=0 --group=0 -cpf "$taro" . )
  local shaz; shaz=""; local shax=""
  case "$OUTFMT" in
    zst) zstd -q -T0 -19 -f "$taro" -o "$zst"; rm -f "$taro"; shaz="$(__sha256_file "$zst")" ;;
    xz)  xz   -T0 -9e -f  "$taro"; mv -f "${taro}.xz" "$xz"; shax="$(__sha256_file "$xz")" ;;
    both)
      zstd -q -T0 -19 -f "$taro" -o "$zst"; shaz="$(__sha256_file "$zst")"
      xz   -T0 -9e -f  "$taro"; mv -f "${taro}.xz" "$xz"; shax="$(__sha256_file "$xz")"
      ;;
    *) pbc_err "--format inválido"; return 2 ;;
  esac

  # Index local (staging)
  local meta="${base}/${basefile}.meta.json"
  {
    echo "{"
    printf '  "key": %q,\n' "$(__cache_key)"
    printf '  "name": %q,\n' "${ADM_META[name]}"
    printf '  "version": %q,\n' "${ADM_META[version]}"
    printf '  "category": %q,\n' "${ADM_META[category]}"
    printf '  "arch": %q,\n' "$ARCH"
    printf '  "libc": %q,\n' "$LIBC"
    printf '  "profile": %q,\n' "$PROFILE"
    printf '  "manifest": %q,\n' "$manifest"
    printf '  "zst": %q,\n' "$zst"
    printf '  "xz": %q,\n' "$xz"
    printf '  "sha256_zst": %q,\n' "$shaz"
    printf '  "sha256_xz": %q,\n' "$shax"
    printf '  "build_ts": %q\n' "$(date -u +%FT%TZ)"
    echo "}"
  } > "$meta"

  # Assinatura (opcional)
  if [[ -n "$SIGN_TOOL" && -n "$SIGN_KEY" ]]; then
    case "$SIGN_TOOL" in
      minisign)
        adm_is_cmd minisign || pbc_warn "minisign não encontrado"
        [[ -f "$zst" ]] && minisign -Sm "$zst" -s "$SIGN_KEY" || true
        [[ -f "$xz"  ]] && minisign -Sm "$xz"  -s "$SIGN_KEY" || true
        ;;
      gpg)
        adm_is_cmd gpg || pbc_warn "gpg não encontrado"
        [[ -f "$zst" ]] && gpg --batch --yes --local-user "$SIGN_KEY" --output "${zst}.sig" --detach-sign "$zst" || true
        [[ -f "$xz"  ]] && gpg --batch --yes --local-user "$SIGN_KEY" --output "${xz}.sig"  --detach-sign "$xz"  || true
        ;;
      *) pbc_warn "assinador desconhecido: $SIGN_TOOL" ;;
    esac
  fi

  pbc_hooks_run "post-package" "PKG_META=$meta"
  pbc_ok "Empacotado em: $base"
}

###############################################################################
# Store/Index/Find (bincache)
###############################################################################
__cache_bucket(){
  local key="$(__cache_key)"; printf '%s/%s/%s' "$PBC_CACHE_DIR" "$ARCH-$LIBC" "$(dirname "$key")"
}
__cache_filename(){
  local key="$(__cache_key)"; echo "$(basename "$key" | tr '/' '_')"
}
__index_path(){ echo "${PBC_IDX_DIR}/index-${ARCH}-${LIBC}.json"; }

__json_put(){
  local json="$1" key="$2" value="$3"
  local tmp; tmp="$(tmpfile)"
  if adm_is_cmd jq; then
    jq --arg k "$key" --argjson v "$value" '.[$k] = $v' "$json" 2>/dev/null > "$tmp" || echo "{}" > "$tmp"
  else
    # fallback tosco
    cp -f "$json" "$tmp" 2>/dev/null || echo "{}" > "$tmp"
  fi
  mv -f "$tmp" "$json"
}

pbc_store(){
  __require_meta || { pbc_err "meta incompleto"; return 2; }
  local base basefile zst xz; read -r base basefile zst xz < <(__artifact_paths)
  [[ -d "$base" ]] || { pbc_err "nada para armazenar (rode pack)"; return 3; }

  local bucket fname; bucket="$(__cache_bucket)"; fname="$(__cache_filename)"
  __ensure_dir "$bucket"

  __lock "bincache-${ARCH}-${LIBC}"

  # mover (ou reflink) para o bucket
  shopt -s nullglob
  for f in "$base/${basefile}.meta.json" "$base/${basefile}.manifest.json" "$zst" "$xz" "$zst.sig" "$xz.sig" "$zst.minisig" "$xz.minisig"; do
    [[ -e "$f" ]] || continue
    local dst="${bucket}/${fname}.$(basename "$f" | sed "s#^${basefile}\.##")"
    if (( DEDUPE )) && adm_is_cmd cp; then
      cp --reflink=auto -f "$f" "$dst" 2>/dev/null || cp -f "$f" "$dst"
    else
      cp -f "$f" "$dst"
    fi
  done
  shopt -u nullglob

  # Index
  local idx; idx="$(__index_path)"
  [[ -f "$idx" ]] || echo "{}" > "$idx"
  local meta_path="${bucket}/${fname}.meta.json"
  local val; val="$(cat "$meta_path")"
  __json_put "$idx" "$(__cache_key)" "$val"

  __unlock
  pbc_ok "Armazenado em: $bucket"
}

pbc_list(){
  local idx; idx="$(__index_path)"
  [[ -r "$idx" ]] || { pbc_warn "índice ausente: $idx"; return 0; }
  if adm_is_cmd jq; then
    jq -r 'to_entries[] | "\(.key)  ->  \(.value.version)  [\(.value.arch)/\(.value.libc)  \(.value.profile)]"' "$idx"
  else
    cat "$idx"
  fi
}

pbc_find(){
  local idx; idx="$(__index_path)"
  [[ -r "$idx" ]] || { pbc_warn "índice ausente: $idx"; return 0; }
  local name="${ADM_META[name]:-}" cat="${ADM_META[category]:-}" ver="${ADM_META[version]:-}"
  if adm_is_cmd jq; then
    jq -r --arg n "$name" --arg c "$cat" --arg v "$ver" '
      to_entries[]
      | select((.value.name==$n or ($n=="")) and (.value.category==$c or ($c=="")) and (.value.version==$v or ($v=="")))
      | .key' "$idx"
  else
    grep -F "$name" "$idx" || true
  fi
}
###############################################################################
# Verificação, restauração e DB de instalados
###############################################################################
__verify_sign(){
  local f="$1"
  case "$SIGN_TOOL" in
    minisign)
      [[ -f "${f}.minisig" ]] || return 0
      adm_is_cmd minisign || { pbc_warn "minisign indisponível"; return 0; }
      minisign -Vm "$f" -P "$SIGN_KEY" >/dev/null 2>&1
      ;;
    gpg)
      [[ -f "${f}.sig" ]] || return 0
      adm_is_cmd gpg || { pbc_warn "gpg indisponível"; return 0; }
      gpg --verify "${f}.sig" "$f" >/dev/null 2>&1
      ;;
    ""|none) return 0 ;;
    *) pbc_warn "assinatura desconhecida: $SIGN_TOOL"; return 0 ;;
  esac
}

pbc_verify_pkg(){
  local key="$(__cache_key)" ; local idx="$(__index_path)"
  [[ -n "$RESTORE_KEY" ]] && key="$RESTORE_KEY"
  [[ -r "$idx" ]] || { pbc_err "índice não encontrado: $idx"; return 2; }

  local dir="${PBC_CACHE_DIR}/${ARCH}-${LIBC}/$(dirname "$key")"
  local base="$(basename "$key" | tr '/' '_')"
  local meta="${dir}/${base}.meta.json" man="${dir}/${base}.manifest.json"
  [[ -r "$meta" && -r "$man" ]] || { pbc_err "meta/manifest ausentes para $key"; return 3; }

  local zst="${dir}/${base}.tar.zst" xz="${dir}/${base}.tar.xz"
  local ok=0
  if [[ -f "$zst" ]]; then
    local sha exp; sha="$(__sha256_file "$zst")"; exp="$(jq -r '.sha256_zst' "$meta" 2>/dev/null || echo "")"
    [[ -n "$exp" && "$sha" == "$exp" ]] || { pbc_err "sha256 zst diverge ($sha != $exp)"; return 4; }
    __verify_sign "$zst" || { pbc_err "assinatura inválida (zst)"; return 5; }
    ok=1
  fi
  if [[ -f "$xz" ]]; then
    local sha exp; sha="$(__sha256_file "$xz")"; exp="$(jq -r '.sha256_xz' "$meta" 2>/dev/null || echo "")"
    [[ -z "$exp" || "$sha" == "$exp" ]] || { pbc_err "sha256 xz diverge ($sha != $exp)"; return 6; }
    __verify_sign "$xz" || { pbc_err "assinatura inválida (xz)"; return 7; }
    ok=1
  fi
  ((ok)) || { pbc_err "nenhum artefato (xz/zst) encontrado para $key"; return 8; }
  pbc_ok "Verificação OK: $key"
}

__check_conflicts(){
  local root="$1" tarball="$2"
  # Lista arquivos do tarball e checa existência em root; ignora se --allow-conflicts
  (( ALLOW_CONFLICTS )) && return 0
  if adm_is_cmd tar; then
    tar -tf "$tarball" | while IFS= read -r f; do
      [[ -e "$root/$f" ]] && { pbc_err "conflito: $root/$f já existe"; return 9; }
    done
  fi
  return 0
}

__register_installed(){
  # Marca em DB de instalados para __is_already_built (usado por outros scripts)
  local cat="${ADM_META[category]}" name="${ADM_META[name]}"
  local ver="${ADM_META[version]}" key="$(__cache_key)"
  local mark="${ADM_DB_DIR}/installed/${cat}/${name}"
  __ensure_dir "$mark"
  echo "$ver $key $(date -u +%FT%TZ)" > "${mark}/.installed"
}

pbc_restore(){
  __require_meta || { pbc_err "meta incompleto"; return 2; }
  local key="$(__cache_key)"
  [[ -n "$RESTORE_KEY" ]] && key="$RESTORE_KEY"
  local dir="${PBC_CACHE_DIR}/${ARCH}-${LIBC}/$(dirname "$key")"
  local base="$(basename "$key" | tr '/' '_')"
  local zst="${dir}/${base}.tar.zst" xz="${dir}/${base}.tar.xz"
  local tarball=""
  if [[ -f "$zst" ]]; then tarball="$zst"; elif [[ -f "$xz" ]]; then tarball="$xz"; fi
  [[ -n "$tarball" ]] || { pbc_err "artefato não encontrado p/ $key"; return 3; }

  pbc_verify_pkg || return $?

  [[ "$VERIFY_ONLY" == "1" ]] && { pbc_ok "verify-only OK"; return 0; }

  __check_conflicts "$INSTALL_ROOT" "$tarball" || return $?

  pbc_hooks_run "pre-restore" "ROOT=$INSTALL_ROOT" "KEY=$key"
  if (( DRYRUN )); then
    pbc_info "(dry-run) extrairia $tarball → $INSTALL_ROOT"
  else
    if [[ "$tarball" == *.zst ]]; then
      zstd -q -d -c "$tarball" | tar -xpf - -C "$INSTALL_ROOT"
    else
      xz -d -c "$tarball" | tar -xpf - -C "$INSTALL_ROOT"
    fi
  fi
  __register_installed
  pbc_hooks_run "post-restore" "ROOT=$INSTALL_ROOT" "KEY=$key"
  pbc_ok "Restaurado: $key → $INSTALL_ROOT"
}

###############################################################################
# GC, dedupe e stats
###############################################################################
__cache_size_bytes(){ du -sb "$PBC_CACHE_DIR" 2>/dev/null | awk '{print $1}'; }

pbc_stats(){
  echo "Cache dir: $PBC_CACHE_DIR"
  echo "Índice: $(__index_path)"
  echo "Tamanho: $(numfmt --to=iec "$(__cache_size_bytes)" 2>/dev/null || __cache_size_bytes) bytes"
  find "$PBC_CACHE_DIR" -type f | wc -l | xargs echo "Arquivos:"
}

pbc_gc(){
  __lock "bincache-${ARCH}-${LIBC}"
  local idx="$(__index_path)"; [[ -f "$idx" ]] || { pbc_warn "índice ausente"; __unlock; return 0; }
  local now; now="$(date +%s)"
  # 1) por idade
  if (( GC_MAX_AGE_DAYS > 0 )) && adm_is_cmd jq; then
    local cutoff=$(( now - GC_MAX_AGE_DAYS*86400 ))
    mapfile -t olds < <(jq -r --arg cutoff "$cutoff" '
      to_entries[] | select((.value.build_ts|fromdate? // 0) < ($cutoff|tonumber)) | .key' "$idx")
    for k in "${olds[@]}"; do __gc_drop_key "$k"; done
  fi
  # 2) por keep-last N (mantém N versões por (cat,name))
  if (( KEEP_NUM > 0 )) && adm_is_cmd jq; then
    mapfile -t basepairs < <(jq -r '
        to_entries[] | "\(.value.category)/\(.value.name)" ' "$idx" | sort -u)
    local pair
    for pair in "${basepairs[@]}"; do
      mapfile -t keys < <(jq -r --arg p "$pair" '
        to_entries[]
        | select("\(.value.category)/\(.value.name)" == $p)
        | .key' "$idx" | sort -r)
      local i=0
      for k in "${keys[@]}"; do
        (( i < KEEP_NUM )) || __gc_drop_key "$k"
        ((i++))
      done
    done
  fi
  # 3) por tamanho alvo
  if (( GC_MAX_BYTES > 0 )); then
    local cur szfile
    while :; do
      cur="$(__cache_size_bytes)"
      (( cur <= GC_MAX_BYTES )) && break
      # remove o artefato mais antigo (mtime) dentro do cache
      szfile="$(find "$PBC_CACHE_DIR" -type f -printf '%T@ %p\n' | sort -n | head -n1 | cut -d' ' -f2-)"
      [[ -n "$szfile" ]] || break
      rm -f "$szfile" || true
    done
  fi
  __unlock
  pbc_ok "GC concluído."
}

__gc_drop_key(){
  local key="$1"
  local dir="${PBC_CACHE_DIR}/${ARCH}-${LIBC}/$(dirname "$key")"
  local base="$(basename "$key" | tr '/' '_')"
  shopt -s nullglob
  rm -f "$dir/${base}."* || true
  shopt -u nullglob
  local idx="$(__index_path)"
  if adm_is_cmd jq; then
    local tmp; tmp="$(tmpfile)"; jq "del(.\"$key\")" "$idx" > "$tmp" 2>/dev/null || cp -f "$idx" "$tmp"
    mv -f "$tmp" "$idx"
  fi
}

###############################################################################
# MAIN
###############################################################################
pbc_run(){
  parse_cli "$@"
  case "$CMD" in
    pack)    pbc_pack ;;
    store)   pbc_store ;;
    list)    pbc_list ;;
    find)    pbc_find ;;
    verify)  pbc_verify_pkg ;;
    restore) pbc_restore ;;
    stats)   pbc_stats ;;
    gc)      pbc_gc ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  declare -A ADM_META
  pbc_run "$@"
fi
