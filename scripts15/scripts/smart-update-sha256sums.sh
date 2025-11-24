#!/usr/bin/env bash
# smart-update-sha256sums.sh
#
# Atualiza o bloco sha256sums=() de um metadata:
#  - Lê sources=() do metadata
#  - Usa cache em /var/cache/pkg/sources (igual ao pkg)
#  - Não baixa de novo se já existir no cache
#  - Atualiza/apende entradas dentro do bloco sha256sums=()
#
# Uso:
#   sudo ./smart-update-sha256sums.sh <categoria> <nome> [indice_source]
#
#   <categoria>     ex: core
#   <nome>          ex: gcc
#   indice_source   opcional, 1-based (ex: 1); se omitido, atualiza todos
#
# Ex:
#   sudo ./smart-update-sha256sums.sh core gcc
#   sudo ./smart-update-sha256sums.sh core libcap 1

set -euo pipefail

PKG_META_ROOT="/usr/src/packages"
PKG_CACHE_ROOT="${PKG_CACHE_ROOT:-/var/cache/pkg}"
PKG_CACHE_SOURCES="${PKG_CACHE_SOURCES:-$PKG_CACHE_ROOT/sources}"

usage() {
  cat <<EOF
Uso: $0 <categoria> <nome> [indice_source]

Exemplos:
  sudo $0 core xz
  sudo $0 core gcc
  sudo $0 core libcap 1    # só o primeiro source do array
EOF
  exit 1
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  usage
fi

CATEGORY="$1"
NAME="$2"
SOURCE_INDEX="${3:-}"

METADATA="${PKG_META_ROOT}/${CATEGORY}/${NAME}/metadata"

if [ ! -r "$METADATA" ]; then
  echo "Metadata não encontrado: $METADATA" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Precisa ser root para editar $METADATA e usar o cache em $PKG_CACHE_ROOT." >&2
  exit 1
fi

if ! command -v sha256sum >/dev/null 2>&1; then
  echo "sha256sum não encontrado no PATH." >&2
  exit 1
fi

mkdir -p "$PKG_CACHE_SOURCES"

fetch_if_needed() {
  local src="$1"
  local cachefile="$2"

  if [ -e "$cachefile" ]; then
    echo "   * Já em cache: $cachefile"
    return 0
  fi

  echo "   * Baixando: $src"
  if command -v curl >/dev/null 2>&1; then
    curl -fL -o "$cachefile" "$src"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$cachefile" "$src"
  else
    echo "Nem curl nem wget disponíveis para baixar $src" >&2
    return 1
  fi
}

cache_key_for_source() {
  local src="$1"
  echo "$src" | sed 's#[/:]#_#g'
}

# 1) Ler sources[] do metadata em subshell (pra não poluir ambiente atual)
readarray -t ALL_SOURCES < <(
  bash -c '
    set -e
    unset sources
    # shellcheck source=/dev/null
    . "$1"
    for s in "${sources[@]:-}"; do
      printf "%s\n" "$s"
    done
  ' _ "$METADATA"
)

if ((${#ALL_SOURCES[@]} == 0)); then
  echo "Nenhum source encontrado em 'sources=()' no metadata." >&2
  exit 1
fi

# Se o usuário passou índice, filtra apenas aquele source (1-based)
declare -a SOURCES
if [ -n "$SOURCE_INDEX" ]; then
  if ! [[ "$SOURCE_INDEX" =~ ^[0-9]+$ ]]; then
    echo "Indice inválido: $SOURCE_INDEX (use número 1-based)" >&2
    exit 1
  fi
  idx=$((SOURCE_INDEX - 1))
  if (( idx < 0 || idx >= ${#ALL_SOURCES[@]} )); then
    echo "Indice $SOURCE_INDEX fora do intervalo (1..${#ALL_SOURCES[@]})." >&2
    exit 1
  fi
  SOURCES=( "${ALL_SOURCES[$idx]}" )
else
  SOURCES=( "${ALL_SOURCES[@]}" )
fi

echo ">> Metadata: $METADATA"
echo ">> Sources selecionados:"
printf '   - %s\n' "${SOURCES[@]}"

# 2) Ler sha256sums existentes (se houver) pra preservar/mesclar
declare -A SHA_ENTRIES   # key -> hash
declare -a SHA_KEYS      # ordem original
FOUND_BLOCK=0

{
  inside=0
  while IFS= read -r line; do
    if (( inside )); then
      # Fim do bloco sha256sums
      if [[ "$line" == *")"* ]]; then
        inside=0
        continue
      fi

      # Procurar linhas do tipo "key=hash" dentro de aspas
      if [[ "$line" =~ \"([^\"]+)\" ]]; then
        entry="${BASH_REMATCH[1]}"   # key=hash
        key="${entry%%=*}"
        val="${entry#*=}"
        if [ -n "$key" ] && [ -n "$val" ]; then
          if [[ -z "${SHA_ENTRIES[$key]:-}" ]]; then
            SHA_KEYS+=( "$key" )
          fi
          SHA_ENTRIES["$key"]="$val"
        fi
      fi
      continue
    fi

    if [[ "$line" =~ ^sha256sums=\( ]]; then
      FOUND_BLOCK=1
      inside=1
      continue
    fi
  done
} < "$METADATA"

# 3) Gerar novos hashes (sem rebaixar se já estiver no cache)
declare -A NEW_SHA       # key -> hash

echo ">> Usando cache em: $PKG_CACHE_SOURCES"
echo ">> Calculando sha256 dos sources..."

for src in "${SOURCES[@]}"; do
  # Só tratar URLs http(s)/ftp
  if ! printf '%s\n' "$src" | grep -Eq '^(https?|ftp)://'; then
    echo "   * [AVISO] source não é URL http/https/ftp, pulando: $src" >&2
    continue
  fi

  key="$(cache_key_for_source "$src")"
  cachefile="$PKG_CACHE_SOURCES/$key"

  fetch_if_needed "$src" "$cachefile"

  echo "   * sha256sum de $key ..."
  hash="$(sha256sum "$cachefile" | awk '{print $1}')"

  echo "     -> $key=$hash"
  NEW_SHA["$key"]="$hash"
done

if ((${#NEW_SHA[@]} == 0)); then
  echo "Nenhum hash novo gerado. Nada a fazer." >&2
  exit 1
fi

# 4) Mesclar NEW_SHA com SHA_ENTRIES existente
for key in "${!NEW_SHA[@]}"; do
  if [[ -z "${SHA_ENTRIES[$key]:-}" ]]; then
    SHA_KEYS+=( "$key" )
  fi
  SHA_ENTRIES["$key"]="${NEW_SHA[$key]}"
done

# 5) Regravar metadata, substituindo/apendando bloco sha256sums
TMP_METADATA="$(mktemp)"

emit_sha_block() {
  echo 'sha256sums=('
  for key in "${SHA_KEYS[@]}"; do
    val="${SHA_ENTRIES[$key]}"
    [ -n "$val" ] || continue
    printf '  "%s=%s"\n' "$key" "$val"
  done
  echo ')'
}

echo ">> Reescrevendo sha256sums dentro de $METADATA"

inside=0
REPLACED=0

while IFS= read -r line; do
  if (( inside )); then
    # Fim do bloco antigo
    if [[ "$line" == *")"* ]]; then
      inside=0
      # Já imprimimos o bloco novo no início do bloco, então só continua
    fi
    continue
  fi

  if [[ "$line" =~ ^sha256sums=\( ]]; then
    inside=1
    if (( ! REPLACED )); then
      emit_sha_block >> "$TMP_METADATA"
      REPLACED=1
    fi
    continue
  fi

  echo "$line" >> "$TMP_METADATA"
done < "$METADATA"

# Se não havia bloco sha256sums, append no final
if (( ! FOUND_BLOCK )); then
  echo >> "$TMP_METADATA"
  emit_sha_block >> "$TMP_METADATA"
fi

# Preservar dono/permissão
orig_owner="$(stat -c '%u:%g' "$METADATA")"
orig_mode="$(stat -c '%a' "$METADATA")"

mv "$TMP_METADATA" "$METADATA"
chown "$orig_owner" "$METADATA" || true
chmod "$orig_mode" "$METADATA" || true

echo ">> sha256sums atualizado com sucesso em:"
echo "   $METADATA"
echo
echo ">> Novo bloco sha256sums:"
grep -A999 '^sha256sums=(' "$METADATA"
