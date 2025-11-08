#!/usr/bin/env bash
# 17-adm-clean.part1.sh
# Limpeza segura do ecossistema ADM (dry-run por padrão).
###############################################################################
# Guardas e pré-requisitos
###############################################################################
if [[ -n "${ADM_CLEAN_LOADED_PART1:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_CLEAN_LOADED_PART1=1

for _m in ADM_CONF_LOADED ADM_LIB_LOADED; do
  if [[ -z "${!_m:-}" ]]; then
    echo "ERRO: 17-adm-clean requer módulos básicos carregados (00/01). Faltando: ${_m}" >&2
    return 2 2>/dev/null || exit 2
  fi
done

###############################################################################
# Defaults e contexto
###############################################################################
: "${ADM_STATE_ROOT:=/usr/src/adm/state}"
: "${ADM_CACHE_ROOT:=/usr/src/adm/cache}"
: "${ADM_TMP_ROOT:=/usr/src/adm/tmp}"

clean_err()  { adm_err "$*"; }
clean_warn() { adm_warn "$*"; }
clean_info() { adm_log INFO "clean" "${C_CTX:-}" "$*"; }

declare -Ag C=(
  [root]="/" [level]="quick" [days]="" [keep]="" [size_limit]="" [only]="" [exclude]="" [json]="false"
  [simulate]="true" [confirm_purge]="false" [quarantine]="false"
  [cat]="" [name]="" [arch]="" [libc]="" [stage]=""
)
declare -Ag P=()   # paths
declare -Ag STATS=( [tmp_del]=0 [tmp_bytes]=0 [src_del]=0 [src_bytes]=0 [bin_del]=0 [bin_bytes]=0
                    [logs_del]=0 [logs_bytes]=0 [boot_del]=0 [boot_bytes]=0 [reg_fix]=0 )

###############################################################################
# Paths calculados por --root
###############################################################################
_clean_paths_init() {
  local r="${C[root]%/}"
  P[root]="$r"
  P[adm]="${r}/usr/src/adm"
  P[tmp]="${ADM_TMP_ROOT/#\/usr\/src\/adm/${P[adm]}}"
  P[state]="${r}/usr/src/adm/state"
  P[cache]="${ADM_CACHE_ROOT/#\/usr\/src\/adm/${P[adm]}}"
  P[logs]="${P[state]}/logs/clean"
  mkdir -p -- "${P[logs]}" || { clean_err "não foi possível criar ${P[logs]}"; return 3; }
  P[log_tmp]="${P[logs]}/tmp.log"
  P[log_src]="${P[logs]}/src.log"
  P[log_bin]="${P[logs]}/bin.log"
  P[log_logs]="${P[logs]}/logs.log"
  P[log_boot]="${P[logs]}/bootstrap.log"
  P[log_reg]="${P[logs]}/registry.log"
}

###############################################################################
# Utilidades gerais
###############################################################################
_clean_nproc() { command -v nproc >/dev/null 2>&1 && nproc || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1; }

_clean_bytes() { # converte "123", "10MiB", "2GiB" -> bytes
  local v="$1"
  if [[ "$v" =~ ^[0-9]+$ ]]; then echo "$v"; return 0; fi
  local num unit; num="${v//[!0-9]/}"; unit="${v//$num/}"; unit="${unit^^}"
  case "$unit" in
    B|"") echo "$num";;
    K|KB) echo $((num*1000));;
    M|MB) echo $((num*1000*1000));;
    G|GB) echo $((num*1000*1000*1000));;
    KI|KIB) echo $((num*1024));;
    MI|MIB) echo $((num*1024*1024));;
    GI|GIB) echo $((num*1024*1024*1024));;
    *) echo 0;;
  esac
}

_clean_age_days() { # retorna idade (dias inteiros) desde mtime
  local f="$1"; local now; now=$(date +%s)
  local mt; mt=$(stat -c %Y "$f" 2>/dev/null || echo "$now")
  echo $(( (now - mt) / 86400 ))
}

_clean_realpath() { # realpath -m compat
  if command -v realpath >/dev/null 2>&1; then realpath -m -- "$1"; else
    (cd "$(dirname -- "$1")" 2>/dev/null && echo "$(pwd -P)/$(basename -- "$1")") 2>/dev/null || echo "$1"
  fi
}

_clean_within_adm() { # garante que o path está dentro de /usr/src/adm (ajustado por root)
  local rp="$(_clean_realpath "$1")"
  [[ "$rp" == "${P[adm]}"* ]]
}

_clean_should_skip() { # aplica excludes globais
  local p="$1" g
  IFS=$'\n' read -r -d '' -a arr < <(printf "%s" "${C[exclude]}" | tr ' ' '\n' | sed '/^$/d' && printf '\0')
  for g in "${arr[@]}"; do
    [[ -z "$g" ]] && continue
    [[ "$p" == $g ]] && return 0
  done
  return 1
}

_clean_del() { # _clean_del <path> <logfile> <stat_key_count> <stat_key_bytes>
  local p="$1" log="$2" kcnt="$3" kbytes="$4"
  _clean_within_adm "$p" || { clean_warn "fora do escopo ADM (ignorado): $p"; return 4; }
  _clean_should_skip "$p" && { echo "skip: $p" >> "$log"; return 0; }
  local sz=0
  if [[ -e "$p" ]]; then
    if [[ -d "$p" && ! -L "$p" ]]; then
      sz=$(du -sb "$p" 2>/dev/null | awk '{print $1}')
    else
      sz=$(stat -c %s "$p" 2>/dev/null || echo 0)
    fi
  fi
  if [[ "${C[simulate]}" == "true" ]]; then
    echo "[sim] rm -rf -- $p" >> "$log"
  else
    rm -rf -- "$p" >>"$log" 2>&1 || { clean_warn "falha ao remover: $p (continua)"; return 3; }
    echo "rm -rf -- $p" >> "$log"
  fi
  STATS["$kcnt"]=$(( ${STATS["$kcnt"]} + 1 ))
  STATS["$kbytes"]=$(( ${STATS["$kbytes"]} + sz ))
}

_clean_rm_find() { # _clean_rm_find <base> <find-expr...> --log <log> --statc <kcnt> --statb <kbytes>
  local base="$1"; shift
  local log="" kcnt="" kbytes="" expr=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --log) log="$2"; shift 2;;
      --statc) kcnt="$2"; shift 2;;
      --statb) kbytes="$2"; shift 2;;
      *) expr+=("$1"); shift;;
    esac
  done
  [[ -d "$base" ]] || return 0
  while IFS= read -r -d '' p; do
    _clean_del "$p" "$log" "$kcnt" "$kbytes"
  done < <(eval "find \"\$base\" ${expr[*]} -print0")
}

###############################################################################
# Parsing de flags comuns
###############################################################################
_clean_parse_common_flags() {
  # popula C[*] a partir da CLI do comando atual
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root) C[root]="$2"; shift 2;;
      --level) C[level]="$2"; shift 2;;
      --days)  C[days]="$2"; shift 2;;
      --keep)  C[keep]="$2"; shift 2;;
      --size-limit) C[size_limit]="$2"; shift 2;;
      --cat) C[cat]="$2"; shift 2;;
      --name) C[name]="$2"; shift 2;;
      --arch) C[arch]="$2"; shift 2;;
      --libc) C[libc]="$2"; shift 2;;
      --stage) C[stage]="$2"; shift 2;;
      --only) C[only]="${C[only]} $2"; shift 2;;
      --exclude-glob) C[exclude]="${C[exclude]} $2"; shift 2;;
      --json|--print-json) C[json]="true"; shift;;
      --simulate) C[simulate]="true"; shift;;
      --yes) C[simulate]="false"; shift;;
      --confirm-purge) C[confirm_purge]="true"; shift;;
      --quarantine) C[quarantine]="true"; shift;;
      --no-quarantine) C[quarantine]="false"; shift;;
      *) clean_warn "flag desconhecida: $1"; shift;;
    esac
  done

  # defaults por nível
  case "${C[level]}" in
    quick) : "${C[days]:=14}";;
    deep)  : "${C[days]:=30}"; : "${C[keep]:=3}";;
    purge) : "${C[days]:=0}";  : "${C[keep]:=1}";;
    *) clean_warn "level desconhecido, usando quick"; C[level]="quick"; : "${C[days]:=14}";;
  esac

  # segurança extra para purge
  if [[ "${C[level]}" == "purge" && "${C[simulate]}" == "false" && "${C[confirm_purge]}" != "true" ]]; then
    clean_err "purge exige --yes --confirm-purge"; return 1
  fi

  _clean_paths_init || return $?
  return 0
}

###############################################################################
# Relatórios/JSON
###############################################################################
_clean_stats_json() {
  printf '{'
  printf '"tmp":{"deleted":%d,"bytes":%d},'    "${STATS[tmp_del]}" "${STATS[tmp_bytes]}"
  printf '"src":{"deleted":%d,"bytes":%d},'    "${STATS[src_del]}" "${STATS[src_bytes]}"
  printf '"bin":{"deleted":%d,"bytes":%d},'    "${STATS[bin_del]}" "${STATS[bin_bytes]}"
  printf '"logs":{"deleted":%d,"bytes":%d},'   "${STATS[logs_del]}" "${STATS[logs_bytes]}"
  printf '"bootstrap":{"deleted":%d,"bytes":%d},' "${STATS[boot_del]}" "${STATS[boot_bytes]}"
  printf '"registry":{"fixes":%d},'            "${STATS[reg_fix]}"
  local total=$(( STATS[tmp_bytes]+STATS[src_bytes]+STATS[bin_bytes]+STATS[logs_bytes]+STATS[boot_bytes] ))
  printf '"total_bytes":%d' "$total"
  printf '}\n'
}
# 17-adm-clean.part2.sh
# Implementações de áreas: tmp/src/bin/logs/bootstrap/registry
if [[ -n "${ADM_CLEAN_LOADED_PART2:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_CLEAN_LOADED_PART2=1
###############################################################################
# TMP / WORKDIRS
###############################################################################
_clean_tmp() {
  adm_step "clean" "tmp" "varrendo temporários"
  local min_days="${C[days]}"
  [[ -d "${P[tmp]}" ]] || { echo "sem tmp em ${P[tmp]}" > "${P[log_tmp]}"; return 0; }

  # Remover *.tmp, *.part, diretórios de trabalho antigos
  _clean_rm_find "${P[tmp]}" \
    -type f \( -name '*.tmp' -o -name '*.part' -o -name '*.aria2' -o -name '*.log.old' \) -mtime +${min_days} -print0 \
    --log "${P[log_tmp]}" --statc tmp_del --statb tmp_bytes

  _clean_rm_find "${P[tmp]}" \
    -type d \( -name 'hooks-*' -o -name 'patch-*' -o -name '*.work' -o -name '*.tmp.d' \) -mtime +${min_days} -print0 \
    --log "${P[log_tmp]}" --statc tmp_del --statb tmp_bytes

  adm_ok "tmp: $((${STATS[tmp_bytes]} / 1024 / 1024)) MiB (estimado)"
}

###############################################################################
# CACHE DE FONTES (src)
###############################################################################
_clean_src() {
  adm_step "clean" "src" "varrendo cache de fontes"
  local src="${P[cache]}/src"
  [[ -d "$src" ]] || { echo "sem cache de fontes" > "${P[log_src]}"; return 0; }

  # Parciais comuns de download
  _clean_rm_find "$src" \
    -type f \( -name '*.part' -o -name '*.aria2' -o -name '*.tmp' -o -name '.partial*' \) -print0 \
    --log "${P[log_src]}" --statc src_del --statb src_bytes

  # Repositórios git: gc opcional e remoção por idade no modo deep/purge
  if [[ "${C[level]}" != "quick" ]]; then
    while IFS= read -r -d '' repo; do
      # gc seguro em simulado? apenas loga.
      if [[ "${C[simulate]}" == "true" ]]; then
        echo "[sim] git -C $repo gc --prune=now --aggressive" >> "${P[log_src]}"
      else
        git -C "$repo" gc --prune=now --aggressive >> "${P[log_src]}" 2>&1 || true
      fi
    done < <(find "$src" -type d -name '*.git' -print0)
    # mirrors muito antigos
    _clean_rm_find "$src" -type d -name '*.git' -mtime +${C[days]} -print0 \
      --log "${P[log_src]}" --statc src_del --statb src_bytes
  fi

  adm_ok "src: $((${STATS[src_bytes]} / 1024 / 1024)) MiB (estimado)"
}

###############################################################################
# CACHE BINÁRIO (bin)
###############################################################################
# Mantém N versões mais novas por cat/name, remove pares (tarball + .meta + .sha256 + .sig)
_clean_bin_prune_keep() {
  local root="${P[cache]}/bin"
  [[ -d "$root" ]] || { echo "sem cache binário" > "${P[log_bin]}"; return 0; }

  local filter_cat="${C[cat]}" filter_name="${C[name]}"
  local keep="${C[keep]:-3}"

  while IFS= read -r -d '' pkgdir; do
    local cat; cat="$(dirname "$pkgdir")"; cat="${cat#$root/}"
    local name; name="$(basename -- "$pkgdir")"

    [[ -n "$filter_cat" && "$cat" != "$filter_cat" ]] && continue
    [[ -n "$filter_name" && "$name" != "$filter_name" ]] && continue

    # Lista todos os tarballs desse name
    mapfile -t tars < <(find "$pkgdir" -maxdepth 1 -type f -name "${name}-*.tar.*" -printf "%T@ %p\n" \
                        | sort -rn | awk '{print $2}')
    (( ${#tars[@]} <= keep )) && continue

    # Mantém os primeiros 'keep', remove o resto e seus meta pares
    local i=0
    for t in "${tars[@]}"; do
      i=$((i+1))
      if (( i <= keep )); then continue; fi
      local base="${t%.tar.*}"
      _clean_del "$t" "${P[log_bin]}" bin_del bin_bytes
      _clean_del "${t}.sha256" "${P[log_bin]}" bin_del bin_bytes
      _clean_del "${t}.sig" "${P[log_bin]}" bin_del bin_bytes
      _clean_del "${base}.meta" "${P[log_bin]}" bin_del bin_bytes
    done
  done < <(find "$root" -mindepth 2 -maxdepth 2 -type d -print0)
}

_clean_bin_orphans_meta() {
  local root="${P[cache]}/bin"
  [[ -d "$root" ]] || return 0
  # .meta sem tarball correspondente
  while IFS= read -r -d '' meta; do
    local base="${meta%.meta}"
    local tb=""
    tb="$(ls -1 "${base}.tar."* 2>/dev/null | head -n1 || true)"
    [[ -n "$tb" ]] && continue
    _clean_del "$meta" "${P[log_bin]}" bin_del bin_bytes
  done < <(find "$root" -type d -name '*.meta' -print0)
}

_clean_bin() {
  adm_step "clean" "bin" "podando cache binário"
  _clean_bin_orphans_meta
  _clean_bin_prune_keep
  adm_ok "bin: $((${STATS[bin_bytes]} / 1024 / 1024)) MiB (estimado)"
}

###############################################################################
# LOGS (rotação + poda por idade/tamanho)
###############################################################################
_clean_logs() {
  adm_step "clean" "logs" "rotacionando e limpando logs"
  local lroot="${P[state]}/logs"
  [[ -d "$lroot" ]] || { echo "sem logs em ${lroot}" > "${P[log_logs]}"; return 0; }

  # Comprimir .log antigos
  while IFS= read -r -d '' f; do
    local age=$(_clean_age_days "$f")
    (( age <= C[days] )) && continue
    local gz="${f}.gz"
    if [[ "${C[simulate]}" == "true" ]]; then
      echo "[sim] gzip -n $f" >> "${P[log_logs]}"
    else
      gzip -n "$f" >> "${P[log_logs]}" 2>&1 || true
    fi
  done < <(find "$lroot" -type f -name '*.log' -print0)

  # Remover logs muito antigos/comprimidos
  _clean_rm_find "$lroot" -type f \( -name '*.log.gz' -o -name '*.jsonl' -o -name '*.old' \) -mtime +${C[days]} -print0 \
    --log "${P[log_logs]}" --statc logs_del --statb logs_bytes

  # Limite de tamanho opcional
  if [[ -n "${C[size_limit]}" ]]; then
    local lim=$(_clean_bytes "${C[size_limit]}")
    local cur; cur=$(du -sb "$lroot" 2>/dev/null | awk '{print $1}')
    while (( cur > lim )); do
      # remove o arquivo mais antigo
      local oldest; oldest="$(find "$lroot" -type f -printf '%T@ %p\n' | sort -n | head -n1 | cut -d' ' -f2-)"
      [[ -z "$oldest" ]] && break
      _clean_del "$oldest" "${P[log_logs]}" logs_del logs_bytes
      cur=$(du -sb "$lroot" 2>/dev/null | awk '{print $1}')
    done
  fi

  adm_ok "logs: $((${STATS[logs_bytes]} / 1024 / 1024)) MiB (estimado)"
}

###############################################################################
# BOOTSTRAP (stages antigos / chroots inativos)
###############################################################################
_clean_bootstrap() {
  adm_step "clean" "bootstrap" "limpando stages antigos"
  local broot="${P[state]}/bootstrap"
  [[ -d "$broot" ]] || { echo "sem bootstrap em ${broot}" > "${P[log_boot]}"; return 0; }
  local stage_filter="${C[stage]}"

  while IFS= read -r -d '' rf; do
    local st; st="$(basename -- "$(dirname -- "$rf")")" # stageN
    [[ -n "$stage_filter" && "$st" != "stage${stage_filter}" ]] && continue

    # evitar se estiver montado
    mountpoint -q "$rf" 2>/dev/null && { echo "montado (skip): $rf" >> "${P[log_boot]}"; continue; }

    local age=$(_clean_age_days "$rf")
    (( age < C[days] )) && continue

    _clean_del "$rf" "${P[log_boot]}" boot_del boot_bytes
  done < <(find "$broot" -maxdepth 2 -type d -name rootfs -print0)

  adm_ok "bootstrap: $((${STATS[boot_bytes]} / 1024 / 1024)) MiB (estimado)"
}

###############################################################################
# REGISTRY fix (índices)
###############################################################################
_clean_registry_fix() {
  adm_step "clean" "registry" "recriando índices"
  local reg="${P[state]}/registry"
  [[ -d "$reg" ]] || { echo "sem registry em ${reg}" > "${P[log_reg]}"; return 0; }

  if command -v adm_registry_check_index >/dev/null 2>&1; then
    if [[ "${C[simulate]}" == "true" ]]; then
      echo "[sim] adm_registry check-index" >> "${P[log_reg]}"
    else
      adm_registry_check_index >> "${P[log_reg]}" 2>&1 || true
    fi
    STATS[reg_fix]=$((STATS[reg_fix]+1))
  else
    echo "adm_registry_check_index não disponível (pulei)" >> "${P[log_reg]}"
  fi
  adm_ok "registry: índices verificados"
}
# 17-adm-clean.part3.sh
# CLI: run, report, quarantine, prune-bin, rotate-logs
if [[ -n "${ADM_CLEAN_LOADED_PART3:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_CLEAN_LOADED_PART3=1
###############################################################################
# Áreas e execução coordenada
###############################################################################
_clean_should_run_area() {
  local area="$1"
  [[ -z "${C[only]// /}" ]] && return 0
  [[ " ${C[only]} " == *" ${area} "* ]]
}

adm_clean_run() {
  STATS=( [tmp_del]=0 [tmp_bytes]=0 [src_del]=0 [src_bytes]=0 [bin_del]=0 [bin_bytes]=0
          [logs_del]=0 [logs_bytes]=0 [boot_del]=0 [boot_bytes]=0 [reg_fix]=0 )
  _clean_parse_common_flags "$@" || return $?
  C_CTX="level=${C[level]} simulate=${C[simulate]} days=${C[days]} keep=${C[keep]:-n/a}"
  adm_step "clean" "run" "$C_CTX"

  # segurança máxima: só trabalha sob /usr/src/adm no --root
  if [[ ! -d "${P[adm]}" ]]; then
    clean_err "prefixo ADM inexistente: ${P[adm]}"
    return 4
  fi

  _clean_should_run_area tmp       && _clean_tmp
  _clean_should_run_area src       && _clean_src
  _clean_should_run_area bin       && _clean_bin
  _clean_should_run_area logs      && _clean_logs
  _clean_should_run_area bootstrap && _clean_bootstrap
  _clean_should_run_area registry  && _clean_registry_fix

  local total=$(( STATS[tmp_bytes]+STATS[src_bytes]+STATS[bin_bytes]+STATS[logs_bytes]+STATS[boot_bytes] ))
  adm_ok "TOTAL (estimado): $((total/1024/1024)) MiB | simulate=${C[simulate]}"
  [[ "${C[json]}" == "true" ]] && _clean_stats_json
}

adm_clean_report() {
  # alias para run --simulate + --json opcional
  local args=( "$@" )
  args+=( --simulate )
  adm_clean_run "${args[@]}"
}

###############################################################################
# Quarantine (fontes/artefatos corrompidos)
###############################################################################
adm_clean_quarantine() {
  local days=7
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days) days="$2"; shift 2;;
      --root|--level|--keep|--size-limit|--cat|--name|--arch|--libc|--stage|--only|--exclude-glob|--json|--simulate|--yes|--confirm-purge|--quarantine|--no-quarantine)
        # encaminhar para parser comum
        set -- "$@" "$1" "${2:-}"; shift;;
      *) clean_warn "flag desconhecida: $1"; shift;;
    esac
  done
  _clean_parse_common_flags "$@" || return $?
  local qdir="${P[cache]}/quarantine"
  mkdir -p -- "$qdir" || { clean_err "não foi possível criar $qdir"; return 3; }

  adm_step "clean" "quarantine" "purga > ${days}d"
  _clean_rm_find "$qdir" -type f -mtime +${days} -print0 \
    --log "${P[log_src]}" --statc src_del --statb src_bytes
  adm_ok "quarantine: $((${STATS[src_bytes]} / 1024 / 1024)) MiB (estimado)"
}

###############################################################################
# prune-bin (somente cache binário)
###############################################################################
adm_clean_prune_bin() {
  local keep="3"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep) keep="$2"; shift 2;;
      --cat) C[cat]="$2"; shift 2;;
      --name) C[name]="$2"; shift 2;;
      --root|--simulate|--yes|--json) set -- "$@" "$1" "${2:-}"; shift;;
      *) clean_warn "flag desconhecida: $1"; shift;;
    esac
  done
  _clean_parse_common_flags "$@" || return $?
  C[level]="deep"; C[keep]="$keep"
  _clean_bin
  [[ "${C[json]}" == "true" ]] && _clean_stats_json
}

###############################################################################
# rotate-logs (somente logs)
###############################################################################
adm_clean_rotate_logs() {
  local days="14" size=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days) days="$2"; shift 2;;
      --size-limit) size="$2"; shift 2;;
      --root|--simulate|--yes|--json) set -- "$@" "$1" "${2:-}"; shift;;
      *) clean_warn "flag desconhecida: $1"; shift;;
    esac
  done
  _clean_parse_common_flags "$@" || return $?
  C[days]="$days"; C[size_limit]="$size"
  _clean_logs
  [[ "${C[json]}" == "true" ]] && _clean_stats_json
}

###############################################################################
# Ajuda e CLI
###############################################################################
_clean_usage() {
  cat >&2 <<'EOF'
uso:
  adm_clean run [--level quick|deep|purge] [--days N] [--keep N] [--size-limit 5GiB]
                [--cat C] [--name P] [--arch A] [--libc L] [--stage N]
                [--only tmp|src|bin|logs|bootstrap|registry] [--exclude-glob PAT]...
                [--root DIR] [--json] [--simulate|--yes] [--confirm-purge]
                [--quarantine|--no-quarantine]
  adm_clean report [mesmas flags de run]
  adm_clean quarantine [--days 7] [--yes] [--root DIR]
  adm_clean prune-bin [--keep 3] [--cat C] [--name P] [--yes] [--root DIR]
  adm_clean rotate-logs [--days 14] [--size-limit 1GiB] [--yes] [--root DIR]
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="$1"; shift || true
  case "$cmd" in
    run)          adm_clean_run "$@" || exit $?;;
    report)       adm_clean_report "$@" || exit $?;;
    quarantine)   adm_clean_quarantine "$@" || exit $?;;
    prune-bin)    adm_clean_prune_bin "$@" || exit $?;;
    rotate-logs)  adm_clean_rotate_logs "$@" || exit $?;;
    ""|help|-h|--help) _clean_usage; exit 2;;
    *) clean_warn "comando desconhecido: $cmd"; _clean_usage; exit 2;;
  esac
fi

ADM_CLEAN_LOADED=1
export ADM_CLEAN_LOADED
