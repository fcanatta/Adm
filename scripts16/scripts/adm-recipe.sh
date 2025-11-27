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

Notas:
  - <grupo> vira subdiretório em: \$ADM_RECIPES_DIR/<grupo>/<nome>.sh
  - O template gerado já é compatível com o adm (PKG_SOURCES, PKG_SHA256S, PKG_MD5S).
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

  [[ -n "$group" ]] || die "Informe o grupo (ex.: core, cross-toolchain, libs)."
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
# Pacote: $name ($version)

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
# Exemplo:
# PKG_SOURCES="https://ftp.gnu.org/gnu/$name/$name-\$PKG_VERSION.tar.xz"
PKG_SOURCES=""

# Checksums opcionais (listas alinhadas com PKG_SOURCES).
# Exemplo:
# PKG_SHA256S="hash1 hash2"
# PKG_MD5S="md5_1 md5_2"
PKG_SHA256S=""
PKG_MD5S=""

# Versão upstream para o mecanismo de upgrade do adm.
# Por padrão, tenta usar adm_generic_upstream_version (implementado no adm),
# caindo para a própria PKG_VERSION se ela não existir ou falhar.
pkg_upstream_version() {
  if command -v adm_generic_upstream_version >/dev/null 2>&1; then
    adm_generic_upstream_version
  else
    printf '%s\n' "\$PKG_VERSION"
  fi
}

# -------------------------------------------------------------
# Etapas do build
# -------------------------------------------------------------

# Executada antes do build (aplicar patch, checar ambiente, etc.)
pkg_prepare() {
  :
}

# Compilar o pacote
# Use sempre as variáveis:
#   - \$PKG_DESTDIR: raiz de instalação temporária (DESTDIR)
#   - \$PKG_PREFIX:  prefixo lógico de instalação (normalmente /usr)
pkg_build() {
  :
}

# Testes (opcional)
pkg_check() {
  :
}

# Instalar no DESTDIR do adm.
# Use sempre DESTDIR="\${PKG_DESTDIR}" e respeite \$PKG_PREFIX.
pkg_install() {
  : "\${PKG_DESTDIR:?PKG_DESTDIR não definido}"

  # Exemplo para autotools:
  # ./configure --prefix="\$PKG_PREFIX"
  # make
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
