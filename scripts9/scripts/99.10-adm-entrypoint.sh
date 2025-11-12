#!/usr/bin/env bash
# 99.10-adm-entrypoint.sh
# Ponto de entrada do ADM: prepara ambiente, valida pré-requisitos e
# despacha para o CLI unificado 98.10-cli-dispatch.sh.
###############################################################################
# Modo estrito + traps
###############################################################################
set -Eeuo pipefail
IFS=$'\n\t'

__ep_err_trap() {
  local code=$? line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-MAIN}
  echo "[ERR] adm-entrypoint falhou: code=${code} line=${line} func=${func}" 1>&2 || true
  exit "$code"
}
trap __ep_err_trap ERR

###############################################################################
# Descoberta de paths & variáveis base
###############################################################################
# Descobre diretório do script mesmo quando chamado via symlink.
__realpath() {
  # compatível sem coreutils realpath
  local tgt="$1" dir base
  while [ -L "$tgt" ]; do
    dir=$(cd -P "$(dirname "$tgt")" && pwd)
    tgt=$(readlink "$tgt")
    [[ "$tgt" != /* ]] && tgt="$dir/$tgt"
  done
  dir=$(cd -P "$(dirname "$tgt")" && pwd)
  base=$(basename "$tgt")
  echo "$dir/$base"
}
EP_SELF="$(__realpath "${BASH_SOURCE[0]}")"
EP_DIR="$(dirname "$EP_SELF")"

# Raiz do ADM (pode ser sobrescrita por variável de ambiente)
ADM_ROOT="${ADM_ROOT:-/usr/src/adm}"
# Heurística: se o script roda dentro de ADM_ROOT/scripts, use essa raiz.
if [[ "$EP_DIR" == "$ADM_ROOT/scripts" ]]; then
  : # ok
elif [[ -d "$EP_DIR/.." && -d "$EP_DIR/../scripts" && -d "$EP_DIR/../metafiles" ]]; then
  ADM_ROOT="$(cd -P "$EP_DIR/.." && pwd)"
fi

ADM_SCRIPTS="${ADM_SCRIPTS:-${ADM_ROOT}/scripts}"
ADM_META_DIR="${ADM_META_DIR:-${ADM_ROOT}/metafiles}"
ADM_DB_DIR="${ADM_DB_DIR:-${ADM_ROOT}/db}"
ADM_STATE_DIR="${ADM_STATE_DIR:-${ADM_ROOT}/state}"
ADM_LOG_DIR="${ADM_LOG_DIR:-${ADM_STATE_DIR}/logs}"
ADM_TMPDIR="${ADM_TMPDIR:-${ADM_ROOT}/.tmp}"

DISPATCH="${DISPATCH:-${ADM_SCRIPTS}/98.10-cli-dispatch.sh}"

# Configurações gerais
export UMASK_DEFAULT="${UMASK_DEFAULT:-022}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"
umask "$UMASK_DEFAULT" || true

###############################################################################
# Cores, logo e logging
###############################################################################
NO_COLOR="${NO_COLOR:-0}"
if [[ "$NO_COLOR" == "1" ]]; then
  C_RST=""; C_BD=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""
elif [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  C_RST="$(tput sgr0)"; C_BD="$(tput bold)"
  C_OK="$(tput setaf 2)"; C_WRN="$(tput setaf 3)"; C_ERR="$(tput setaf 1)"; C_INF="$(tput setaf 6)"
else
  C_RST=""; C_BD=""; C_OK=""; C_WRN=""; C_ERR=""; C_INF=""
fi
log_i(){ echo -e "${C_INF}[ADM]${C_RST} $*"; }
log_ok(){ echo -e "${C_OK}[OK ]${C_RST} $*"; }
log_w(){ echo -e "${C_WRN}[WAR]${C_RST} $*" 1>&2; }
log_e(){ echo -e "${C_ERR}[ERR]${C_RST} $*" 1>&2; }

ADM_LOGO=$'
   ___    ____  __  ___
  / _ |  / __ \/  |/  /  ADM
 / __ | / /_/ / /|_/ /   Advanced (from scratch) Manager
/_/ |_| \____/_/  /_/    build • install • update • repair
'

print_logo(){ echo -e "${C_BD}${ADM_LOGO}${C_RST}"; }

###############################################################################
# Utils & locks
###############################################################################
tmpfile(){ mktemp "${ADM_TMPDIR}/entry.XXXXXX"; }
adm_is_cmd(){ command -v "$1" >/dev/null 2>&1; }

__ensure_dir(){
  local d="$1" mode="${2:-0755}"
  if [[ ! -d "$d" ]]; then
    mkdir -p "$d"
    chmod "$mode" "$d" || true
  fi
}

__lock(){
  __ensure_dir "${ADM_STATE_DIR}/locks"
  exec {__EP_FD}>"${ADM_STATE_DIR}/locks/entry.lock"
  flock -n ${__EP_FD} || { log_w "aguardando lock de entry…"; flock ${__EP_FD}; }
}
__unlock(){ :; }

###############################################################################
# Pré-requisitos e verificação de ambiente
###############################################################################
check_shell_version(){
  local maj="${BASH_VERSINFO[0]:-0}"
  if (( maj < 4 )); then
    log_e "Bash >= 4 é necessário. Detectado: ${BASH_VERSION:-desconhecido}"
    exit 2
  fi
}

check_cmds(){
  local -a req=( awk sed grep find xargs tr cut sort uniq tee mkdir rm mv cp tar gzip xz bunzip2 bzip2 zstd sha256sum )
  local -a net=( curl wget )
  local -a vcs=( git )
  local -a nice=( jq tput dialog whiptail fzf rsync aria2c )
  local missing=()

  for c in "${req[@]}"; do adm_is_cmd "$c" || missing+=( "$c" ); done
  # Pelo menos um downloader
  if ! adm_is_cmd curl && ! adm_is_cmd wget; then missing+=( "curl|wget" ); fi
  # VCS principal
  for c in "${vcs[@]}"; do adm_is_cmd "$c" || missing+=( "$c" ); done

  if ((${#missing[@]})); then
    log_e "Faltam utilitários essenciais: ${missing[*]}"
    echo "Instale-os e tente novamente."
    exit 3
  fi

  # Avisos (não fatais)
  for c in "${nice[@]}"; do adm_is_cmd "$c" || log_w "Opcional ausente: $c"
  done
}

ensure_layout(){
  __ensure_dir "$ADM_ROOT" 0755
  __ensure_dir "$ADM_SCRIPTS" 0755
  __ensure_dir "$ADM_META_DIR" 0755
  __ensure_dir "$ADM_DB_DIR" 0755
  __ensure_dir "$ADM_STATE_DIR" 0755
  __ensure_dir "$ADM_LOG_DIR" 0755
  __ensure_dir "$ADM_TMPDIR" 0777
}

check_permissions(){
  # Verifica escrita nos locais críticos
  local -a mustw=( "$ADM_STATE_DIR" "$ADM_LOG_DIR" "$ADM_TMPDIR" "$ADM_DB_DIR" )
  local prob=0
  for d in "${mustw[@]}"; do
    if [[ ! -w "$d" ]]; then
      prob=1
      log_w "Sem permissão de escrita: $d"
    fi
  done
  ((prob==0)) || log_w "Algumas operações podem precisar de sudo."
}

first_run_wizard(){
  # Executa uma vez por host para criação básica
  local flag="${ADM_STATE_DIR}/.first_run_done"
  if [[ -f "$flag" ]]; then return 0; fi
  print_logo
  log_i "Inicializando estrutura do ADM em: $ADM_ROOT"
  ensure_layout
  check_permissions
  touch "$flag" || true

  # Oferece symlink adm no PATH, se possível
  if [[ ":$PATH:" != *":/usr/local/bin:"* ]]; then
    log_w "/usr/local/bin não está no PATH atual."
  fi
  if [[ -w /usr/local/bin || $(id -u) -eq 0 ]]; then
    ln -sf "${DISPATCH}" /usr/local/bin/adm 2>/dev/null || true
    if [[ -x /usr/local/bin/adm ]]; then
      log_ok "Symlink criado: /usr/local/bin/adm → ${DISPATCH}"
    else
      log_w "Não foi possível criar symlink /usr/local/bin/adm (talvez sem permissão)."
    fi
  else
    log_w "Sem permissão para criar /usr/local/bin/adm (tente com sudo)."
  fi
}

###############################################################################
# Comandos de manutenção (entrypoint)
###############################################################################
show_help(){
  print_logo
  cat <<EOF
Uso:
  adm-entry [opções] [--] <args do CLI>

Comandos diretos (entrypoint):
  --doctor               Verificações de ambiente e pré-requisitos
  --env                  Mostra variáveis de ambiente do ADM
  --paths                Mostra caminhos importantes do ADM
  --fix-perms            Ajusta permissões padrão das pastas do ADM
  --install-symlink      Cria/atualiza symlink /usr/local/bin/adm -> dispatcher
  --install-completions  Instala bash/zsh completion para 'adm' (se suportado)
  --version              Mostra versão do dispatcher (se disponível)
  --help                 Esta ajuda

Atalhos:
  adm-entry              Abre o TUI do ADM (se disponível)
  adm-entry --tui        Força TUI
  adm-entry --no-color   Desabilita cores (equivale a NO_COLOR=1)
  adm-entry [qualquer outro argumento]  → repassado ao dispatcher 98.10

Dicas:
- O comando principal é o dispatcher: ${DISPATCH##*/}
  Você pode chamá-lo diretamente ou via 'adm' se o symlink estiver instalado.
EOF
}

show_env(){
  cat <<EOF
ADM_ROOT=$ADM_ROOT
ADM_SCRIPTS=$ADM_SCRIPTS
ADM_META_DIR=$ADM_META_DIR
ADM_DB_DIR=$ADM_DB_DIR
ADM_STATE_DIR=$ADM_STATE_DIR
ADM_LOG_DIR=$ADM_LOG_DIR
ADM_TMPDIR=$ADM_TMPDIR
DISPATCH=$DISPATCH
PATH=$PATH
SHELL=${SHELL:-unknown}
USER=${USER:-unknown}
EOF
}

show_paths(){
  for p in "$ADM_ROOT" "$ADM_SCRIPTS" "$ADM_META_DIR" "$ADM_DB_DIR" "$ADM_STATE_DIR" "$ADM_LOG_DIR" "$ADM_TMPDIR"; do
    printf "%-24s %s\n" "$(basename "$p"):" "$p"
  done
}

fix_perms(){
  ensure_layout
  chmod 0755 "$ADM_ROOT" "$ADM_SCRIPTS" "$ADM_META_DIR" "$ADM_DB_DIR" "$ADM_STATE_DIR" 2>/dev/null || true
  chmod 0777 "$ADM_TMPDIR" 2>/dev/null || true
  log_ok "Permissões padrão aplicadas."
}

install_symlink(){
  local target="/usr/local/bin/adm"
  if [[ ! -x "$DISPATCH" ]]; then
    log_e "Dispatcher não encontrado/executável: $DISPATCH"
    exit 4
  fi
  if [[ -w "$(dirname "$target")" ]]; then
    ln -sf "$DISPATCH" "$target"
    chmod +x "$target" || true
    log_ok "Symlink instalado: $target → $DISPATCH"
  else
    log_e "Sem permissão para instalar $target (use sudo)."
    exit 5
  fi
}

install_completions(){
  # Gera stubs mínimos; o CLI completo pode fornecer um gerador próprio depois.
  local bashd="/etc/bash_completion.d"
  local zshd="/usr/share/zsh/site-functions"
  local err=0
  if [[ -w "$bashd" ]]; then
    cat > "$bashd/adm" <<'BASHC' || err=1
# completion mínimo para 'adm'
_adm_complete() {
  COMPREPLY=()
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local cmds="install search info run list-commands help"
  COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
}
complete -F _adm_complete adm
BASHC
    log_ok "Completion bash instalado em $bashd/adm"
  else
    log_w "Sem permissão para instalar completion bash em $bashd"
  fi
  if [[ -w "$zshd" ]]; then
    cat > "$zshd/_adm" <<'ZSHC' || err=1
#compdef adm
_arguments \
  '1:command:(install search info run list-commands help)'
ZSHC
    log_ok "Completion zsh instalado em $zshd/_adm"
  else
    log_w "Sem permissão para instalar completion zsh em $zshd"
  fi
  ((err==0)) || exit 6
}

doctor(){
  print_logo
  check_shell_version
  ensure_layout
  check_cmds
  check_permissions
  if [[ -x "$DISPATCH" ]]; then
    log_ok "Dispatcher OK: $DISPATCH"
  else
    log_e "Dispatcher ausente ou não executável: $DISPATCH"
    exit 7
  fi
  log_ok "Ambiente saudável."
}

show_version(){
  if [[ -x "$DISPATCH" ]]; then
    # tenta extrair versão do dispatcher (se exportar algo)
    if "${DISPATCH}" --help >/dev/null 2>&1; then
      echo "ADM dispatcher: ${DISPATCH##*/}"
      exit 0
    fi
  fi
  echo "ADM entrypoint (versão desconhecida)"
}

###############################################################################
# Main
###############################################################################
main(){
  __lock
  check_shell_version
  ensure_layout
  check_cmds

  # interpreta opções do entrypoint
  local args=("$@")
  local force_tui=0
  while (($#)); do
    case "$1" in
      --help|-h) show_help; __unlock; exit 0 ;;
      --doctor)  doctor; __unlock; exit 0 ;;
      --env)     show_env; __unlock; exit 0 ;;
      --paths)   show_paths; __unlock; exit 0 ;;
      --fix-perms) fix_perms; __unlock; exit 0 ;;
      --install-symlink) install_symlink; __unlock; exit 0 ;;
      --install-completions) install_completions; __unlock; exit 0 ;;
      --version|-V) show_version; __unlock; exit 0 ;;
      --no-color) NO_COLOR=1; __unlock; exec env NO_COLOR=1 "$EP_SELF" "${args[@]/--no-color/}" ;;
      --tui) force_tui=1; shift; args=("${args[@]/--tui/}"); continue ;;
      --) shift; args=("${@:1}"); break ;;
      *) break ;;
    esac
    shift
  done

  first_run_wizard

  # Se nenhum argumento (ou --tui), abre TUI do dispatcher
  if (( ${#args[@]} == 0 || force_tui==1 )); then
    print_logo
    if [[ -x "$DISPATCH" ]]; then
      __unlock
      exec "$DISPATCH"
    else
      log_e "Dispatcher não encontrado: $DISPATCH"
      exit 8
    fi
  fi

  # Caso contrário, repassa tudo para o dispatcher
  if [[ -x "$DISPATCH" ]]; then
    __unlock
    exec "$DISPATCH" "${args[@]}"
  else
    log_e "Dispatcher não encontrado: $DISPATCH"
    exit 8
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
