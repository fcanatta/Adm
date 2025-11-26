#!/usr/bin/env bash
# adm-recipe - gerador de recipes para o adm

set -euo pipefail

ADM_STATE_DIR="${ADM_STATE_DIR:-/var/lib/adm}"
ADM_RECIPES_DIR="${ADM_RECIPES_DIR:-$ADM_STATE_DIR/recipes}"

usage() {
  cat <<EOF
Uso:
  adm-recipe generate <grupo> <nome> [versão]

Exemplos:
  adm-recipe generate core bash 5.2.32
  adm-recipe generate cross-toolchain gcc-pass1 15.2.0
  adm-recipe generate libs zlib       # pergunta a versão e usa 1.0.0 se vazio
EOF
}

die() {
  echo "ERRO: $*" >&2
  exit 1
}

cmd_generate() {
  local group name version
  group="${1:-}"
  name="${2:-}"
  version="${3:-}"

  [[ -n "$group" ]] || die "Informe o grupo (ex.: core, cross-toolchain)."
  [[ -n "$name"  ]] || die "Informe o nome do pacote (ex.: gcc, bash, zlib)."

  # Se a versão não foi passada na linha de comando, pergunta interativamente
  if [[ -z "$version" ]]; then
    read -rp "Versão do pacote $name (ex: 1.2.3) [1.0.0]: " version
    version="${version:-1.0.0}"
  fi

  # Caminho da recipe
  local target_dir="$ADM_RECIPES_DIR/$group"
  local target_file="$target_dir/$name.sh"

  mkdir -p "$target_dir"

  if [[ -e "$target_file" ]]; then
    die "Recipe já existe: $target_file"
  fi

  local now
  now="$(date -Iseconds)"

  cat >"$target_file" <<EOF
#!/usr/bin/env bash
# Recipe gerado automaticamente por adm-recipe em $now
# Grupo: $group
# Pacote: $name (${version})

PKG_NAME="$name"
PKG_VERSION="$version"
PKG_RELEASE="1"

PKG_DESC="$name - descrição do pacote aqui"
PKG_LICENSE="UNKNOWN"
PKG_URL="https://example.org/$name"
PKG_GROUPS="$group"

# Dependências (nomes de outros PKG_NAME, separados por espaço)
PKG_DEPENDS=""

# Fontes (URLs, separados por espaço se houver mais de um)
PKG_SOURCES=""

# Checksums opcionais (preencha se quiser validação forte de download)
PKG_SHA256SUM=""
PKG_MD5SUM=""

# Versão upstream para o mecanismo de upgrade do adm.
# Por padrão, retorna a própria PKG_VERSION. Edite se quiser algo mais esperto.
pkg_upstream_version() {
  printf '%s\n' "\$PKG_VERSION"
}

# -------------------------------------------------------------
# Etapas do build
# -------------------------------------------------------------

# Executada antes do build (aplicar patch, checar ambiente, etc.)
pkg_prepare() {
  :
}

# Compilar o pacote
pkg_build() {
  :
}

# Testes (opcional)
pkg_check() {
  :
}

# Instalar no DESTDIR do adm.
# Use sempre DESTDIR="\${PKG_DESTDIR}" ou "\${PKG_DESTDIR}\$algum_prefixo".
pkg_install() {
  : "\${PKG_DESTDIR:?PKG_DESTDIR não definido}"

  # Exemplo para autotools:
  # make DESTDIR="\${PKG_DESTDIR}" install
}
EOF

  chmod +x "$target_file"

  echo "Recipe criada em: $target_file"
}

# -------------------------------------------------------------
# Main
# -------------------------------------------------------------

cmd="${1:-}"

case "$cmd" in
  generate)
    shift
    cmd_generate "$@"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    die "Comando desconhecido: $cmd (use 'adm-recipe generate' ou '--help')"
    ;;
esac
