#!/usr/bin/env bash
# 02.20-schema-guard-minimal.sh
# Guarda de esquema mínimo para "metafile" do ADM (somente os campos definidos).
# Local: /usr/src/adm/scripts/02.20-schema-guard-minimal.sh
###############################################################################
# Modo estrito + trap de erros (sem erros silenciosos)
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__sg_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] schema-guard falhou: codigo=${code} linha=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __sg_err_trap ERR

###############################################################################
# Paths, logging básico (fallback) e utilitários
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_LOCK_DIR="${ADM_LOCK_DIR:-${ADM_STATE_DIR}/locks}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"

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
__ensure_dir "$ADM_STATE_DIR"; __ensure_dir "$ADM_LOCK_DIR"; __ensure_dir "$ADM_TMPDIR"

# Cores simples
if [[ -t 1 ]] && adm_is_cmd tput && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RST="$(tput sgr0)"; C_OK="$(tput setaf 2)"; C_WRN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INF="$(tput setaf 6)"; C_BD="$(tput bold)"
else
  C_RST=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""; C_BD=""
fi
sg_info(){ echo -e "${C_INF}[SG]${C_RST} $*"; }
sg_ok(){   echo -e "${C_OK}[OK ]${C_RST} $*"; }
sg_warn(){ echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
sg_err(){  echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }

tmpfile(){ mktemp "${ADM_TMPDIR}/sg.XXXXXX"; }

# Locks
__sg_lock_file(){ printf '%s' "${ADM_LOCK_DIR}/metafile.guard.lock"; }
sg_lock(){
  local lf="$(__sg_lock_file)"; : >"$lf" || { sg_err "não abre lock: $lf"; exit 10; }
  exec {SG_FD}>"$lf" || { sg_err "não abre FD lock"; exit 11; }
  flock "$SG_FD"
}
sg_unlock(){ flock -u "${SG_FD:-9}" 2>/dev/null || true; }

###############################################################################
# Esquema mínimo ACEITO (apenas estas chaves)
###############################################################################
SG_KEYS_ORDER=( \
  name version category run_deps build_deps opt_deps \
  num_builds description homepage maintainer sha256sums sources )

SG_KEYS_SET=("${SG_KEYS_ORDER[@]}") # alias legível
SG_REQUIRED=( name version category description homepage maintainer sha256sums sources )

# Regex de validação
RE_NAME='^[A-Za-z0-9._+-]{1,128}$'
RE_VERSION='^[0-9A-Za-z._+-]{1,128}$'
RE_CATEGORY='^[a-z][a-z0-9._+-]{1,64}$'
RE_SHA256='^[a-f0-9]{64}$'
RE_URL='^(https?|git|ssh|rsync)://|^(git@|file:/|/).+|^https://(github|gitlab|sourceforge)\.com/.+'
RE_EMAIL='^[^[:space:]]+@[^[:space:]]+\.[^[:space:]]+$'

###############################################################################
# Helpers de texto/listas
###############################################################################
_trim(){ sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//'; }
_strip_quotes(){
  local v="$1"
  if [[ "$v" =~ ^\".*\"$ || "$v" =~ ^\'.*\'$ ]]; then printf '%s' "${v:1:-1}"; else printf '%s' "$v"; fi
}
_csv_to_list(){
  # CSV → "a b c" (sem vazios)
  local s="$1"; s="$(_strip_quotes "$s")"
  s="$(echo "$s" | tr ',' '\n' | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//' | sed '/^$/d')"
  tr '\n' ' ' <<<"$s" | sed -e 's/[[:space:]]\+/ /g' -e 's/[[:space:]]$//'
}
_list_to_csv(){ tr ' ' ',' <<<"${1:-}"; }

###############################################################################
# Parser minimalista interno (fallback) e ponte p/ 02.10 quando disponível
###############################################################################
declare -gA SG_META

sg_meta_clear(){ SG_META=(); }

sg_meta_parse_file_minimal(){
  local f="${1:?metafile}" line k v lineno=0
  sg_meta_clear
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((lineno++))
    # permite comentários (removidos) e linhas em branco
    line="${line%%#*}"
    line="$(printf '%s' "$line" | _trim)"
    [[ -z "$line" ]] && continue
    # exige k=v
    if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      sg_err "linha inválida (${f}:${lineno}): '$line'"; exit 20
    fi
    k="${line%%=*}"; v="${line#*=}"
    k="$(printf '%s' "$k" | _trim)"; v="$(printf '%s' "$v" | _trim)"
    SG_META["$k"]="$v"
  done <"$f"
  SG_META["__file"]="$f"
}

# Tenta usar o parser/validador do 02.10 (se estiver presente) para maior coesão
sg_try_use_meta_module(){
  local mod="${ADM_ROOT}/scripts/02.10-parse-validate-metafile.sh"
  if [[ -r "$mod" ]]; then
    # shellcheck disable=SC1090
    source "$mod"
    if declare -F adm_meta_parse_file >/dev/null 2>&1; then
      SG_HAS_META_MODULE=1
    else
      SG_HAS_META_MODULE=0
    fi
  else
    SG_HAS_META_MODULE=0
  fi
}

sg_meta_load_any(){
  local target="${1:?metafile|categoria/prog|prog}"
  sg_try_use_meta_module
  if [[ "${SG_HAS_META_MODULE:-0}" == "1" ]]; then
    adm_meta_load "$target"         # parse + validate
    # Promove ADM_META → SG_META (somente as chaves do esquema)
    sg_meta_clear
    local k
    for k in "${SG_KEYS_SET[@]}"; do
      [[ -v ADM_META["$k"] ]] && SG_META["$k"]="${ADM_META[$k]}"
    done
    SG_META["__file"]="${ADM_META[__file]}"
  else
    local path
    path="$(  # resolver como o módulo faria (caminho ou cat/prog ou prog)
      if [[ -f "$target" ]]; then printf '%s' "$target";
      elif [[ "$target" == */* ]]; then printf '%s/%s/metafile' "${ADM_ROOT}/metafiles" "$target";
      else find "${ADM_ROOT}/metafiles" -type f -path "*/${target}/metafile" -print -quit; fi
    )"
    [[ -n "$path" ]] || { sg_err "metafile não encontrado para '$target'"; exit 21; }
    [[ -r "$path" ]] || { sg_err "metafile não legível: $path"; exit 22; }
    sg_meta_parse_file_minimal "$path"
  fi
}

###############################################################################
# Linter de esquema mínimo
###############################################################################
sg_key_allowed(){
  local k="$1"
  local x
  for x in "${SG_KEYS_SET[@]}"; do [[ "$k" == "$x" ]] && return 0; done
  return 1
}

sg_list_keys_in_file(){
  local f="${1:?metafile}" line k
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | _trim)"
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      k="${line%%=*}"; printf '%s\n' "$k"
    else
      printf '__INVALID__\t%s\n' "$line"
    fi
  done <"$f"
}

sg_lint(){
  local f="${1:?metafile}" strict="${2:-0}"
  local ok=1
  local seen=()
  local IFS=$'\n'
  while read -r K; do
    if [[ "$K" == __INVALID__*$'\t'* ]]; then
      ok=0
      sg_err "linha fora do formato k=v: ${K#*$'\t'}"
      continue
    fi
    if ! sg_key_allowed "$K"; then
      ok=0
      sg_err "chave não permitida: $K"
      continue
    fi
    # duplicatas
    if printf '%s\n' "${seen[@]}" | grep -qx -- "$K"; then
      ok=0; sg_err "chave duplicada: $K"
    else
      seen+=("$K")
    fi
  done < <(sg_list_keys_in_file "$f")

  if (( strict )); then
    # strict: sem comentários e sem linhas vazias
    if grep -qE '^[[:space:]]*#' "$f"; then ok=0; sg_err "strict: comentários não são permitidos"; fi
    if grep -qE '^[[:space:]]*$' "$f"; then ok=0; sg_err "strict: linhas vazias não são permitidas"; fi
  fi

  # obrigatórios presentes?
  local k
  for k in "${SG_REQUIRED[@]}"; do
    if ! grep -qE "^${k}=" "$f"; then ok=0; sg_err "campo obrigatório ausente: $k"; fi
  done

  (( ok==1 ))
}

###############################################################################
# Normalização e validação semântica (canônica)
###############################################################################
sg_normalize_in_memory(){
  # converte SG_META para forma canônica (listas, trim, quotes)
  # Listas → espaço-separado; CSV só no print final
  local fld
  for fld in run_deps build_deps opt_deps sources sha256sums; do
    [[ -n "${SG_META[$fld]:-}" ]] && SG_META["$fld"]="$(_csv_to_list "${SG_META[$fld]}")"
  done
  if [[ -n "${SG_META[num_builds]:-}" ]]; then
    if [[ ! "${SG_META[num_builds]}" =~ ^[0-9]+$ ]]; then
      sg_warn "num_builds inválido → será ajustado para 0"
      SG_META[num_builds]="0"
    fi
  else
    SG_META[num_builds]="0"
  fi
  # Strip de aspas em todos os campos textuais
  for fld in name version category description homepage maintainer; do
    [[ -n "${SG_META[$fld]:-}" ]] && SG_META["$fld"]="$(_strip_quotes "${SG_META[$fld]}")"
  done
}

sg_validate_semantics(){
  local fail=0
  # obrigatórios
  local k
  for k in "${SG_REQUIRED[@]}"; do
    if [[ -z "${SG_META[$k]:-}" ]]; then sg_err "obrigatório vazio: $k"; fail=1; fi
  done
  # formatos
  [[ "${SG_META[name]:-}" =~ $RE_NAME ]]      || { sg_err "name inválido"; fail=1; }
  [[ "${SG_META[version]:-}" =~ $RE_VERSION ]]|| { sg_err "version inválida"; fail=1; }
  [[ "${SG_META[category]:-}" =~ $RE_CATEGORY ]] || { sg_err "category inválida"; fail=1; }
  if [[ "${SG_META[maintainer]:-}" != *"<"*">"* ]]; then sg_err "maintainer sem <email>"; fail=1; else
    local email; email="$(sed -n 's/.*<\([^>]*\)>.*/\1/p' <<<"${SG_META[maintainer]}")"
    [[ "$email" =~ $RE_EMAIL ]] || { sg_err "email do maintainer inválido"; fail=1; }
  fi
  [[ "${SG_META[homepage]:-}" =~ ^https?:// ]] || { sg_err "homepage inválida (http/https)"; fail=1; }

  # sources ↔ sha256sums 1:1
  local -a srcs sums; IFS=' ' read -r -a srcs <<< "${SG_META[sources]:-}"; IFS=' ' read -r -a sums <<< "${SG_META[sha256sums]:-}"
  ((${#srcs[@]}>0)) || { sg_err "sources vazio"; fail=1; }
  ((${#srcs[@]}==${#sums[@]})) || { sg_err "sha256sums não casa com sources"; fail=1; }
  local i u h
  for ((i=0;i<${#srcs[@]};i++)); do u="${srcs[$i]}"; h="${sums[$i]}";
    [[ "$h" =~ $RE_SHA256 ]] || { sg_err "sha256 inválido no idx $i"; fail=1; }
    [[ "$u" =~ $RE_URL ]] || { sg_err "source inválido no idx $i"; fail=1; }
  done

  (( fail==0 ))
}

sg_emit_canonical(){
  # imprime conteúdo canônico no stdout
  local k
  for k in "${SG_KEYS_ORDER[@]}"; do
    case "$k" in
      run_deps|build_deps|opt_deps|sources|sha256sums)
        local v="${SG_META[$k]:-}"
        v="$(_list_to_csv "$v")"
        printf '%s=%s\n' "$k" "$v"
        ;;
      num_builds)
        printf 'num_builds=%s\n' "${SG_META[num_builds]:-0}"
        ;;
      *)
        printf '%s=%s\n' "$k" "${SG_META[$k]:-}"
        ;;
    esac
  done
}

sg_normalize_line_endings(){
  # Normaliza para LF; remove CR em fim de linha
  local in="$1" out="$2"
  awk '{gsub(/\r$/,""); print}' "$in" > "$out"
}
###############################################################################
# Reescrita canônica INPLACE (com backup e lock)
###############################################################################
sg_canonicalize_inplace(){
  local target="${1:?metafile|categoria/prog|prog}" strict="${2:-0}"
  sg_lock
  # Carregar + normalizar + validar
  sg_meta_load_any "$target"
  local path="${SG_META[__file]}"
  [[ -w "$path" ]] || { sg_err "metafile não gravável: $path"; sg_unlock; exit 60; }

  # Lint do arquivo fonte (antes de reescrever)
  if ! sg_lint "$path" "$strict"; then
    sg_warn "lint encontrou problemas — prosseguindo com reescrita canônica."
  fi

  # Normalização de EOL
  local tmp0; tmp0="$(tmpfile)"
  sg_normalize_line_endings "$path" "$tmp0"

  # Reparse do tmp0 para refletir trims/lights (sem confiar no arquivo original)
  sg_meta_parse_file_minimal "$tmp0" || true  # SG_META é refeito; parse minimalista aqui
  sg_normalize_in_memory
  if ! sg_validate_semantics; then
    sg_unlock
    sg_err "falha nas validações semânticas; não será reescrito."
    exit 61
  fi

  # Emissão canônica para tmp1
  local tmp1; tmp1="$(tmpfile)"
  sg_emit_canonical > "$tmp1"

  # Backup e commit atômico
  local bak="${path}.bak.$(date -u +%Y%m%d-%H%M%S)"
  cp -f -- "$path" "$bak"
  if [[ $EUID -ne 0 ]] && adm_is_cmd sudo; then
    sudo mv -f -- "$tmp1" "$path"
    sudo chmod 0644 "$path"
    sudo chown root:root "$path" || true
  else
    mv -f -- "$tmp1" "$path"
    chmod 0644 "$path"
    chown root:root "$path" || true
  fi

  sg_ok "metafile reescrito de forma canônica."
  sg_info "backup: $bak"
  sg_unlock
}

###############################################################################
# Somente checagem (sem modificar)
###############################################################################
sg_check_only(){
  local target="${1:?metafile|categoria/prog|prog}" strict="${2:-0}"
  sg_meta_load_any "$target"  # assegura que caminho existe/legível
  local path="${SG_META[__file]}"

  local ok=1
  # Lint de chaves/duplicatas/formato e (opcional) strict
  if ! sg_lint "$path" "$strict"; then ok=0; fi

  # Normalização/validação semântica
  sg_meta_parse_file_minimal "$path"
  sg_normalize_in_memory
  if ! sg_validate_semantics; then ok=0; fi

  if (( ok==1 )); then
    sg_ok "OK: o arquivo está em conformidade com o esquema mínimo."
  else
    sg_err "NÃO OK: o arquivo tem problemas. Use --fix-inplace para corrigir."
    return 1
  fi
}

###############################################################################
# Impressão canônica no stdout (sem tocar arquivo)
###############################################################################
sg_print_canonical(){
  local target="${1:?metafile|categoria/prog|prog}"
  sg_meta_load_any "$target"
  # Reparse minimalista do próprio arquivo, para refletir seu conteúdo atual
  sg_meta_parse_file_minimal "${SG_META[__file]}"
  sg_normalize_in_memory
  if ! sg_validate_semantics; then
    sg_err "arquivo inválido; correções são necessárias (use --fix-inplace)."
    exit 70
  fi
  sg_emit_canonical
}

###############################################################################
# CLI
#   --check <alvo> [--strict]
#   --fix-inplace <alvo> [--strict]
#   --print <alvo>
###############################################################################
sg_usage(){
  cat <<'EOF'
Uso:
  02.20-schema-guard-minimal.sh --check <metafile|categoria/prog|prog> [--strict]
  02.20-schema-guard-minimal.sh --fix-inplace <metafile|categoria/prog|prog> [--strict]
  02.20-schema-guard-minimal.sh --print <metafile|categoria/prog|prog>

Opções:
  --check        Apenas valida (lint + semântica). Exit 0/1.
  --fix-inplace  Reescreve o arquivo de forma canônica (backup + lock).
  --print        Emite forma canônica no stdout (não modifica arquivo).
  --strict       Proíbe comentários e linhas em branco no arquivo de origem.

Observações:
  - O esquema mínimo aceita SOMENTE as chaves:
      name, version, category, run_deps, build_deps, opt_deps,
      num_builds, description, homepage, maintainer, sha256sums, sources
  - Listas são gravadas como CSV compacto (sem espaços).
  - num_builds é garantido inteiro (default 0).
  - sources e sha256sums devem ter o mesmo comprimento (1:1).
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  action="" strict=0 target=""
  while (($#)); do
    case "$1" in
      --check)       action="check"; target="${2:-}"; shift 2 ;;
      --fix-inplace) action="fix";   target="${2:-}"; shift 2 ;;
      --print)       action="print"; target="${2:-}"; shift 2 ;;
      --strict)      strict=1; shift ;;
      -h|--help)     sg_usage; exit 0 ;;
      *) sg_err "opção inválida: $1"; sg_usage; exit 2 ;;
    esac
  done
  [[ -n "$action" && -n "$target" ]] || { sg_err "ação/alvo ausentes"; sg_usage; exit 3; }

  case "$action" in
    check) sg_check_only "$target" "$strict" ;;
    fix)   sg_canonicalize_inplace "$target" "$strict" ;;
    print) sg_print_canonical "$target" ;;
  esac
fi
