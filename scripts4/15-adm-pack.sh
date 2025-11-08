#!/usr/bin/env bash
# 15-adm-pack.part1.sh
# Empacota um DESTDIR em tarballs binários determinísticos (.tar.zst por padrão),
# gera manifesto, index.json, checksums e (opcional) assina os artefatos.
###############################################################################
# Guardas e variáveis base
###############################################################################
if [[ -n "${ADM_PACK_LOADED_PART1:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_PACK_LOADED_PART1=1

for _m in ADM_CONF_LOADED ADM_LIB_LOADED; do
  if [[ -z "${!_m:-}" ]]; then
    echo "ERRO: 15-adm-pack requer módulos básicos carregados (00/01). Faltando: ${_m}" >&2
    return 2 2>/dev/null || exit 2
  fi
done

: "${ADM_CACHE_ROOT:=/usr/src/adm/cache}"
: "${ADM_STATE_ROOT:=/usr/src/adm/state}"
: "${ADM_TMP_ROOT:=/usr/src/adm/tmp}"
: "${ADM_METAFILE_ROOT:=/usr/src/adm/metafile}"
: "${ADM_PROFILE_STATE:=/usr/src/adm/state/profile/active.env}"

pack_err()  { adm_err "$*"; }
pack_warn() { adm_warn "$*"; }
pack_info() { adm_log INFO "pack" "${P_NAME:-}" "$*"; }

declare -Ag PK=(
  [compress]="zstd" [level]="19" [arch]="" [libc]="" [split]="" [sign]="" [key]="" [keep_temp]="false"
  [no_manifest]="false" [no_index]="false" [json]="false"
)

declare -Ag MF=()      # metafile fields
declare -Ag PATHS=()   # logs e caminhos
declare -Ag META=()    # metainfo do build/profile

###############################################################################
# Auxiliares de checagem/paths
###############################################################################
_pk_require_cmds() {
  local miss=()
  command -v tar >/dev/null 2>&1 || miss+=("tar")
  command -v sha256sum >/dev/null 2>&1 || miss+=("sha256sum")
  case "${PK[compress]}" in
    zstd) command -v zstd >/dev/null 2>&1 || miss+=("zstd");;
    xz)   command -v xz >/dev/null 2>&1 || miss+=("xz");;
    gz)   command -v gzip >/dev/null 2>&1 || miss+=("gzip");;
  esac
  ((${#miss[@]}==0)) || { pack_err "ferramentas ausentes: ${miss[*]}"; return 2; }
}

_pk_paths_init() {
  local cat="$1" name="$2" ver="$3"
  local base="${ADM_STATE_ROOT%/}/logs/pack/${cat}/${name}"
  mkdir -p -- "$base" "$ADM_TMP_ROOT" || { pack_err "falha ao criar diretórios de log/tmp"; return 3; }
  PATHS[create]="${base}/create.log"
  PATHS[verify]="${base}/verify.log"
  PATHS[index]="${base}/index.log"
  PATHS[sign]="${base}/sign.log"

  local repo="${ADM_CACHE_ROOT%/}/bin/${cat}/${name}"
  mkdir -p -- "$repo" || { pack_err "falha ao criar diretório de cache: $repo"; return 3; }

  local arch="${PK[arch]:-$(uname -m 2>/dev/null || echo unknown)}"
  local libc="${PK[libc]:-$(ldd --version 2>/dev/null | head -n1 | sed -n 's/.*\(musl\|glibc\).*/\1/p' || echo unknown)}"
  [[ "$libc" =~ musl|glibc ]] || libc="unknown"
  PK[arch]="$arch"; PK[libc]="$libc"

  PATHS[tarbase]="${name}-${ver}-${arch}-${libc}"
  PATHS[tardir]="$repo"
  PATHS[tarball]="${repo}/${PATHS[tarbase]}.tar.$([[ ${PK[compress]} == zstd ]] && echo zst || ([[ ${PK[compress]} == gz ]] && echo gz || echo xz))"
  PATHS[tarsha]="${PATHS[tarball]}.sha256"
  PATHS[metadir]="${repo}/${PATHS[tarbase]}.meta"
  mkdir -p -- "${PATHS[metadir]}" || { pack_err "falha ao criar metadir: ${PATHS[metadir]}"; return 3; }
}

_pk_safe_tree_check() {
  # rejeita paths absolutos, traversal, caracteres de controle
  local dir="$1"
  while IFS= read -r -d '' p; do
    local rel="${p#$dir/}"
    [[ "$rel" == /* ]] && { pack_err "caminho absoluto detectado: $rel"; return 4; }
    [[ "$rel" == *".."* ]] && { pack_err "path traversal detectado: $rel"; return 4; }
    [[ "$rel" =~ [[:cntrl:]] ]] && { pack_err "caracter de controle em path: $rel"; return 4; }
  done < <(find "$dir" -mindepth 1 -print0)
}

###############################################################################
# Metafile atual (para metadados)
###############################################################################
_pk_metafile_load() {
  local cat="$1" name="$2"
  local mf="${ADM_METAFILE_ROOT%/}/${cat}/${name}/metafile"
  if [[ -r "$mf" ]] && command -v adm_metafile_get >/dev/null 2>&1; then
    MF[name]="$(adm_metafile_get "$mf" name)"
    MF[version]="$(adm_metafile_get "$mf" version)"
    MF[category]="$(adm_metafile_get "$mf" category)"
    MF[build_type]="$(adm_metafile_get "$mf" build_type)"
    MF[run_deps]="$(adm_metafile_get "$mf" run_deps)"
    MF[build_deps]="$(adm_metafile_get "$mf" build_deps)"
    MF[opt_deps]="$(adm_metafile_get "$mf" opt_deps)"
    MF[description]="$(adm_metafile_get "$mf" description)"
    MF[homepage]="$(adm_metafile_get "$mf" homepage)"
    MF[maintainer]="$(adm_metafile_get "$mf" maintainer)"
    MF[sources]="$(adm_metafile_get "$mf" sources)"
    MF[sha256sums]="$(adm_metafile_get "$mf" sha256sums)"
  elif [[ -r "$mf" ]]; then
    MF[name]="$(sed -n 's/^name=//p' "$mf" | head -n1)"
    MF[version]="$(sed -n 's/^version=//p' "$mf" | head -n1)"
    MF[category]="$(sed -n 's/^category=//p' "$mf" | head -n1)"
    MF[build_type]="$(sed -n 's/^build_type=//p' "$mf" | head -n1)"
    MF[run_deps]="$(sed -n 's/^run_deps=//p' "$mf" | head -n1)"
    MF[build_deps]="$(sed -n 's/^build_deps=//p' "$mf" | head -n1)"
    MF[opt_deps]="$(sed -n 's/^opt_deps=//p' "$mf" | head -n1)"
    MF[description]="$(sed -n 's/^description=//p' "$mf" | head -n1)"
    MF[homepage]="$(sed -n 's/^homepage=//p' "$mf" | head -n1)"
    MF[maintainer]="$(sed -n 's/^maintainer=//p' "$mf" | head -n1)"
    MF[sources]="$(sed -n 's/^sources=//p' "$mf" | head -n1)"
    MF[sha256sums]="$(sed -n 's/^sha256sums=//p' "$mf" | head -n1)"
  else
    pack_warn "metafile não encontrado para ${cat}/${name}; prosseguindo com metadados mínimos"
    MF[name]="$name"; MF[version]="${MF[version]:-0.0.0}"; MF[category]="$cat"
  fi
}

###############################################################################
# Manifesto (lista de arquivos + sha256 + modo + owner + tamanho)
###############################################################################
_pk_manifest_generate() {
  local dest="$1" man="${PATHS[metadir]}/manifest.txt"
  : > "$man" 2>/dev/null || { pack_err "não foi possível criar $man"; return 3; }
  # ordem determinística
  (cd "$dest" && find . -type f -o -type l -o -type d | LC_ALL=C sort) | while read -r rel; do
    local p="${dest%/}/${rel#./}"
    if [[ -h "$p" ]]; then
      local tgt; tgt="$(readlink "$p")"
      printf "S\t%s\t%s\n" "$rel" "$tgt" >> "$man"
    elif [[ -f "$p" ]]; then
      local sum; sum="$(sha256sum "$p" | awk '{print $1}')"
      local mode; mode="$(stat -c '%a' "$p")"
      local sz; sz="$(stat -c '%s' "$p")"
      printf "F\t%s\t%s\t%s\t%s\n" "$rel" "$sum" "$mode" "$sz" >> "$man"
    elif [[ -d "$p" ]]; then
      local mode; mode="$(stat -c '%a' "$p")"
      printf "D\t%s\t%s\n" "$rel" "$mode" >> "$man"
    fi
  done
  PATHS[manifest]="$man"
}

###############################################################################
# Triggers heurísticos
###############################################################################
_pk_detect_triggers() {
  local dest="$1" f="${PATHS[metadir]}/triggers.json"
  local needs_ldconfig=false needs_icon=false needs_desktop=false needs_gschemas=false needs_ca=false needs_fc=false needs_depmod=false needs_mime=false
  [[ -d "${dest}/lib" || -d "${dest}/lib64" || -d "${dest}/usr/lib" ]] && needs_ldconfig=true
  [[ -d "${dest}/usr/share/icons" ]] && needs_icon=true
  [[ -d "${dest}/usr/share/applications" ]] && needs_desktop=true
  [[ -d "${dest}/usr/share/glib-2.0/schemas" ]] && needs_gschemas=true
  [[ -d "${dest}/etc/ssl/certs" || -d "${dest}/usr/share/ca-certificates" ]] && needs_ca=true
  [[ -d "${dest}/usr/share/fonts" ]] && needs_fc=true
  [[ -d "${dest}/lib/modules" ]] && needs_depmod=true
  [[ -d "${dest}/usr/share/mime" ]] && needs_mime=true

  {
    echo '{'
    echo '  "ldconfig": '"$needs_ldconfig"','
    echo '  "gtk_update_icon_cache": '"$needs_icon"','
    echo '  "update_desktop_database": '"$needs_desktop"','
    echo '  "glib_compile_schemas": '"$needs_gschemas"','
    echo '  "update_ca_trust": '"$needs_ca"','
    echo '  "fc_cache": '"$needs_fc"','
    echo '  "depmod": '"$needs_depmod"','
    echo '  "update_mime_database": '"$needs_mime"''
    echo '}'
  } > "$f" 2>/dev/null || true
  PATHS[triggers]="$f"
}

###############################################################################
# Index.json (metadados do pacote)
###############################################################################
_pk_index_write() {
  local dest="$1"
  local f="${PATHS[metadir]}/index.json"
  local files; files="$(find "$dest" -type f | wc -l | awk '{print $1}')"
  local size; size="$(du -sm "$dest" | awk '{print $1}')"
  local sde="${SOURCE_DATE_EPOCH:-1704067200}"

  # carregar active.env se existir
  if [[ -r "$ADM_PROFILE_STATE" ]]; then
    # shellcheck disable=SC1090
    source "$ADM_PROFILE_STATE" 2>/dev/null || true
    META[cflags]="$CFLAGS"; META[cxxflags]="$CXXFLAGS"; META[ldflags]="$LDFLAGS"; META[makeflags]="$MAKEFLAGS"
    META[linker]="$LINKER"; META[pie]="$( [[ "$LDFLAGS" == *'-pie'* ]] && echo true || echo false )"
    META[lto]="$( [[ "$CFLAGS" == *'-flto'* || "$LDFLAGS" == *'-flto'* ]] && echo true || echo false )"
    META[relro]="$( [[ "$LDFLAGS" == *'-z,relro'* ]] && echo true || echo false )"
    META[profile]="$(grep -E '^PROFILE_NAME=' "$ADM_PROFILE_STATE" | sed 's/PROFILE_NAME=//; s/"//g')"
  fi

  {
    echo '{'
    printf '  "name": %q,\n'        "${MF[name]}"
    printf '  "version": %q,\n'     "${MF[version]}"
    printf '  "category": %q,\n'    "${MF[category]}"
    printf '  "arch": %q,\n'        "${PK[arch]}"
    printf '  "libc": %q,\n'        "${PK[libc]}"
    printf '  "build_type": %q,\n'  "${MF[build_type]}"
    printf '  "profile": %q,\n'     "${META[profile]}"
    printf '  "run_deps": %q,\n'    "${MF[run_deps]}"
    printf '  "build_deps": %q,\n'  "${MF[build_deps]}"
    printf '  "opt_deps": %q,\n'    "${MF[opt_deps]}"
    printf '  "size_total_mb": %s,\n' "${size:-0}"
    printf '  "files": %s,\n'       "${files:-0}"
    printf '  "source_date_epoch": %q,\n' "$sde"
    printf '  "maintainer": %q,\n'  "${MF[maintainer]}"
    printf '  "homepage": %q,\n'    "${MF[homepage]}"
    printf '  "description": %q,\n' "${MF[description]}"
    echo '  "hashes": {'
    printf '    "tarball_sha256": %q,\n' "$(cat "${PATHS[tarsha]}" 2>/dev/null | awk '{print $1}')"
    printf '    "manifest_sha256": %q\n' "$(sha256sum "${PATHS[manifest]}" 2>/dev/null | awk '{print $1}')"
    echo '  },'
    echo '  "paths": {'
    printf '    "tarball": %q,\n' "${PATHS[tarball]}"
    printf '    "meta_dir": %q\n' "${PATHS[metadir]}"
    echo '  },'
    echo '  "build": {'
    printf '    "cflags": %q,\n'   "${META[cflags]}"
    printf '    "cxxflags": %q,\n' "${META[cxxflags]}"
    printf '    "ldflags": %q,\n'  "${META[ldflags]}"
    printf '    "makeflags": %q,\n'"${META[makeflags]}"
    printf '    "linker": %q,\n'   "${META[linker]}"
    printf '    "lto": %q,\n'      "${META[lto]}"
    printf '    "pie": %q,\n'      "${META[pie]}"
    printf '    "relro": %q\n'     "${META[relro]}"
    echo '  },'
    echo '  "source": {'
    printf '    "sources": %q,\n'    "${MF[sources]}"
    printf '    "sha256sums": %q\n'  "${MF[sha256sums]}"
    echo '  }'
    echo '}'
  } > "$f" 2>>"${PATHS[create]}" || { pack_warn "falhou ao escrever index.json"; :; }
  PATHS[indexjson]="$f"
}
# 15-adm-pack.part2.sh
# Empacotamento, verificação, extração-teste e listagem
if [[ -n "${ADM_PACK_LOADED_PART2:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_PACK_LOADED_PART2=1
###############################################################################
# Empacotar DESTDIR -> tarball determinístico
###############################################################################
_pk_tar_create() {
  local dest="$1"
  local sde="${SOURCE_DATE_EPOCH:-1704067200}"
  local comp="${PK[compress]}" lvl="${PK[level]}"

  adm_step "${MF[name]}" "${MF[version]}" "empacotando (tar.$([[ $comp == zstd ]] && echo zst || ([[ $comp == gz ]] && echo gz || echo xz)))"
  (cd "$dest" && \
    tar --numeric-owner --owner=0 --group=0 \
        --sort=name --mtime="@${sde}" -cpf - . \
    | { case "$comp" in
          zstd) zstd -${lvl} -T0 -q ;;
          xz)   xz -${lvl} -z -q ;;
          gz)   gzip -${lvl} -n -q ;;
        esac; } \
    > "${PATHS[tarball]}") >> "${PATHS[create]}" 2>&1 || {
      pack_err "falha ao criar tarball (veja: ${PATHS[create]})"; return 3; }

  sha256sum "${PATHS[tarball]}" > "${PATHS[tarsha]}" 2>>"${PATHS[create]}" || {
    pack_err "falha ao gerar sha256 do tarball"; return 3; }
  return 0
}

###############################################################################
# Create (principal)
###############################################################################
adm_pack_create() {
  local cat="$1" name="$2"; shift 2 || true
  local destdir="" version="" license_dir=""
  PK[compress]="zstd"; PK[level]="19"; PK[split]=""; PK[sign]="" ; PK[key]=""; PK[keep_temp]="false"
  PK[no_manifest]="false"; PK[no_index]="false"; PK[json]="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) version="$2"; shift 2;;
      --destdir) destdir="$2"; shift 2;;
      --arch) PK[arch]="$2"; shift 2;;
      --libc) PK[libc]="$2"; shift 2;;
      --compress) PK[compress]="$2"; shift 2;;
      --level) PK[level]="$2"; shift 2;;
      --split) PK[split]="$2"; shift 2;;
      --license-dir) license_dir="$2"; shift 2;;
      --sign) PK[sign]="$2"; shift 2;;
      --key)  PK[key]="$2"; shift 2;;
      --keep-temp) PK[keep_temp]="true"; shift;;
      --no-manifest) PK[no_manifest]="true"; shift;;
      --no-index) PK[no_index]="true"; shift;;
      --print-json|--json) PK[json]="true"; shift;;
      *) pack_warn "flag desconhecida: $1"; shift;;
    esac
  done

  [[ -n "$cat" && -n "$name" && -n "$version" && -n "$destdir" ]] || {
    pack_err "uso: adm_pack create <cat> <name> --version <ver> --destdir <DIR> [flags]"; return 1; }

  [[ -d "$destdir" ]] || { pack_err "DESTDIR inexistente: $destdir"; return 3; }
  (find "$destdir" -mindepth 1 -print -quit | grep -q .) || { pack_err "DESTDIR vazio: $destdir"; return 5; }

  P_NAME="${name}@${version}"
  _pk_require_cmds || return $?
  _pk_metafile_load "$cat" "$name" || return $?
  MF[version]="${version}" # força versão do build corrente
  _pk_paths_init "$cat" "$name" "$version" || return $?

  adm_step "$name" "$version" "checagens de segurança"
  _pk_safe_tree_check "$destdir" || return $?

  adm_step "$name" "$version" "gerando manifesto"
  [[ "${PK[no_manifest]}" == "true" ]] || _pk_manifest_generate "$destdir" || return $?

  adm_step "$name" "$version" "detectando triggers"
  _pk_detect_triggers "$destdir" || true

  adm_step "$name" "$version" "criando tarball"
  _pk_tar_create "$destdir" || return $?

  [[ "${PK[no_index]}" == "true" ]] || { adm_step "$name" "$version" "escrevendo index.json"; _pk_index_write "$destdir" || true; }

  # Assinatura (opcional)
  if [[ -n "${PK[sign]}" ]]; then
    adm_step "$name" "$version" "assinando (${PK[sign]})"
    adm_pack_sign "${PATHS[tarball]}" --with "${PK[sign]}" ${PK[key]:+--key "${PK[key]}"} || return $?
  fi

  adm_ok "empacotado: ${PATHS[tarball]}"
  echo "${PATHS[tarball]}"
  if [[ "${PK[json]}" == "true" ]]; then
    printf '{"tarball":"%s","sha256":"%s","meta_dir":"%s"}\n' \
      "${PATHS[tarball]}" "$(awk '{print $1}' "${PATHS[tarsha]}")" "${PATHS[metadir]}"
  fi
  return 0
}

###############################################################################
# Verify
###############################################################################
adm_pack_verify() {
  local src="$1"; shift || true
  [[ -n "$src" ]] || { pack_err "uso: adm_pack verify <tarball|cat/name@ver>"; return 1; }

  local tarball="$src"
  if [[ ! -r "$tarball" ]]; then
    # resolver no cache
    local cat="${src%%/*}" rest="${src#*/}"
    local name="${rest%@*}" ver="${rest#*@}"
    local repo="${ADM_CACHE_ROOT%/}/bin/${cat}/${name}"
    tarball="$(ls -1 "${repo}/${name}-${ver}-"*.tar.* 2>/dev/null | head -n1)"
  fi
  [[ -r "$tarball" ]] || { pack_err "tarball não encontrado: $src"; return 3; }
  local dir="${tarball%.tar.*}.meta"
  local man="${dir}/manifest.txt" idx="${dir}/index.json" sum="${tarball}.sha256"
  : > "${PATHS[verify]:-${ADM_STATE_ROOT%/}/logs/pack/verify.log}" 2>/dev/null || true

  adm_step "$(basename -- "$tarball")" "" "verificando sha256"
  local got; got="$(sha256sum "$tarball" | awk '{print $1}')"
  if [[ -r "$sum" ]]; then
    local exp; exp="$(awk '{print $1}' "$sum")"
    [[ "$got" == "$exp" ]] || { pack_err "sha256 divergente (got=$got exp=$exp)"; return 4; }
  else
    pack_warn "arquivo .sha256 ausente; apenas calculado: $got"
  fi

  if [[ -r "$man" ]]; then
    adm_step "$(basename -- "$tarball")" "" "checando manifesto"
    # extrair lista de arquivos do tar sem conteúdo (para cruzar nomes)
    local tmpd; tmpd="$(mktemp -d)"
    # extração minimalista para comparar sums
    tar -tf "$tarball" > "${tmpd}/list" 2>>"${PATHS[verify]}" || { pack_err "tar -tf falhou"; rm -rf "$tmpd"; return 4; }
    # não revalida conteúdo inteiro (custoso); opcionalmente spot-check
    local missing=0
    grep -E '^[FD]\t' "$man" | awk -F'\t' '{print $2}' | while read -r rel; do
      grep -qx "$rel" "${tmpd}/list" || { echo "faltando: $rel" >> "${PATHS[verify]}"; missing=1; }
    done
    rm -rf "$tmpd"
    (( missing == 0 )) || { pack_warn "há diferenças entre manifesto e tar (veja: ${PATHS[verify]})"; }
  else
    pack_warn "manifesto ausente em ${dir}"
  fi

  if [[ -r "$idx" ]]; then
    adm_step "$(basename -- "$tarball")" "" "checando index.json"
    command -v jq >/dev/null 2>&1 && jq . "$idx" >/dev/null 2>>"${PATHS[verify]}" || true
  else
    pack_warn "index.json ausente em ${dir}"
  fi

  adm_ok "verificação concluída"
  return 0
}

###############################################################################
# Extract-test
###############################################################################
adm_pack_extract_test() {
  local tarball="$1"; shift || true
  local into="${1:-}"
  [[ -r "$tarball" ]] || { pack_err "tarball não encontrado: $tarball"; return 3; }
  local tmp="${into:-$(mktemp -d)}"
  adm_step "$(basename -- "$tarball")" "" "extraindo teste em $tmp"
  tar -xpf "$tarball" -C "$tmp" >> "${PATHS[verify]}" 2>&1 || { pack_err "falha ao extrair"; return 4; }
  adm_ok "extraído para: $tmp"
}
# 15-adm-pack.part3.sh
# Listagem, index e assinatura + CLI
if [[ -n "${ADM_PACK_LOADED_PART3:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_PACK_LOADED_PART3=1
###############################################################################
# List
###############################################################################
adm_pack_list() {
  local q="${1:-}" fmt_json=false versions=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json|--print-json) fmt_json=true; shift;;
      --versions) versions=true; shift;;
      *) q="$1"; shift;;
    esac
  done
  local root="${ADM_CACHE_ROOT%/}/bin"
  [[ -d "$root" ]] || { pack_err "cache binário vazio: $root"; return 0; }
  if $fmt_json; then
    echo -n '['
    local first=true
    find "$root" -type f -name '*.tar.*' | LC_ALL=C sort | while read -r t; do
      local base="$(basename -- "$t")" cat name ver arch libc
      cat="${t#$root/}"; cat="${cat%%/*}"
      name="$(basename -- "$(dirname -- "$t")")"
      base="${base%.tar.*}"
      ver="$(echo "$base" | sed -E "s/^${name}-([^ -]+)-.*/\1/")"
      arch="$(echo "$base" | rev | cut -d- -f2 | rev)"
      libc="$(echo "$base" | rev | cut -d- -f1 | rev)"
      if [[ -n "$q" && "$q" != "$cat/$name" ]]; then continue; fi
      $first || echo -n ','
      printf '{"cat":%q,"name":%q,"version":%q,"arch":%q,"libc":%q,"tarball":%q}' \
        "$cat" "$name" "$ver" "$arch" "$libc" "$t"
      first=false
    done
    echo ']'
  else
    if [[ -n "$q" ]]; then
      local cat="${q%%/*}" name="${q#*/}"
      find "$root/$cat/$name" -type f -name '*.tar.*' 2>/dev/null | LC_ALL=C sort | while read -r t; do
        echo "$t"
      done
    else
      find "$root" -type f -name '*.tar.*' | LC_ALL=C sort
    fi
  fi
}

###############################################################################
# Index (repo.json)
###############################################################################
adm_pack_index() {
  local cache_dir="${1:-${ADM_CACHE_ROOT%/}/bin}"
  : > "${PATHS[index]:-${ADM_STATE_ROOT%/}/logs/pack/index.log}" 2>/dev/null || true
  [[ -d "$cache_dir" ]] || { pack_err "cache_dir inexistente: $cache_dir"; return 1; }
  local outfile="${cache_dir%/}/repo.json"
  {
    echo '['
    local first=true
    while IFS= read -r -d '' meta; do
      [[ -r "$meta/index.json" ]] || continue
      $first || echo ','
      if command -v jq >/dev/null 2>&1; then
        jq -c '.' "$meta/index.json"
      else
        # fallback tosco: incluir apenas tarball e nome
        local base="$(basename -- "$meta")"
        printf '{"name":%q,"tarball":%q}' "${base%.meta}" "$(dirname -- "$meta")/${base%.meta}.tar.zst"
      fi
      first=false
    done < <(find "$cache_dir" -type d -name '*.meta' -print0 | LC_ALL=C sort -z)
    echo ']'
  } > "$outfile" 2>>"${PATHS[index]}" || { pack_err "falha ao escrever $outfile"; return 3; }
  adm_ok "índice criado: $outfile"
}

###############################################################################
# Assinatura
###############################################################################
adm_pack_sign() {
  local target="$1"; shift || true
  local with="" key=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with) with="$2"; shift 2;;
      --key) key="$2"; shift 2;;
      *) pack_warn "flag desconhecida: $1"; shift;;
    esac
  done
  [[ -r "$target" ]] || { pack_err "arquivo não encontrado para assinar: $target"; return 3; }
  case "$with" in
    gpg)
      command -v gpg >/dev/null 2>&1 || { pack_err "gpg ausente"; return 2; }
      gpg --batch --yes ${key:+--local-user "$key"} --output "${target}.sig" --detach-sign "$target" >> "${PATHS[sign]}" 2>&1 || {
        pack_err "assinatura gpg falhou (veja: ${PATHS[sign]})"; return 6; }
      ;;
    minisign)
      command -v minisign >/dev/null 2>&1 || { pack_err "minisign ausente"; return 2; }
      minisign -Sm "$target" ${key:+-s "$key"} >> "${PATHS[sign]}" 2>&1 || {
        pack_err "assinatura minisign falhou (veja: ${PATHS[sign]})"; return 6; }
      ;;
    ""|*) pack_err "especifique --with gpg|minisign"; return 1;;
  esac
  adm_ok "assinado: ${target}.sig"
}

###############################################################################
# CLI
###############################################################################
_pack_usage() {
  cat >&2 <<'EOF'
uso:
  adm_pack create <cat> <name> --version <ver> --destdir <DIR>
           [--arch auto|x86_64|aarch64|...] [--libc musl|glibc]
           [--compress zstd|xz|gz] [--level N]
           [--split dev,doc,dbg,locale] [--license-dir PATH]
           [--sign gpg|minisign] [--key <id|path>] [--no-manifest] [--no-index]
           [--keep-temp] [--json]
  adm_pack verify <tarball|cat/name@ver>
  adm_pack extract-test <tarball> [--into DIR]
  adm_pack list [<cat>/<name>] [--versions] [--json]
  adm_pack index [<cache_dir>]
  adm_pack sign <tarball> --with gpg|minisign [--key <id|path>]
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="$1"; shift || true
  case "$cmd" in
    create)       adm_pack_create "$@" || exit $?;;
    verify)       adm_pack_verify "$@" || exit $?;;
    extract-test) adm_pack_extract_test "$@" || exit $?;;
    list)         adm_pack_list "$@" || exit $?;;
    index)        adm_pack_index "$@" || exit $?;;
    sign)         adm_pack_sign "$@" || exit $?;;
    ""|help|-h|--help) _pack_usage; exit 2;;
    *)
      pack_warn "comando desconhecido: $cmd"
      _pack_usage
      exit 2;;
  esac
fi

ADM_PACK_LOADED=1
export ADM_PACK_LOADED
