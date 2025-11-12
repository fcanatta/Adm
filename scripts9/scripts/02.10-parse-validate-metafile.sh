#!/usr/bin/env bash
# 02.10-parse-validate-metafile.sh
# Parser e validador do "metafile" minimalista do ADM.
# Local: /usr/src/adm/scripts/02.10-parse-validate-metafile.sh
###############################################################################
# Modo estrito + trap de erros
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__adm_err_trap_meta() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] parse-metafile falhou: codigo=${code} linha=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __adm_err_trap_meta ERR

###############################################################################
# Defaults e caminhos-base
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_META_DIR="${ADM_META_DIR:-${ADM_ROOT}/metafiles}"
ADM_UPDATE_DIR="${ADM_UPDATE_DIR:-${ADM_ROOT}/update}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_LOCK_DIR="${ADM_LOCK_DIR:-${ADM_STATE_DIR}/locks}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"

adm_is_cmd() { command -v "$1" >/dev/null 2>&1; }

# Fallback de cores/log se 01.10 não estiver carregado
if [[ -t 1 ]] && adm_is_cmd tput && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  ADM_COLOR_RST="$(tput sgr0)"; ADM_COLOR_OK="$(tput setaf 2)"; ADM_COLOR_WRN="$(tput setaf 3)"; ADM_COLOR_ERR="$(tput setaf 1)"; ADM_COLOR_INF="$(tput setaf 6)"; ADM_COLOR_BLD="$(tput bold)"
else
  ADM_COLOR_RST=""; ADM_COLOR_OK=""; ADM_COLOR_WRN=""; ADM_COLOR_ERR=""; ADM_COLOR_INF=""; ADM_COLOR_BLD=""
fi
adm_info()  { echo -e "${ADM_COLOR_INF}[ADM]${ADM_COLOR_RST} $*"; }
adm_ok()    { echo -e "${ADM_COLOR_OK}[OK ]${ADM_COLOR_RST} $*"; }
adm_warn()  { echo -e "${ADM_COLOR_WRN}[WAR]${ADM_COLOR_RST} $*" 1>&2; }
adm_error() { echo -e "${ADM_COLOR_ERR}[ERR]${ADM_COLOR_RST} $*" 1>&2; }

__adm_ensure_dir() {
  local d="$1" mode="${2:-0755}" owner="${3:-root}" group="${4:-root}"
  if [[ ! -d "$d" ]]; then
    if adm_is_cmd install; then
      if [[ $EUID -ne 0 ]] && adm_is_cmd sudo; then
        sudo install -d -m "$mode" -o "$owner" -g "$group" "$d"
      else
        install -d -m "$mode" -o "$owner" -g "$group" "$d"
      fi
    else
      mkdir -p "$d"
      chmod "$mode" "$d"
      chown "$owner:$group" "$d" || true
    fi
  fi
}
__adm_ensure_dir "$ADM_STATE_DIR"
__adm_ensure_dir "$ADM_LOCK_DIR"
__adm_ensure_dir "$ADM_TMPDIR"

###############################################################################
# Especificação do metafile
###############################################################################
# Campos permitidos e APENAS estes:
# name, version, category, run_deps, build_deps, opt_deps, num_builds,
# description, homepage, maintainer, sha256sums, sources
ADM_META_ALLOWED_KEYS=(
  name version category run_deps build_deps opt_deps
  num_builds description homepage maintainer sha256sums sources
)

# Expressões de validação
ADM_RE_NAME='^[a-zA-Z0-9._+-]{1,128}$'
ADM_RE_VERSION='^[0-9A-Za-z._+-]{1,128}$'
ADM_RE_CATEGORY='^[a-z][a-z0-9._+-]{1,64}$'
ADM_RE_SHA256='^[a-f0-9]{64}$'
ADM_RE_URL='^(https?|git|ssh|rsync)://|^(git@|file:/|/).+|^https://(github|gitlab|sourceforge)\.com/.+'
ADM_RE_EMAIL='^[^[:space:]]+@[^[:space:]]+\.[^[:space:]]+$'

# Banco de dados do pacote carregado (assoc array)
declare -gA ADM_META

###############################################################################
# Helpers de string/lista
###############################################################################
__trim() { sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//'; }

__strip_quotes() {
  local v="$1"
  if [[ "$v" =~ ^\".*\"$ || "$v" =~ ^\'.*\'$ ]]; then
    printf '%s' "${v:1:-1}"
  else
    printf '%s' "$v"
  fi
}

__csv_to_list() {
  # normaliza CSV → "a b c" (usa quebra em vírgulas, remove vazios)
  local s="$1"
  s="$(__strip_quotes "$s")"
  s="$(echo "$s" | tr ',' '\n' | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//' | sed '/^$/d' )"
  # volta para espaço-separado
  tr '\n' ' ' <<<"$s" | sed -e 's/[[:space:]]\+/ /g' -e 's/[[:space:]]$//'
}

__validate_key_allowed() {
  local k="$1" ok=0 x
  for x in "${ADM_META_ALLOWED_KEYS[@]}"; do
    [[ "$k" == "$x" ]] && { ok=1; break; }
  done
  (( ok==1 )) || { adm_error "Chave não permitida no metafile: $k"; exit 20; }
}

__meta_set() {
  local k="$1" v="$2"
  ADM_META["$k"]="$v"
}

__assert_present() {
  local k="$1"
  if [[ -z "${ADM_META[$k]:-}" ]]; then
    adm_error "Campo obrigatório ausente ou vazio: $k"
    exit 21
  fi
}

###############################################################################
# Localização do metafile
###############################################################################
# Possibilidades de argumento:
#  1) Caminho absoluto/relativo de um arquivo 'metafile'
#  2) "<categoria>/<programa>"
#  3) "<programa>" (procura em ${ADM_META_DIR}/*/<programa>/metafile)
adm_meta_resolve_path() {
  local arg="${1:?alvo}"
  local f=""
  if [[ -f "$arg" ]]; then
    f="$arg"
  elif [[ "$arg" == */* ]]; then
    f="${ADM_META_DIR}/${arg}/metafile"
  else
    # busca por nome único
    mapfile -t found < <(find "${ADM_META_DIR}" -type f -path "*/${arg}/metafile" 2>/dev/null || true)
    if ((${#found[@]} == 0)); then
      adm_error "metafile não encontrado para programa '${arg}' em ${ADM_META_DIR}"
      exit 22
    elif ((${#found[@]} > 1)); then
      adm_error "múltiplos metafiles para '${arg}':"; printf ' - %s\n' "${found[@]}" 1>&2
      exit 23
    else
      f="${found[0]}"
    fi
  fi
  [[ -r "$f" ]] || { adm_error "metafile não legível: $f"; exit 24; }
  printf '%s' "$f"
}

###############################################################################
# Parse do metafile
###############################################################################
adm_meta_parse_file() {
  local file="${1:?metafile}"
  local line k v
  # limpa mapa
  ADM_META=()

  local lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((lineno++))
    # remove comentários e trim
    line="${line%%#*}"
    line="$(printf '%s' "$line" | __trim)"
    [[ -z "$line" ]] && continue
    # formato k=v
    if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      adm_error "linha inválida (${file}:${lineno}): '$line'"
      exit 25
    fi
    k="${line%%=*}"
    v="${line#*=}"
    k="$(printf '%s' "$k" | __trim)"
    v="$(printf '%s' "$v" | __trim)"
    __validate_key_allowed "$k"

    # restringe aos campos do esquema
    case "$k" in
      name|version|category|description|homepage|maintainer|num_builds|sha256sums|sources|run_deps|build_deps|opt_deps)
        # normalizações específicas mais adiante
        __meta_set "$k" "$v"
        ;;
      *)
        adm_error "chave desconhecida (guard): $k"; exit 26 ;;
    esac
  done <"$file"

  # pós-processamento e normalização de listas
  [[ -n "${ADM_META[run_deps]:-}"   ]] && ADM_META[run_deps]="$(__csv_to_list "${ADM_META[run_deps]}")"
  [[ -n "${ADM_META[build_deps]:-}" ]] && ADM_META[build_deps]="$(__csv_to_list "${ADM_META[build_deps]}")"
  [[ -n "${ADM_META[opt_deps]:-}"   ]] && ADM_META[opt_deps]="$(__csv_to_list "${ADM_META[opt_deps]}")"

  [[ -n "${ADM_META[sources]:-}"    ]] && ADM_META[sources]="$(__csv_to_list "${ADM_META[sources]}")"
  [[ -n "${ADM_META[sha256sums]:-}" ]] && ADM_META[sha256sums]="$(__csv_to_list "${ADM_META[sha256sums]}")"

  # num_builds → inteiro
  if [[ -n "${ADM_META[num_builds]:-}" ]]; then
    local nb="${ADM_META[num_builds]}"
    if [[ ! "$nb" =~ ^[0-9]+$ ]]; then
      adm_error "num_builds não é inteiro: '$nb'"
      exit 27
    fi
  else
    ADM_META[num_builds]="0"
  fi

  __meta_set "__file" "$file"
}

###############################################################################
# Validações semânticas
###############################################################################
adm_meta_validate() {
  # obrigatórios
  __assert_present name
  __assert_present version
  __assert_present category
  __assert_present description
  __assert_present homepage
  __assert_present maintainer
  __assert_present sha256sums
  __assert_present sources

  # formatos
  if ! [[ "${ADM_META[name]}" =~ $ADM_RE_NAME ]]; then
    adm_error "name inválido: '${ADM_META[name]}'"; exit 30
  fi
  if ! [[ "${ADM_META[version]}" =~ $ADM_RE_VERSION ]]; then
    adm_error "version inválida: '${ADM_META[version]}'"; exit 31
  fi
  if ! [[ "${ADM_META[category]}" =~ $ADM_RE_CATEGORY ]]; then
    adm_error "category inválida: '${ADM_META[category]}'"; exit 32
  fi

  # maintainer "Nome <email>"
  if ! [[ "${ADM_META[maintainer]}" =~ <.*> ]]; then
    adm_error "maintainer deve conter e-mail entre < >: '${ADM_META[maintainer]}'"; exit 33
  else
    local email
    email="$(sed -n 's/.*<\([^>]*\)>.*/\1/p' <<<"${ADM_META[maintainer]}")"
    if ! [[ "$email" =~ $ADM_RE_EMAIL ]]; then
      adm_error "e-mail de maintainer inválido: '$email'"; exit 34
    fi
  fi

  # homepage URL mínima
  if ! [[ "${ADM_META[homepage]}" =~ ^https?:// ]]; then
    adm_error "homepage inválida (esperado http/https): '${ADM_META[homepage]}'"; exit 35
  fi

  # listas 1:1 sources ↔ sha256sums
  local -a srcs sums
  IFS=' ' read -r -a srcs <<< "${ADM_META[sources]}"
  IFS=' ' read -r -a sums <<< "${ADM_META[sha256sums]}"
  if ((${#srcs[@]} == 0)); then
    adm_error "sources vazio"; exit 36
  fi
  if ((${#sums[@]} != ${#srcs[@]})); then
    adm_error "sha256sums (${#sums[@]}) não casa com sources (${#srcs[@]})"; exit 37
  fi

  local i
  for ((i=0; i<${#srcs[@]}; i++)); do
    local u="${srcs[$i]}" h="${sums[$i]}"
    if ! [[ "$h" =~ $ADM_RE_SHA256 ]]; then
      adm_error "sha256 inválido no índice $i: '$h'"; exit 38
    fi
    # Validação básica de URL/caminho
    if ! [[ "$u" =~ $ADM_RE_URL ]]; then
      adm_error "source inválido no índice $i: '$u'"; exit 39
    fi
  done

  adm_ok "metafile válido: ${ADM_META[category]}/${ADM_META[name]}@${ADM_META[version]}"
}
###############################################################################
# Utilidades públicas: acesso, arrays e impressão
###############################################################################
adm_meta_field() {
  # uso: adm_meta_field <chave>
  local k="${1:?chave}"
  printf '%s' "${ADM_META[$k]:-}"
}

adm_meta_sources_to_array() {
  # imprime cada source em uma linha (para `readarray -t`)
  [[ -n "${ADM_META[sources]:-}" ]] || return 0
  tr ' ' '\n' <<< "${ADM_META[sources]}"
}

adm_meta_sha256_to_array() {
  [[ -n "${ADM_META[sha256sums]:-}" ]] || return 0
  tr ' ' '\n' <<< "${ADM_META[sha256sums]}"
}

adm_meta_require_fields() {
  # uso: adm_meta_require_fields campo1 campo2 ...
  local miss=() f
  for f in "$@"; do
    [[ -n "${ADM_META[$f]:-}" ]] || miss+=("$f")
  done
  if ((${#miss[@]})); then
    adm_error "metafile: campos requeridos ausentes: ${miss[*]}"
    exit 41
  fi
}

adm_meta_print() {
  # exibe o conteúdo normalizado do metafile
  local k
  echo "name=${ADM_META[name]}"
  echo "version=${ADM_META[version]}"
  echo "category=${ADM_META[category]}"
  echo "run_deps=${ADM_META[run_deps]:-}"
  echo "build_deps=${ADM_META[build_deps]:-}"
  echo "opt_deps=${ADM_META[opt_deps]:-}"
  echo "num_builds=${ADM_META[num_builds]:-0}"
  echo "description=${ADM_META[description]}"
  echo "homepage=${ADM_META[homepage]}"
  echo "maintainer=${ADM_META[maintainer]}"
  echo "sha256sums=$(tr ' ' ',' <<<"${ADM_META[sha256sums]}")"
  echo "sources=$(tr ' ' ',' <<<"${ADM_META[sources]}")"
}

###############################################################################
# Atualização segura de num_builds (com lock e backup)
###############################################################################
__meta_lock_file() {
  local cat="${ADM_META[category]:-}" prog="${ADM_META[name]:-}"
  [[ -n "$cat" && -n "$prog" ]] || { adm_error "lock: category/name vazios"; exit 50; }
  printf '%s' "${ADM_LOCK_DIR}/metafile.${cat}.${prog}.lock"
}

adm_meta_increment_builds() {
  # Reabre o arquivo e atualiza num_builds de forma atômica
  local file="${ADM_META[__file]:-}"
  [[ -n "$file" && -w "$file" ]] || { adm_error "increment: metafile não gravável: $file"; exit 51; }

  local lf="$(__meta_lock_file)"
  : > "$lf" || { adm_error "não consigo tocar lockfile: $lf"; exit 52; }
  exec {fd}>"$lf" || { adm_error "lock fd falhou: $lf"; exit 53; }
  flock "$fd"

  # lê e modifica em tmp
  local tmp="${ADM_TMPDIR}/.$$.$RANDOM.metafile"
  cp -f -- "$file" "$tmp"

  # extrai valor atual
  local nb newnb
  nb="$(grep -E '^num_builds=' "$tmp" | head -n1 | cut -d= -f2 || echo '')"
  if [[ -z "$nb" ]]; then nb=0; fi
  if ! [[ "$nb" =~ ^[0-9]+$ ]]; then
    adm_warn "num_builds inválido no arquivo; reiniciando para 0"
    nb=0
  fi
  newnb=$((nb+1))

  # substitui linha (se existir) ou adiciona
  if grep -qE '^num_builds=' "$tmp"; then
    sed -i -E "s/^num_builds=.*/num_builds=${newnb}/" "$tmp"
  else
    printf '\nnum_builds=%s\n' "$newnb" >> "$tmp"
  fi

  # backup e commit atômico
  local bak="${file}.bak.$(date -u +%Y%m%d-%H%M%S)"
  cp -f -- "$file" "$bak"
  mv -f -- "$tmp" "$file"

  # reflete no mapa atual
  ADM_META[num_builds]="$newnb"

  flock -u "$fd"
  adm_ok "num_builds atualizado: ${nb} → ${newnb}"
}

###############################################################################
# Função de alto nível: carregar (resolver → parse → validar)
###############################################################################
adm_meta_load() {
  # uso: adm_meta_load <metafile|categoria/prog|prog>
  local target="${1:?alvo}"
  local f
  f="$(adm_meta_resolve_path "$target")"
  adm_info "Carregando metafile: $f"
  adm_meta_parse_file "$f"
  adm_meta_validate
}

###############################################################################
# Execução direta (self-test) — NÃO altera arquivos reais
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  __adm_ensure_dir "${ADM_TMPDIR}"
  testdir="${ADM_TMPDIR}/meta-selftest"
  mkdir -p "${testdir}/apps/hello"
  mf="${testdir}/apps/hello/metafile"

  cat > "$mf" <<'EOF'
name=hello
version=1.2.3
category=apps
run_deps=dep1, dep2
build_deps=depA
opt_deps=
num_builds=0
description=Descrição curta
homepage=https://example.org/hello
maintainer=Nome <email@example.org>
sha256sums=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
sources=https://example.org/hello-1.2.3.tar.xz
EOF

  # Redireciona META_DIR temporariamente
  ADM_META_DIR="$testdir"
  adm_meta_load "apps/hello"
  adm_meta_print | sed 's/^/  /'
  adm_meta_increment_builds
  adm_ok "Self-test do parser/validador concluído."
fi
