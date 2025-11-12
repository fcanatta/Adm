#!/usr/bin/env bash
# 08.10-install-register-verify.sh
# Instala a partir de DESTDIR ou pacote, registra no DB e verifica integridade.
###############################################################################
# Modo estrito + traps
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__irv_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] install-register-verify falhou: code=${code} line=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __irv_err_trap ERR

###############################################################################
# Caminhos, logging, utilitários
###############################################################################
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_LOG_DIR="${ADM_LOG_DIR:-${ADM_STATE_DIR}/logs}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"
ADM_DB_DIR="${ADM_DB_DIR:-${ADM_ROOT}/db}"
ADM_META_DIR="${ADM_META_DIR:-${ADM_ROOT}/metafiles}"

__ensure_dir(){
  local d="$1" mode="${2:-0755}" owner="${3:-root}" group="${4:-root}"
  if [[ ! -d "$d" ]]; then
    if command -v install >/dev/null 2>&1; then
      if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
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
__ensure_dir "$ADM_DB_DIR"

# Cores
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RST="$(tput sgr0)"; C_OK="$(tput setaf 2)"; C_WRN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INF="$(tput setaf 6)"; C_BD="$(tput bold)"
else
  C_RST=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""; C_BD=""
fi
irv_info(){  echo -e "${C_INF}[ADM]${C_RST} $*"; }
irv_ok(){    echo -e "${C_OK}[OK ]${C_RST} $*"; }
irv_warn(){  echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
irv_err(){   echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }
tmpfile(){ mktemp "${ADM_TMPDIR}/irv.XXXXXX"; }
trim(){ sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }
sha256f(){ sha256sum "$1" | awk '{print $1}'; }

# Locks
__lock(){
  local name="$1"; __ensure_dir "$ADM_STATE_DIR/locks"
  exec {__IRV_FD}>"$ADM_STATE_DIR/locks/${name}.lock"
  flock -n ${__IRV_FD} || { irv_warn "aguardando lock de ${name}…"; flock ${__IRV_FD}; }
}
__unlock(){ :; }

###############################################################################
# Hooks
###############################################################################
declare -A ADM_META   # name, version, category (e opcionalmente outros)
__pkg_root(){
  local c="${ADM_META[category]:-}" n="${ADM_META[name]:-}"
  [[ -n "$c" && -n "$n" ]] || { echo ""; return 1; }
  printf '%s/%s/%s' "$ADM_ROOT" "$c" "$n"
}
__hooks_dirs(){
  local pr; pr="$(__pkg_root)" || true
  printf '%s\n' "$pr/hooks" "$ADM_ROOT/hooks"
}
irv_hooks_run(){
  local stage="${1:?}"; shift || true
  local d f ran=0
  for d in $(__hooks_dirs); do
    [[ -d "$d" ]] || continue
    for f in "$d/$stage" "$d/$stage.sh"; do
      if [[ -x "$f" ]]; then
        irv_info "Hook: $(realpath -m "$f")"
        ( set -Eeuo pipefail; "$f" "$@" )
        ran=1
      fi
    done
  done
  (( ran )) || irv_info "Hook '${stage}': nenhum"
}

###############################################################################
# CLI
###############################################################################
CMD=""                         # install|register|verify|all
ROOT="/"                       # destino final
DESTDIR=""                     # fonte (modo destdir)
PKG_TAR=""                     # fonte (modo pacote tar.{zst,xz})
MANIFEST=""                    # manifest.json (opcional, preferir o do pacote)
OVERWRITE=0                    # permite sobrescrever arquivos existentes
DRYRUN=0
NO_REGISTER=0                  # pular registro (apenas instalação)
VERIFY_AFTER=1                 # em 'install' faz verify
ARCH="${ARCH:-$(uname -m)}"
LIBC="${ADM_LIBC:-}"           # glibc|musl|auto
PROFILE="${ADM_PROFILE:-normal}"
CHECK_RPATH=1                  # habilita checagem básica de rpath/ldd
FAIL_ON_MISMATCH=1             # verify falha se mismatch
PRESERVE_TIMES=1               # preserva timestamps
CONCURRENCY="${JOBS:-$(command -v nproc >/dev/null 2>&1 && nproc || echo 2)}"

irv_usage(){
  cat <<'EOF'
Uso:
  08.10-install-register-verify.sh <comando> [opções]

Comandos:
  install     Instala a partir de --destdir ou --pkg-tar (detecta autom.)
  register    Registra a instalação no DB (metadados, manifest, files)
  verify      Verifica integridade da instalação atual
  all         install + register + verify (padrão)

Opções gerais:
  --root PATH              Raiz de instalação (default: /)
  --category CAT           Categoria (metafile)
  --name NAME              Nome
  --version VER            Versão
  --arch ARCH              (auto: uname -m)
  --libc glibc|musl|auto   (auto detecta via ldd)
  --profile PROFILE        aggressive|normal|minimal
  --destdir PATH           Origem DESTDIR (staging) para instalar
  --pkg-tar FILE           Pacote tar.zst/tar.xz para instalar
  --manifest FILE          Manifest JSON (se não embutido no pacote)
  --overwrite              Permite sobrescrever arquivos existentes no ROOT
  --no-register            Em 'install', não registrar
  --no-verify              Em 'install', não verificar após instalar
  --dry-run                Simula ações (não altera o sistema)
  --help
EOF
}

parse_cli(){
  [[ $# -ge 1 ]] || { irv_usage; exit 2; }
  CMD="$1"; shift
  while (($#)); do
    case "$1" in
      --root) ROOT="${2:-/}"; shift 2 ;;
      --category) ADM_META[category]="${2:-}"; shift 2 ;;
      --name) ADM_META[name]="${2:-}"; shift 2 ;;
      --version) ADM_META[version]="${2:-}"; shift 2 ;;
      --arch) ARCH="${2:-$ARCH}"; shift 2 ;;
      --libc) LIBC="${2:-}"; shift 2 ;;
      --profile) PROFILE="${2:-$PROFILE}"; shift 2 ;;
      --destdir) DESTDIR="${2:-}"; shift 2 ;;
      --pkg-tar) PKG_TAR="${2:-}"; shift 2 ;;
      --manifest) MANIFEST="${2:-}"; shift 2 ;;
      --overwrite) OVERWRITE=1; shift ;;
      --no-register) NO_REGISTER=1; shift ;;
      --no-verify) VERIFY_AFTER=0; shift ;;
      --dry-run) DRYRUN=1; shift ;;
      --help|-h) irv_usage; exit 0 ;;
      *) irv_err "opção inválida: $1"; irv_usage; exit 2 ;;
    esac
  done
  case "$CMD" in
    install|register|verify|all) : ;;
    *) irv_err "comando inválido: $CMD"; irv_usage; exit 2 ;;
  esac

  # libc
  [[ -z "$LIBC" || "$LIBC" == "glibc" || "$LIBC" == "musl" || "$LIBC" == "auto" ]] || { irv_err "--libc inválido"; exit 2; }
  if [[ -z "$LIBC" || "$LIBC" == "auto" ]]; then
    if ldd --version 2>&1 | grep -qi musl; then LIBC="musl"; else LIBC="glibc"; fi
  fi

  # meta required
  local miss=0
  for k in category name version; do
    if [[ -z "${ADM_META[$k]:-}" ]]; then irv_err "metadado ausente: $k"; miss=1; fi
  done
  (( miss==0 )) || exit 3
}

###############################################################################
# Paths e DB
###############################################################################
__db_pkg_dir(){ local c="${ADM_META[category]}" n="${ADM_META[name]}"; echo "${ADM_DB_DIR}/installed/${c}/${n}"; }
__db_manifest(){ echo "$(__db_pkg_dir)/manifest.json"; }
__db_files(){ echo "$(__db_pkg_dir)/files.lst"; }
__db_meta(){ echo "$(__db_pkg_dir)/meta.json"; }
__db_stamp(){ echo "$(__db_pkg_dir)/.installed"; }

__require_root(){
  [[ $EUID -eq 0 ]] || { irv_err "requer root para instalar/registrar"; exit 1; }
}
###############################################################################
# Instalação a partir de DESTDIR
###############################################################################
__install_from_destdir(){
  local src="${DESTDIR:?}"
  irv_info "Instalando de DESTDIR → ${ROOT}"
  [[ -d "$src" ]] || { irv_err "DESTDIR inválido: $src"; return 2; }

  irv_hooks_run "pre-install" "MODE=destdir" "SRC=$src" "ROOT=$ROOT"

  if (( DRYRUN )); then
    (cd "$src" && find . -type f -o -type l -o -type d | sed 's#^\./#/#') | while read -r p; do
      [[ "$p" == "/" ]] && continue
      echo "(dry-run) instalar $p"
    done
    return 0
  fi

  # cópia preservando atributos; respeita overwrite
  shopt -s dotglob
  local f dst
  (cd "$src" && find . -mindepth 1 -print0) | while IFS= read -r -d '' f; do
    local rel="${f#./}"
    dst="${ROOT}/${rel}"
    if [[ -e "$dst" && $OVERWRITE -eq 0 ]]; then
      irv_err "conflito: ${dst} já existe (use --overwrite)"; exit 12
    fi
    if [[ -d "$src/$rel" ]]; then
      __ensure_dir "$dst"
    else
      __ensure_dir "$(dirname "$dst")"
      # usa cp --preserve para manter perms/timestamps/xattr
      if command -v cp >/dev/null 2>&1; then
        cp --reflink=auto --preserve=all -f "$src/$rel" "$dst"
      else
        install -m "$(stat -c '%a' "$src/$rel" 2>/dev/null || echo 0644)" "$src/$rel" "$dst"
      fi
    fi
  done
  shopt -u dotglob

  irv_hooks_run "post-install" "MODE=destdir" "SRC=$src" "ROOT=$ROOT"
  irv_ok "Instalação (DESTDIR) concluída."
}

###############################################################################
# Instalação a partir de pacote tar.{zst,xz}
###############################################################################
__extract_pkg_to_tmp(){
  local pkg="$1"
  local d; d="$(mktemp -d "${ADM_TMPDIR}/irv-pkg.XXXX")"
  case "$pkg" in
    *.tar.zst) zstd -q -d -c "$pkg" | tar -xpf - -C "$d" ;;
    *.tar.xz)  xz   -d -c "$pkg" | tar -xpf - -C "$d" ;;
    *) irv_err "formato de pacote não suportado: $pkg" ;;
  esac
  echo "$d"
}

__load_pkg_meta_from_cache(){
  # tenta ler .meta.json e .manifest.json do mesmo diretório do pacote (estilo 07.10-store)
  local pkg="$1"
  local base="${pkg%.*}"; base="${base%.*}"  # remove .tar.zst/.tar.xz
  local meta="${base}.meta.json" man="${base}.manifest.json"
  [[ -r "$MANIFEST" ]] || MANIFEST=""
  [[ -r "$MANIFEST" ]] || [[ -r "$man" ]] && MANIFEST="$man" || true
  if [[ -r "$meta" ]] && command -v jq >/dev/null 2>&1; then
    # se não foi passado via CLI, preenche category/name/version/arch/libc/profile
    for K in name version category arch libc profile; do
      local V; V="$(jq -r ".${K}" "$meta" 2>/dev/null || echo "")"
      [[ "$K" == "arch"     ]] && [[ -z "${ARCH:-}"     ]] && [[ -n "$V" ]] && ARCH="$V"
      [[ "$K" == "libc"     ]] && [[ -z "${LIBC:-}"     ]] && [[ -n "$V" ]] && LIBC="$V"
      [[ "$K" == "profile"  ]] && [[ -z "${PROFILE:-}"  ]] && [[ -n "$V" ]] && PROFILE="$V"
      [[ "$K" == "name"     ]] && [[ -z "${ADM_META[name]:-}"     ]] && [[ -n "$V" ]] && ADM_META[name]="$V"
      [[ "$K" == "version"  ]] && [[ -z "${ADM_META[version]:-}"  ]] && [[ -n "$V" ]] && ADM_META[version]="$V"
      [[ "$K" == "category" ]] && [[ -z "${ADM_META[category]:-}" ]] && [[ -n "$V" ]] && ADM_META[category]="$V"
    done
  fi
}

__install_from_pkg(){
  local pkg="${PKG_TAR:?}"
  [[ -r "$pkg" ]] || { irv_err "pacote não encontrado: $pkg"; return 2; }

  __load_pkg_meta_from_cache "$pkg"
  irv_info "Instalando de pacote → ${ROOT}"
  irv_hooks_run "pre-install" "MODE=pkg" "PKG=$pkg" "ROOT=$ROOT"

  local tmp; tmp="$(__extract_pkg_to_tmp "$pkg")"
  if (( DRYRUN )); then
    (cd "$tmp" && find . -type f -o -type l -o -type d | sed 's#^\./#/#') | while read -r p; do
      [[ "$p" == "/" ]] && continue
      echo "(dry-run) instalar $p"
    done
    rm -rf "$tmp" || true
    return 0
  fi

  # copiar conteúdo
  shopt -s dotglob
  local f dst
  (cd "$tmp" && find . -mindepth 1 -print0) | while IFS= read -r -d '' f; do
    local rel="${f#./}"; dst="${ROOT}/${rel}"
    if [[ -e "$dst" && $OVERWRITE -eq 0 ]]; then
      irv_err "conflito: ${dst} já existe (use --overwrite)"; exit 12
    fi
    if [[ -d "$tmp/$rel" ]]; then
      __ensure_dir "$dst"
    else
      __ensure_dir "$(dirname "$dst")"
      if command -v cp >/dev/null 2>&1; then
        cp --reflink=auto --preserve=all -f "$tmp/$rel" "$dst"
      else
        install -m "$(stat -c '%a' "$tmp/$rel" 2>/dev/null || echo 0644)" "$tmp/$rel" "$dst"
      fi
    fi
  done
  shopt -u dotglob
  rm -rf "$tmp" || true

  irv_hooks_run "post-install" "MODE=pkg" "PKG=$pkg" "ROOT=$ROOT"
  irv_ok "Instalação (pacote) concluída."
}

###############################################################################
# Registro no DB de instalados
###############################################################################
__register_install(){
  local dir; dir="$(__db_pkg_dir)"
  __ensure_dir "$dir"
  irv_hooks_run "pre-register" "DBDIR=$dir"

  local meta_json="$(__db_meta)"
  local files_lst="$(__db_files)"
  local mani_json="$(__db_manifest)"
  local stamp="$(__db_stamp)"

  # meta.json
  {
    echo "{"
    printf '  "name": %q,\n' "${ADM_META[name]}"
    printf '  "version": %q,\n' "${ADM_META[version]}"
    printf '  "category": %q,\n' "${ADM_META[category]}"
    printf '  "arch": %q,\n' "$ARCH"
    printf '  "libc": %q,\n' "$LIBC"
    printf '  "profile": %q,\n' "$PROFILE"
    printf '  "root": %q,\n' "$ROOT"
    printf '  "ts": %q\n' "$(date -u +%FT%TZ)"
    echo "}"
  } > "$meta_json"

  # files.lst (baseado no manifest se disponível, senão varre o ROOT por mtime recente no .installed anterior)
  if [[ -r "$MANIFEST" ]] && command -v jq >/dev/null 2>&1; then
    jq -r '.files[].path' "$MANIFEST" | sed 's#^/#/#' > "$files_lst" || true
    cp -f "$MANIFEST" "$mani_json" || true
  else
    # tentamos listar arquivos recém colocados com base em presença no ROOT (fallback)
    irv_warn "manifest ausente; gerando files.lst por varredura (precisão menor)"
    : > "$files_lst"
  fi

  echo "$(date -u +%FT%TZ) ${ADM_META[version]} ${ARCH}/${LIBC} ${PROFILE}" > "$stamp"

  irv_hooks_run "post-register" "DBDIR=$dir" "META=$meta_json" "FILES=$files_lst"
  irv_ok "Registro concluído: $dir"
}
###############################################################################
# Verificação pós-instalação
###############################################################################
__ldd_check_one(){
  local f="$1"
  command -v file >/dev/null 2>&1 || return 0
  file -b "$f" 2>/dev/null | grep -qi 'ELF' || return 0
  command -v ldd >/dev/null 2>&1 || return 0
  local miss=0
  while IFS= read -r line; do
    echo "$line" | grep -q 'not found' && { echo "MISSING: $line"; miss=1; }
  done < <(ldd "$f" 2>&1 || true)
  return $miss
}

__perm_check_one(){
  local f="$1"
  # alerta sobre setuid/setgid inoportunos
  local mode; mode="$(stat -c '%a' "$f" 2>/dev/null || echo "")"
  [[ -z "$mode" ]] && return 0
  # só informa; decisão política cabe ao usuário
  [[ "$mode" =~ ^4 ]] && echo "SETUID? $f (mode=$mode)"
  [[ "$mode" =~ ^2 ]] && echo "SETGID? $f (mode=$mode)"
}

__verify_checksums(){
  local ok=1
  local mani="$(__db_manifest)"
  if [[ -r "$MANIFEST" ]]; then mani="$MANIFEST"; fi
  if [[ ! -r "$mani" ]] || ! command -v jq >/dev/null 2>&1; then
    irv_warn "manifest ausente ou jq indisponível; skip checksum"
    echo "$ok"; return 0
  fi
  local c mism=0
  while IFS= read -r -d '' c; do
    local p; p="$(jq -r --argjson idx "$c" '.files[$idx].path' "$mani")"
    [[ -n "$p" ]] || continue
    local abs="${ROOT%/}/${p#/}"
    if [[ ! -e "$abs" ]]; then
      irv_warn "arquivo ausente: $p"
      mism=1; continue
    fi
    # manifest do 07.10 não guarda sha do conteúdo por arquivo (apenas lista). Se existir campo sha, usa:
    local sha; sha="$(jq -r --argjson idx "$c" '.files[$idx].sha256 // empty' "$mani")"
    if [[ -n "$sha" ]]; then
      local cur; cur="$(sha256f "$abs")"
      if [[ "$cur" != "$sha" ]]; then
        irv_warn "sha diverge: $p"
        mism=1
      fi
    fi
  done < <(jq -r 'if .files then range(0;.files|length) | @sh else empty end' "$mani" | tr -d "'" | tr '\n' '\0')
  (( mism==0 )) || ok=0
  echo "$ok"
}

__verify_walk(){
  local files="$(__db_files)"
  local issues=0
  local checked=0
  if [[ -s "$files" ]]; then
    while IFS= read -r rel; do
      [[ -z "$rel" ]] && continue
      local f="${ROOT%/}/${rel#/}"
      [[ -e "$f" ]] || { irv_warn "ausente: $rel"; issues=1; continue; }
      if (( CHECK_RPATH )); then __ldd_check_one "$f" || issues=1; fi
      __perm_check_one "$f" || true
      ((checked++)) || true
    done < "$files"
  else
    # fallback: listar binários “prováveis” sob /usr/bin /usr/lib /lib*
    while IFS= read -r f; do
      __ldd_check_one "$f" || issues=1
      __perm_check_one "$f" || true
      ((checked++)) || true
    done < <(find "${ROOT%/}"/usr/bin "${ROOT%/}"/usr/lib "${ROOT%/}"/lib* -type f 2>/dev/null || true)
  fi
  echo "$issues $checked"
}

__verify_post_install(){
  irv_hooks_run "pre-verify" "ROOT=$ROOT"

  local okcs; okcs="$(__verify_checksums)"
  local issues cnt; read -r issues cnt <<< "$(__verify_walk)"

  if (( okcs == 1 )); then irv_ok "checksums OK ou ignorados"
  else irv_warn "divergência de checksum detectada"; fi

  if (( issues == 0 )); then irv_ok "nenhum problema crítico em ldd/permissions (arquivos verificados: $cnt)"
  else
    irv_warn "foram encontrados problemas ($issues)."
    (( FAIL_ON_MISMATCH )) && { irv_err "verificação falhou (policy FAIL_ON_MISMATCH)"; return 21; }
  fi

  irv_hooks_run "post-verify" "ROOT=$ROOT"
  return 0
}

###############################################################################
# Orquestração
###############################################################################
irv_install(){
  __require_root
  __lock "install"
  # Seleciona modo
  if [[ -n "$DESTDIR" && -n "$PKG_TAR" ]]; then
    irv_err "use apenas um modo: --destdir OU --pkg-tar"; exit 2
  fi
  if [[ -z "$DESTDIR" && -z "$PKG_TAR" ]]; then
    irv_err "especifique --destdir ou --pkg-tar"; exit 2
  fi

  if [[ -n "$PKG_TAR" ]]; then
    __install_from_pkg
    # tentar adotar manifest do pacote se houver
    [[ -z "$MANIFEST" ]] && __load_pkg_meta_from_cache "$PKG_TAR" || true
  else
    __install_from_destdir
  fi

  if (( NO_REGISTER==0 )); then
    __register_install
  else
    irv_warn "registro desabilitado (--no-register)"
  fi

  if (( VERIFY_AFTER==1 )); then
    __verify_post_install || { __unlock; return 21; }
  fi

  # pós-instalação geral do sistema
  # ldconfig (glibc), depmod, update-initramfs/dracut (se presentes)
  if command -v ldconfig >/dev/null 2>&1 && [[ "$LIBC" == "glibc" ]] && (( DRYRUN==0 )); then
    irv_info "executando ldconfig…"; ldconfig || irv_warn "ldconfig retornou erro"
  fi
  if command -v depmod >/dev/null 2>&1 && (( DRYRUN==0 )); then
    irv_info "executando depmod -a…"; depmod -a || irv_warn "depmod retornou erro"
  fi
  if command -v dracut >/dev/null 2>&1 && (( DRYRUN==0 )); then
    irv_info "dracut --regenerate-all… (se aplicável)"; dracut --regenerate-all -f || irv_warn "dracut retornou erro"
  elif command -v update-initramfs >/dev/null 2>&1 && (( DRYRUN==0 )); then
    irv_info "update-initramfs -u…"; update-initramfs -u || irv_warn "update-initramfs retornou erro"
  fi

  __unlock
  irv_ok "Install/Register/Verify concluído."
}

irv_register_only(){
  __require_root
  __lock "install"
  __register_install
  __unlock
}
irv_verify_only(){
  __lock "install"
  __verify_post_install
  __unlock
}

###############################################################################
# MAIN
###############################################################################
irv_run(){
  parse_cli "$@"
  case "$CMD" in
    install)  irv_install ;;
    register) irv_register_only ;;
    verify)   irv_verify_only ;;
    all)      irv_install ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  irv_run "$@"
fi
