#!/usr/bin/env bash
# 09-adm-build.part1.sh
# Orquestrador de builds a partir do planfile do resolver:
#  - interpreta STEPs (install/build), executa helpers de build, empacota,
#  - registra manifest/triggers, e produz binários em cache (tar.zst).
# Requer: 00 (config), 01 (lib), 02 (cache), 03 (download), 04 (metafile),
#         05 (hooks/patches), 08 (build-system-helpers), 07 (resolver) p/ gerar plano.
###############################################################################
# Guardas
###############################################################################
if [[ -n "${ADM_BUILD_LOADED_PART1:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_BUILD_LOADED_PART1=1

# Checagem mínima de dependências carregadas
for _m in ADM_CONF_LOADED ADM_LIB_LOADED; do
  if [[ -z "${!_m:-}" ]]; then
    echo "ERRO: 09-adm-build requer módulos básicos carregados (00/01). Faltando: ${_m}" >&2
    return 2 2>/dev/null || exit 2
  fi
done

: "${ADM_CACHE_ROOT:=/usr/src/adm/cache}"
: "${ADM_STATE_ROOT:=/usr/src/adm/state}"
: "${ADM_WORK_ROOT:=/usr/src/adm/work}"
: "${ADM_BUILD_ROOT:=/usr/src/adm/build}"
: "${ADM_DEST_ROOT:=/usr/src/adm/dest}"
: "${ADM_TMP_ROOT:=/usr/src/adm/tmp}"
: "${ADM_BIN_CACHE_ROOT:=${ADM_CACHE_ROOT}/bin}"
: "${ADM_SRC_CACHE_ROOT:=${ADM_CACHE_ROOT}/src}"

: "${ADM_MIN_DISK_MB:=200}"               # espaço mínimo antes de extrair/compilar/empacotar
: "${ADM_TIMEOUT_PACKAGE:=1800}"
: "${ADM_LOG_KEEP:=5}"

###############################################################################
# Auxiliares de erro/log
###############################################################################
b_err()  { adm_err "$*"; }
b_warn() { adm_warn "$*"; }
b_info() { adm_log INFO "${B_CTX_NAME:-pkg}" "build" "$*"; }

###############################################################################
# Contexto do pacote atual (preenchido por step)
###############################################################################
declare -Ag B_CTX=(
  [cat]="" [name]="" [ver]="" [origin]="" [metafile]="" [cache]="" [build_type]=""
  [SRC_DIR]="" [BUILD_DIR]="" [DESTDIR]="" [TMP_DIR]="" [LOG_DIR]="" [STATE_FILE]=""
)

###############################################################################
# Utilidades gerais
###############################################################################
_build_sanitize() {
  local s="$1"; s="${s//[^A-Za-z0-9_.\/-]/_}"; echo "$s"
}

_build_key_from() {
  printf "%s/%s@%s" "$1" "$2" "$3"
}

_build_paths_prepare() {
  # Define SRC_DIR/BUILD_DIR/DESTDIR/TMP_DIR/LOG_DIR e valida sanidade
  local cat="${B_CTX[cat]}" name="${B_CTX[name]}" ver="${B_CTX[ver]}"
  local base="${cat}/${name}-${ver}"
  B_CTX[SRC_DIR]="${ADM_WORK_ROOT%/}/src/${base}/src"
  B_CTX[BUILD_DIR]="${ADM_BUILD_ROOT%/}/${base}"
  B_CTX[DESTDIR]="${ADM_DEST_ROOT%/}/${cat}/${name}/${ver}"
  B_CTX[TMP_DIR]="${ADM_TMP_ROOT%/}/${base}"
  B_CTX[LOG_DIR]="${ADM_STATE_ROOT%/}/logs/${cat}/${name}/${ver}"
  B_CTX[STATE_FILE]="${ADM_STATE_ROOT%/}/progress/${cat}_${name}_${ver}.state"

  mkdir -p -- "${B_CTX[SRC_DIR]%/}" "${B_CTX[BUILD_DIR]%/}" \
               "${B_CTX[DESTDIR]%/}" "${B_CTX[TMP_DIR]%/}" \
               "${B_CTX[LOG_DIR]%/}"  "${ADM_STATE_ROOT%/}/progress" \
               "${ADM_BIN_CACHE_ROOT%/}/${cat}" 2>/dev/null || {
    b_err "falha ao criar diretórios de trabalho/destino"; return 3; }

  # DESTDIR nunca pode ser /
  local dd="$(readlink -f -- "${B_CTX[DESTDIR]}")"
  [[ "$dd" != "/" && "$dd" == ${ADM_DEST_ROOT%/}/* ]] || { b_err "DESTDIR inválido: $dd"; return 5; }

  return 0
}

_build_log_file() {
  local stage="$1"
  echo "${B_CTX[LOG_DIR]%/}/${stage}.log"
}

_build_log_rotate() {
  # mantém somente os N últimos logs por etapa
  local stage="$1" keep="${ADM_LOG_KEEP}"
  [[ -z "$keep" || "$keep" -le 0 ]] && return 0
  local files
  mapfile -t files < <(ls -1t "${B_CTX[LOG_DIR]%/}/${stage}.log"* 2>/dev/null || true)
  local i=0
  for f in "${files[@]}"; do
    i=$((i+1))
    (( i > keep )) && rm -f -- "$f" 2>/dev/null || true
  done
}

_build_check_space() {
  local need_mb="${1:-$ADM_MIN_DISK_MB}" path="${2:-${B_CTX[TMP_DIR]}}"
  local avail
  avail="$(df -Pm "$path" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
  (( avail >= need_mb )) || { b_err "espaço insuficiente em $path: precisa ${need_mb}MB, disponível ${avail}MB"; return 3; }
}

###############################################################################
# State machine (persistente)
###############################################################################
_build_state_set() {
  local st="$1"
  mkdir -p -- "$(dirname -- "${B_CTX[STATE_FILE]}")" 2>/dev/null || true
  echo "$st" > "${B_CTX[STATE_FILE]}" 2>/dev/null || { b_warn "não foi possível gravar state"; return 0; }
}
_build_state_get() {
  [[ -f "${B_CTX[STATE_FILE]}" ]] && cat "${B_CTX[STATE_FILE]}" || echo "pending"
}

###############################################################################
# Locks
###############################################################################
_build_lock_path() {
  printf "%s/locks/%s_%s_%s.lock" "${ADM_STATE_ROOT%/}" "${B_CTX[cat]}" "${B_CTX[name]}" "${B_CTX[ver]}"
}
_build_lock_acquire() {
  local lp="$(_build_lock_path)"; mkdir -p -- "$(dirname -- "$lp")" || true
  exec {ADM_BUILD_LOCK_FD}>"$lp" || { b_err "não foi possível abrir lock $lp"; return 7; }
  flock -n "$ADM_BUILD_LOCK_FD" || { b_err "lock ocupado para ${B_CTX[cat]}/${B_CTX[name]}@${B_CTX[ver]}"; return 7; }
}
_build_lock_release() {
  if [[ -n "${ADM_BUILD_LOCK_FD:-}" ]]; then
    flock -u "$ADM_BUILD_LOCK_FD" 2>/dev/null || true
    exec {ADM_BUILD_LOCK_FD}>&- 2>/dev/null || true
  fi
}

###############################################################################
# Parser do planfile
###############################################################################
_build_parse_step_line() {
  # Entrada: linha; Saída: popula vars locais: action, cat, name, ver, origin, cache/metafile
  local line="$1"
  line="${line#"${line%%[![:space:]]*}"}"
  [[ "$line" == STEP* ]] || return 1

  local action rest; action="$(awk '{print $2}' <<<"$line")"
  rest="${line#STEP $action }"
  # extrair pkg e k=v
  local pkg="${rest%% *}"
  rest="${rest#${pkg} }"

  local cn="${pkg%@*}" ver="${pkg#*@}"
  local cat="${cn%%/*}" name="${cn#*/}"

  local origin="" cache="" metafile=""
  local kv; for kv in $rest; do
    case "$kv" in
      origin=*) origin="${kv#origin=}";;
      cache=*) cache="${kv#cache=}";;
      metafile=*) metafile="${kv#metafile=}";;
    esac
  done

  [[ -n "$cat" && -n "$name" && -n "$ver" && -n "$action" && -n "$origin" ]] || return 1

  printf "%s\n" "action=$action"
  printf "%s\n" "cat=$cat"
  printf "%s\n" "name=$name"
  printf "%s\n" "ver=$ver"
  printf "%s\n" "origin=$origin"
  printf "%s\n" "cache=$cache"
  printf "%s\n" "metafile=$metafile"
  return 0
}

###############################################################################
# Baixar e verificar fontes (com fallback se 03 não estiver disponível)
###############################################################################
_build_download_and_verify() {
  # Usa metafile da B_CTX para obter sources e sha256sums
  local mf="${B_CTX[metafile]}"
  [[ -f "$mf" ]] || { b_err "metafile inválido: $mf"; return 3; }

  adm_meta_load "$mf" || { b_err "falha ao ler metafile"; return 3; }
  local sources sha sums ok=0
  sources="$(adm_meta_get sources 2>/dev/null || true)"
  sha="$(adm_meta_get sha256sums 2>/dev/null || true)"

  IFS=',' read -r -a S <<<"$sources"
  IFS=',' read -r -a H <<<"$sha"

  mkdir -p -- "${ADM_SRC_CACHE_ROOT%/}/${B_CTX[cat]}/${B_CTX[name]}/${B_CTX[ver]}" "${B_CTX[TMP_DIR]}" || return 3
  local i=0
  for url in "${S[@]}"; do
    url="$(echo "$url" | xargs)"
    [[ -z "$url" ]] && continue
    local fn="$(basename -- "$url")"
    local out="${ADM_SRC_CACHE_ROOT%/}/${B_CTX[cat]}/${B_CTX[name]}/${B_CTX[ver]}/$fn"

    if [[ -f "$out" ]]; then
      b_info "usando cache de fonte: $fn"
    else
      b_info "baixando fonte: $url"
      if command -v adm_download_any >/dev/null 2>&1; then
        adm_download_any "$url" "$out" >>"$(_build_log_file prepare)" 2>&1 || { b_err "download falhou: $url"; return 4; }
      else
        # Fallback minimalista
        case "$url" in
          http://*|https://*)
            command -v curl >/dev/null 2>&1 && curl -fL "$url" -o "$out" >>"$(_build_log_file prepare)" 2>&1 || \
            { command -v wget >/dev/null 2>&1 && wget -O "$out" "$url" >>"$(_build_log_file prepare)" 2>&1; } || \
            { b_err "download http(s) falhou e 03-adm-download não está disponível"; return 4; }
            ;;
          git+*)
            local repo="${url#git+}"; bs_require_cmd git || return 2
            local td="${B_CTX[TMP_DIR]%/}/git-$(date +%s)-$i"
            git clone --depth 1 "$repo" "$td" >>"$(_build_log_file prepare)" 2>&1 || { b_err "git clone falhou: $repo"; return 4; }
            (cd "$td" && git archive --format=tar --output="$out.tar" HEAD && zstd -19 -T0 "$out.tar" -o "$out.tar.zst" && mv "$out.tar.zst" "$out" && rm -f "$out.tar") >>"$(_build_log_file prepare)" 2>&1 || true
            ;;
          rsync://*|rsync.*)
            bs_require_cmd rsync || return 2
            rsync -av --delete "$url" "$out" >>"$(_build_log_file prepare)" 2>&1 || { b_err "rsync falhou: $url"; return 4; }
            ;;
          ftp://*)
            command -v curl >/dev/null 2>&1 && curl -fL "$url" -o "$out" >>"$(_build_log_file prepare)" 2>&1 || \
            { command -v wget >/dev/null 2>&1 && wget -O "$out" "$url" >>"$(_build_log_file prepare)" 2>&1; } || \
            { b_err "download ftp falhou"; return 4; }
            ;;
          file://*)
            local p="${url#file://}"
            cp -a "$p" "$out" 2>>"$(_build_log_file prepare)" || { b_err "cópia local falhou: $p"; return 4; }
            ;;
          *)
            b_err "URL não suportada: $url"; return 2;;
        esac
      fi
    fi

    # Verificação de hash se fornecido
    local exp="${H[$i]:-}"
    if [[ -n "$exp" ]]; then
      if command -v sha256sum >/dev/null 2>&1; then
        local got; got="$(sha256sum "$out" | awk '{print $1}')"
        [[ "$got" == "$exp" ]] || { b_err "sha256 mismatch para $fn"; return 6; }
      else
        b_warn "sha256sum não disponível — pulando verificação"
      fi
    fi
    i=$((i+1)); ok=$((ok+1))
  done

  (( ok>0 )) || { b_err "nenhuma fonte definida no metafile"; return 3; }
  return 0
}

###############################################################################
# Unpack seguro para SRC_DIR
###############################################################################
_build_unpack_sandboxed() {
  _build_check_space "$ADM_MIN_DISK_MB" "${B_CTX[TMP_DIR]}" || return $?
  mkdir -p -- "${B_CTX[SRC_DIR]}" || return 3

  local cachedir="${ADM_SRC_CACHE_ROOT%/}/${B_CTX[cat]}/${B_CTX[name]}/${B_CTX[ver]}"
  shopt -s nullglob
  local archives=( "$cachedir"/*.tar "$cachedir"/*.tar.* "$cachedir"/*.tgz "$cachedir"/*.txz "$cachedir"/*.zip "$cachedir"/*.zst "$cachedir"/*.tar.zst )
  shopt -u nullglob
  [[ ${#archives[@]} -gt 0 ]] || { b_err "nenhum arquivo de fonte para extrair (cache vazio)"; return 3; }

  # Limpa src antes, exceto se reuse-src
  if [[ "${B_FLAGS_reuse_src:-false}" != "true" ]]; then
    rm -rf -- "${B_CTX[SRC_DIR]}"/* 2>/dev/null || true
  fi

  local a
  for a in "${archives[@]}"; do
    case "$a" in
      *.zip)
        command -v unzip >/dev/null 2>&1 || { b_err "unzip não disponível"; return 2; }
        (cd "${B_CTX[SRC_DIR]}" && unzip -q "$a") >>"$(_build_log_file prepare)" 2>&1 || { b_err "falha ao extrair $a"; return 3; }
        ;;
      *.tar.zst|*.zst)
        command -v zstd >/dev/null 2>&1 || { b_err "zstd não disponível"; return 2; }
        # lista + checagem simples de path traversal
        if tar -tf <(zstd -dc "$a") 2>/dev/null | grep -E '^(\.\.|/)' -q; then
          b_err "tarball inseguro (path traversal): $a"; return 6;
        fi
        (cd "${B_CTX[SRC_DIR]}" && zstd -dc "$a" | tar -xpf -) >>"$(_build_log_file prepare)" 2>&1 || { b_err "extrair $a falhou"; return 3; }
        ;;
      *.tar*|*.tgz|*.txz)
        if tar -tf "$a" 2>/dev/null | grep -E '^(\.\.|/)' -q; then
          b_err "tarball inseguro (path traversal): $a"; return 6;
        fi
        (cd "${B_CTX[SRC_DIR]}" && tar -xpf "$a") >>"$(_build_log_file prepare)" 2>&1 || { b_err "extrair $a falhou"; return 3; }
        ;;
      *)
        # arquivos avulsos (ex: patch-only) — apenas copiar
        cp -a "$a" "${B_CTX[SRC_DIR]}/" 2>>"$(_build_log_file prepare)" || true
        ;;
    esac
  done

  # Se a extração criou um único diretório de topo, usar ele como src raiz
  local entries; entries="$(find "${B_CTX[SRC_DIR]}" -mindepth 1 -maxdepth 1 -printf '%f\n' | wc -l)"
  if (( entries == 1 )); then
    local top; top="$(find "${B_CTX[SRC_DIR]}" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    if [[ -n "$top" ]]; then
      # mover conteúdo para SRC_DIR
      rsync -a "$top"/ "${B_CTX[SRC_DIR]}"/ >>"$(_build_log_file prepare)" 2>&1 && rm -rf -- "$top" || true
    fi
  fi

  return 0
}
# 09-adm-build.part2.sh
# Execução de STEPs (install/bin e build/source), empacotamento/registro e CLI.
if [[ -n "${ADM_BUILD_LOADED_PART2:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_BUILD_LOADED_PART2=1
###############################################################################
# Helpers para empacotar/registrar
###############################################################################
_build_tarball_path() {
  printf "%s/%s/%s-%s.tar.zst" "${ADM_BIN_CACHE_ROOT%/}" "${B_CTX[cat]}" "${B_CTX[name]}" "${B_CTX[ver]}"
}

_build_manifest_write() {
  local outf="${ADM_STATE_ROOT%/}/manifest/${B_CTX[cat]}_${B_CTX[name]}_${B_CTX[ver]}.list"
  mkdir -p -- "$(dirname -- "$outf")" || true
  : > "$outf" || { b_warn "não foi possível criar manifest $outf"; return 3; }
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${B_CTX[DESTDIR]}" && find . -type f -print0 | xargs -0 sha256sum) >> "$outf" 2>/dev/null || true
  else
    (cd "${B_CTX[DESTDIR]}" && find . -type f -print) >> "$outf" 2>/dev/null || true
  fi
  echo "$outf"
}

_build_triggers_write() {
  # Reaproveitar triggers detectadas nos helpers (08) se existentes; caso contrário, heurística simples
  local trg="${ADM_STATE_ROOT%/}/triggers/${B_CTX[cat]}_${B_CTX[name]}_${B_CTX[ver]}.trg"
  mkdir -p -- "$(dirname -- "$trg")" || true
  : > "$trg" || { b_warn "não foi possível criar triggers $trg"; return 3; }
  if compgen -G "${B_CTX[DESTDIR]}/usr/share/glib-2.0/schemas/*.xml" >/dev/null; then
    echo "glib-compile-schemas /usr/share/glib-2.0/schemas" >> "$trg"
  fi
  if compgen -G "${B_CTX[DESTDIR]}/usr/share/applications/*.desktop" >/dev/null; then
    echo "update-desktop-database" >> "$trg"
  fi
  if compgen -G "${B_CTX[DESTDIR]}/usr/share/icons/*/index.theme" >/dev/null; then
    echo "gtk-update-icon-cache" >> "$trg"
  fi
  echo "$trg"
}

_build_package_tarball() {
  local tarball="$(_build_tarball_path)"
  local tmp="${tarball}.partial"
  mkdir -p -- "$(dirname -- "$tarball")" || return 3

  _build_check_space "$ADM_MIN_DISK_MB" "${B_CTX[DESTDIR]}" || return $?
  adm_with_spinner "Empacotando tar.zst..." -- timeout "$ADM_TIMEOUT_PACKAGE" sh -c '
    set -e
    cd "'"${B_CTX[DESTDIR]}"'"
    # tar determinístico: owner 0:0, mtime fixo (SOURCE_DATE_EPOCH), sem xattrs (~padrão)
    TAR_OPT=("--sort=name" "--owner=0" "--group=0" "--numeric-owner" "-cpf" "-")
    if tar --help 2>/dev/null | grep -q -- "--mtime"; then
      TAR_OPT+=("--mtime=@'"${SOURCE_DATE_EPOCH:-0}"'")
    fi
    tar "${TAR_OPT[@]}" . | zstd -19 -T0 -o "'"$tmp"'"
  ' || { b_err "empacotamento falhou"; return 4; }

  mv -f -- "$tmp" "$tarball" || { b_err "não foi possível finalizar tarball ($tarball)"; return 3; }

  # sha256 opcional ao lado
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$(dirname -- "$tarball")" && sha256sum "$(basename -- "$tarball")" > "$(basename -- "$tarball").sha256") || true
  fi

  echo "$tarball"
  return 0
}

_build_register() {
  _build_manifest_write >/dev/null 2>&1 || true
  _build_triggers_write >/dev/null 2>&1 || true
}

###############################################################################
# Execução de um STEP: install (binário do cache)
###############################################################################
_build_step_install_bin() {
  local log="$(_build_log_file install)"
  : > "$log" 2>/dev/null || true
  _build_log_rotate install

  adm_step "${B_CTX[name]}" "${B_CTX[ver]}" "Instalação (binário cache)"
  [[ -r "${B_CTX[cache]}" && -s "${B_CTX[cache]}" ]] || { b_err "tarball binário inválido: ${B_CTX[cache]}"; echo "veja: $log"; return 3; }

  # extração segura
  if tar -tf <(zstd -dc "${B_CTX[cache]}") 2>>"$log" | grep -E '^(\.\.|/)' -q; then
    b_err "tarball binário inseguro (path traversal): ${B_CTX[cache]}"; echo "veja: $log"; return 6;
  fi
  ( cd "${B_CTX[DESTDIR]}" && zstd -dc "${B_CTX[cache]}" | tar -xpf - ) >>"$log" 2>&1 || { b_err "extração do binário falhou"; echo "veja: $log"; return 4; }

  _build_register
  _build_state_set "installed"
  adm_ok "instalado em DESTDIR"
  return 0
}

###############################################################################
# Execução de um STEP: build (a partir do source)
###############################################################################
_build_detect_build_type() {
  # Primeiro tenta o metafile; se ausente/unknown, heurística muito simples
  local bt="${B_CTX[build_type]}"
  if [[ -z "$bt" || "$bt" == "custom" || "$bt" == "unknown" ]]; then
    if [[ -f "${B_CTX[SRC_DIR]}/configure" || -f "${B_CTX[SRC_DIR]}/configure.ac" ]]; then bt="autotools";
    elif [[ -f "${B_CTX[SRC_DIR]}/CMakeLists.txt" ]]; then bt="cmake";
    elif [[ -f "${B_CTX[SRC_DIR]}/meson.build" ]]; then bt="meson";
    elif [[ -f "${B_CTX[SRC_DIR]}/Cargo.toml" ]]; then bt="cargo";
    elif [[ -f "${B_CTX[SRC_DIR]}/go.mod" ]]; then bt="go";
    elif [[ -f "${B_CTX[SRC_DIR]}/pyproject.toml" || -f "${B_CTX[SRC_DIR]}/setup.py" ]]; then bt="python";
    elif [[ -f "${B_CTX[SRC_DIR]}/package.json" ]]; then bt="node";
    else bt="make"; fi
  fi
  echo "$bt"
}

_build_step_build_src() {
  local prep_log="$(_build_log_file prepare)"
  local cfg_log="$(_build_log_file configure)"
  local bld_log="$(_build_log_file build)"
  local tst_log="$(_build_log_file test)"
  local ins_log="$(_build_log_file install)"
  _build_log_rotate prepare; _build_log_rotate configure; _build_log_rotate build; _build_log_rotate test; _build_log_rotate install
  : > "$prep_log" 2>/dev/null || true
  : > "$cfg_log" 2>/dev/null || true
  : > "$bld_log" 2>/dev/null || true
  : > "$tst_log" 2>/dev/null || true
  : > "$ins_log" 2>/dev/null || true

  adm_step "${B_CTX[name]}" "${B_CTX[ver]}" "Build from source"

  # 1) Carregar metafile
  adm_meta_load "${B_CTX[metafile]}" >>"$prep_log" 2>&1 || { b_err "metafile inválido"; echo "veja: $prep_log"; return 3; }
  B_CTX[build_type]="$(adm_meta_get build_type 2>>"$prep_log" || echo "")"

  # 2) Download/verify
  adm_with_spinner "Baixando/verificando fontes..." -- _build_download_and_verify >>"$prep_log" 2>&1 || { echo "veja: $prep_log"; return $?; }
  _build_state_set "prepared"

  # 3) Unpack seguro
  adm_with_spinner "Extraindo fontes..." -- _build_unpack_sandboxed >>"$prep_log" 2>&1 || { echo "veja: $prep_log"; return $?; }

  # Preparar dirs/ambiente via helpers comuns
  PKG_NAME="${B_CTX[name]}"; PKG_VERSION="${B_CTX[ver]}"; PKG_CATEGORY="${B_CTX[cat]}"
  SRC_DIR="${B_CTX[SRC_DIR]}"; BUILD_DIR="${B_CTX[BUILD_DIR]}"; DESTDIR="${B_CTX[DESTDIR]}"
  adm_bs_prepare_dirs >>"$prep_log" 2>&1 || { b_err "prepare_dirs falhou"; echo "veja: $prep_log"; return 4; }
  adm_bs_export_env >>"$prep_log" 2>&1 || { b_err "export_env falhou"; echo "veja: $prep_log"; return 4; }

  # 4) Hooks iniciais
  adm_hooks_run pre-node >>"$prep_log" 2>&1 || { b_err "hook pre-node falhou"; echo "veja: $prep_log"; return 4; }

  # 5) Detectar build_type e executar sequência
  local bt; bt="$(_build_detect_build_type)"
  b_info "build_type detectado: $bt"

  case "$bt" in
    autotools)
      { adm_bs_autotools_configure; } >>"$cfg_log" 2>&1 || { b_err "configure (autotools) falhou"; echo "veja: $cfg_log"; return 4; }
      _build_state_set "configured"
      { adm_bs_autotools_build; } >>"$bld_log" 2>&1 || { b_err "build (autotools) falhou"; echo "veja: $bld_log"; return 4; }
      _build_state_set "built"
      { adm_bs_autotools_test; } >>"$tst_log" 2>&1 || { b_warn "testes falharam (autotools). veja: $tst_log"; }
      { adm_bs_autotools_install; } >>"$ins_log" 2>&1 || { b_err "install (autotools) falhou"; echo "veja: $ins_log"; return 4; }
      ;;
    cmake)
      { adm_bs_cmake_configure; } >>"$cfg_log" 2>&1 || { b_err "cmake configure falhou"; echo "veja: $cfg_log"; return 4; }
      _build_state_set "configured"
      { adm_bs_cmake_build; } >>"$bld_log" 2>&1 || { b_err "cmake build falhou"; echo "veja: $bld_log"; return 4; }
      _build_state_set "built"
      { adm_bs_cmake_test; } >>"$tst_log" 2>&1 || { b_warn "testes falharam (cmake). veja: $tst_log"; }
      { adm_bs_cmake_install; } >>"$ins_log" 2>&1 || { b_err "cmake install falhou"; echo "veja: $ins_log"; return 4; }
      ;;
    meson)
      { adm_bs_meson_setup; } >>"$cfg_log" 2>&1 || { b_err "meson setup falhou"; echo "veja: $cfg_log"; return 4; }
      _build_state_set "configured"
      { adm_bs_meson_build; } >>"$bld_log" 2>&1 || { b_err "meson build falhou"; echo "veja: $bld_log"; return 4; }
      _build_state_set "built"
      { adm_bs_meson_test; } >>"$tst_log" 2>&1 || { b_warn "testes falharam (meson). veja: $tst_log"; }
      { adm_bs_meson_install; } >>"$ins_log" 2>&1 || { b_err "meson install falhou"; echo "veja: $ins_log"; return 4; }
      ;;
    cargo)
      { adm_bs_cargo_build; } >>"$bld_log" 2>&1 || { b_err "cargo build falhou"; echo "veja: $bld_log"; return 4; }
      _build_state_set "built"
      { adm_bs_cargo_test; } >>"$tst_log" 2>&1 || { b_warn "testes falharam (cargo). veja: $tst_log"; }
      { adm_bs_cargo_install; } >>"$ins_log" 2>&1 || { b_err "cargo install falhou"; echo "veja: $ins_log"; return 4; }
      ;;
    go)
      { adm_bs_go_build; } >>"$bld_log" 2>&1 || { b_err "go build falhou"; echo "veja: $bld_log"; return 4; }
      _build_state_set "built"
      { adm_bs_go_test; } >>"$tst_log" 2>&1 || { b_warn "testes falharam (go). veja: $tst_log"; }
      { adm_bs_go_install; } >>"$ins_log" 2>&1 || { b_err "go install falhou"; echo "veja: $ins_log"; return 4; }
      ;;
    python)
      { adm_bs_python_build; } >>"$bld_log" 2>&1 || { b_err "python build falhou"; echo "veja: $bld_log"; return 4; }
      _build_state_set "built"
      { adm_bs_python_test; } >>"$tst_log" 2>&1 || { b_warn "testes falharam (python). veja: $tst_log"; }
      { adm_bs_python_install; } >>"$ins_log" 2>&1 || { b_err "python install falhou"; echo "veja: $ins_log"; return 4; }
      ;;
    node)
      { adm_bs_node_ci; } >>"$bld_log" 2>&1 || { b_err "node ci falhou"; echo "veja: $bld_log"; return 4; }
      _build_state_set "built"
      { adm_bs_node_build; } >>"$bld_log" 2>&1 || true
      { adm_bs_node_install; } >>"$ins_log" 2>&1 || { b_err "node install falhou"; echo "veja: $ins_log"; return 4; }
      ;;
    make|*)
      # fallback: tentar alvos padrão
      (cd "${B_CTX[SRC_DIR]}" && make -j"$(adm_bs_jobs)") >>"$bld_log" 2>&1 || { b_err "make falhou"; echo "veja: $bld_log"; return 4; }
      _build_state_set "built"
      if (cd "${B_CTX[SRC_DIR]}" && make -q test) >/dev/null 2>&1; then
        (cd "${B_CTX[SRC_DIR]}" && make test) >>"$tst_log" 2>&1 || b_warn "testes falharam (make). veja: $tst_log"
      fi
      (cd "${B_CTX[SRC_DIR]}" && make install DESTDIR="${B_CTX[DESTDIR]}" PREFIX=/usr) >>"$ins_log" 2>&1 || { b_err "make install falhou"; echo "veja: $ins_log"; return 4; }
      # fixups essenciais
      adm_bs_pkgconfig_fixups >>"$ins_log" 2>&1 || true
      adm_bs_fix_rpath >>"$ins_log" 2>&1 || true
      adm_bs_strip_and_compress >>"$ins_log" 2>&1 || true
      adm_bs_install_docs_and_licenses >>"$ins_log" 2>&1 || true
      adm_bs_shebang_rewrite >>"$ins_log" 2>&1 || true
      ;;
  esac

  _build_state_set "installed"

  # 6) Empacotar e registrar
  local pkglog="$(_build_log_file package)"
  : > "$pkglog" 2>/dev/null || true
  _build_log_rotate package
  local tarball
  tarball="$(_build_package_tarball)" >>"$pkglog" 2>&1 || { b_err "empacotamento falhou"; echo "veja: $pkglog"; return 4; }
  _build_state_set "packaged"

  _build_register >>"$pkglog" 2>&1 || true
  _build_state_set "registered"

  adm_ok "build concluído (tarball: $tarball)"
  return 0
}

###############################################################################
# Execução do plano completo
###############################################################################
_build_execute_planfile() {
  local planfile="$1"
  [[ -r "$planfile" ]] || { b_err "planfile não legível: $planfile"; return 1; }

  local start_ts="$(date +%s)"
  local step_line
  while IFS= read -r step_line; do
    [[ -z "$step_line" ]] && continue
    [[ "$step_line" =~ ^STEP ]] || continue

    # parse
    local kv; kv="$(_build_parse_step_line "$step_line")" || { b_err "linha malformada no plano: $step_line"; return 1; }
    # reset contexto
    unset B_CTX
    declare -Ag B_CTX
    eval "$kv"
    B_CTX[cat]="$cat"; B_CTX[name]="$name"; B_CTX[ver]="$ver"
    B_CTX[origin]="$origin"; B_CTX[cache]="$cache"; B_CTX[metafile]="$metafile"
    B_CTX_NAME="${B_CTX[name]}"

    # paths e lock
    _build_paths_prepare || return $?
    trap '_build_lock_release' EXIT
    _build_lock_acquire || return $?

    # resumo da etapa
    adm_step "${B_CTX[name]}" "${B_CTX[ver]}" "executando STEP: ${B_CTX[origin]}"
    echo "log dir: ${B_CTX[LOG_DIR]}"

    # validação de políticas
    if [[ "${B_CFG_bin_only:-false}" == "true" && "${B_CTX[origin]}" != "bin" ]]; then
      b_err "política bin-only: passo de origem=source no plano"; return 5;
    fi
    if [[ "${B_CFG_source_only:-false}" == "true" && "${B_CTX[origin]}" != "source" ]]; then
      b_err "política source-only: passo de origem=bin no plano"; return 5;
    fi

    # resume
    local st="$(_build_state_get)"
    b_info "state atual: $st"

    case "${B_CTX[origin]}" in
      bin)
        # Para bin, se já instalado e tarball confere, pode pular
        if [[ "$st" =~ ^(installed|packaged|registered|done)$ ]]; then
          b_info "passo já concluído anteriormente (state=$st) — pulando"
        else
          _build_step_install_bin || return $?
        fi
        ;;
      source)
        if [[ "$st" == "registered" || "$st" == "done" ]]; then
          b_info "build já completo — pulando"
        else
          _build_step_build_src || return $?
        fi
        ;;
      *) b_err "origin desconhecida: ${B_CTX[origin]}"; return 1;;
    esac

    _build_state_set "done"
    _build_lock_release
    trap - EXIT
  done < "$planfile"

  local end_ts="$(date +%s)"
  b_info "tempo total: $((end_ts-start_ts))s"
  adm_ok "plano executado com sucesso"
  return 0
}
# 09-adm-build.part3.sh
# CLI: run/from-plan/plan/package/clean e integração com resolver.
if [[ -n "${ADM_BUILD_LOADED_PART3:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ADM_BUILD_LOADED_PART3=1
###############################################################################
# Geração de plano via resolver
###############################################################################
adm_build_plan() {
  local cat="$1" name="$2"; shift 2 || true
  [[ -n "$cat" && -n "$name" ]] || { b_err "uso: adm_build_plan <category> <name> [flags do resolver]"; return 2; }
  if ! command -v adm_resolve_plan >/dev/null 2>&1; then
    b_err "resolver (07-adm-resolver.sh) não está carregado"; return 2;
  fi
  local plan
  plan="$(adm_resolve_plan "$cat" "$name" "$@")" || return $?
  echo "$plan"
}

###############################################################################
# Execução a partir do plano
###############################################################################
adm_build_from_plan() {
  # Flags de política locais
  B_CFG_bin_only=false
  B_CFG_source_only=false
  B_FLAGS_reuse_src=false

  local planfile=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bin-only) B_CFG_bin_only=true; shift;;
      --source-only) B_CFG_source_only=true; shift;;
      --reuse-src) B_FLAGS_reuse_src=true; shift;;
      --offline) export ADM_OFFLINE=true; shift;;
      --no-test) export ADM_RUN_TESTS=false; shift;;
      --no-strip) export ADM_STRIP=false; shift;;
      --plan) planfile="$2"; shift 2;;
      *) # primeiro não-flag deve ser o planfile
         if [[ -z "$planfile" ]]; then planfile="$1"; shift; else b_warn "opção desconhecida: $1"; shift; fi;;
    esac
  done

  [[ -n "$planfile" ]] || { b_err "uso: adm_build_from_plan <planfile> [flags]"; return 2; }

  _build_execute_planfile "$planfile"
}

###############################################################################
# Execução completa: resolver → executar plano
###############################################################################
adm_build_run() {
  local cat="$1" name="$2"; shift 2 || true
  [[ -n "$cat" && -n "$name" ]] || { b_err "uso: adm_build_run <category> <name> [flags]"; return 2; }

  # repassar flags relevantes ao resolver e também aos passos
  local resolver_flags=() passthrough_flags=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version|--profile|--lockfile) resolver_flags+=( "$1" "$2" ); shift 2;;
      --with-opts|--no-opts|--bin-only|--source-only|--offline|--strict|--update) resolver_flags+=( "$1" ); shift;;
      --reuse-src|--no-test|--no-strip) passthrough_flags+=( "$1" ); shift;;
      *) resolver_flags+=( "$1" ); shift;;
    esac
  done

  local plan
  plan="$(adm_build_plan "$cat" "$name" "${resolver_flags[@]}")" || return $?
  adm_build_from_plan "$plan" "${passthrough_flags[@]}"
}

###############################################################################
# Empacotar um DESTDIR existente
###############################################################################
adm_build_package() {
  local cat="$1" name="$2"; shift 2 || true
  local ver="" destdir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) ver="$2"; shift 2;;
      --destdir) destdir="$2"; shift 2;;
      *) b_warn "opção desconhecida: $1"; shift;;
    esac
  done
  [[ -n "$cat" && -n "$name" ]] || { b_err "uso: adm_build_package <cat> <name> [--version V] [--destdir D]"; return 2; }
  [[ -n "$ver" ]] || { b_err "--version é obrigatório"; return 2; }
  [[ -n "$destdir" && -d "$destdir" ]] || { b_err "--destdir inexistente: $destdir"; return 3; }

  # Preencher contexto mínimo e empacotar
  declare -Ag B_CTX
  B_CTX[cat]="$cat"; B_CTX[name]="$name"; B_CTX[ver]="$ver"
  B_CTX[DESTDIR]="$destdir"
  B_CTX[TMP_DIR]="${ADM_TMP_ROOT%/}/${cat}/${name}-${ver}"
  mkdir -p -- "${B_CTX[TMP_DIR]}" "${ADM_BIN_CACHE_ROOT%/}/${cat}" "${ADM_STATE_ROOT%/}/"{manifest,triggers} || true

  local pkglog="${ADM_STATE_ROOT%/}/logs/${cat}/${name}/${ver}/package.log"
  mkdir -p -- "$(dirname -- "$pkglog")" || true
  : > "$pkglog" 2>/dev/null || true

  local tarball
  tarball="$(_build_package_tarball)" >>"$pkglog" 2>&1 || { b_err "empacotamento falhou"; echo "veja: $pkglog"; return 4; }
  _build_register >>"$pkglog" 2>&1 || true
  adm_ok "tarball gerado: $tarball"
  echo "$tarball"
}

###############################################################################
# Limpeza
###############################################################################
adm_build_clean() {
  local cat="$1" name="$2"; shift 2 || true
  local ver="" all=false yes=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) ver="$2"; shift 2;;
      --all) all=true; shift;;
      --yes) yes=true; shift;;
      *) b_warn "opção desconhecida: $1"; shift;;
    esac
  done
  [[ -n "$cat" && -n "$name" ]] || { b_err "uso: adm_build_clean <cat> <name> [--version V] [--all] [--yes]"; return 2; }
  [[ -n "$ver" ]] || { b_err "--version é obrigatório"; return 2; }

  local base="${cat}/${name}-${ver}"
  local SRC_DIR="${ADM_WORK_ROOT%/}/src/${base}/src"
  local BUILD_DIR="${ADM_BUILD_ROOT%/}/${base}"
  local DESTDIR="${ADM_DEST_ROOT%/}/${cat}/${name}/${ver}"
  local TMP_DIR="${ADM_TMP_ROOT%/}/${base}"
  local tarball="${ADM_BIN_CACHE_ROOT%/}/${cat}/${name}-${ver}.tar.zst"

  rm -rf -- "$BUILD_DIR" "$TMP_DIR" 2>/dev/null || true
  if [[ "$all" == "true" ]]; then
    if [[ "$yes" != "true" ]]; then
      read -r -p "Confirmar remoção de DESTDIR e tarball? [y/N] " ans
      [[ "$ans" == "y" || "$ans" == "Y" ]] || { b_warn "cancelado pelo usuário"; return 0; }
    fi
    rm -rf -- "$SRC_DIR" "$DESTDIR" "$tarball" 2>/dev/null || true
  fi
  adm_ok "limpeza concluída"
}

###############################################################################
# CLI simples
###############################################################################
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="$1"; shift || true
  case "$cmd" in
    run)        adm_build_run "$@" || exit $?;;
    from-plan)  adm_build_from_plan "$@" || exit $?;;
    plan)       adm_build_plan "$@" || exit $?;;
    package)    adm_build_package "$@" || exit $?;;
    clean)      adm_build_clean "$@" || exit $?;;
    *)
      echo "uso:" >&2
      echo "  $0 run <cat> <name> [flags resolver + --reuse-src --no-test --no-strip]" >&2
      echo "  $0 from-plan <planfile> [--bin-only|--source-only] [--reuse-src] [--offline] [--no-test] [--no-strip]" >&2
      echo "  $0 plan <cat> <name> [flags resolver]" >&2
      echo "  $0 package <cat> <name> --version V --destdir D" >&2
      echo "  $0 clean <cat> <name> --version V [--all] [--yes]" >&2
      exit 2;;
  esac
fi

ADM_BUILD_LOADED=1
export ADM_BUILD_LOADED
