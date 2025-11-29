#!/bin/bash
set -euo pipefail

# Raiz do adm. Ajuste aqui se usar outro lugar, ou exporte ADM_ROOT no ambiente.
ADM_ROOT="${ADM_ROOT:-/var/lib/adm}"
DB_DIR="${DB_DIR:-${ADM_ROOT}/db}"
META_DIR="${META_DIR:-${ADM_ROOT}/metadata}"

usage() {
    cat <<EOF
Uso:
  $0 list-missing          - Lista todos os pacotes instalados que NÃO possuem nenhum hook local
  $0 gen-hook <pkg> <tipo> - Gera um hook genérico para o pacote e tipo informados
                             (tipo = pre_install | post_install | pre_uninstall | post_uninstall)
  $0 gen-all <pkg>         - Gera todos os hooks padrão em falta para o pacote

Observações:
  - <pkg> é o nome lógico do pacote no adm (ex: shadow, core/shadow, security/openssl)
  - Os hooks são criados no mesmo diretório do arquivo .meta do pacote,
    com nomes do tipo: programa.pre_install, programa.post_uninstall, etc.
EOF
}

# Localiza o .meta mais provável para um "programa" (nome curto, sem grupo)
find_meta_for_prog() {
    local prog="$1"
    # Procura exatamente "prog.meta" em META_DIR (profundidade até 3 costuma bastar)
    find "$META_DIR" -mindepth 1 -maxdepth 5 -type f -name "${prog}.meta" -print 2>/dev/null | head -n1 || true
}

# Retorna o diretório de hooks para um pacote (com base no .meta)
hook_dir_for_pkg() {
    local pkg="$1"
    local prog meta

    prog="${pkg##*/}"
    meta="$(find_meta_for_prog "$prog")"

    if [[ -z "$meta" ]]; then
        echo "ERRO: metadata (.meta) para o programa '$prog' não encontrado em $META_DIR" >&2
        return 1
    fi

    dirname "$meta"
}

# Verifica se um pacote (nome lógico) tem algum hook definido
pkg_has_any_hook() {
    local pkg="$1"
    local prog hook_dir t

    prog="${pkg##*/}"
    hook_dir="$(hook_dir_for_pkg "$pkg")" || return 1

    for t in pre_install post_install pre_uninstall post_uninstall; do
        if [[ -e "$hook_dir/${prog}.${t}" ]]; then
            return 0  # tem pelo menos um hook
        fi
    done
    return 1  # nenhum hook encontrado
}

# Lista todos os pacotes instalados que não têm hooks
list_missing_hooks() {
    if [[ ! -d "$DB_DIR" ]]; then
        echo "ERRO: DB_DIR não encontrado: $DB_DIR" >&2
        exit 1
    fi

    local found_any=0

    # Um "pacote" é qualquer diretório dentro do DB que tenha metadata.meta ou files.list
    while IFS= read -r pkgdir; do
        if [[ ! -d "$pkgdir" ]]; then
            continue
        fi

        if [[ ! -f "$pkgdir/metadata.meta" && ! -f "$pkgdir/files.list" ]]; then
            continue
        fi

        local pkg pkg_rel
        pkg_rel="${pkgdir#$DB_DIR/}"
        pkg="$pkg_rel"

        # Tenta ver se tem hooks; se não tiver .meta correspondente, só avisa
        if pkg_has_any_hook "$pkg"; then
            continue
        else
            echo "$pkg"
            found_any=1
        fi
    done < <(find "$DB_DIR" -mindepth 1 -type d 2>/dev/null)

    if [[ "$found_any" -eq 0 ]]; then
        echo "# Todos os pacotes instalados parecem ter pelo menos um hook definido."
    fi
}

# Gera um hook genérico para um pacote/tipo
gen_one_hook() {
    local pkg="$1"
    local hook_type="$2"

    case "$hook_type" in
        pre_install|post_install|pre_uninstall|post_uninstall) ;;
        *)
            echo "ERRO: tipo de hook inválido: '$hook_type'" >&2
            echo "Tipos válidos: pre_install, post_install, pre_uninstall, post_uninstall" >&2
            return 1
            ;;
    esac

    local hook_dir prog hook_file
    hook_dir="$(hook_dir_for_pkg "$pkg")" || return 1
    prog="${pkg##*/}"
    hook_file="${hook_dir}/${prog}.${hook_type}"

    if [[ -e "$hook_file" ]]; then
        echo "AVISO: hook já existe, não sobrescrevendo: $hook_file" >&2
        return 0
    fi

    cat >"$hook_file" <<EOF
#!/bin/bash
# Hook genérico gerado automaticamente pelo adm-hooks-helper.sh
# Argumentos: \$1 = nome lógico do pacote, \$2 = tipo de hook
set -euo pipefail
pkg="\${1:-$pkg}"
phase="\${2:-$hook_type}"

echo "[\$pkg] [\$phase] Hook \$(basename "\$0") ainda não foi personalizado."
EOF

    chmod +x "$hook_file"
    echo "Hook criado: $hook_file"
}

# Gera todos os hooks padrão em falta para um pacote
gen_all_hooks_for_pkg() {
    local pkg="$1"
    local t
    for t in pre_install post_install pre_uninstall post_uninstall; do
        gen_one_hook "$pkg" "$t" || true
    done
}

# --------------------------------------------------
# Entrada principal
# --------------------------------------------------

cmd="${1:-}"

case "$cmd" in
    list-missing)
        list_missing_hooks
        ;;
    gen-hook)
        shift || true
        if [[ $# -lt 2 ]]; then
            usage
            exit 1
        fi
        gen_one_hook "$1" "$2"
        ;;
    gen-all)
        shift || true
        if [[ $# -lt 1 ]]; then
            usage
            exit 1
        fi
        gen_all_hooks_for_pkg "$1"
        ;;
    ""|-h|--help|help)
        usage
        ;;
    *)
        echo "Comando desconhecido: $cmd" >&2
        usage
        exit 1
        ;;
esac
