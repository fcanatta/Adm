#!/usr/bin/env bash
# 14-adm-profile.part1.sh
# Gestão, validação e aplicação de perfis de build do ADM.
###############################################################################
# Guardas e variáveis base
###############################################################################
if [[ -n "${ADM_PROFILE_LOADED_PART1:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_PROFILE_LOADED_PART1=1

for _m in ADM_CONF_LOADED ADM_LIB_LOADED; do
  if [[ -z "${!_m:-}" ]]; then
    echo "ERRO: 14-adm-profile requer módulos básicos carregados (00/01). Faltando: ${_m}" >&2
    return 2 2>/dev/null || exit 2
  fi
done

: "${ADM_PROFILES_ROOT:=/usr/src/adm/profiles}"
: "${ADM_STATE_ROOT:=/usr/src/adm/state}"
: "${ADM_TMP_ROOT:=/usr/src/adm/tmp}"
: "${ADM_PROFILE_DEFAULT:=normal}"

prof_err()  { adm_err "$*"; }
prof_warn() { adm_warn "$*"; }
prof_info() { adm_log INFO "profile" "${P_CTX:-}" "$*"; }

declare -Ag PCTX=(
  [stage]="" [cat]="" [name]="" [strict]="false" [verbose]="false" [no_test]="false"
)

# Paths resolvidos
_prof_paths_init() {
  PATH_PROFILES="${ADM_PROFILES_ROOT%/}"
  PATH_BUILTIN="${PATH_PROFILES}/profiles.d"
  PATH_OVR_CAT="${PATH_PROFILES}/overrides/category"
  PATH_OVR_PROG="${PATH_PROFILES}/overrides/program"
  PATH_OVR_STAGE="${PATH_PROFILES}/stage"
  PATH_STATE="${ADM_STATE_ROOT%/}/profile"
  mkdir -p -- "$PATH_BUILTIN" "$PATH_OVR_CAT" "$PATH_OVR_PROG" "$PATH_OVR_STAGE" "$PATH_STATE" "$ADM_TMP_ROOT" || {
    prof_err "falha ao criar diretórios de profiles/state"; return 3; }
  PATH_ACTIVE="${PATH_STATE}/active.env"
  PATH_REPORT="${PATH_STATE}/report.txt"
  PATH_JSON="${PATH_STATE}/profile.json"
  PATH_LOG_APPLY="${ADM_STATE_ROOT%/}/logs/profile/apply.log"
  PATH_LOG_VALIDATE="${ADM_STATE_ROOT%/}/logs/profile/validate.log"
  mkdir -p -- "${ADM_STATE_ROOT%/}/logs/profile" || true
}

###############################################################################
# Criação dos perfis built-in (idempotente)
###############################################################################
_prof_write_file_atomic() {
  local target="$1"; shift
  local tmp="${target}.tmp.$$"
  umask 022
  { printf "%s\n" "$@"; } > "$tmp" 2>/dev/null || { prof_err "falha ao escrever temp $tmp"; return 3; }
  mv -f -- "$tmp" "$target" 2>/dev/null || { prof_err "falha ao gravar $target"; return 3; }
}

_prof_builtin_create_one() {
  local name="$1" body="$2"
  local f="${PATH_BUILTIN}/${name}.profile"
  [[ -e "$f" ]] && return 0
  prof_info "criando profile built-in: $name"
  _prof_write_file_atomic "$f" "$body" || return $?
}

adm_profile_create_builtins() {
  _prof_paths_init || return $?
  # minimal
  _prof_builtin_create_one "minimal" "$(cat <<'EOF'
# Perfil minimal — estável p/ bootstrap stage0/1
PROFILE_NAME=minimal
OPTLEVEL=2
SYMBOLS=0
LTO=off
PIE=off
RELRO=partial
FORTIFY=1
STACKPROT=none
JOBS=1
LINKER=bfd
TUNE=generic
SANITIZE=none
STRIP=on

CFLAGS_BASE="-O2 -g0 -fno-plt"
CXXFLAGS_BASE="-O2 -g0 -fno-plt"
CPPFLAGS_BASE=""
LDFLAGS_BASE="-Wl,--as-needed -Wl,-O1"
EOF
)" || return $?
  # normal
  _prof_builtin_create_one "normal" "$(cat <<'EOF'
# Perfil normal — padrão p/ stage2/3
PROFILE_NAME=normal
OPTLEVEL=2
SYMBOLS=0
LTO=off
PIE=on
RELRO=full
FORTIFY=2
STACKPROT=strong
JOBS=auto
LINKER=auto
TUNE=generic
SANITIZE=none
STRIP=on

CFLAGS_BASE="-O2 -g0 -fno-plt -fstack-protector-strong"
CXXFLAGS_BASE="-O2 -g0 -fno-plt -fstack-protector-strong"
CPPFLAGS_BASE=""
LDFLAGS_BASE="-Wl,--as-needed -Wl,-O1 -Wl,--sort-common"
EOF
)" || return $?
  # aggressive
  _prof_builtin_create_one "aggressive" "$(cat <<'EOF'
# Perfil aggressive — otimizações e hardening máximos quando suportado
PROFILE_NAME=aggressive
OPTLEVEL=2
SYMBOLS=0
LTO=on
PIE=on
RELRO=full
FORTIFY=3
STACKPROT=strong
JOBS=auto
LINKER=auto
TUNE=generic
SANITIZE=none
STRIP=on

CFLAGS_BASE="-O2 -g0 -fno-plt -flto -fuse-linker-plugin -fstack-protector-strong -fPIE"
CXXFLAGS_BASE="-O2 -g0 -fno-plt -flto -fuse-linker-plugin -fstack-protector-strong -fPIE"
CPPFLAGS_BASE=""
LDFLAGS_BASE="-Wl,--as-needed -Wl,-O1 -Wl,--sort-common -Wl,-z,relro -pie"
EOF
)" || return $?
  # debug
  _prof_builtin_create_one "debug" "$(cat <<'EOF'
# Perfil debug — sem otimizações, símbolos máximos
PROFILE_NAME=debug
OPTLEVEL=0
SYMBOLS=3
LTO=off
PIE=off
RELRO=partial
FORTIFY=0
STACKPROT=none
JOBS=auto
LINKER=auto
TUNE=generic
SANITIZE=none
STRIP=off

CFLAGS_BASE="-O0 -g3 -fno-omit-frame-pointer"
CXXFLAGS_BASE="-O0 -g3 -fno-omit-frame-pointer"
CPPFLAGS_BASE=""
LDFLAGS_BASE="-Wl,--as-needed -Wl,-O1"
EOF
)" || return $?
  # size
  _prof_builtin_create_one "size" "$(cat <<'EOF'
# Perfil size — foco em binários menores
PROFILE_NAME=size
OPTLEVEL=s
SYMBOLS=0
LTO=auto
PIE=on
RELRO=full
FORTIFY=2
STACKPROT=strong
JOBS=auto
LINKER=auto
TUNE=generic
SANITIZE=none
STRIP=on

CFLAGS_BASE="-Os -g0 -ffunction-sections -fdata-sections"
CXXFLAGS_BASE="-Os -g0 -ffunction-sections -fdata-sections"
CPPFLAGS_BASE=""
LDFLAGS_BASE="-Wl,--as-needed -Wl,-O1 -Wl,--gc-sections"
EOF
)" || return $?

  # default symlink se não existir
  if [[ ! -e "${PATH_BUILTIN}/default" ]]; then
    ln -s "normal.profile" "${PATH_BUILTIN}/default" 2>/dev/null || true
  fi
  adm_ok "perfis built-in garantidos em ${PATH_BUILTIN}"
}

###############################################################################
# Utilidades de parsing/merge de KEY=VALUE
###############################################################################
# Somente chaves permitidas (protege contra injeção)
_prof_key_whitelist_regex='^(PROFILE_NAME|OPTLEVEL|SYMBOLS|LTO|PIE|RELRO|FORTIFY|STACKPROT|JOBS|LINKER|TUNE|SANITIZE|STRIP|CFLAGS_BASE|CXXFLAGS_BASE|CPPFLAGS_BASE|LDFLAGS_BASE|EXTRA_CFLAGS|EXTRA_CXXFLAGS|EXTRA_CPPFLAGS|EXTRA_LDFLAGS|RUSTFLAGS|GOFLAGS|NINJAFLAGS|MAKEFLAGS|PKG_CONFIG_PATH|PKG_CONFIG_LIBDIR)$'

_prof_load_kv_file() {
  # _prof_load_kv_file <file> <assocname>
  local f="$1" map="$2"
  [[ -r "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^([A-Za-z0-9_]+)=(.*)$ ]]; then
      local k="${BASH_REMATCH[1]}" v="${BASH_REMATCH[2]}"
      if [[ "$k" =~ $'_prof_key_whitelist_regex' ]]; then :; fi
      if [[ ! "$k" =~ $ _prof_key_whitelist_regex ]]; then
        # verificar com eval-safe: usar regex var com [[ ]]
        if [[ ! "$k" =~ $(_prof_key_whitelist_regex) ]]; then
          prof_warn "ignorado: chave não permitida em $f: $k"
          continue
        fi
      fi
      # retirar aspas se presentes (sem eval)
      v="${v#\"}"; v="${v%\"}"
      v="${v#\'}"; v="${v%\'}"
      eval "$map[\"$k\"]=\"\$v\""
    else
      prof_warn "linha inválida em $f (ignorada)"
    fi
  done < "$f"
}

_prof_merge_maps() {
  # _prof_merge_maps <dstmap> <srcmap> : src sobrepõe dst
  local -n dst="$1"; local -n src="$2"
  local k
  for k in "${!src[@]}"; do
    dst["$k"]="${src[$k]}"
  done
}

###############################################################################
# Normalização de flags e construção dos envs
###############################################################################
_prof_nproc() { command -v nproc >/dev/null 2>&1 && nproc || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1; }

_prof_flags_dedup() {
  # _prof_flags_dedup "<flags...>" -> remove duplicatas mantendo a última
  local input="$1" out=() seen=()
  # quebrar em palavras respeitando aspas simples/duplas
  # shellcheck disable=SC2206
  local arr=( $input )
  for tok in "${arr[@]}"; do
    # chave de comparação: removemos valores de opções longas repetidas
    local key="$tok"
    case "$tok" in
      -D*|-U*|-I*|-L*|-l*|-f*|-O*|-g*|-Wl,*|-W*) key="${tok%%=*}";;
    esac
    seen["$key"]="$tok"
  done
  for k in "${!seen[@]}"; do out+=("${seen[$k]}"); done
  printf "%s" "${out[*]}"
}

_prof_apply_overrides_logic() {
  # transforma chaves lógicas (OPTLEVEL/LTO/PIE/RELRO/FORTIFY/STACKPROT/TUNE/LINKER/SANITIZE/JOBS/STRIP)
  # em CFLAGS/CXXFLAGS/CPPFLAGS/LDFLAGS/MAKEFLAGS/NINJAFLAGS/etc
  local -n M="$1"
  local cflags="${M[CFLAGS_BASE]} ${M[EXTRA_CFLAGS]}"
  local cxxflags="${M[CXXFLAGS_BASE]} ${M[EXTRA_CXXFLAGS]}"
  local cppflags="${M[CPPFLAGS_BASE]} ${M[EXTRA_CPPFLAGS]}"
  local ldflags="${M[LDFLAGS_BASE]} ${M[EXTRA_LDFLAGS]}"

  # OPTLEVEL
  case "${M[OPTLEVEL]:-2}" in
    s) cflags+=" -Os"; cxxflags+=" -Os";;
    0|1|2|3) cflags+=" -O${M[OPTLEVEL]}"; cxxflags+=" -O${M[OPTLEVEL]}";;
  esac
  # SYMBOLS
  case "${M[SYMBOLS]:-0}" in
    0) cflags+=" -g0"; cxxflags+=" -g0";;
    1|2|3) cflags+=" -g${M[SYMBOLS]}"; cxxflags+=" -g${M[SYMBOLS]}";;
  esac
  # LTO
  case "${M[LTO]:-off}" in
    on)   cflags+=" -flto -fuse-linker-plugin"; cxxflags+=" -flto -fuse-linker-plugin"; ldflags+=" -flto";;
    thin) cflags+=" -flto=thin -fuse-linker-plugin"; cxxflags+=" -flto=thin -fuse-linker-plugin"; ldflags+=" -flto=thin";;
    off)  :;;
  esac
  # PIE
  case "${M[PIE]:-on}" in
    on)  cflags+=" -fPIE"; cxxflags+=" -fPIE"; ldflags+=" -pie";;
    off) :;;
  esac
  # RELRO
  case "${M[RELRO]:-full}" in
    full)    ldflags+=" -Wl,-z,relro -Wl,-z,now";;
    partial) ldflags+=" -Wl,-z,relro";;
    off)     :;;
  esac
  # FORTIFY
  local fort="${M[FORTIFY]:-2}"
  cppflags+=" -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=${fort}"
  # STACKPROT
  case "${M[STACKPROT]:-strong}" in
    none)   :;;
    strong) cflags+=" -fstack-protector-strong"; cxxflags+=" -fstack-protector-strong";;
    all)    cflags+=" -fstack-protector-all"; cxxflags+=" -fstack-protector-all";;
  esac
  # TUNE
  case "${M[TUNE]:-generic}" in
    native) cflags+=" -march=native"; cxxflags+=" -march=native";;
    generic) cflags+=" -mtune=generic"; cxxflags+=" -mtune=generic";;
    *) cflags+=" -mtune=${M[TUNE]}"; cxxflags+=" -mtune=${M[TUNE]}";;
  endesac 2>/dev/null || true

  # SANITIZE
  case "${M[SANITIZE]:-none}" in
    address) M[ASAN]="1"; ldflags+=" -fsanitize=address"; cflags+=" -fsanitize=address"; cxxflags+=" -fsanitize=address";;
    ub)      ldflags+=" -fsanitize=undefined"; cflags+=" -fsanitize=undefined"; cxxflags+=" -fsanitize=undefined";;
    thread)  ldflags+=" -fsanitize=thread"; cflags+=" -fsanitize=thread"; cxxflags+=" -fsanitize=thread";;
    none)    :;;
  esac

  # LINKER
  case "${M[LINKER]:-auto}" in
    lld)  ldflags+=" -fuse-ld=lld";;
    mold) ldflags+=" -fuse-ld=mold";;
    gold) ldflags+=" -fuse-ld=gold";;
    bfd)  ldflags+=" -fuse-ld=bfd";;
    auto) :;;
  esac

  # STRIP
  case "${M[STRIP]:-on}" in
    on)  M[DO_STRIP]="true";;
    off) M[DO_STRIP]="false";;
  esac

  # JOBS
  local jobs="${M[JOBS]:-auto}"
  if [[ "$jobs" == "auto" ]]; then jobs="$(_prof_nproc)"; fi
  M[MAKEFLAGS]="-j${jobs}"
  M[NINJAFLAGS]="-j${jobs}"
  M[CARGO_BUILD_JOBS]="$jobs"

  # Deduplicar
  M[CFLAGS]="$(_prof_flags_dedup "$cflags")"
  M[CXXFLAGS]="$(_prof_flags_dedup "$cxxflags")"
  M[CPPFLAGS]="$(_prof_flags_dedup "$cppflags")"
  M[LDFLAGS]="$(_prof_flags_dedup "$ldflags")"

  # Determinismo base
  M[SOURCE_DATE_EPOCH]="${SOURCE_DATE_EPOCH:-1704067200}"
  M[TZ]="UTC"; M[LANG]="C"; M[LC_ALL]="C"; M[PYTHONHASHSEED]="0"
  # Go
  M[GOFLAGS]="${M[GOFLAGS]} -trimpath -buildvcs=false"
}

###############################################################################
# Resolução do profile (base + overrides)
###############################################################################
_prof_resolve() {
  # _prof_resolve <profile> [stage] [cat] [name] -> exporta env final para PATH_ACTIVE.tmp
  local prof="$1" stage="${2:-}" cat="${3:-}" name="${4:-}"
  local -A BASE=() STAGE=() CAT=() PROG=() MERGED=()

  _prof_paths_init || return $?

  local file_base=""
  if [[ -r "${PATH_BUILTIN}/${prof}.profile" ]]; then
    file_base="${PATH_BUILTIN}/${prof}.profile"
  elif [[ "$prof" == "default" && -L "${PATH_BUILTIN}/default" ]]; then
    file_base="${PATH_BUILTIN}/$(basename -- "$(readlink -f "${PATH_BUILTIN}/default")")"
  else
    prof_err "perfil não encontrado: $prof (procure em ${PATH_BUILTIN})"
    return 1
  fi

  _prof_load_kv_file "$file_base" BASE

  # Overrides por stage
  if [[ -n "$stage" && -d "${PATH_OVR_STAGE}/${stage}.d" ]]; then
    for f in "${PATH_OVR_STAGE}/${stage}.d/"*.override; do
      [[ -e "$f" ]] || continue
      _prof_load_kv_file "$f" STAGE
    done
  fi
  # Overrides por categoria
  if [[ -n "$cat" && -d "${PATH_OVR_CAT}/${cat}.d" ]]; then
    for f in "${PATH_OVR_CAT}/${cat}.d/"*.override; do
      [[ -e "$f" ]] || continue
      _prof_load_kv_file "$f" CAT
    done
  fi
  # Overrides por programa
  if [[ -n "$cat" && -n "$name" && -d "${PATH_OVR_PROG}/${cat}/${name}.d" ]]; then
    for f in "${PATH_OVR_PROG}/${cat}/${name}.d/"*.override; do
      [[ -e "$f" ]] || continue
      _prof_load_kv_file "$f" PROG
    done
  fi

  MERGED=()
  _prof_merge_maps MERGED BASE
  _prof_merge_maps MERGED STAGE
  _prof_merge_maps MERGED CAT
  _prof_merge_maps MERGED PROG

  # Aplicar lógica e materializar flags finais
  _prof_apply_overrides_logic MERGED

  # Stage policy
  if [[ "$stage" =~ ^(0|1)$ ]]; then
    # desabilitar LTO/PIE agressivo em stage0/1
    MERGED[CFLAGS]="${MERGED[CFLAGS]//-flto/}"
    MERGED[CXXFLAGS]="${MERGED[CXXFLAGS]//-flto/}"
    MERGED[LDFLAGS]="${MERGED[LDFLAGS]//-flto/}"
    MERGED[CFLAGS]="${MERGED[CFLAGS]//-fPIE/}"
    MERGED[CXXFLAGS]="${MERGED[CXXFLAGS]//-fPIE/}"
    MERGED[LDFLAGS]="${MERGED[LDFLAGS]//-pie/}"
  fi

  # Gerar active.env temporário
  local tmp="${PATH_ACTIVE}.tmp.$$"
  {
    echo "# active profile (auto-gerado)"; echo "PROFILE_NAME=${MERGED[PROFILE_NAME]:-$prof}"
    for k in CFLAGS CXXFLAGS CPPFLAGS LDFLAGS MAKEFLAGS NINJAFLAGS CARGO_BUILD_JOBS RUSTFLAGS GOFLAGS SOURCE_DATE_EPOCH TZ LANG LC_ALL PYTHONHASHSEED DO_STRIP; do
      [[ -n "${MERGED[$k]}" ]] && printf "%s=%q\n" "$k" "${MERGED[$k]}"
    done
    for k in PKG_CONFIG_PATH PKG_CONFIG_LIBDIR LINKER TUNE SANITIZE; do
      [[ -n "${MERGED[$k]}" ]] && printf "%s=%q\n" "$k" "${MERGED[$k]}"
    done
  } > "$tmp" 2>/dev/null || { prof_err "falha ao escrever active.env temporário"; return 3; }

  mv -f -- "$tmp" "$PATH_ACTIVE" 2>/dev/null || { prof_err "falha ao atualizar $PATH_ACTIVE"; return 3; }

  # Report
  {
    echo "profile: ${MERGED[PROFILE_NAME]:-$prof}"
    echo "stage: ${stage:-n/a}  cat: ${cat:-n/a}  name: ${name:-n/a}"
    echo
    echo "CFLAGS=${MERGED[CFLAGS]}"
    echo "CXXFLAGS=${MERGED[CXXFLAGS]}"
    echo "CPPFLAGS=${MERGED[CPPFLAGS]}"
    echo "LDFLAGS=${MERGED[LDFLAGS]}"
    echo "MAKEFLAGS=${MERGED[MAKEFLAGS]}  NINJAFLAGS=${MERGED[NINJAFLAGS]}  CARGO_BUILD_JOBS=${MERGED[CARGO_BUILD_JOBS]}"
    echo "LINKER=${MERGED[LINKER]:-auto}  TUNE=${MERGED[TUNE]:-generic}  SANITIZE=${MERGED[SANITIZE]:-none}"
    echo "DO_STRIP=${MERGED[DO_STRIP]:-true}"
  } > "$PATH_REPORT" 2>/dev/null || true

  # JSON opcional simples
  {
    printf '{'
    printf '"profile":"%s","stage":"%s","category":"%s","name":"%s",' "${MERGED[PROFILE_NAME]:-$prof}" "${stage:-}" "${cat:-}" "${name:-}"
    printf '"CFLAGS":%q,"CXXFLAGS":%q,"CPPFLAGS":%q,"LDFLAGS":%q,' "${MERGED[CFLAGS]}" "${MERGED[CXXFLAGS]}" "${MERGED[CPPFLAGS]}" "${MERGED[LDFLAGS]}"
    printf '"MAKEFLAGS":%q,"NINJAFLAGS":%q,"CARGO_BUILD_JOBS":%q' "${MERGED[MAKEFLAGS]}" "${MERGED[NINJAFLAGS]}" "${MERGED[CARGO_BUILD_JOBS]}"
    printf '}\n'
  } > "$PATH_JSON" 2>/dev/null || true

  return 0
}
# 14-adm-profile.part2.sh
# Validações, CLI helpers, list/show/apply/set-default/export/which
if [[ -n "${ADM_PROFILE_LOADED_PART2:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_PROFILE_LOADED_PART2=1
_prof_paths_init >/dev/null 2>&1 || true
###############################################################################
# Validações (toolchain, LTO, linker) — falham de forma clara
###############################################################################
_prof_cmd_or_fail() { command -v "$1" >/dev/null 2>&1 || { prof_err "comando obrigatório ausente: $1"; return 2; }; }

_prof_validate_toolchain_basic() {
  : > "$PATH_LOG_VALIDATE" 2>/dev/null || true
  _prof_cmd_or_fail cc || return 2
  _prof_cmd_or_fail ar || return 2
  _prof_cmd_or_fail ranlib || return 2
  _prof_cmd_or_fail pkg-config || prof_warn "pkg-config ausente (alguns builds podem falhar)"
  return 0
}

_prof_validate_compile_link() {
  # compila um hello.c com as flags ativas
  local tmpc="${ADM_TMP_ROOT%/}/phello-$$.c" tmpe="${ADM_TMP_ROOT%/}/phello-$$"
  cat > "$tmpc" <<'EOF'
#include <stdio.h>
int main(){ puts("ok"); return 0; }
EOF
  # shellcheck disable=SC1090
  source "$PATH_ACTIVE" 2>/dev/null || true
  local ccflags="${CFLAGS} ${CPPFLAGS}"
  local ldflags="${LDFLAGS}"
  cc $ccflags "$tmpc" -o "$tmpe" $ldflags >>"$PATH_LOG_VALIDATE" 2>&1 || {
    prof_err "falha ao compilar com CFLAGS/LDFLAGS atuais (veja: $PATH_LOG_VALIDATE)"; rm -f "$tmpc" "$tmpe"; return 4; }
  "$tmpe" >>"$PATH_LOG_VALIDATE" 2>&1 || {
    prof_err "binário de teste não executou (veja: $PATH_LOG_VALIDATE)"; rm -f "$tmpc" "$tmpe"; return 4; }
  rm -f "$tmpc" "$tmpe" 2>/dev/null || true
  return 0
}

_prof_validate_lto() {
  # testa -flto quando presente nas flags
  # shellcheck disable=SC1090
  source "$PATH_ACTIVE" 2>/dev/null || true
  if [[ "$CFLAGS" =~ -flto || "$LDFLAGS" =~ -flto ]]; then
    local tmpc="${ADM_TMP_ROOT%/}/plto-$$.c" tmpe="${ADM_TMP_ROOT%/}/plto-$$"
    echo "int main(){return 0;}" > "$tmpc"
    if ! cc $CFLAGS "$tmpc" -o "$tmpe" $LDFLAGS >>"$PATH_LOG_VALIDATE" 2>&1; then
      prof_warn "LTO parece não suportado pela toolchain; desativando no active.env"
      # remove -flto das variáveis e regrava
      local cflags="${CFLAGS//-flto/}" cxxflags="${CXXFLAGS//-flto/}" ldflags="${LDFLAGS//-flto/}"
      { awk '!/^CFLAGS=|^CXXFLAGS=|^LDFLAGS=/' "$PATH_ACTIVE"; printf "CFLAGS=%q\n" "$cflags"; printf "CXXFLAGS=%q\n" "$cxxflags"; printf "LDFLAGS=%q\n" "$ldflags"; } > "${PATH_ACTIVE}.new" 2>/dev/null || return 3
      mv -f -- "${PATH_ACTIVE}.new" "$PATH_ACTIVE"
    fi
    rm -f "$tmpc" "$tmpe" 2>/dev/null || true
  fi
  return 0
}

_prof_validate_linker() {
  # se -fuse-ld=lld/gold/mold foi pedido, testar presença
  # shellcheck disable=SC1090
  source "$PATH_ACTIVE" 2>/dev/null || true
  local req=""
  [[ "$LDFLAGS" == *"-fuse-ld=lld"* ]] && req="ld.lld"
  [[ "$LDFLAGS" == *"-fuse-ld=gold"* ]] && req="ld.gold"
  [[ "$LDFLAGS" == *"-fuse-ld=mold"* ]] && req="mold"
  [[ "$LDFLAGS" == *"-fuse-ld=bfd"*  ]] && req="" # padrão do binutils
  [[ -z "$req" ]] && return 0
  command -v "$req" >/dev/null 2>&1 || {
    if [[ "${PCTX[strict]}" == "true" ]]; then
      prof_err "linker solicitado indisponível: $req"; return 4
    fi
    prof_warn "linker solicitado indisponível ($req); usando o padrão"
    # Remover -fuse-ld da LDFLAGS
    local ldflags="${LDFLAGS/-fuse-ld=lld/}"; ldflags="${ldflags/-fuse-ld=gold/}"; ldflags="${ldflags/-fuse-ld=mold/}"
    { awk '!/^LDFLAGS=/' "$PATH_ACTIVE"; printf "LDFLAGS=%q\n" "$ldflags"; } > "${PATH_ACTIVE}.new" 2>/dev/null || return 3
    mv -f -- "${PATH_ACTIVE}.new" "$PATH_ACTIVE"
  }
  return 0
}

adm_profile_validate() {
  _prof_paths_init || return $?
  : > "$PATH_LOG_VALIDATE" 2>/dev/null || true
  _prof_validate_toolchain_basic || return $?
  _prof_validate_compile_link || return $?
  _prof_validate_lto || return $?
  _prof_validate_compile_link || return $?
  _prof_validate_linker || return $?
  adm_ok "validação do profile ativa concluída"
}

###############################################################################
# CLI helpers: list, show, which
###############################################################################
adm_profile_list() {
  _prof_paths_init || return $?
  local cur=""; [[ -r "$PATH_ACTIVE" ]] && cur="$(grep -E '^PROFILE_NAME=' "$PATH_ACTIVE" | sed 's/PROFILE_NAME=//; s/"//g')"
  for f in "${PATH_BUILTIN}/"*.profile; do
    [[ -e "$f" ]] || continue
    local n="$(basename -- "$f" .profile)"
    if [[ "$n" == "$cur" ]]; then echo "* $n"; else echo "  $n"; fi
  done
}

adm_profile_show() {
  _prof_paths_init || return $?
  local prof="${1:-}"
  if [[ -z "$prof" && -r "$PATH_ACTIVE" ]]; then
    echo "# active.env"
    cat "$PATH_ACTIVE"
    return 0
  fi
  if [[ -r "${PATH_BUILTIN}/${prof}.profile" ]]; then
    cat "${PATH_BUILTIN}/${prof}.profile"
    return 0
  fi
  prof_err "perfil não encontrado: ${prof:-<ativo>}"
  return 1
}

adm_profile_which() {
  _prof_paths_init || return $?
  if [[ -r "$PATH_ACTIVE" ]]; then
    grep -E '^PROFILE_NAME=' "$PATH_ACTIVE" | sed 's/PROFILE_NAME=//; s/"//g'
  else
    echo "none"
  fi
}

###############################################################################
# Apply e set-default
###############################################################################
adm_profile_apply() {
  local profile="" stage="" cat="" name=""
  local jobs="" lto="" pie="" relro="" linker="" sanitize="" tune="" strip=""
  PCTX[strict]=false; PCTX[verbose]=false; PCTX[no_test]=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) profile="$2"; shift 2;;
      --stage) stage="$2"; shift 2;;
      --cat|--category) cat="$2"; shift 2;;
      --name|--program) name="$2"; shift 2;;
      --jobs) jobs="$2"; shift 2;;
      --lto) lto="$2"; shift 2;;
      --pie) pie="$2"; shift 2;;
      --relro) relro="$2"; shift 2;;
      --linker) linker="$2"; shift 2;;
      --sanitize) sanitize="$2"; shift 2;;
      --tune) tune="$2"; shift 2;;
      --strip) strip="$2"; shift 2;;
      --strict) PCTX[strict]=true; shift;;
      --no-test) PCTX[no_test]=true; shift;;
      --verbose) PCTX[verbose]=true; shift;;
      *) profile="${profile:-$1}"; shift;;
    esac
  done
  _prof_paths_init || return $?
  adm_profile_create_builtins || return $?

  profile="${profile:-$ADM_PROFILE_DEFAULT}"

  adm_step "profile" "$profile" "resolvendo"
  _prof_resolve "$profile" "$stage" "$cat" "$name" || return $?

  # Overrides de CLI pós-resolução: reabrir active.env e sobrescrever logicamente
  # shellcheck disable=SC1090
  source "$PATH_ACTIVE" 2>/dev/null || true
  declare -A CLI=()
  [[ -n "$jobs" ]]    && CLI[JOBS]="$jobs"
  [[ -n "$lto" ]]     && CLI[LTO]="$lto"
  [[ -n "$pie" ]]     && CLI[PIE]="$pie"
  [[ -n "$relro" ]]   && CLI[RELRO]="$relro"
  [[ -n "$linker" ]]  && CLI[LINKER]="$linker"
  [[ -n "$sanitize" ]]&& CLI[SANITIZE]="$sanitize"
  [[ -n "$tune" ]]    && CLI[TUNE]="$tune"
  [[ -n "$strip" ]]   && CLI[STRIP]="$strip"

  if ((${#CLI[@]})); then
    # carregar base novamente em MAP e aplicar lógica
    declare -A MAP=()
    while IFS='=' read -r k v; do
      [[ -z "$k" ]] && continue
      v="${v%\"}"; v="${v#\"}"
      MAP["$k"]="$v"
    done < <(grep -E '^[A-Z0-9_]+=' "$PATH_ACTIVE" || true)

    for k in "${!CLI[@]}"; do MAP["$k"]="${CLI[$k]}"; done
    _prof_apply_overrides_logic MAP

    # regravar active.env
    local tmp="${PATH_ACTIVE}.cli.$$"
    {
      echo "PROFILE_NAME=${profile}"
      for k in CFLAGS CXXFLAGS CPPFLAGS LDFLAGS MAKEFLAGS NINJAFLAGS CARGO_BUILD_JOBS RUSTFLAGS GOFLAGS SOURCE_DATE_EPOCH TZ LANG LC_ALL PYTHONHASHSEED DO_STRIP; do
        [[ -n "${MAP[$k]}" ]] && printf "%s=%q\n" "$k" "${MAP[$k]}"
      done
      for k in PKG_CONFIG_PATH PKG_CONFIG_LIBDIR LINKER TUNE SANITIZE; do
        [[ -n "${MAP[$k]}" ]] && printf "%s=%q\n" "$k" "${MAP[$k]}"
      done
    } > "$tmp" 2>/dev/null || return 3
    mv -f -- "$tmp" "$PATH_ACTIVE" || return 3
  fi

  if [[ "${PCTX[no_test]}" != "true" ]]; then
    adm_step "profile" "$profile" "validando"
    adm_profile_validate || return $?
  else
    prof_warn "validações desabilitadas (--no-test)"
  fi

  adm_ok "profile aplicado: $(adm_profile_which)"
  return 0
}

adm_profile_set_default() {
  local prof="$1"
  _prof_paths_init || return $?
  [[ -r "${PATH_BUILTIN}/${prof}.profile" ]] || { prof_err "perfil inexistente: $prof"; return 1; }
  rm -f -- "${PATH_BUILTIN}/default" 2>/dev/null || true
  ln -s "${prof}.profile" "${PATH_BUILTIN}/default" 2>/dev/null || { prof_err "não foi possível atualizar default"; return 3; }
  adm_ok "perfil padrão atualizado para: $prof"
}

###############################################################################
# Export
###############################################################################
adm_profile_export() {
  _prof_paths_init || return $?
  if [[ ! -r "$PATH_ACTIVE" ]]; then
    prof_err "nenhum profile ativo (rode: adm_profile apply <profile>)"
    return 1
  fi
  case "$1" in
    --print-json) [[ -r "$PATH_JSON" ]] && cat "$PATH_JSON" || echo '{}' ;;
    *) cat "$PATH_ACTIVE" ;;
  esac
}
# 14-adm-profile.part3.sh
# CLI principal
if [[ -n "${ADM_PROFILE_LOADED_PART3:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_PROFILE_LOADED_PART3=1
###############################################################################
# Ajuda
###############################################################################
_prof_usage() {
  cat >&2 <<'EOF'
uso:
  adm_profile list
  adm_profile show [<profile>]
  adm_profile which
  adm_profile apply [--profile <name>] [--stage N] [--cat <categoria>] [--name <programa>]
                    [--jobs N] [--lto on|off|thin] [--pie on|off] [--relro full|partial|off]
                    [--linker bfd|gold|lld|mold] [--sanitize none|address|ub|thread]
                    [--tune generic|native|<cpu>] [--strip on|off]
                    [--strict] [--no-test] [--verbose]
  adm_profile set-default <profile>
  adm_profile validate
  adm_profile export [--print-json]
EOF
}

###############################################################################
# CLI
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="$1"; shift || true
  case "$cmd" in
    list)         adm_profile_list "$@" || exit $?;;
    show)         adm_profile_show "$@" || exit $?;;
    which)        adm_profile_which "$@" || exit $?;;
    apply)        adm_profile_apply "$@" || exit $?;;
    set-default)  adm_profile_set_default "$@" || exit $?;;
    validate)     adm_profile_validate "$@" || exit $?;;
    export)       adm_profile_export "$@" || exit $?;;
    ""|help|-h|--help) _prof_usage; exit 2;;
    *)
      prof_warn "comando desconhecido: $cmd"
      _prof_usage
      exit 2;;
  esac
fi

ADM_PROFILE_LOADED=1
export ADM_PROFILE_LOADED
