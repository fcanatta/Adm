#!/usr/bin/env bash
# 06-cross-toolchain.sh
# Orquestra a cross-toolchain LFS:
#   binutils-pass1 -> gcc-pass1 -> linux-headers -> glibc -> musl
#   -> binutils-pass2 -> gcc-pass2 -> libstdc++-15.2.0 -> limpeza
# e monta categorias (sys,libs,dev,x11,wayland,apps) via 04/05.
###############################################################################
# Detecção de modo (CLI vs sourced)
###############################################################################

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ADM_CROSS_CLI_MODE=1
else
    ADM_CROSS_CLI_MODE=0
fi

# Carrega env/lib se ainda não foram carregados
if [[ -z "${ADM_ENV_LOADED:-}" ]]; then
    if [[ -f /usr/src/adm/scripts/01-env.sh ]]; then
        # shellcheck disable=SC1091
        . /usr/src/adm/scripts/01-env.sh
    else
        echo "ERRO: 01-env.sh não encontrado em /usr/src/adm/scripts." >&2
        exit 1
    fi
fi

if [[ -z "${ADM_LIB_LOADED:-}" ]]; then
    if [[ -f /usr/src/adm/scripts/02-lib.sh ]]; then
        # shellcheck disable=SC1091
        . /usr/src/adm/scripts/02-lib.sh
    else
        echo "ERRO: 02-lib.sh não encontrado em /usr/src/adm/scripts." >&2
        exit 1
    fi
fi

# Precisamos de detect/build/install
if [[ -f /usr/src/adm/scripts/03-detect.sh ]]; then
    # shellcheck disable=SC1091
    . /usr/src/adm/scripts/03-detect.sh || true
fi

if [[ -f /usr/src/adm/scripts/04-build-pkg.sh ]]; then
    # shellcheck disable=SC1091
    . /usr/src/adm/scripts/04-build-pkg.sh || true
fi

if [[ -f /usr/src/adm/scripts/05-install-pkg.sh ]]; then
    # shellcheck disable=SC1091
    . /usr/src/adm/scripts/05-install-pkg.sh || true
fi

###############################################################################
# 1. Configuração da cross-toolchain (ordem exata)
###############################################################################
# Cada item aqui é um "name=" de metafile real em ADM_REPO

# Passo 1: binutils e gcc cross C-only
ADM_CROSS_STAGE1_PKGS=(
    "binutils-pass1"
    "gcc-pass1"
)

# Headers do kernel que a glibc/musl usam
ADM_CROSS_HEADERS_PKG=(
    "linux-headers"
)

# Libcs: primeiro glibc, depois musl (com patch via hook/patch)
ADM_CROSS_LIBC_PKGS=(
    "glibc"
    "musl"
)

# Passo 2: binutils ajustado + gcc definitivo + libstdc++
ADM_CROSS_STAGE2_PKGS=(
    "binutils-pass2"
    "gcc-pass2"
    "libstdc++-15.2.0"
)

# Pacotes temporários que podem ser limpos depois
ADM_CROSS_CLEAN_PKGS=(
    "binutils-pass1"
    "gcc-pass1"
)

# Categorias para base/world
ADM_CROSS_BASE_CATEGORIES=("sys" "libs" "dev")
ADM_CROSS_WORLD_CATEGORIES=("sys" "libs" "dev" "x11" "wayland" "apps")

# Raiz do sistema LFS / chroot
: "${ADM_CROSS_ROOT:=${ADM_CHROOT}}"

###############################################################################
# 2. Helpers de busca de metafile e checagem de instalação
###############################################################################

adm_cross_find_metafile_for_pkg() {
    local name="$1"
    local f

    if declare -F adm_build_find_metafile_for_pkg >/dev/null 2>&1; then
        adm_build_find_metafile_for_pkg "$name" && return 0
    fi
    if declare -F adm_detect_find_metafile_for_pkg >/dev/null 2>&1; then
        adm_detect_find_metafile_for_pkg "$name" && return 0
    fi

    while IFS= read -r -d '' f; do
        if [[ "$(basename "$(dirname "$f")")" == "$name" ]]; then
            echo "$f"
            return 0
        fi
    done < <(find "${ADM_REPO}" -maxdepth 3 -type f -name "metafile" -print0 2>/dev/null || true)

    return 1
}

adm_cross_pkg_db_file() {
    local name="$1"
    echo "${ADM_DB_PKG}/${name}.installed"
}

adm_cross_is_installed() {
    local name="$1"
    [[ -f "$(adm_cross_pkg_db_file "$name")" ]]
}

###############################################################################
# 3. Chroot seguro (montagem / desmontagem)
###############################################################################

adm_cross_prepare_root() {
    local root="$ADM_CROSS_ROOT"

    if [[ -z "$root" ]]; then
        adm_error "ADM_CROSS_ROOT não definido."
        return 1
    fi

    mkdir -p "${root}" || {
        adm_error "Não foi possível criar raiz de cross '${root}'."
        return 1
    }

    for d in dev proc sys run tmp var tmp; do
        mkdir -p "${root}/${d}" 2>/dev/null || true
    done

    if [[ -r /etc/resolv.conf ]]; then
        mkdir -p "${root}/etc" || true
        cp -L /etc/resolv.conf "${root}/etc/resolv.conf" 2>/dev/null || true
    fi
}

adm_cross_mount_chroot() {
    local root="$ADM_CROSS_ROOT"

    adm_info "Montando chroot base em '${root}'."
    adm_cross_prepare_root || return 1

    if ! mountpoint -q "${root}/dev"; then
        mount --bind /dev "${root}/dev" || adm_warn "Falha ao montar /dev em chroot."
    fi
    if ! mountpoint -q "${root}/dev/pts"; then
        mkdir -p "${root}/dev/pts" || true
        mount --bind /dev/pts "${root}/dev/pts" || adm_warn "Falha ao montar /dev/pts em chroot."
    fi
    if ! mountpoint -q "${root}/proc"; then
        mount -t proc proc "${root}/proc" || adm_warn "Falha ao montar /proc em chroot."
    fi
    if ! mountpoint -q "${root}/sys"; then
        mount -t sysfs sys "${root}/sys" || adm_warn "Falha ao montar /sys em chroot."
    fi
    if ! mountpoint -q "${root}/run"; then
        mount --bind /run "${root}/run" || adm_warn "Falha ao montar /run em chroot."
    fi
}

adm_cross_umount_one() {
    local path="$1"
    if mountpoint -q "$path"; then
        umount "$path" 2>/dev/null || adm_warn "Falha ao desmontar '$path'."
    fi
}

adm_cross_umount_chroot() {
    local root="$ADM_CROSS_ROOT"
    adm_info "Desmontando chroot '${root}'."
    adm_cross_umount_one "${root}/run"
    adm_cross_umount_one "${root}/sys"
    adm_cross_umount_one "${root}/proc"
    adm_cross_umount_one "${root}/dev/pts"
    adm_cross_umount_one "${root}/dev"
}

adm_cross_run_in_chroot() {
    local root="$ADM_CROSS_ROOT"
    local cmd=("$@")

    if [[ ! -d "$root" ]]; then
        adm_error "Chroot '${root}' não existe."
        return 1
    fi

    chroot "$root" /usr/bin/env \
        ADM_PROFILE="${ADM_PROFILE}" \
        ADM_LIBC="${ADM_LIBC}" \
        ADM_ROOT="/usr/src/adm" \
        /usr/bin/env "${cmd[@]}"
}

###############################################################################
# 4. Construção e instalação de um pacote (cross-aware)
###############################################################################

adm_cross_build_and_install_one() {
    local pkg="$1"
    local metafile=""

    [[ -z "$pkg" ]] && return 0

    if adm_cross_is_installed "$pkg"; then
        adm_info "Pacote '${pkg}' já instalado no DB; pulando."
        return 0
    fi

    metafile="$(adm_cross_find_metafile_for_pkg "$pkg" || true)"
    if [[ -z "$metafile" ]]; then
        adm_error "Metafile não encontrado para pacote '${pkg}'."
        return 1
    fi

    adm_info "Construindo pacote '${pkg}' a partir de '${metafile}'."

    if [[ ! -x "${ADM_SCRIPTS}/04-build-pkg.sh" ]]; then
        adm_error "04-build-pkg.sh não executável; não posso construir '${pkg}'."
        return 1
    fi

    "${ADM_SCRIPTS}/04-build-pkg.sh" "$metafile" || {
        adm_error "Falha na construção do pacote '${pkg}'."
        return 1
    }

    adm_info "Instalando pacote '${pkg}' na raiz '${ADM_CROSS_ROOT}'."

    if [[ ! -x "${ADM_SCRIPTS}/05-install-pkg.sh" ]]; then
        adm_error "05-install-pkg.sh não executável; não posso instalar '${pkg}'."
        return 1
    fi

    ADM_INSTALL_ROOT="${ADM_CROSS_ROOT}" "${ADM_SCRIPTS}/05-install-pkg.sh" "$metafile" || {
        adm_error "Falha na instalação do pacote '${pkg}' em '${ADM_CROSS_ROOT}'."
        return 1
    }

    return 0
}

adm_cross_build_sequence() {
    local label="$1"
    shift
    local pkgs=("$@")
    local p

    adm_info "Iniciando sequência '${label}' (${#pkgs[@]} pacote(s))."

    for p in "${pkgs[@]}"; do
        adm_run_with_spinner "Build+install '${p}'..." \
            adm_cross_build_and_install_one "$p" || return 1
    done

    adm_info "Sequência '${label}' concluída."
}

###############################################################################
# 5. Estágios da cross-toolchain (ordem LFS)
###############################################################################

adm_cross_stage1() {
    adm_info "==== STAGE 1: binutils-pass1, gcc-pass1 ===="
    adm_cross_build_sequence "stage1" "${ADM_CROSS_STAGE1_PKGS[@]}"
}

adm_cross_headers_stage() {
    adm_info "==== HEADERS: linux-headers ===="
    adm_cross_build_sequence "headers" "${ADM_CROSS_HEADERS_PKG[@]}"
}

adm_cross_libc_stage() {
    adm_info "==== LIBC: glibc + musl (com patch) ===="
    local p
    for p in "${ADM_CROSS_LIBC_PKGS[@]}"; do
        # musl pode não existir; ignora silencioso se for o caso
        if ! adm_cross_find_metafile_for_pkg "$p" >/dev/null 2>&1; then
            adm_warn "Metafile para '${p}' não encontrado; pulando."
            continue
        fi
        adm_run_with_spinner "Build+install libc '${p}'..." \
            adm_cross_build_and_install_one "$p" || return 1
    done
}

adm_cross_stage2() {
    adm_info "==== STAGE 2: binutils-pass2, gcc-pass2, libstdc++-15.2.0 ===="
    adm_cross_build_sequence "stage2" "${ADM_CROSS_STAGE2_PKGS[@]}"
}

adm_cross_cleanup() {
    adm_info "==== LIMPEZA DO TOOLCHAIN TEMPORÁRIO ===="
    local p
    for p in "${ADM_CROSS_CLEAN_PKGS[@]}"; do
        if declare -F adm_remove_pipeline >/dev/null 2>&1; then
            adm_info "Removendo temporário '${p}' via remove-pkg."
            adm_remove_pipeline "$p" || adm_warn "Falha ao remover '${p}' durante limpeza."
        else
            adm_warn "Suporte de remoção não carregado; '${p}' não será removido automaticamente."
        fi
    done

    if [[ -x "${ADM_SCRIPTS}/08-clean.sh" ]]; then
        adm_info "Chamando 08-clean.sh --mode cross."
        "${ADM_SCRIPTS}/08-clean.sh" --mode cross || adm_warn "08-clean.sh reportou problemas."
    fi
}

adm_cross_full_toolchain() {
    adm_init_log "cross-toolchain"
    adm_enable_strict_mode

    adm_info "==== INICIANDO CROSS TOOLCHAIN COMPLETA (LFS) ===="
    adm_info "Ordem: binutils-pass1 -> gcc-pass1 -> linux-headers -> glibc -> musl -> binutils-pass2 -> gcc-pass2 -> libstdc++-15.2.0"

    adm_cross_stage1       || return 1
    adm_cross_headers_stage|| return 1
    adm_cross_libc_stage   || return 1
    adm_cross_stage2       || return 1
    adm_cross_cleanup      || adm_warn "Limpeza encontrou problemas; verifique logs."

    adm_info "==== CROSS TOOLCHAIN COMPLETA CONCLUÍDA ===="
}

###############################################################################
# 6. Construção de categorias (sys, libs, dev, x11, wayland, apps)
###############################################################################

adm_cross_list_packages_in_category() {
    local cat="$1"
    local dir="${ADM_REPO}/${cat}"
    local f

    [[ -d "$dir" ]] || return 0

    while IFS= read -r -d '' f; do
        echo "$(basename "$(dirname "$f")")"
    done < <(find "$dir" -mindepth 2 -maxdepth 2 -type f -name "metafile" -print0 2>/dev/null || true)
}

adm_cross_build_category() {
    local cat="$1"
    local pkgs=()
    local p

    adm_info "==== CATEGORIA '${cat}' NA RAIZ '${ADM_CROSS_ROOT}' ===="

    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        pkgs+=("$p")
    done < <(adm_cross_list_packages_in_category "$cat")

    if [[ "${#pkgs[@]}" -eq 0 ]]; then
        adm_warn "Nenhum pacote encontrado na categoria '${cat}'."
        return 0
    fi

    adm_info "Categoria '${cat}' contém ${#pkgs[@]} pacote(s): ${pkgs[*]}"

    local pkg
    for pkg in "${pkgs[@]}"; do
        adm_run_with_spinner "Build+install '${pkg}' (cat=${cat})..." \
            adm_cross_build_and_install_one "$pkg" || return 1
    done

    adm_info "Categoria '${cat}' concluída."
}

adm_cross_build_categories_list() {
    local label="$1"; shift
    local cats=("$@")
    local c

    adm_info "==== CONSTRUINDO CONJUNTO DE CATEGORIAS (${label}) ===="
    for c in "${cats[@]}"; do
        adm_cross_build_category "$c" || return 1
    done
    adm_info "==== CONJUNTO '${label}' CONCLUÍDO ===="
}

adm_cross_build_base_categories() {
    adm_cross_build_categories_list "base (sys,libs,dev)" "${ADM_CROSS_BASE_CATEGORIES[@]}"
}

adm_cross_build_world_categories() {
    adm_cross_build_categories_list "world (sys,libs,dev,x11,wayland,apps)" "${ADM_CROSS_WORLD_CATEGORIES[@]}"
}

###############################################################################
# 7. Pipelines high-level: base, world, full
###############################################################################

adm_cross_pipeline_base() {
    adm_init_log "cross-base"
    adm_enable_strict_mode

    adm_info "==== PIPELINE BASE: CROSS TOOLCHAIN + CATEGORIAS BASE ===="
    adm_info "Perfil: ${ADM_PROFILE}, libc: ${ADM_LIBC}, raiz: ${ADM_CROSS_ROOT}"

    adm_cross_full_toolchain || return 1

    adm_cross_mount_chroot   || return 1
    adm_info "Entrando no chroot '${ADM_CROSS_ROOT}' para construir categorias base."

    adm_cross_run_in_chroot "/usr/src/adm/scripts/06-cross-toolchain.sh" \
        --build-base-inside || {
        adm_cross_umount_chroot
        return 1
    }

    adm_cross_umount_chroot

    adm_info "==== PIPELINE BASE CONCLUÍDA ===="
}

adm_cross_pipeline_world() {
    adm_init_log "cross-world"
    adm_enable_strict_mode

    adm_info "==== PIPELINE WORLD: CROSS TOOLCHAIN + WORLD COMPLETO ===="
    adm_info "Perfil: ${ADM_PROFILE}, libc: ${ADM_LIBC}, raiz: ${ADM_CROSS_ROOT}"

    adm_cross_full_toolchain || return 1

    adm_cross_mount_chroot   || return 1
    adm_info "Entrando no chroot '${ADM_CROSS_ROOT}' para construir WORLD completo."

    adm_cross_run_in_chroot "/usr/src/adm/scripts/06-cross-toolchain.sh" \
        --build-world-inside || {
        adm_cross_umount_chroot
        return 1
    }

    adm_cross_umount_chroot

    adm_info "==== PIPELINE WORLD CONCLUÍDA ===="
}

###############################################################################
# 8. CLI / dispatch
###############################################################################

adm_cross_usage() {
    cat <<EOF
Uso: 06-cross-toolchain.sh <comando> [opções]

Comandos principais:
  cross           - constrói APENAS a cross-toolchain completa (binutils1,gcc1,linux-headers,glibc,musl,binutils2,gcc2,libstdc++)
  base            - cross-toolchain + categorias base (sys,libs,dev) via chroot
  world           - cross-toolchain + WORLD completo (sys,libs,dev,x11,wayland,apps) via chroot

Comandos internos:
  stage1          - apenas stage1 (binutils-pass1,gcc-pass1)
  headers         - apenas linux-headers
  libc            - apenas etapa de libc (glibc + musl)
  stage2          - apenas stage2 (binutils-pass2,gcc-pass2,libstdc++-15.2.0)
  clean           - apenas limpeza
  build-base      - apenas categorias base (fora do chroot)
  build-world     - categorias base + x11 + wayland + apps (fora do chroot)
  --build-base-inside
                  - usado dentro do chroot para montar categorias base
  --build-world-inside
                  - usado dentro do chroot para montar WORLD

Opções:
  --root <path>   - raiz do sistema alvo (default: ${ADM_CROSS_ROOT})
  --profile <p>   - perfil (minimal|normal|aggressive)
  --libc <l>      - libc principal (glibc|musl)

Exemplos:
  06-cross-toolchain.sh cross
  06-cross-toolchain.sh base --profile minimal --libc glibc
  06-cross-toolchain.sh world --root /mnt/lfs
EOF
}

adm_cross_main() {
    adm_enable_strict_mode

    local cmd=""
    local next_is_root=0 next_is_profile=0 next_is_libc=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            cross|base|world|stage1|stage2|libc|headers|clean|build-base|build-world|--build-base-inside|--build-world-inside)
                cmd="$1"
                shift
                ;;
            --root)    next_is_root=1; shift; continue ;;
            --profile) next_is_profile=1; shift; continue ;;
            --libc)    next_is_libc=1; shift; continue ;;
            *)
                if [[ $next_is_root -eq 1 ]]; then
                    ADM_CROSS_ROOT="$1"; next_is_root=0; shift; continue
                elif [[ $next_is_profile -eq 1 ]]; then
                    ADM_PROFILE="$1";   next_is_profile=0; shift; continue
                elif [[ $next_is_libc -eq 1 ]]; then
                    ADM_LIBC="$1";      next_is_libc=0; shift; continue
                else
                    adm_error "Argumento desconhecido: '$1'"
                    adm_cross_usage
                    exit 1
                fi
                ;;
        esac
    done

    adm_set_profile "$ADM_PROFILE" "$ADM_LIBC" || {
        adm_error "Perfil/libc inválidos."
        exit 1
    }

    [[ -z "$cmd" ]] && cmd="cross"

    case "$cmd" in
        cross)              adm_cross_full_toolchain      ;;
        base)               adm_cross_pipeline_base       ;;
        world)              adm_cross_pipeline_world      ;;
        stage1)             adm_cross_stage1              ;;
        headers)            adm_cross_headers_stage       ;;
        libc)               adm_cross_libc_stage          ;;
        stage2)             adm_cross_stage2              ;;
        clean)              adm_cross_cleanup             ;;
        build-base)         adm_cross_build_base_categories ;;
        build-world)        adm_cross_build_world_categories ;;
        --build-base-inside)
            adm_init_log "cross-build-base-inside"
            adm_cross_build_base_categories
            ;;
        --build-world-inside)
            adm_init_log "cross-build-world-inside"
            adm_cross_build_world_categories
            ;;
        *)
            adm_error "Comando desconhecido: '${cmd}'"
            adm_cross_usage
            exit 1
            ;;
    esac
}

if [[ "$ADM_CROSS_CLI_MODE" -eq 1 ]]; then
    adm_cross_main "$@"
fi
