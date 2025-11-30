#!/usr/bin/env bash
set -euo pipefail

#========================================================
#  ADM Manager - Gerenciador simples para Linux From Scratch
#  - Prepara estrutura do LFS
#  - Monta / desmonta FS virtuais
#  - Entra em chroot (opcionalmente com unshare)
#  - Administra builds de scripts em $LFS/build-scripts
#    * resolução de dependências
#    * hooks pre/post install & uninstall
#    * manifesto de arquivos instalados
#    * uninstall por manifesto
#    * uninstall de órfãos
#    * registro em $LFS/var/adm
#========================================================

LFS_CONFIG="${LFS_CONFIG:-/etc/adm.conf}"

# Valores padrão (podem ser sobrescritos pelo arquivo de config)
LFS="${LFS:-/mnt/lfs}"
LFS_USER="${LFS_USER:-lfsbuild}"
LFS_GROUP="${LFS_GROUP:-lfsbuild}"
LFS_SOURCES_DIR="${LFS_SOURCES_DIR:-$LFS/sources}"
LFS_TOOLS_DIR="${LFS_TOOLS_DIR:-$LFS/tools}"
LFS_LOG_DIR="${LFS_LOG_DIR:-$LFS/logs}"
LFS_BUILD_SCRIPTS_DIR="${LFS_BUILD_SCRIPTS_DIR:-$LFS/build-scripts}"

CHROOT_SECURE="${CHROOT_SECURE:-1}"  # 1 = tentar unshare, 0 = chroot simples

# Registro / banco do ADM
ADM_DB_DIR="${ADM_DB_DIR:-$LFS/var/adm}"
ADM_INSTALLED_DIR="$ADM_DB_DIR/installed"
ADM_LOG_DIR="$ADM_DB_DIR/logs"
ADM_LAST_SUCCESS="$ADM_DB_DIR/last_success"

# Manifesto por pacote: $ADM_INSTALLED_DIR/<pkg>.manifest
# Meta por pacote:      $ADM_INSTALLED_DIR/<pkg>.meta

# Arquivo opcional com ordem de build (para ferramentas externas, se quiser):
# linhas no formato: categoria:programa (ex: core:binutils-pass1)
BUILD_ORDER_FILE="${BUILD_ORDER_FILE:-$LFS/build-scripts/build-order.txt}"

#--------------------------------------------------------
# Helpers genéricos
#--------------------------------------------------------

die() {
    echo "Erro: $*" >&2
    exit 1
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "este script precisa ser executado como root."
    fi
}

load_config() {
    if [[ -f "$LFS_CONFIG" ]]; then
        # shellcheck source=/dev/null
        . "$LFS_CONFIG"
    fi
}

adm_ensure_db() {
    mkdir -p "$ADM_INSTALLED_DIR" "$ADM_LOG_DIR" "$LFS_LOG_DIR"
}

adm_log() {
    local ts
    ts="$(date +'%F %T')"
    echo "[$ts] $*" >> "$ADM_LOG_DIR/adm.log"
}

pkg_name_from_script() {
    # /foo/core/binutils-pass1/binutils-pass1.sh -> binutils-pass1
    local script_path="$1"
    local base="${script_path##*/}"
    echo "${base%.sh}"
}

pkg_meta_file() {
    local pkg="$1"
    echo "$ADM_INSTALLED_DIR/${pkg}.meta"
}

pkg_manifest_file() {
    local pkg="$1"
    echo "$ADM_INSTALLED_DIR/${pkg}.manifest"
}

pkg_is_installed() {
    local pkg="$1"
    [[ -f "$(pkg_manifest_file "$pkg")" ]]
}

#--------------------------------------------------------
# Proteção anti-strip (Gl i bc & libs críticas)
#--------------------------------------------------------

# Verifica se um arquivo é ELF
adm_is_elf() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    if command -v file >/dev/null 2>&1; then
        file -L "$f" 2>/dev/null | grep -q "ELF"
    else
        # Sem 'file', jogamos seguro: não stripamos nada
        return 1
    fi
}

# Retorna 0 se o arquivo é Glibc / loader / crt* crítico
adm_is_glibc_critical() {
    local f="$1"
    local b
    b="$(basename "$f")"

    case "$b" in
        # dynamic loaders
        ld-linux*.so.*|ld-lsb*.so.*)
            return 0 ;;
        # libc
        libc-*.so|libc.so.*)
            return 0 ;;
        # pthread
        libpthread-*.so|libpthread.so.*)
            return 0 ;;
        # math
        libm-*.so|libm.so.*)
            return 0 ;;
        # time / realtime
        librt-*.so|librt.so.*)
            return 0 ;;
        # dl
        libdl-*.so|libdl.so.*)
            return 0 ;;
        # resolver / nsl (algumas distros usam)
        libresolv-*.so|libresolv.so.*|libnsl-*.so|libnsl.so.*)
            return 0 ;;
        # startup objects da toolchain
        crt1.o|crti.o|crtn.o)
            return 0 ;;
    esac

    # Também protegemos qualquer coisa dentro de /lib ou /lib64 que se pareça loader
    case "$f" in
        */lib/ld-linux*.so.*|*/lib64/ld-linux*.so.*)
            return 0 ;;
    esac

    return 1
}

# Strip seguro de um único arquivo
adm_safe_strip_file() {
    local f="$1"

    # Se não é arquivo regular, ignora
    [[ -f "$f" ]] || return 0

    # Se não é ELF, ignora
    if ! adm_is_elf "$f"; then
        return 0
    fi

    # Se é Glibc ou arquivo crítico, não mexe
    if adm_is_glibc_critical "$f"; then
        echo ">> [safe-strip] SKIP (glibc/crítico): $f"
        return 0
    fi

    if ! command -v strip >/dev/null 2>&1; then
        die "'strip' não encontrado no PATH (safe-strip abortado)."
    fi

    # Strip conservador: remove só símbolos não usados
    if strip --strip-unneeded "$f" 2>/dev/null; then
        echo ">> [safe-strip] strip --strip-unneeded: $f"
    else
        echo ">> [safe-strip] AVISO: falha ao stripar $f (ignorando)." >&2
        # não damos die aqui pra não matar todo o processo por 1 arquivo
    fi
}

# Strip seguro recursivo em uma árvore
adm_safe_strip_tree() {
    local root="${1:-}"

    [[ -z "$root" ]] && die "Uso: adm safe-strip <diretório>"

    if [[ ! -d "$root" ]]; then
        die "Diretório para safe-strip não existe: $root"
    fi

    echo ">> [safe-strip] Iniciando strip seguro em: $root"
    local f
    # find + while para não estourar xargs
    while IFS= read -r f; do
        adm_safe_strip_file "$f"
    done < <(find "$root" -type f -print)

    echo ">> [safe-strip] Strip seguro concluído em: $root"
}

#--------------------------------------------------------
# Localizar script de build em subpastas de $LFS/build-scripts
#   - aceita:
#       binutils-pass1
#       binutils-pass1.sh
#       core/binutils-pass1
#       core/binutils-pass1/binutils-pass1.sh
#   - sempre resolve pelo NOME DO ARQUIVO (basename sem .sh)
#--------------------------------------------------------

find_build_script() {
    local spec="$1"
    local name="${spec##*/}"   # pega o último componente
    name="${name%.sh}"         # remove .sh se tiver

    local hits
    hits=$(find "$LFS_BUILD_SCRIPTS_DIR" -type f -name "${name}.sh" 2>/dev/null || true)

    # conta quantas linhas não vazias
    local count
    count=$(printf '%s\n' "$hits" | sed '/^$/d' | wc -l)

    if [[ "$count" -eq 0 ]]; then
        die "script de build '${spec}' (nome base '${name}.sh') não encontrado em $LFS_BUILD_SCRIPTS_DIR"
    elif [[ "$count" -gt 1 ]]; then
        echo "Mais de um script encontrado para base '${name}.sh':" >&2
        printf '  %s\n' $hits >&2
        die "seja mais específico no nome do script."
    fi

    printf '%s\n' "$hits"
}

#--------------------------------------------------------
# Snapshot de FS para gerar manifesto
#   - lista tudo sob $LFS, menos o diretório de DB do ADM
#--------------------------------------------------------

snapshot_fs() {
    local outfile="$1"
    find "$LFS" -xdev \
        -path "$ADM_DB_DIR" -prune -o \
        -print | sort > "$outfile"
}

calc_manifest() {
    local before="$1" after="$2" out="$3"
    comm -13 "$before" "$after" > "$out"
}

#--------------------------------------------------------
# Hooks por programa:
#   em $LFS/build-scripts/<categoria>/<prog>/<prog>.* :
#     <prog>.pre_install
#     <prog>.post_install
#     <prog>.pre_uninstall
#     <prog>.post_uninstall
#--------------------------------------------------------

run_hook_in_chroot() {
    local rel_dir="$1"   # relativo a $LFS_BUILD_SCRIPTS_DIR
    local pkg="$2"       # binutils-pass1
    local hook="$3"      # pre_install, post_install, pre_uninstall, post_uninstall

    local rel_path_dir="$rel_dir"
    [[ "$rel_path_dir" == "." ]] && rel_path_dir=""

    local chroot_dir="/build-scripts"
    [[ -n "$rel_path_dir" ]] && chroot_dir="$chroot_dir/$rel_path_dir"

    local hook_file="${pkg}.${hook}"

    # Monta comando para rodar no chroot
    local cmd="cd '$chroot_dir'; if [[ -x './$hook_file' ]]; then ./'$hook_file'; fi"

    chroot "$LFS" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM:-xterm}" \
        PATH=/usr/bin:/usr/sbin:/bin:/sbin \
        /bin/bash -lc "$cmd"
}

#--------------------------------------------------------
# Ler dependências do programa:
#   arquivo: <prog>.deps na MESMA PASTA DO SCRIPT
#   - um item por linha
#   - aceita:
#       gcc-pass1
#       gcc-pass1.sh
#       core/gcc-pass1
#       core/gcc-pass1/gcc-pass1.sh
#   - cada dependência é resolvida via find_build_script e construída com run-build
#--------------------------------------------------------

resolve_deps_for_script() {
    local script_path="$1"  # absoluto
    local pkg_dir
    pkg_dir="$(dirname "$script_path")"
    local pkg
    pkg="$(pkg_name_from_script "$script_path")"

    local deps_file="$pkg_dir/${pkg}.deps"

    [[ -f "$deps_file" ]] || return 0

    echo ">> [ADM] Resolvendo dependências para $pkg (arquivo: $(basename "$deps_file"))"
    adm_log "RESOLVE DEPS $pkg (file=$(basename "$deps_file"))"

    local dep
    while IFS= read -r dep || [[ -n "$dep" ]]; do
        # limpa comentários e espaços
        dep="${dep%%#*}"
        dep="${dep#"${dep%%[![:space:]]*}"}"
        dep="${dep%"${dep##*[![:space:]]}"}"
        [[ -z "$dep" ]] && continue

        # acha script da dependência
        local dep_path
        dep_path="$(find_build_script "$dep")"
        local dep_pkg
        dep_pkg="$(pkg_name_from_script "$dep_path")"

        if pkg_is_installed "$dep_pkg"; then
            echo ">> [ADM] Dependência '$dep_pkg' já instalada; pulando."
            adm_log "SKIP DEP  $dep_pkg (já instalado; req por $pkg)"
            continue
        fi

        echo ">> [ADM] Construindo dependência: $dep_pkg ($dep)"
        adm_log "BUILD DEP $dep_pkg (req por $pkg)"

        run_build_script "$dep"   # recursivo, usa o mesmo mecanismo
    done < "$deps_file"
}

#--------------------------------------------------------
# Registro de sucesso/fracasso
#  - meta: NAME, SCRIPT, BUILT_AT, DEPS
#  - manifest: lista de arquivos instalados
#--------------------------------------------------------

register_success() {
    local script_path="$1"
    local pkg
    pkg="$(pkg_name_from_script "$script_path")"
    local meta_file
    meta_file="$(pkg_meta_file "$pkg")"

    local pkg_dir
    pkg_dir="$(dirname "$script_path")"
    local deps_file="$pkg_dir/${pkg}.deps"
    local deps=""
    if [[ -f "$deps_file" ]]; then
        deps="$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$deps_file" \
               | sed '/^$/d' | while read -r d; do
                     d="${d##*/}"; d="${d%.sh}"
                     printf '%s ' "$d"
                 done)"
        deps="${deps% }"
    fi

    cat > "$meta_file" <<EOF
NAME=$pkg
SCRIPT=$script_path
BUILT_AT=$(date +'%F %T')
DEPS=$deps
EOF

    echo "$pkg" > "$ADM_LAST_SUCCESS"
    adm_log "BUILD OK   $pkg (script=$script_path)"
}

register_failure() {
    local script_path="$1"
    local rc="$2"
    local pkg
    pkg="$(pkg_name_from_script "$script_path")"
    adm_log "BUILD FAIL $pkg (script=$script_path, exit=$rc)"
}

read_meta_field() {
    local pkg="$1" field="$2"
    local meta_file
    meta_file="$(pkg_meta_file "$pkg")"
    [[ -f "$meta_file" ]] || return 1
    # shellcheck disable=SC1090
    . "$meta_file"
    eval "echo \${$field:-}"
}

#--------------------------------------------------------
# Montagem / desmontagem FS virtuais
#--------------------------------------------------------

mount_virtual_fs() {    
    echo ">> Montando sistemas de arquivos virtuais em $LFS ..."

    if ! mountpoint -q "$LFS"; then
        echo "AVISO: $LFS não é um ponto de montagem (mountpoint)."
        echo "       Continuando assim mesmo; certifique-se de saber o que está fazendo."
    fi
    
    # /dev
    if ! mountpoint -q "$LFS/dev"; then
        mount --bind /dev "$LFS/dev"
        echo "  - /dev montado."
    fi

    # /dev/pts
    if ! mountpoint -q "$LFS/dev/pts"; then
        mount -t devpts devpts "$LFS/dev/pts" -o gid=5,mode=620
        echo "  - devpts em /dev/pts montado."
    fi

    # /proc
    if ! mountpoint -q "$LFS/proc"; then
        mount -t proc proc "$LFS/proc"
        echo "  - /proc montado."
    fi

    # /sys
    if ! mountpoint -q "$LFS/sys"; then
        mount -t sysfs sysfs "$LFS/sys"
        echo "  - /sys montado."
    fi

    # /run
    if ! mountpoint -q "$LFS/run"; then
        mount -t tmpfs tmpfs "$LFS/run"
        echo "  - /run montado."
    fi

    echo ">> Sistemas de arquivos virtuais montados."
}

umount_virtual_fs() {
    echo ">> Desmontando sistemas de arquivos virtuais de $LFS ..."

    for mp in run sys proc dev/pts dev; do
        if mountpoint -q "$LFS/$mp"; then
            umount "$LFS/$mp"
            echo "  - $LFS/$mp desmontado."
        fi
    done

    echo ">> Desmontagem concluída."
}

enter_chroot_plain() {
    echo ">> Entrando em chroot simples em $LFS ..."
    exec chroot "$LFS" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM:-xterm}" \
        PS1='(lfs-chroot) \u:\w\$ ' \
        PATH=/usr/bin:/usr/sbin:/bin:/sbin \
        /bin/bash --login
}

enter_chroot_secure() {
    echo ">> Entrando em chroot (modo seguro) em $LFS ..."

    if ! command -v unshare >/dev/null 2>&1; then
        echo ">> 'unshare' não encontrado; caindo para chroot simples."
        enter_chroot_plain
        return
    fi

    exec unshare --mount --uts --ipc --pid --fork --mount-proc \
         chroot "$LFS" /usr/bin/env -i \
         HOME=/root \
         TERM="${TERM:-xterm}" \
         PS1='(lfs-secure) \u:\w\$ ' \
         PATH=/usr/bin:/usr/sbin:/bin:/sbin \
         /bin/bash --login
}

#--------------------------------------------------------
# Init / user / status
#--------------------------------------------------------

init_layout() {
    echo ">> Criando estrutura básica em $LFS ..."
    mkdir -pv "$LFS"
    mkdir -pv "$LFS_SOURCES_DIR" "$LFS_TOOLS_DIR" "$LFS_LOG_DIR" "$LFS_BUILD_SCRIPTS_DIR"

    chmod -v a+wt "$LFS_SOURCES_DIR" || true

    mkdir -pv "$LFS"/{bin,boot,etc,home,lib,lib64,usr,var,proc,sys,dev,run,tmp}
    chmod -v 1777 "$LFS/tmp"

    echo ">> Estrutura básica criada."
}

create_build_user() {
    echo ">> Criando usuário/grupo de build ($LFS_USER:$LFS_GROUP)..."

    if ! getent group "$LFS_GROUP" >/dev/null 2>&1; then
        groupadd "$LFS_GROUP"
        echo "  - Grupo $LFS_GROUP criado."
    else
        echo "  - Grupo $LFS_GROUP já existe."
    fi

    if ! id "$LFS_USER" >/dev/null 2>&1; then
        useradd -s /bin/bash -g "$LFS_GROUP" -m -k /dev/null "$LFS_USER"
        echo "  - Usuário $LFS_USER criado."
    else
        echo "  - Usuário $LFS_USER já existe."
    fi

    chown -v "$LFS_USER:$LFS_GROUP" "$LFS_SOURCES_DIR" "$LFS_TOOLS_DIR" "$LFS_LOG_DIR" "$LFS_BUILD_SCRIPTS_DIR"

    echo ">> Usuário/grupo de build configurados."
}

status() {
    cat <<EOF
=== ADM / LFS Status ===
LFS base...............: $LFS
Sources................: $LFS_SOURCES_DIR
Tools..................: $LFS_TOOLS_DIR
Logs...................: $LFS_LOG_DIR
Build scripts..........: $LFS_BUILD_SCRIPTS_DIR
ADM DB.................: $ADM_DB_DIR
LFS_USER / LFS_GROUP...: $LFS_USER / $LFS_GROUP
Chroot seguro (unshare): $( [[ "$CHROOT_SECURE" -eq 1 ]] && echo "ATIVADO" || echo "DESATIVADO" )

Montagens:
$(mount | grep "on $LFS" || echo "  (sem montagens relacionadas a $LFS)")

EOF
}

#--------------------------------------------------------
# run-build: build com deps, hooks e manifesto
#   uso: adm run-build binutils-pass1
#        adm run-build core/binutils-pass1/binutils-pass1.sh
#--------------------------------------------------------

run_build_script() {
    local spec="${1:-}"
    [[ -z "$spec" ]] && die "Informe o identificador do script de build. Ex: run-build binutils-pass1"

    adm_ensure_db

    local script_path
    script_path="$(find_build_script "$spec")"
    local pkg
    pkg="$(pkg_name_from_script "$script_path")"

    if pkg_is_installed "$pkg"; then
        echo ">> [ADM] Pacote $pkg já registrado como instalado; pulando."
        adm_log "SKIP       $pkg (já instalado)"
        return 0
    fi

    echo ">> [ADM] Preparando build de $pkg (script: $script_path)"
    adm_log "RUN-BUILD  $pkg (script=$script_path)"

    # Resolver dependências recursivas
    resolve_deps_for_script "$script_path"

    # Montar FS virtuais se necessário
    mount_virtual_fs

    # Caminho relativo do script a partir de $LFS_BUILD_SCRIPTS_DIR
    local rel_path
    rel_path="${script_path#$LFS_BUILD_SCRIPTS_DIR/}"
    local rel_dir pkg_dir_name
    rel_dir="$(dirname "$rel_path")"
    pkg_dir_name="$rel_dir"   # usado para hooks/chroot
    [[ "$pkg_dir_name" == "." ]] && pkg_dir_name=""

    # Snapshots antes/depois para manifesto
    local before after
    before="$(mktemp)"
    after="$(mktemp)"
    snapshot_fs "$before"

    # Comando a ser executado no chroot:
    #  cd /build-scripts/<rel_dir>;
    #  ./<pkg>.pre_install (se existir)
    #  ./<pkg>.sh
    #  ./<pkg>.post_install (se existir)
    local chroot_dir="/build-scripts"
    [[ -n "$pkg_dir_name" ]] && chroot_dir="$chroot_dir/$pkg_dir_name"

    local chroot_cmd="cd '$chroot_dir'; \
if [[ -x './${pkg}.pre_install' ]]; then ./'${pkg}.pre_install'; fi; \
./'${pkg}.sh'; \
if [[ -x './${pkg}.post_install' ]]; then ./'${pkg}.post_install'; fi;"

    if chroot "$LFS" /usr/bin/env -i \
        HOME=/root \
        TERM="${TERM:-xterm}" \
        PATH=/usr/bin:/usr/sbin:/bin:/sbin \
        /bin/bash -lc "$chroot_cmd"
    then
        # snapshot depois
        snapshot_fs "$after"
        local manifest
        manifest="$(pkg_manifest_file "$pkg")"
        mkdir -p "$ADM_INSTALLED_DIR"
        calc_manifest "$before" "$after" "$manifest"
        rm -f "$before" "$after"

        register_success "$script_path"
    else
        local rc=$?
        rm -f "$before" "$after"
        register_failure "$script_path" "$rc"
        exit "$rc"
    fi
}

#--------------------------------------------------------
# build-status: lista pacotes registrados
#--------------------------------------------------------

build_status() {
    adm_ensure_db
    echo "=== ADM Build Status ==="
    local any=0
    for meta in "$ADM_INSTALLED_DIR"/*.meta 2>/dev/null; do
        [[ -f "$meta" ]] || continue
        any=1
        # shellcheck disable=SC1090
        . "$meta"
        printf "  - %-20s (script=%s, data=%s, deps=%s)\n" \
            "${NAME:-?}" "${SCRIPT:-?}" "${BUILT_AT:-?}" "${DEPS:-}"
    done
    if [[ "$any" -eq 0 ]]; then
        echo "  (nenhum pacote registrado ainda)"
    fi
    if [[ -f "$ADM_LAST_SUCCESS" ]]; then
        echo
        echo "Último build com sucesso: $(cat "$ADM_LAST_SUCCESS")"
    fi
}

#--------------------------------------------------------
# uninstall: remove arquivos pelo manifesto + hooks
#   uso: adm uninstall binutils-pass1
#--------------------------------------------------------

uninstall_pkg() {
    local pkg="${1:-}"
    [[ -z "$pkg" ]] && die "Uso: adm uninstall <pacote>"

    adm_ensure_db

    local manifest meta_file
    manifest="$(pkg_manifest_file "$pkg")"
    meta_file="$(pkg_meta_file "$pkg")"

    [[ -f "$manifest" ]] || die "Manifesto não encontrado para $pkg: $manifest"
    [[ -f "$meta_file" ]] || die "Meta não encontrada para $pkg: $meta_file"

    # encontra script correspondente para poder rodar hooks
    local script_path
    script_path="$(read_meta_field "$pkg" SCRIPT)"
    if [[ -z "$script_path" || ! -f "$script_path" ]]; then
        # fallback: tenta achar pelo nome
        script_path="$(find_build_script "$pkg")"
    fi
    local rel_path rel_dir
    rel_path="${script_path#$LFS_BUILD_SCRIPTS_DIR/}"
    rel_dir="$(dirname "$rel_path")"
    [[ "$rel_dir" == "." ]] && rel_dir=""

    echo ">> [ADM] Desinstalando pacote $pkg"
    adm_log "UNINSTALL  $pkg"

    # pre_uninstall hook (chroot)
    mount_virtual_fs
    run_hook_in_chroot "$rel_dir" "$pkg" "pre_uninstall"

    # remove arquivos/diretórios listados (ordem reversa)
    tac "$manifest" | while read -r path; do
        [[ -z "$path" ]] && continue
        if [[ -f "$path" || -L "$path" ]]; then
            rm -f "$path" || echo "  ! Falha ao remover arquivo $path"
        elif [[ -d "$path" ]]; then
            rmdir "$path" 2>/dev/null || true
        fi
    done

    rm -f "$manifest" "$meta_file"

    # post_uninstall hook (chroot)
    run_hook_in_chroot "$rel_dir" "$pkg" "post_uninstall"

    adm_log "UNINSTALL OK $pkg"
    echo ">> [ADM] Pacote $pkg desinstalado."
}

#--------------------------------------------------------
# Encontrar & desinstalar órfãos
#  - órfão = ninguém o cita em DEPS
#--------------------------------------------------------

find_orphans() {
    adm_ensure_db
    local pkgs
    pkgs=$(for f in "$ADM_INSTALLED_DIR"/*.meta 2>/dev/null; do
        [[ -f "$f" ]] || continue
        basename "${f%.meta}"
    done)

    local p o deps needed
    for p in $pkgs; do
        needed=0
        for o in $pkgs; do
            [[ "$o" == "$p" ]] && continue
            deps=$(read_meta_field "$o" DEPS)
            if echo " $deps " | grep -q " $p "; then
                needed=1
                break
            fi
        done
        if [[ "$needed" -eq 0 ]]; then
            echo "$p"
        fi
    done
}

uninstall_orphans() {
    adm_ensure_db
    local orphans
    orphans="$(find_orphans)"

    if [[ -z "$orphans" ]]; then
        echo ">> [ADM] Nenhum órfão encontrado."
        return 0
    fi

    echo ">> [ADM] Pacotes órfãos (ninguém depende deles):"
    echo "$orphans" | sed 's/^/  - /'

    read -r -p "Remover todos? [y/N] " ans
    case "$ans" in
        y|Y)
            local p
            for p in $orphans; do
                uninstall_pkg "$p"
            done
            ;;
        *)
            echo ">> [ADM] Remoção de órfãos abortada."
            ;;
    esac
}

#--------------------------------------------------------
# Uso
#--------------------------------------------------------

usage() {
    cat <<EOF
Uso: $0 <comando> [opções]

Comandos principais:
  init                   Prepara estrutura básica do LFS (pastas, permissões)
  create-user            Cria usuário/grupo para construção (LFS_USER/LFS_GROUP)
  mount                  Monta sistemas de arquivos virtuais no LFS
  umount                 Desmonta sistemas de arquivos virtuais do LFS
  chroot                 Entra em chroot (seguro se possível)
  chroot-plain           Entra em chroot simples (sem unshare, etc.)
  status                 Mostra status básico do ambiente LFS
  safe-strip <dir>       Faz strip seguro em <dir>, pulando Glibc e arquivos críticos

Comandos de build:
  run-build <spec>       Executa script de build dentro do LFS com:
                         - resolução de dependências (arquivo <prog>.deps)
                         - hooks pre/post install
                         - manifesto de arquivos instalados
                         spec pode ser:
                           binutils-pass1
                           binutils-pass1.sh
                           core/binutils-pass1
                           core/binutils-pass1/binutils-pass1.sh
  build-status           Lista pacotes já registrados

Comandos de desinstalação:
  uninstall <pacote>     Desinstala pacote usando manifesto
                         (pacote = nome lógico, ex: binutils-pass1)
  uninstall-orphans      Desinstala pacotes órfãos (ninguém depende deles)

Arquivo de configuração (opcional):
  $LFS_CONFIG

Estrutura de scripts:
  $LFS/build-scripts/<categoria>/<programa>/<programa>.sh
  $LFS/build-scripts/<categoria>/<programa>/<programa>.deps
  $LFS/build-scripts/<categoria>/<programa>/<programa>.pre_install
  $LFS/build-scripts/<categoria>/<programa>/<programa>.post_install
  $LFS/build-scripts/<categoria>/<programa>/<programa>.pre_uninstall
  $LFS/build-scripts/<categoria>/<programa>/<programa>.post_uninstall
EOF
}

#--------------------------------------------------------
# Main
#--------------------------------------------------------

main() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    load_config
    require_root

    local cmd="$1"; shift || true

    case "$cmd" in
        init)
            init_layout
            ;;
        create-user)
            create_build_user
            ;;
        mount)
            mount_virtual_fs
            ;;
        umount)
            umount_virtual_fs
            ;;
        chroot)
            mount_virtual_fs
            if [[ "$CHROOT_SECURE" -eq 1 ]]; then
                enter_chroot_secure
            else
                enter_chroot_plain
            fi
            ;;
        chroot-plain)
            mount_virtual_fs
            enter_chroot_plain
            ;;
        status)
            status
            ;;
        safe-strip)
            adm_safe_strip_tree "${1:-}"
            ;;
        run-build)
            run_build_script "$@"
            ;;
        build-status)
            build_status
            ;;
        uninstall)
            uninstall_pkg "${1:-}"
            ;;
        uninstall-orphans)
            uninstall_orphans
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            echo "Comando desconhecido: $cmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
