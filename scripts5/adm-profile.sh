#!/usr/bin/env sh
# adm-profile.sh — Gerenciador de perfis de build para o sistema ADM
# POSIX sh; compatível com dash/ash/bash. Sem dependências obrigatórias.
# # Listar perfis
# /usr/src/adm/bin/adm-profile.sh list
# Criar um perfil custom baseado em musl
# /usr/src/adm/bin/adm-profile.sh create minha-musl --from=musl
# Ajustar overrides na sessão e salvar no custom
# /usr/src/adm/bin/adm-profile.sh set OPT_LEVEL=-Os LTO=off --save minha-musl
# Selecionar perfis combinados (normal + clang)
# /usr/src/adm/bin/adm-profile.sh select normal,clang
# Ver efetivo (com validação e bonitinho)
# /usr/src/adm/bin/adm-profile.sh validate
# Exportar flags para o ambiente do build
eval "$(/usr/src/adm/bin/adm-profile.sh export)"
set -u
# =========================
# 0) Diretórios e estado
# =========================
: "${ADM_ROOT:=/usr/src/adm}"
ADM_PROFILES_DIR="$ADM_ROOT/profiles"
ADM_CUSTOM_DIR="$ADM_PROFILES_DIR/custom"
ADM_REGISTRY_DIR="$ADM_ROOT/registry"
ADM_STATE_DIR="$ADM_REGISTRY_DIR/state"
ADM_ACTIVE_FILE="$ADM_STATE_DIR/profile.active"
ADM_SESSION_OVR="$ADM_STATE_DIR/profile.session.conf"
# Contexto externo (podem vir de fora; defaults seguros)
: "${ADM_STAGE:=host}"    # host|stage0|stage1|stage2
: "${ADM_PROFILE:=normal}" # nome(s) atual(is), vírgula separada
: "${ADM_PKG_DIR:=$PWD}"
: "${ADM_PKG_NAME:=}"
: "${ADM_PKG_VERSION:=}"
: "${ADM_PIPELINE:=build}"
# =========================
# 1) Cores (bonito)
# =========================
: "${ADM_LOG_COLOR:=auto}" # auto|always|never
: "${NO_COLOR:=}"

_is_tty(){ [ -t 1 ]; }
_color_on=0
_color_setup(){
  if [ "$ADM_LOG_COLOR" = "never" ] || [ -n "$NO_COLOR" ] || [ "$TERM" = "dumb" ]; then
    _color_on=0
  elif [ "$ADM_LOG_COLOR" = "always" ] || _is_tty; then
    _color_on=1
  else
    _color_on=0
  fi
}
_b(){ [ $_color_on -eq 1 ] && printf '\033[1m'; }
_rst(){ [ $_color_on -eq 1 ] && printf '\033[0m'; }
_c_mag(){ [ $_color_on -eq 1 ] && printf '\033[35;1m'; } # rosa negrito (estágio)
_c_yel(){ [ $_color_on -eq 1 ] && printf '\033[33;1m'; } # amarelo negrito (caminho)
_c_dim(){ [ $_color_on -eq 1 ] && printf '\033[2m'; }
_c_cyn(){ [ $_color_on -eq 1 ] && printf '\033[36m'; }
_c_gry(){ [ $_color_on -eq 1 ] && printf '\033[38;5;244m'; }

# =========================
# 2) Logging (usa adm-log.sh se disponível)
# =========================
_log_have=0
# Se funções do adm-log.sh existirem, usar; senão, fallback
command -v adm_log_info >/dev/null 2>&1 && _log_have=1 || _log_have=0

ts(){ date +"%Y-%m-%dT%H:%M:%S%z" | sed 's/\([0-9][0-9]\)$/:\1/'; }
ctx_human(){
  _stage="$ADM_STAGE"; _pipe="$ADM_PIPELINE"; _pkg="$ADM_PKG_NAME"; _ver="$ADM_PKG_VERSION"
  _path="$ADM_PKG_DIR"
  if [ $_color_on -eq 1 ]; then
    printf "("
    _c_mag; printf "%s" "$_stage"; _rst
    [ -n "$_pipe" ] && { _c_gry; printf ":%s" "$_pipe"; _rst; }
    [ -n "$_pkg" ] && printf " %s" "$_pkg"
    [ -n "$_ver" ] && printf "@%s" "$_ver"
    printf " path="; _c_yel; printf "%s" "$_path"; _rst
    printf ")"
  else
    printf "(%s:%s %s@%s path=%s)" "$_stage" "$_pipe" "$_pkg" "$_ver" "$_path"
  fi
}
say(){
  _lvl="$1"; shift; _msg="$*"
  if [ $_log_have -eq 1 ]; then
    case "$_lvl" in
      INFO) adm_log_info "$_msg";;
      WARN) adm_log_warn "$_msg";;
      ERROR) adm_log_error "$_msg";;
      DEBUG) adm_log_debug "$_msg";;
      *) adm_log_info "$_msg";;
    esac
  else
    # Fallback humano bonito
    _color_setup
    case "$_lvl" in
      INFO) _tag="[INFO]";;
      WARN) _tag="[WARN]";;
      ERROR) _tag="[ERROR]";;
      DEBUG) _tag="[DEBUG]";;
      *) _tag="[$_lvl]";;
    esac
    printf "%s %s %s %s\n" "$_tag" "[$(ts)]" "$(ctx_human)" "$_msg"
  fi
}

die(){ say ERROR "$*"; exit 1; }

# =========================
# 3) Util: IO/Conf
# =========================
ensure_dirs(){
  for d in "$ADM_PROFILES_DIR" "$ADM_CUSTOM_DIR" "$ADM_STATE_DIR"; do
    [ -d "$d" ] || mkdir -p "$d" || die "não foi possível criar diretório: $d"
  done
}

# Cria perfis padrão se ausentes
write_if_missing(){
  _f="$1"; shift; _content="$*"
  [ -f "$_f" ] && return 0
  printf "%s\n" "$_content" >"$_f" || die "falha ao criar $_f"
}

default_profile_minimal(){
cat <<'EOF'
# minimal.conf — compat primeiro (stage0 friendly)
OPT_LEVEL=-O2
PIPE=off
MARCH=generic
LTO=off
PGO=off
STACK_PROTECTOR=strong
RELRO=full
FORTIFY=on
PIE=on
AS_NEEDED=on
LINKER=bfd
DEBUG=min
STRIP=install
DETERMINISTIC_AR=on
SOURCE_DATE_EPOCH=auto
MAKE_JOBS=auto
EOF
}
default_profile_normal(){
cat <<'EOF'
# normal.conf — padrão equilibrado
OPT_LEVEL=-O2
PIPE=on
MARCH=x86-64-v2
LTO=thin
PGO=off
STACK_PROTECTOR=strong
RELRO=full
FORTIFY=on
PIE=on
AS_NEEDED=on
LINKER=gold
DEBUG=min
STRIP=install
ICF=on
GC_SECTIONS=on
DETERMINISTIC_AR=on
SOURCE_DATE_EPOCH=auto
MAKE_JOBS=auto
EOF
}
default_profile_aggressive(){
cat <<'EOF'
# aggressive.conf — máximo seguro
OPT_LEVEL=-O3
PIPE=on
MARCH=native
LTO=full
PGO=off
STACK_PROTECTOR=strong
RELRO=full
FORTIFY=on
PIE=on
AS_NEEDED=on
LINKER=lld
DEBUG=min
STRIP=install
ICF=on
GC_SECTIONS=on
DETERMINISTIC_AR=on
SOURCE_DATE_EPOCH=auto
MAKE_JOBS=auto
EOF
}
default_profile_glibc(){
cat <<'EOF'
# glibc.conf — ajustes glibc
FORTIFY=on
RELRO=full
PIE=on
STACK_PROTECTOR=strong
AS_NEEDED=on
LINKER=gold
ICF=on
GC_SECTIONS=on
ALLOW_LTO_STAGE0=off
EOF
}
default_profile_musl(){
cat <<'EOF'
# musl.conf — compat musl (evita glibc-isms)
FORTIFY=off
RELRO=full
PIE=on
STACK_PROTECTOR=strong
AS_NEEDED=on
LINKER=lld
ICF=on
GC_SECTIONS=on
LTO=off
EOF
}
default_profile_clang(){
cat <<'EOF'
# clang.conf — toolchain LLVM
CC=clang
CXX=clang++
AR=llvm-ar
RANLIB=llvm-ranlib
NM=llvm-nm
STRIP=llvm-strip
LD=ld.lld
LINKER=lld
OPT_LEVEL=-O2
LTO=thin
STACK_PROTECTOR=strong
RELRO=full
PIE=on
EOF
}

ensure_default_profiles(){
  ensure_dirs
  write_if_missing "$ADM_PROFILES_DIR/minimal.conf"   "$(default_profile_minimal)"
  write_if_missing "$ADM_PROFILES_DIR/normal.conf"    "$(default_profile_normal)"
  write_if_missing "$ADM_PROFILES_DIR/aggressive.conf" "$(default_profile_aggressive)"
  write_if_missing "$ADM_PROFILES_DIR/glibc.conf"     "$(default_profile_glibc)"
  write_if_missing "$ADM_PROFILES_DIR/musl.conf"      "$(default_profile_musl)"
  write_if_missing "$ADM_PROFILES_DIR/clang.conf"     "$(default_profile_clang)"
}

# Carrega um .conf KEY=VALUE em ambiente atual (com validação de chave)
load_conf_file(){
  _file="$1"
  [ -f "$_file" ] || die "perfil não encontrado: $_file"
  # shellcheck disable=SC2162
  while IFS= read line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue;;
      *=*)
        key=$(printf "%s" "$line" | sed 's/=.*//')
        val=$(printf "%s" "$line" | sed 's/^[^=]*=//')
        case "$key" in
          *[!A-Z0-9_]*|'') say WARN "chave inválida ignorada em $_file: $key"; continue;;
        esac
        # Remover espaços laterais
        key=$(printf "%s" "$key" | sed 's/[[:space:]]//g')
        # Exporta como var de overlay: PRO_XXX="value"
        eval "PRO_${key}=\"\$val\""
        ;;
      *) say WARN "linha inválida ignorada em $_file: $line";;
    esac
  done <"$_file"
}

# Limpa variáveis PRO_*
clear_overlay(){
  for v in $(set | sed -n 's/^\(PRO_[A-Z0-9_]*\)=.*/\1/p'); do
    unset "$v"
  done
}

# Mescla perfis (ordem: primeiro o menos prioritário)
merge_profiles(){
  clear_overlay
  for name in "$@"; do
    case "$name" in
      */*|*..*) die "nome de perfil inválido: $name";;
    esac
    if [ -f "$ADM_PROFILES_DIR/$name.conf" ]; then
      load_conf_file "$ADM_PROFILES_DIR/$name.conf"
    elif [ -f "$ADM_CUSTOM_DIR/$name.conf" ]; then
      load_conf_file "$ADM_CUSTOM_DIR/$name.conf"
    else
      die "perfil '$name' não existe (nem base nem custom)"
    fi
  done
  # Overlay de sessão (se existir)
  [ -f "$ADM_SESSION_OVR" ] && load_conf_file "$ADM_SESSION_OVR"
  # local.conf (global)
  [ -f "$ADM_PROFILES_DIR/local.conf" ] && load_conf_file "$ADM_PROFILES_DIR/local.conf"
}

# Extrai valor efetivo: prioridade do overlay → senão default seguro
get_effective(){
  _k="$1"; _d="${2:-}"
  eval "v=\${PRO_${_k}:-}"
  [ -n "${v:-}" ] && { printf "%s" "$v"; return; }
  printf "%s" "$_d"
}

# =========================
# 4) Cálculo de flags
# =========================
calc_flags(){
  # Defaults seguros
  CFLAGS="-O2"
  CXXFLAGS="-O2"
  CPPFLAGS=""
  LDFLAGS="-Wl,-O1 -Wl,--as-needed"
  MAKEFLAGS=""
  RUSTFLAGS=""
  GOFLAGS=""
  CC="${CC:-gcc}"
  CXX="${CXX:-g++}"
  LD="${LD:-ld}"
  AR="${AR:-ar}"
  RANLIB="${RANLIB:-ranlib}"
  NM="${NM:-nm}"
  STRIP_BIN="${STRIP_BIN:-strip}"
  PKG_CONFIG="${PKG_CONFIG:-pkg-config}"

  # Lê overlay
  OPT_LEVEL=$(get_effective OPT_LEVEL "-O2")
  PIPE=$(get_effective PIPE "on")
  MARCH=$(get_effective MARCH "generic")
  LTO=$(get_effective LTO "off")
  PGO=$(get_effective PGO "off")
  STACK_PROTECTOR=$(get_effective STACK_PROTECTOR "strong")
  RELRO=$(get_effective RELRO "full")
  FORTIFY=$(get_effective FORTIFY "on")
  PIE=$(get_effective PIE "on")
  AS_NEEDED=$(get_effective AS_NEEDED "on")
  LINKER=$(get_effective LINKER "")
  DEBUG_KIND=$(get_effective DEBUG "min")
  STRIP_KIND=$(get_effective STRIP "install")
  ICF=$(get_effective ICF "on")
  GC_SECTIONS=$(get_effective GC_SECTIONS "on")
  MAKE_JOBS=$(get_effective MAKE_JOBS "auto")

  CC=$(get_effective CC "$CC")
  CXX=$(get_effective CXX "$CXX")
  LD_BIN=$(get_effective LD "$LD")
  AR=$(get_effective AR "$AR")
  RANLIB=$(get_effective RANLIB "$RANLIB")
  NM=$(get_effective NM "$NM")
  STRIP_BIN=$(get_effective STRIP "$STRIP_BIN")
  PKG_CONFIG=$(get_effective PKG_CONFIG "$PKG_CONFIG")
  PKG_CONFIG_PATH=$(get_effective PKG_CONFIG_PATH "${PKG_CONFIG_PATH:-}")

  # Stage0 restrições
  if [ "$ADM_STAGE" = "stage0" ]; then
    [ "$MARCH" != "generic" ] && { say WARN "stage0 força MARCH=generic (era $MARCH)"; MARCH="generic"; }
    [ "$LTO" != "off" ] && { say WARN "stage0 desabilita LTO (era $LTO)"; LTO="off"; }
    [ "$PGO" != "off" ] && { say WARN "stage0 desabilita PGO (era $PGO)"; PGO="off"; }
    [ -z "$LINKER" ] || [ "$LINKER" = "bfd" ] || { say WARN "stage0 sugere LINKER=bfd (era $LINKER)"; LINKER="bfd"; }
  fi

  # C/C++
  CFLAGS="$OPT_LEVEL"
  CXXFLAGS="$OPT_LEVEL"
  [ "$PIPE" = "on" ] && { CFLAGS="$CFLAGS -pipe"; CXXFLAGS="$CXXFLAGS -pipe"; }
  [ -n "$MARCH" ] && { CFLAGS="$CFLAGS -march=$MARCH"; CXXFLAGS="$CXXFLAGS -march=$MARCH"; }
  case "$STACK_PROTECTOR" in
    strong) CFLAGS="$CFLAGS -fstack-protector-strong"; CXXFLAGS="$CXXFLAGS -fstack-protector-strong";;
    all)    CFLAGS="$CFLAGS -fstack-protector-all"; CXXFLAGS="$CXXFLAGS -fstack-protector-all";;
    off)    :;;
  esac
  [ "$PIE" = "on" ] && { CFLAGS="$CFLAGS -fPIC"; CXXFLAGS="$CXXFLAGS -fPIC"; }
  [ "$FORTIFY" = "on" ] && { CPPFLAGS="$CPPFLAGS -D_FORTIFY_SOURCE=2"; }

  # LTO
  case "$LTO" in
    thin) CFLAGS="$CFLAGS -flto=thin"; CXXFLAGS="$CXXFLAGS -flto=thin";;
    full) CFLAGS="$CFLAGS -flto"; CXXFLAGS="$CXXFLAGS -flto";;
    off|*) :;;
  esac

  # Linker e hardening
  [ -n "$LINKER" ] && LDFLAGS="$LDFLAGS -fuse-ld=$LINKER"
  [ "$AS_NEEDED" = "on" ] && LDFLAGS="$LDFLAGS -Wl,--as-needed"
  case "$RELRO" in
    full) LDFLAGS="$LDFLAGS -Wl,-z,relro -Wl,-z,now";;
    partial) LDFLAGS="$LDFLAGS -Wl,-z,relro";;
    off|*) :;;
  esac
  [ "$ICF" = "on" ] && LDFLAGS="$LDFLAGS -Wl,--icf=all"
  [ "$GC_SECTIONS" = "on" ] && LDFLAGS="$LDFLAGS -Wl,--gc-sections"

  # MAKEFLAGS
  if [ "$MAKE_JOBS" = "auto" ]; then
    if command -v nproc >/dev/null 2>&1; then
      MAKEFLAGS="-j$(nproc)"
    else
      MAKEFLAGS="-j2"
    fi
  else
    MAKEFLAGS="-j$MAKE_JOBS"
  fi

  # Toolchain mapping
  [ -n "$LD_BIN" ] && LD="$LD_BIN"

  # RUST/GO (básico)
  case "$LTO" in
    thin) RUSTFLAGS="$RUSTFLAGS -C lto=thin";;
    full) RUSTFLAGS="$RUSTFLAGS -C lto=fat";;
  esac
  [ "$PIE" = "on" ] && RUSTFLAGS="$RUSTFLAGS -C link-arg=-Wl,-z,relro -C link-arg=-Wl,-z,now"
  GOFLAGS="$GOFLAGS"

  export CFLAGS CXXFLAGS CPPFLAGS LDFLAGS MAKEFLAGS RUSTFLAGS GOFLAGS \
         CC CXX LD AR RANLIB NM STRIP_BIN PKG_CONFIG PKG_CONFIG_PATH
}

# =========================
# 5) Validação e Fallbacks
# =========================
validate_env(){
  # LINKER
  case "${LINKER:-}" in
    lld)
      command -v ld.lld >/dev/null 2>&1 || { say WARN "ld.lld ausente; tentando mold/gold/bfd"; LINKER=""; }
      ;;
    mold)
      command -v mold >/dev/null 2>&1 || { say WARN "mold ausente; tentando lld/gold/bfd"; LINKER=""; }
      ;;
    gold)
      command -v ld.gold >/dev/null 2>&1 || { say WARN "gold ausente; tentando lld/mold/bfd"; LINKER=""; }
      ;;
    bfd|"")
      :;;
    *)
      say WARN "LINKER inválido/indisponível: ${LINKER} — fallback automático"
      LINKER=""
      ;;
  esac

  if [ -z "${LINKER:-}" ]; then
    if command -v ld.lld >/dev/null 2>&1; then LINKER="lld"
    elif command -v mold >/dev/null 2>&1; then LINKER="mold"
    elif command -v ld.gold >/dev/null 2>&1; then LINKER="gold"
    else LINKER="bfd"; fi
    say INFO "linker escolhido: $LINKER"
    LDFLAGS="$(printf "%s" "$LDFLAGS" | sed 's/-fuse-ld=[^ ]*//g') -fuse-ld=$LINKER"
  fi

  # CC/CXX
  if ! command -v "$CC" >/dev/null 2>&1; then
    if command -v clang >/dev/null 2>&1; then CC="clang"; CXX="clang++"; say WARN "CC ausente; usando clang"
    elif command -v gcc >/dev/null 2>&1; then CC="gcc"; CXX="g++"; say WARN "CC ausente; usando gcc"
    else die "nenhum compilador C encontrado (gcc/clang)"; fi
  fi
  if ! command -v "$CXX" >/dev/null 2>&1; then
    if [ "$CC" = "clang" ] && command -v clang++ >/dev/null 2>&1; then CXX="clang++"
    elif [ "$CC" = "gcc" ] && command -v g++ >/dev/null 2>&1; then CXX="g++"
    else say WARN "CXX ausente; continuará sem C++"; fi
  fi

  # LTO checagem simples (heurística)
  case "$LTO" in
    thin|full)
      case "$CC" in
        *clang*) : ;; # ok
        *gcc*)
          # Suporte depende de versão; mantemos com aviso
          "$CC" --help >/dev/null 2>&1 || { say WARN "CC não aceita --help, desativando LTO"; LTO="off"; }
          ;;
        *)
          say WARN "CC desconhecido para LTO; desativando"; LTO="off";;
      esac
      ;;
  esac

  # Stage0: reforça políticas
  if [ "$ADM_STAGE" = "stage0" ]; then
    case "$LINKER" in lld|mold) say WARN "stage0: alterando LINKER de $LINKER para bfd"; LINKER="bfd"; LDFLAGS="$(printf "%s" "$LDFLAGS" | sed 's/-fuse-ld=[^ ]*//g') -fuse-ld=bfd";; esac
  fi

  # Ferramentas auxiliares
  for t in "$AR" "$RANLIB" "$NM" "$STRIP_BIN"; do
    command -v "$t" >/dev/null 2>&1 || say WARN "ferramenta não encontrada: $t"
  done
  [ -n "${PKG_CONFIG_PATH:-}" ] || :
}

print_effective_human(){
  _color_setup
  _rule="============================================================="
  printf "%s\n" "$_rule"
  _b; printf "PERFIL EFETIVO "; _rst
  printf "%s " "$(ctx_human)"; printf "\n%s\n" "$_rule"
  printf "%-14s %s\n" "Profiles:" "$ACTIVE_PROFILES"
  printf "%-14s %s\n" "CC/CXX:"    "$CC / $CXX"
  printf "%-14s %s\n" "LINKER:"    "$LINKER"
  printf "%-14s %s\n" "CFLAGS:"    "$CFLAGS"
  printf "%-14s %s\n" "CXXFLAGS:"  "$CXXFLAGS"
  printf "%-14s %s\n" "CPPFLAGS:"  "$CPPFLAGS"
  printf "%-14s %s\n" "LDFLAGS:"   "$LDFLAGS"
  printf "%-14s %s\n" "RUSTFLAGS:" "$RUSTFLAGS"
  printf "%-14s %s\n" "GOFLAGS:"   "$GOFLAGS"
  printf "%-14s %s\n" "MAKEFLAGS:" "$MAKEFLAGS"
  printf "%-14s %s\n" "PKG_CONFIG:" "$PKG_CONFIG"
  printf "%-14s %s\n" "PKG_PATH:"   "${PKG_CONFIG_PATH:-}"
  printf "%s\n" "$_rule"
}

# =========================
# 6) Subcomandos
# =========================
sub_list(){
  ensure_default_profiles
  say INFO "perfis disponíveis em $ADM_PROFILES_DIR e $ADM_CUSTOM_DIR"
  for f in "$ADM_PROFILES_DIR"/*.conf "$ADM_CUSTOM_DIR"/*.conf 2>/dev/null; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .conf)
    printf " - %s\n" "$base"
  done
  [ -f "$ADM_ACTIVE_FILE" ] && { printf "ativo(s): "; sed -n 's/^PROFILES=//p' "$ADM_ACTIVE_FILE"; }
}

sub_show(){
  ensure_default_profiles
  if [ $# -eq 0 ]; then
    # efetivo
    sub_print
    return
  fi
  for name in $(printf "%s" "$*" | tr ',' ' '); do
    clear_overlay
    if [ -f "$ADM_PROFILES_DIR/$name.conf" ]; then load_conf_file "$ADM_PROFILES_DIR/$name.conf"
    elif [ -f "$ADM_CUSTOM_DIR/$name.conf" ]; then load_conf_file "$ADM_CUSTOM_DIR/$name.conf"
    else die "perfil '$name' não existe"; fi
    _rule="----------------------------"
    printf "%s\n" "$_rule"; _b; printf "PROFILE %s\n" "$name"; _rst; printf "%s\n" "$_rule"
    set | sed -n 's/^PRO_\([A-Z0-9_]*\)=\(.*\)$/\1=\2/p'
  done
}

sub_select(){
  ensure_default_profiles
  [ $# -ge 1 ] || die "uso: select <perfil>[,<perfil2>...]"
  names=$(printf "%s" "$1" | tr ',' ' ')
  # valida
  for n in $names; do
    [ -f "$ADM_PROFILES_DIR/$n.conf" ] || [ -f "$ADM_CUSTOM_DIR/$n.conf" ] || die "perfil inexistente: $n"
  done
  mkdir -p "$ADM_STATE_DIR" || die "não foi possível criar $ADM_STATE_DIR"
  printf "PROFILES=%s\nSET_AT=%s\n" "$(printf "%s" "$1")" "$(ts)" >"$ADM_ACTIVE_FILE" || die "falha ao gravar $ADM_ACTIVE_FILE"
  say INFO "perfil(s) ativo(s): $1"
}

sub_create(){
  ensure_default_profiles
  [ $# -ge 1 ] || die "uso: create <nome> [--from=a,b]"
  name="$1"; shift
  src=""
  [ $# -ge 1 ] && { [ "$1" = "${1#--from=}" ] || src="${1#--from=}"; }
  case "$name" in */*|*..*) die "nome inválido: $name";; esac
  out="$ADM_CUSTOM_DIR/$name.conf"
  [ -f "$out" ] && die "já existe: $out (use outro nome)"
  if [ -n "$src" ]; then
    merge_profiles $(printf "%s" "$src" | tr ',' ' ')
    # Produz arquivo com as chaves definidas
    { set | sed -n 's/^PRO_\([A-Z0-9_]*\)=\(.*\)$/\1=\2/p'; } >"$out" || die "falha ao escrever $out"
    say INFO "criado $out a partir de: $src"
  else
    cat >"$out" <<'EOF' || die "falha ao escrever template"
# custom profile template
# Use KEY=VALUE (uma por linha). Exemplos:
OPT_LEVEL=-O2
PIPE=on
MARCH=generic
LTO=off
PGO=off
STACK_PROTECTOR=strong
RELRO=full
FORTIFY=on
PIE=on
AS_NEEDED=on
LINKER=bfd
DEBUG=min
STRIP=install
MAKE_JOBS=auto
EOF
    say INFO "criado template $out"
  fi
}

sub_set(){
  ensure_default_profiles
  [ $# -ge 1 ] || die "uso: set KEY=VALUE [...] [--save <nome>|--save-active]"
  save_target=""
  args=
  while [ $# -gt 0 ]; do
    case "$1" in
      --save-active) save_target="active"; shift;;
      --save) shift; [ $# -ge 1 ] || die "falta nome após --save"; save_target="custom:$1"; shift;;
      *)
        case "$1" in *=*) args="$args $1"; shift;; *) die "par inválido: $1";; esac
        ;;
    esac
  done
  [ -n "$args" ] || die "nenhum KEY=VALUE informado"
  mkdir -p "$ADM_STATE_DIR" || die "não foi possível criar $ADM_STATE_DIR"
  # aplica na sessão (SESSION_OVR)
  for kv in $args; do
    key=${kv%%=*}; val=${kv#*=}
    case "$key" in *[!A-Z0-9_]*|'') die "chave inválida: $key";; esac
    printf "%s=%s\n" "$key" "$val" >>"$ADM_SESSION_OVR" || die "falha ao gravar sessão"
  done
  say INFO "overrides aplicados na sessão"
  # salvar permanente?
  [ -z "$save_target" ] || {
    case "$save_target" in
      active)
        [ -f "$ADM_ACTIVE_FILE" ] || die "não há perfil ativo para --save-active"
        profs=$(sed -n 's/^PROFILES=//p' "$ADM_ACTIVE_FILE")
        [ -n "$profs" ] || die "arquivo de ativo inválido"
        # salvar no topo como custom overlay de sessão “ativa”
        out="$ADM_CUSTOM_DIR/_active_overlay.conf"
        for kv in $args; do printf "%s\n" "$kv"; done >>"$out" || die "falha ao salvar $out"
        say INFO "overrides salvos em $out (será aplicado junto ao ativo)"
        ;;
      custom:*)
        name="${save_target#custom:}"
        out="$ADM_CUSTOM_DIR/$name.conf"
        [ -f "$out" ] || touch "$out" || die "falha ao criar $out"
        for kv in $args; do printf "%s\n" "$kv"; done >>"$out" || die "falha ao salvar $out"
        say INFO "overrides salvos em $out"
        ;;
    esac
  }
}
sub_export(){
  # Determina perfis ativos: parâmetro > arquivo active > ADM_PROFILE
  ensure_default_profiles
  if [ $# -ge 1 ]; then
    ACTIVE_PROFILES=$(printf "%s" "$1" | tr -d ' ')
  elif [ -f "$ADM_ACTIVE_FILE" ]; then
    ACTIVE_PROFILES=$(sed -n 's/^PROFILES=//p' "$ADM_ACTIVE_FILE")
  else
    ACTIVE_PROFILES="$ADM_PROFILE"
  fi
  merge_profiles $(printf "%s" "$ACTIVE_PROFILES" | tr ',' ' ')
  calc_flags
  validate_env
  # Exporta KEY=VALUE para uso via eval/export
  cat <<EOF
CFLAGS=$CFLAGS
CXXFLAGS=$CXXFLAGS
CPPFLAGS=$CPPFLAGS
LDFLAGS=$LDFLAGS
MAKEFLAGS=$MAKEFLAGS
RUSTFLAGS=$RUSTFLAGS
GOFLAGS=$GOFLAGS
CC=$CC
CXX=$CXX
LD=$LD
AR=$AR
RANLIB=$RANLIB
NM=$NM
STRIP=$STRIP_BIN
PKG_CONFIG=$PKG_CONFIG
PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-}
ADM_ACTIVE_PROFILES=$ACTIVE_PROFILES
EOF
}

sub_validate(){
  # Apenas roda merge+calc+validate e imprime resumo
  ensure_default_profiles
  if [ $# -ge 1 ]; then
    ACTIVE_PROFILES=$(printf "%s" "$1" | tr -d ' ')
  elif [ -f "$ADM_ACTIVE_FILE" ]; then
    ACTIVE_PROFILES=$(sed -n 's/^PROFILES=//p' "$ADM_ACTIVE_FILE")
  else
    ACTIVE_PROFILES="$ADM_PROFILE"
  fi
  merge_profiles $(printf "%s" "$ACTIVE_PROFILES" | tr ',' ' ')
  calc_flags
  validate_env
  print_effective_human
}

sub_print(){
  # Mostra efetivo (atalho para validate sem mensagens extra)
  sub_validate "$@"
}

usage(){
  cat <<'EOF'
Uso: adm-profile.sh <subcomando> [args]

Subcomandos:
  list                         - lista perfis disponíveis (base e custom)
  show [perfil[,perfil2]...]   - mostra conteúdo de 1..N perfis; sem args mostra efetivo
  select <perfil[,perfil2]...> - define perfis ativos (salva em registry/state/profile.active)
  create <nome> [--from=a,b]   - cria perfil custom (template ou a partir de outros)
  set KEY=VAL [...] [--save <nome>|--save-active]
                               - aplica overrides de sessão; opção de salvar
  export [perfil[,perfil2]...] - imprime KEY=VALUE efetivos para eval/export
  validate [perfil[,perfil2]...]
                               - valida ambiente e mostra resumo efetivo
  print                        - sinônimo de validate

Perfis base incluídos: minimal, normal, aggressive, glibc, musl, clang
Perfis custom ficam em: profiles/custom/<nome>.conf
EOF
}

main(){
  _color_setup
  cmd="${1:-}"; shift || true
  case "${cmd:-}" in
    list)       sub_list "$@";;
    show)       sub_show "$@";;
    select)     sub_select "$@";;
    create)     sub_create "$@";;
    set)        sub_set "$@";;
    export)     sub_export "$@";;
    validate)   sub_validate "$@";;
    print)      sub_print "$@";;
    ""|-h|--help|help) usage;;
    *) die "subcomando desconhecido: ${cmd:-<vazio>}. Use --help";;
  esac
}

# Execução direta
if [ "${ADM_PROFILE_AS_LIB:-0}" -eq 0 ]; then
  main "$@"
fi
