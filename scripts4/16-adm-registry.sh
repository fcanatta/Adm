#!/usr/bin/env bash
# 16-adm-registry.part1.sh
# Registro canônico do ADM: grava/consulta installs, índices, txlog e integridade.
###############################################################################
# Guardas, variáveis e sanity-check
###############################################################################
if [[ -n "${ADM_REGISTRY_LOADED_PART1:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_REGISTRY_LOADED_PART1=1

for _m in ADM_CONF_LOADED ADM_LIB_LOADED; do
  if [[ -z "${!_m:-}" ]]; then
    echo "ERRO: 16-adm-registry requer módulos básicos carregados (00/01). Faltando: ${_m}" >&2
    return 2 2>/dev/null || exit 2
  fi
done

: "${ADM_STATE_ROOT:=/usr/src/adm/state}"
: "${ADM_TMP_ROOT:=/usr/src/adm/tmp}"

reg_err()  { adm_err "$*"; }
reg_warn() { adm_warn "$*"; }
reg_info() { adm_log INFO "registry" "${R_CTX:-}" "$*"; }

# Contexto de execução
declare -Ag RG=([root]="/" [now]="" [actor]="" [adm_version]="adm/1")
declare -Ag PATHS=()

_rg_now_iso() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
_rg_uuid()    { cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "00000000-0000-0000-0000-000000000000"; }

###############################################################################
# Paths por --root
###############################################################################
_rg_paths_init() {
  local root="${RG[root]}"
  local base="${root%/}/usr/src/adm/state/registry"
  PATHS[base]="$base"
  PATHS[db]="${base}/db"
  PATHS[idx]="${base}/index"
  PATHS[tx]="${base}/txlog"
  PATHS[lck]="${base}/locks"
  PATHS[logs]="${root%/}/usr/src/adm/state/logs/registry"
  mkdir -p -- "${PATHS[db]}" "${PATHS[idx]}" "${PATHS[tx]}" "${PATHS[lck]}" "${PATHS[logs]}" "${ADM_TMP_ROOT}" || {
    reg_err "falha ao criar diretórios do registry em ${root}"; return 3; }
  PATHS[by_file]="${PATHS[idx]}/by-file.map"
  PATHS[by_name]="${PATHS[idx]}/by-name.map"
  PATHS[provides]="${PATHS[idx]}/provides.map"
  PATHS[rdeps]="${PATHS[idx]}/reverse-deps.map"
  PATHS[hold]="${PATHS[idx]}/holds.list"
  PATHS[log_add]="${PATHS[logs]}/add.log"
  PATHS[log_rm]="${PATHS[logs]}/remove.log"
  PATHS[log_verify]="${PATHS[logs]}/verify.log"
  PATHS[log_idx]="${PATHS[logs]}/index.log"
  PATHS[log_tx]="${PATHS[logs]}/tx.log"
}

###############################################################################
# Locks e utilitários
###############################################################################
_rg_flock() { # _rg_flock <lockname> <cmd...>
  local name="$1"; shift
  local l="${PATHS[lck]}/${name}.lock"
  exec {fd}> "$l" || { reg_err "não foi possível abrir lock: $l"; return 6; }
  flock "$fd" -w 30 -- "$@" 2>>"${PATHS[log_tx]}"
}

_rg_pkg_id() { # <cat> <name> <ver> <arch> <libc> -> cat/name@ver-arch-libc
  printf "%s/%s@%s-%s-%s" "$1" "$2" "$3" "$4" "$5"
}
_rg_pkg_dir() { # <cat> <name> <ver> <arch> <libc> -> db path
  printf "%s/%s/%s/%s-%s-%s" "${PATHS[db]}" "$1" "$2" "$3" "$4" "$5"
}

_rg_json_escape() { # imprime JSON string escapada
  # sem jq: substituir aspas e barras simples
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

###############################################################################
# Transações (txlog JSONL com hash encadeado)
###############################################################################
declare -Ag TX=([id]="" [op]="" [file]="" [hash_prev]="" [hash_cur]="" [open]=false)

_rg_txlog_file() {
  local ymd; ymd="$(date -u +'%Y%m')"
  echo "${PATHS[tx]}/adm-tx-${ymd}.jsonl"
}

_rg_tx_hash() { # encadeia SHA256 do arquivo + linha nova (se existir)
  local f="$1" line="$2"
  local prev=""
  [[ -r "$f" ]] && prev="$(tail -n1 "$f" | awk -F'","' '{print $NF}' | sed -E 's/.*"hash":"?([0-9a-f]+)"?.*/\1/')" || true
  [[ -n "$line" ]] || { echo "$prev"; return 0; }
  printf "%s%s" "$prev" "$line" | sha256sum | awk '{print $1}'
}

adm_registry_begin_tx() {
  local op="$1"; shift || true
  RG[root]="/"
  local reason=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root) RG[root]="$2"; shift 2;;
      --reason) reason="$2"; shift 2;;
      *) reg_warn "flag desconhecida: $1"; shift;;
    esac
  done
  _rg_paths_init || return $?
  TX[id]="$(_rg_uuid)"; TX[op]="$op"; TX[file]="$(_rg_txlog_file)"; TX[open]=true
  RG[now]="$(_rg_now_iso)"; RG[actor]="${SUDO_USER:-$USER}@$(hostname -f 2>/dev/null || hostname)"
  local header
  header=$(printf '{"ts":%s,"op":%s,"txid":%s,"actor":%s,"root":%s,"phase":"begin","reason":%s}' \
    "$(_rg_json_escape "${RG[now]}")" "$(_rg_json_escape "$op")" "$(_rg_json_escape "${TX[id]}")" \
    "$(_rg_json_escape "${RG[actor]}")" "$(_rg_json_escape "${RG[root]}")" "$(_rg_json_escape "${reason:-}")]")
  # correção do colchete acidental: remover "]" final
  header="${header%]}"
  _rg_flock "registry" bash -c '
    f="$1"; line="$2"; hp="$3";
    hash=$(printf "%s" "$hp" | sha256sum | awk "{print \$1}")
    echo "{\"entry\":'$line',\"hash\":\"$hash\"}" >> "$f"
  ' _ "${TX[file]}" "${header}" "$(_rg_tx_hash "${TX[file]}" "${header}")" || { reg_err "falha ao escrever tx begin"; return 6; }
  adm_step "registry" "$op" "transação iniciada"
}

adm_registry_commit_tx() {
  [[ "${TX[open]}" == "true" ]] || { reg_err "nenhuma transação ativa"; return 6; }
  local footer
  footer=$(printf '{"ts":%s,"op":%s,"txid":%s,"phase":"commit"}' \
    "$(_rg_json_escape "$(_rg_now_iso)")" "$(_rg_json_escape "${TX[op]}")" "$(_rg_json_escape "${TX[id]}")")
  _rg_flock "registry" bash -c '
    f="$1"; line="$2"; hp="$3";
    hash=$(printf "%s" "$hp" | sha256sum | awk "{print \$1}")
    echo "{\"entry\":'$line',\"hash\":\"$hash\"}" >> "$f"
  ' _ "${TX[file]}" "${footer}" "$(_rg_tx_hash "${TX[file]}" "${footer}")" || { reg_err "falha ao escrever tx commit"; return 6; }
  TX[open]=false
  adm_ok "transação commit"
}

adm_registry_abort_tx() {
  [[ "${TX[open]}" == "true" ]] || { reg_err "nenhuma transação ativa"; return 6; }
  local footer
  footer=$(printf '{"ts":%s,"op":%s,"txid":%s,"phase":"abort"}' \
    "$(_rg_json_escape "$(_rg_now_iso)")" "$(_rg_json_escape "${TX[op]}")" "$(_rg_json_escape "${TX[id]}")")
  _rg_flock "registry" bash -c '
    f="$1"; line="$2"; hp="$3";
    hash=$(printf "%s" "$hp" | sha256sum | awk "{print \$1}")
    echo "{\"entry\":'$line',\"hash\":\"$hash\"}" >> "$f"
  ' _ "${TX[file]}" "${footer}" "$(_rg_tx_hash "${TX[file]}" "${footer}")" || { reg_err "falha ao escrever tx abort"; return 6; }
  TX[open]=false
  adm_ok "transação abort"
}

###############################################################################
# Helpers de leitura/gravação de receipt/manifest
###############################################################################
_rg_write_atomic() { # _rg_write_atomic <target> "<conteudo>"
  local target="$1" body="$2" tmp="${target}.tmp.$$"
  umask 022
  printf "%s\n" "$body" > "$tmp" 2>/dev/null || { reg_err "falha ao escrever temp $tmp"; return 3; }
  mv -f -- "$tmp" "$target" 2>/dev/null || { reg_err "falha ao mover $tmp -> $target"; return 3; }
}

_rg_parse_metadir() { # _rg_parse_metadir <meta_dir> -> set vars: R_META_INDEX, R_META_MAN, R_META_TRIG
  local d="$1"
  R_META_INDEX="${d%/}/index.json"
  R_META_MAN="${d%/}/manifest.txt"
  R_META_TRIG="${d%/}/triggers.json"
  [[ -r "$R_META_MAN" ]] || { reg_err "manifest.txt ausente em $d"; return 4; }
  [[ -r "$R_META_INDEX" ]] || reg_warn "index.json ausente em $d"
  [[ -r "$R_META_TRIG"  ]] || : # opcional
}
# 16-adm-registry.part2.sh
# add/remove, índices, consultas e verificação
if [[ -n "${ADM_REGISTRY_LOADED_PART2:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_REGISTRY_LOADED_PART2=1
###############################################################################
# Atualização de índices
###############################################################################
_rg_index_by_file_add() { # <pkgid> <files.list or manifest>
  local pkg="$1" src="$2"
  : > "${PATHS[by_file]}" 2>/dev/null || true
  touch "${PATHS[by_file]}" 2>/dev/null || { reg_err "não foi possível tocar ${PATHS[by_file]}"; return 3; }
  # lock global
  _rg_flock "index" bash -c '
    pkg="$1"; src="$2"; out="$3"
    while IFS= read -r line; do
      # de manifest.txt: F<TAB>path ...  | S<TAB>path ...
      typ="${line%%	*}"
      path="$(echo "$line" | awk -F"\t" "{print \$2}")"
      [ -z "$path" ] && continue
      case "$typ" in F|S) printf "{\"path\":%q,\"pkg\":%q}\n" "$path" "$pkg" ;; esac
    done >> "$out"
  ' _ "$pkg" "$src" "${PATHS[by_file]}"
}

_rg_index_by_name_refresh() {
  # Recria by-name.map a partir de db
  _rg_flock "index" bash -c '
    base="$1"; out="$2"; : > "$out"
    find "$base" -mindepth 3 -maxdepth 3 -type d | while read -r d; do
      cat="$(echo "$d" | awk -F"/db/" "{print \$2}" | cut -d/ -f1)"
      name="$(basename -- "$d")"
      vers=( $(find "$d" -maxdepth 1 -type d -name "*-*-*" -printf "%f\n" | sort) )
      [ ${#vers[@]} -eq 0 ] && continue
      printf "{\"pkg\":%q,\"vers\":[" "$cat/$name" >> "$out"
      first=1; for v in "${vers[@]}"; do
        if [ $first -eq 0 ]; then printf "," >> "$out"; fi
        printf "%q" "$v" >> "$out"; first=0
      done
      echo "]}" >> "$out"
    done
  ' _ "${PATHS[db]}" "${PATHS[by_name]}"
}

_rg_index_rdeps_refresh() {
  # Recria reverse-deps.map a partir dos receipts
  _rg_flock "index" bash -c '
    base="$1"; out="$2"; : > "$out"
    # map: name->pkgid list
    # primeiro, construir pkgid por receipt
    while IFS= read -r r; do
      d="$(dirname "$r")"
      cat="$(echo "$d" | awk -F"/db/" "{print \$2}" | cut -d/ -f1)"
      name="$(echo "$d" | awk -F"/db/[^/]+/" "{print \$2}" | cut -d/ -f1)"
      tag="$(basename -- "$d")" # ver-arch-libc
      pkgid="$cat/$name@${tag}"
      # obter run_deps simples do receipt (sem jq)
      deps="$(grep -E '"'"'"run_deps"'"'"' "$r" | sed -E '"'s/.*"run_deps":[[:space:]]*\["?([^"]*)"?\].*/\1/'"')"
      # deps no formato "dep1,dep2" no metafile; recibo tem ["..."] se originado do pack.
      # faremos split por vírgula/space
      IFS=',' read -r -a arr <<<"$deps"
      for dd in "${arr[@]}"; do
        dd="${dd//[\[\]\"]}" ; dd="${dd// /}"
        [ -z "$dd" ] && continue
        printf "{\"pkg\":%q,\"depends_on\":%q}\n" "$pkgid" "$dd" >> "$out.tmp"
      done
    done < <(find "$base" -type f -name "receipt.json" -print | LC_ALL=C sort)
    # inverter (dep -> quem depende)
    if [ -f "$out.tmp" ]; then
      awk -F\" '"'{print $8}'"' "$out.tmp" | sort -u | while read -r dep; do
        [ -z "$dep" ] && continue
        echo -n "{\"dep\":"
        printf "%q" "$dep"
        echo -n ",\"rdeps\":["
        first=1
        grep -F "\"$dep\"" "$out.tmp" | awk -F\" '"'{print $4}'"' | while read -r p; do
          if [ $first -eq 0 ]; then echo -n ","; fi
          printf "%q" "$p"
          first=0
        done
        echo "]}"
      done > "$out"
      rm -f -- "$out.tmp"
    else
      : > "$out"
    fi
  ' _ "${PATHS[db]}" "${PATHS[rdeps]}"
}

###############################################################################
# Add (registra uma instalação) e Remove (desregistra)
###############################################################################
adm_registry_add() {
  local cat="$1" name="$2" ver="$3" arch="$4" libc="$5"; shift 5 || true
  local meta="" root="/" ; RG[root]="/"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) meta="$2"; shift 2;;
      --root) RG[root]="$2"; root="$2"; shift 2;;
      *) reg_warn "flag desconhecida: $1"; shift;;
    esac
  done
  _rg_paths_init || return $?
  [[ -d "$meta" ]] || { reg_err "--from <metadir> inválido: $meta"; return 1; }

  _rg_parse_metadir "$meta" || return $?
  local pkgid; pkgid="$(_rg_pkg_id "$cat" "$name" "$ver" "$arch" "$libc")"
  local pdir; pdir="$(_rg_pkg_dir "$cat" "$name" "$ver" "$arch" "$libc")"
  mkdir -p -- "$pdir/meta" || { reg_err "falha ao criar $pdir"; return 3; }

  adm_step "registry" "$pkgid" "gravando receipt/manifest"
  # receipt.json básico (usa index.json se existir)
  local receipt
  if [[ -r "$R_META_INDEX" ]]; then
    # snapshot do index com campos extras
    local tarball_sha="$(grep -E '"'"'"tarball_sha256"'"'"' ${R_META_INDEX} 2>/dev/null | head -n1 | sed -E '"s/.*: *\"?([0-9a-f]{64}).*/\1/"')"
    receipt=$(cat <<EOF
{
  "name": "$name",
  "category": "$cat",
  "version": "$ver",
  "arch": "$arch",
  "libc": "$libc",
  "build_type": "",
  "installed_at": "$(_rg_now_iso)",
  "install_id": "$(_rg_uuid)",
  "profile": "",
  "run_deps": [],
  "build_deps": [],
  "opt_deps": [],
  "source": { "sources": [], "sha256sums": [] },
  "pack": { "tarball": "", "tarball_sha256": "$tarball_sha", "manifest_sha256": "" },
  "installer": { "user": "$(id -u):$(id -g)", "host": "$(hostname)", "root": "$root", "adm_version": "${RG[adm_version]}", "scripts": { "install": "10-adm-install.sh", "pack": "15-adm-pack.sh" } }
}
EOF
)
  else
    receipt=$(cat <<EOF
{
  "name": "$name",
  "category": "$cat",
  "version": "$ver",
  "arch": "$arch",
  "libc": "$libc",
  "installed_at": "$(_rg_now_iso)",
  "install_id": "$(_rg_uuid)"
}
EOF
)
  fi
  _rg_write_atomic "${pdir}/receipt.json" "$receipt" || return $?

  # copiar manifest/triggers/index snapshots
  cp -f -- "$R_META_MAN" "${pdir}/manifest.txt" 2>>"${PATHS[log_add]}" || { reg_err "falha ao copiar manifest"; return 3; }
  [[ -r "$R_META_TRIG"  ]] && cp -f -- "$R_META_TRIG" "${pdir}/triggers.json" 2>>"${PATHS[log_add]}" || true
  [[ -r "$R_META_INDEX" ]] && cp -f -- "$R_META_INDEX" "${pdir}/meta/index.json" 2>>"${PATHS[log_add]}" || true

  # gerar files.list a partir do manifest
  awk -F'\t' '/^[FS]\t/ {print $2}' "${pdir}/manifest.txt" | sed 's#^\./#/#; s#^//#/#' > "${pdir}/files.list" 2>>"${PATHS[log_add]}" || {
    reg_err "falha ao gerar files.list"; return 3; }

  # índices
  adm_step "registry" "$pkgid" "atualizando índices"
  _rg_index_by_name_refresh || return $?
  _rg_index_rdeps_refresh || return $?
  # by-file.map: append para este pacote
  _rg_index_by_file_add "$pkgid" "${pdir}/manifest.txt" || return $?

  adm_ok "registrado: $pkgid"
}

adm_registry_remove() {
  local cat="$1" name="$2" ver="$3" arch="$4" libc="$5"; shift 5 || true
  local root="/" ; RG[root]="/"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root) RG[root]="$2"; root="$2"; shift 2;;
      *) reg_warn "flag desconhecida: $1"; shift;;
    esac
  done
  _rg_paths_init || return $?

  local pdir; pdir="$(_rg_pkg_dir "$cat" "$name" "$ver" "$arch" "$libc")"
  [[ -d "$pdir" ]] || { reg_err "registro não encontrado: $cat/$name@$ver-$arch-$libc"; return 3; }
  local pkgid; pkgid="$(_rg_pkg_id "$cat" "$name" "$ver" "$arch" "$libc")"

  adm_step "registry" "$pkgid" "removendo registro"
  rm -rf -- "$pdir" 2>>"${PATHS[log_rm]}" || { reg_err "falha ao remover $pdir"; return 3; }

  adm_step "registry" "$pkgid" "recriando índices"
  _rg_index_by_name_refresh || return $?
  _rg_index_rdeps_refresh || return $?
  # by-file.map precisa de rebuild completo (mais seguro)
  : > "${PATHS[by_file]}" || true
  while IFS= read -r -d '' man; do
    local d; d="$(dirname "$man")"
    local catn name ntag
    catn="$(echo "$d" | awk -F"/db/" '{print $2}' | cut -d/ -f1)"
    name="$(echo "$d" | awk -F"/db/[^/]+/" '{print $2}' | cut -d/ -f1)"
    ntag="$(basename -- "$d")"
    _rg_index_by_file_add "$catn/$name@${ntag}" "$man" || true
  done < <(find "${PATHS[db]}" -type f -name manifest.txt -print0)
  adm_ok "removido: $pkgid"
}

###############################################################################
# Consultas: info/list/files/owner/deps/rdeps/orphans
###############################################################################
adm_registry_info() {
  local q="$1"; shift || true
  _rg_paths_init || return $?
  [[ -n "$q" ]] || { reg_err "uso: adm_registry info <cat>/<name>[@ver]"; return 1; }
  local cat="${q%%/*}" rest="${q#*/}" name="${rest%%@*}" ver="${rest#*@}"
  if [[ "$ver" == "$rest" ]]; then
    # escolher a versão mais recente (lexicográfica)
    local d="${PATHS[db]}/${cat}/${name}"
    [[ -d "$d" ]] || { reg_err "pacote não instalado: $cat/$name"; return 3; }
    ver="$(ls -1 "$d" | sort | tail -n1)"
  fi
  local p="${PATHS[db]}/${cat}/${name}/${ver}/receipt.json"
  [[ -r "$p" ]] || { reg_err "receipt não encontrado: $q"; return 3; }
  cat "$p"
}

adm_registry_list() {
  _rg_paths_init || return $?
  local q="${1:-}"
  if [[ -z "$q" ]]; then
    find "${PATHS[db]}" -mindepth 3 -maxdepth 3 -type d | while read -r d; do
      local cat; cat="$(echo "$d" | awk -F"/db/" '{print $2}' | cut -d/ -f1)"
      local name; name="$(basename -- "$d")"
      local vers; vers="$(find "$d" -maxdepth 1 -type d -name "*-*-*" -printf "%f\n" | sort | xargs)"
      echo "$cat/$name: $vers"
    done
  else
    local cat="${q%%/*}" name="${q#*/}"
    find "${PATHS[db]}/${cat}/${name}" -maxdepth 1 -type d -name "*-*-*" -printf "%f\n" 2>/dev/null | sort
  fi
}

adm_registry_files() {
  local q="$1"; shift || true
  _rg_paths_init || return $?
  [[ -n "$q" ]] || { reg_err "uso: adm_registry files <cat>/<name>[@ver]"; return 1; }
  local cat="${q%%/*}" rest="${q#*/}" name="${rest%%@*}" ver="${rest#*@}"
  if [[ "$ver" == "$rest" ]]; then
    ver="$(ls -1 "${PATHS[db]}/${cat}/${name}" 2>/dev/null | sort | tail -n1)"
  fi
  local f="${PATHS[db]}/${cat}/${name}/${ver}/files.list"
  [[ -r "$f" ]] || { reg_err "files.list não encontrado: $q"; return 3; }
  cat "$f"
}

adm_registry_owner() {
  local path="$1"; shift || true
  _rg_paths_init || return $?
  [[ -n "$path" ]] || { reg_err "uso: adm_registry owner <PATH>"; return 1; }
  path="${path%/}"
  [[ -r "${PATHS[by_file]}" ]] || { reg_err "índice by-file.map ausente; rode: adm_registry check-index"; return 4; }
  grep -F "\"${path}\"" "${PATHS[by_file]}" | awk -F'"' '{print $8}' | sort -u
}

adm_registry_deps() {
  local q="$1"; shift || true
  _rg_paths_init || return $?
  local cat="${q%%/*}" rest="${q#*/}" name="${rest%%@*}" ver="${rest#*@}"
  if [[ "$ver" == "$rest" ]]; then
    ver="$(ls -1 "${PATHS[db]}/${cat}/${name}" 2>/dev/null | sort | tail -n1)"
  fi
  local r="${PATHS[db]}/${cat}/${name}/${ver}/receipt.json"
  [[ -r "$r" ]] || { reg_err "receipt não encontrado: $q"; return 3; }
  grep -E '"run_deps"| "build_deps"| "opt_deps"' "$r" || true
}

adm_registry_rdeps() {
  local q="$1"; shift || true
  _rg_paths_init || return $?
  [[ -r "${PATHS[rdeps]}" ]] || { reg_err "reverse-deps.map ausente; rode: adm_registry check-index"; return 4; }
  local cat="${q%%/*}" rest="${q#*/}" name="${rest%%@*}" ver="${rest#*@}"
  if [[ "$ver" == "$rest" ]]; then
    ver="$(ls -1 "${PATHS[db]}/${cat}/${name}" 2>/dev/null | sort | tail -n1)"
  fi
  # rdeps com base no nome (não versão): dep == cat/name
  local dep="${cat}/${name}"
  grep -F "\"$dep\"" "${PATHS[rdeps]}" || true
}

adm_registry_orphans() {
  _rg_paths_init || return $?
  [[ -r "${PATHS[rdeps]}" ]] || _rg_index_rdeps_refresh || true
  # construir conjunto de todos os pacotes instalados
  declare -A ALL=() USED=() HOLD=()
  [[ -r "${PATHS[hold]}" ]] && while read -r h; do HOLD["$h"]=1; done < <(grep -vE '^\s*$|^\s*#' "${PATHS[hold]}" 2>/dev/null)
  while IFS= read -r -d '' d; do
    local cat; cat="$(echo "$d" | awk -F"/db/" '{print $2}' | cut -d/ -f1)"
    local name; name="$(echo "$d" | awk -F"/db/[^/]+/" '{print $2}' | cut -d/ -f1)"
    local tag; tag="$(basename -- "$d")"
    ALL["$cat/$name@${tag}"]=1
  done < <(find "${PATHS[db]}" -maxdepth 4 -type d -name "*-*-*" -print0)
  # marcar usados
  while read -r line; do
    local list; list="$(echo "$line" | sed -E 's/.*"rdeps":\[(.*)\].*/\1/')" || true
    IFS=',' read -r -a arr <<<"$list"
    for p in "${arr[@]}"; do p="${p//[\"]}"; [[ -n "$p" ]] && USED["$p"]=1; done
  done < "${PATHS[rdeps]}" 2>/dev/null
  for p in "${!ALL[@]}"; do
    [[ -n "${USED[$p]:-}" ]] && continue
    [[ -n "${HOLD[$p]:-}" ]] && continue
    echo "$p"
  done | sort
}

###############################################################################
# Verificação (manifesto vs FS) — modo normal e estrito
###############################################################################
adm_registry_verify() {
  local q="$1"; shift || true
  local strict=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict) strict=true; shift;;
      --root) RG[root]="$2"; shift 2;;
      *) reg_warn "flag desconhecida: $1"; shift;;
    esac
  done
  _rg_paths_init || return $?
  [[ -n "$q" ]] || { reg_err "uso: adm_registry verify <cat>/<name>[@ver] [--strict] [--root DIR]"; return 1; }
  local cat="${q%%/*}" rest="${q#*/}" name="${rest%%@*}" ver="${rest#*@}"
  if [[ "$ver" == "$rest" ]]; then
    ver="$(ls -1 "${PATHS[db]}/${cat}/${name}" 2>/dev/null | sort | tail -n1)"
  fi
  local man="${PATHS[db]}/${cat}/${name}/${ver}/manifest.txt"
  [[ -r "$man" ]] || { reg_err "manifesto não encontrado: $q"; return 3; }

  local root="${RG[root]%/}"
  adm_step "registry" "$q" "verificando (root=$root, strict=$strict)"
  local fails=0
  while IFS=$'\t' read -r kind path a b; do
    [[ -z "$kind" || -z "$path" ]] && continue
    # normaliza
    local real="${root}${path}"
    case "$kind" in
      F)
        if [[ ! -f "$real" ]]; then echo "MISSING: $path" >> "${PATHS[log_verify]}"; fails=$((fails+1)); continue; fi
        if $strict; then
          local got; got="$(sha256sum "$real" | awk '{print $1}')"
          local exp="$a" # no manifesto F\tpath\tsum\tmode\tsize
          [[ "$got" == "$exp" ]] || { echo "SHA MISMATCH: $path (got=$got exp=$exp)" >> "${PATHS[log_verify]}"; fails=$((fails+1)); }
        fi
        ;;
      S)
        [[ -L "$real" ]] || { echo "MISSING-SYMLINK: $path" >> "${PATHS[log_verify]}"; fails=$((fails+1)); }
        ;;
      D)
        [[ -d "$real" ]] || { echo "MISSING-DIR: $path" >> "${PATHS[log_verify]}"; fails=$((fails+1)); }
        ;;
    esac
  done < "$man"
  if (( fails > 0 )); then
    reg_err "verificação encontrou $fails problema(s) — veja: ${PATHS[log_verify]}"
    return 4
  fi
  adm_ok "verificação OK"
}
# 16-adm-registry.part3.sh
# History, export/import, holds, check-index, GC e CLI
if [[ -n "${ADM_REGISTRY_LOADED_PART3:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_REGISTRY_LOADED_PART3=1
###############################################################################
# History (txlog)
###############################################################################
adm_registry_history() {
  local since="" grepq="" json=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) since="$2"; shift 2;;
      --grep) grepq="$2"; shift 2;;
      --json) json=true; shift;;
      *) reg_warn "flag desconhecida: $1"; shift;;
    esac
  done
  _rg_paths_init || return $?
  local dir="${PATHS[tx]}"
  [[ -d "$dir" ]] || { reg_err "txlog ausente"; return 3; }
  local files=()
  if [[ -n "$since" ]]; then
    local ym="${since:0:7}"; ym="${ym//-}"
    files=( $(ls -1 "${dir}/adm-tx-${ym}"*.jsonl 2>/dev/null) )
  else
    files=( $(ls -1 "${dir}/adm-tx-"*.jsonl 2>/dev/null) )
  fi
  ((${#files[@]})) || { reg_warn "nenhum txlog para o período"; return 0; }
  if $json; then
    cat "${files[@]}"
  else
    if [[ -n "$grepq" ]]; then
      grep -i -- "$grepq" "${files[@]}"
    else
      cat "${files[@]}"
    fi
  fi
}

###############################################################################
# Export / Import
###############################################################################
adm_registry_export() {
  local out="${1:-registry-export.tar.zst}"
  _rg_paths_init || return $?
  local root="${RG[root]%/}"
  adm_step "registry" "" "exportando registry para $out"
  tar -C "${root%/}/usr/src/adm/state" -cpf - registry | zstd -19 -q > "$out" || {
    reg_err "falha ao exportar"; return 3; }
  adm_ok "exportado: $out"
}

adm_registry_import() {
  local in="$1"
  [[ -r "$in" ]] || { reg_err "arquivo não encontrado: $in"; return 3; }
  _rg_paths_init || return $?
  local root="${RG[root]%/}"
  adm_step "registry" "" "importando de $in"
  zstd -dc "$in" | tar -C "${root%/}/usr/src/adm/state" -xpf - || { reg_err "falha ao importar"; return 3; }
  adm_ok "importado"
}

###############################################################################
# HOLD / UNHOLD
###############################################################################
adm_registry_set_hold() {
  local q="$1" unset=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --unset) unset=true; shift;;
      *) q="${q:-$1}"; shift;;
    esac
  done
  _rg_paths_init || return $?
  [[ -n "$q" ]] || { reg_err "uso: adm_registry set-hold <cat>/<name>@ver-arch-libc [--unset]"; return 1; }
  touch "${PATHS[hold]}" 2>/dev/null || { reg_err "não foi possível tocar holds.list"; return 3; }
  if $unset; then
    grep -v -F "$q" "${PATHS[hold]}" > "${PATHS[hold]}.tmp" && mv -f -- "${PATHS[hold]}.tmp" "${PATHS[hold]}"
    adm_ok "unhold: $q"
  else
    grep -Fqx "$q" "${PATHS[hold]}" || echo "$q" >> "${PATHS[hold]}"
    adm_ok "hold: $q"
  fi
}

###############################################################################
# Check-index e GC (reindex completo e limpeza)
###############################################################################
adm_registry_check_index() {
  _rg_paths_init || return $?
  adm_step "registry" "" "recriando índices"
  : > "${PATHS[by_file]}" 2>/dev/null || true
  _rg_index_by_name_refresh || return $?
  _rg_index_rdeps_refresh || return $?
  while IFS= read -r -d '' man; do
    local d; d="$(dirname "$man")"
    local cat; cat="$(echo "$d" | awk -F"/db/" '{print $2}' | cut -d/ -f1)"
    local name; name="$(echo "$d" | awk -F"/db/[^/]+/" '{print $2}' | cut -d/ -f1)"
    local tag; tag="$(basename -- "$d")"
    _rg_index_by_file_add "$cat/$name@${tag}" "$man" || true
  done < <(find "${PATHS[db]}" -type f -name manifest.txt -print0)
  adm_ok "índices OK"
}

adm_registry_gc() {
  _rg_paths_init || return $?
  adm_step "registry" "" "GC/verificação de consistência"
  # remover diretórios vazios e reconstruir índices
  find "${PATHS[db]}" -type d -empty -delete 2>>"${PATHS[log_idx]}" || true
  adm_registry_check_index || return $?
  adm_ok "GC concluído"
}

###############################################################################
# Ajuda e CLI
###############################################################################
_reg_usage() {
  cat >&2 <<'EOF'
uso:
  adm_registry begin-tx <op> [--root DIR] [--reason MSG]
  adm_registry commit-tx | abort-tx
  adm_registry add <cat> <name> <ver> <arch> <libc> --from <meta_dir> [--root DIR]
  adm_registry remove <cat> <name> <ver> <arch> <libc> [--root DIR]
  adm_registry info <cat>/<name>[@ver]
  adm_registry list [<cat>/<name>]
  adm_registry files <cat>/<name>[@ver]
  adm_registry owner <PATH>
  adm_registry deps <cat>/<name>[@ver]
  adm_registry rdeps <cat>/<name>[@ver]
  adm_registry orphans
  adm_registry verify <cat>/<name>[@ver] [--strict] [--root DIR]
  adm_registry history [--since YYYY-MM-DD] [--grep STR] [--json]
  adm_registry export [outfile.tar.zst]
  adm_registry import <infile.tar.zst>
  adm_registry set-hold <cat>/<name>@ver-arch-libc [--unset]
  adm_registry check-index
  adm_registry gc
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="$1"; shift || true
  case "$cmd" in
    begin-tx)     adm_registry_begin_tx "$@" || exit $?;;
    commit-tx)    adm_registry_commit_tx "$@" || exit $?;;
    abort-tx)     adm_registry_abort_tx "$@" || exit $?;;
    add)          adm_registry_add "$@" || exit $?;;
    remove)       adm_registry_remove "$@" || exit $?;;
    info)         adm_registry_info "$@" || exit $?;;
    list)         adm_registry_list "$@" || exit $?;;
    files)        adm_registry_files "$@" || exit $?;;
    owner)        adm_registry_owner "$@" || exit $?;;
    deps)         adm_registry_deps "$@" || exit $?;;
    rdeps)        adm_registry_rdeps "$@" || exit $?;;
    orphans)      adm_registry_orphans "$@" || exit $?;;
    verify)       adm_registry_verify "$@" || exit $?;;
    history)      adm_registry_history "$@" || exit $?;;
    export)       adm_registry_export "$@" || exit $?;;
    import)       adm_registry_import "$@" || exit $?;;
    set-hold)     adm_registry_set_hold "$@" || exit $?;;
    check-index)  adm_registry_check_index "$@" || exit $?;;
    gc)           adm_registry_gc "$@" || exit $?;;
    ""|help|-h|--help) _reg_usage; exit 2;;
    *) reg_warn "comando desconhecido: $cmd"; _reg_usage; exit 2;;
  esac
fi

ADM_REGISTRY_LOADED=1
export ADM_REGISTRY_LOADED
