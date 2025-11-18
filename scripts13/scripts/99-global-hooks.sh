#!/usr/bin/env bash
# 99-global-hooks.sh
# Hooks globais do ADM (rodam para QUALQUER pacote)
# Principal: adm_global_post_install <pkg_name> <manifest_path>

ADM_GLOBAL_HOOKS_LOADED=1

# Detecta perfil
adm_global_get_profile() {
    local p="${ADM_PROFILE:-normal}"
    case "$p" in
        minimal|normal|aggressive) ;;
        *) p="normal" ;;
    esac
    printf '%s\n' "$p"
}

# Strip seguro baseado no perfil
adm_global_strip_file() {
    local f="$1"
    local profile="$2"

    [[ -x "$(command -v strip 2>/dev/null)" ]] || return 0
    [[ -f "$f" ]] || return 0

    # Usa 'file' pra ver se é ELF
    if command -v file >/dev/null 2>&1; then
        local t
        t="$(file -b "$f" 2>/dev/null || true)"
        [[ "$t" == *"ELF"* ]] || return 0
    fi

    case "$profile" in
        minimal)
            # strip bem leve, só unneeded
            strip --strip-unneeded "$f" 2>/dev/null || true
            ;;
        normal)
            strip --strip-unneeded "$f" 2>/dev/null || true
            ;;
        aggressive)
            strip --strip-all "$f" 2>/dev/null || true
            ;;
    esac
}

# Lê manifest e devolve só lista de arquivos
adm_global_manifest_files() {
    local manifest="$1"
    local in_files=0 line

    [[ -f "$manifest" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$in_files" -eq 0 ]]; then
            [[ -z "$line" ]] && { in_files=1; continue; }
            continue
        fi
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        printf '%s\n' "$line"
    done < "$manifest"
}

# Hook global pós-install
# uso: adm_global_post_install <pkg_name> <manifest_path>
adm_global_post_install() {
    local pkg="$1"
    local manifest="$2"

    local root="${ADM_INSTALL_ROOT:-/}"
    root="${root%/}"

    local profile
    profile="$(adm_global_get_profile)"

    echo "[global-post-install] Pacote='${pkg}' root='${root}' profile='${profile}'"

    # 1) strip leve/agressivo dependendo do profile
    if command -v file >/dev/null 2>&1; then
        adm_global_manifest_files "$manifest" | while IFS= read -r rel; do
            [[ -z "$rel" ]] && continue
            local abs="${root}${rel}"
            adm_global_strip_file "$abs" "$profile"
        done
    fi

    # 2) sanity MUITO básica: só verifica se os arquivos do manifest existem
    local missing=0
    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        local abs="${root}${rel}"
        if [[ ! -e "$abs" ]]; then
            echo "[global-post-install] AVISO: '${abs}' listado no manifest mas não existe."
            missing=1
        fi
    done < <(adm_global_manifest_files "$manifest")

    if [[ "$missing" -eq 0 ]]; then
        echo "[global-post-install] Manifest OK (todos os arquivos existem)."
    else
        echo "[global-post-install] AVISO: Alguns arquivos do manifest estão faltando."
    fi
}
