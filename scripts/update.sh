#!/usr/bin/env bash
#=============================================================
# update.sh — ADM Updater: detecta upstream, gera build.pkg atualizado,
#              e (opcionalmente) build/package/install.
#
# Modos:
#   --check        : apenas detecta novas versões e lista
#   --fetch        : gera build.pkg em /usr/src/adm/update/... (não compila)
#   --update-all   : atualiza todos os pacotes instalados (modo interativo por padrão)
#   --auto         : aplica atualizações automaticamente (sem prompts)
#   --deps-first   : atualiza dependências antes do pacote principal
#   --force        : regenera build.pkg mesmo se versões iguais
#   --rollback     : restaura último snapshot de update (simple)
#   --interactive  : pergunta antes de aplicar cada atualização
#
# Requisitos: curl, git (optional), tar, sha256sum, awk, sed, sort -V
#=============================================================
set -o errexit
set -o nounset
set -o pipefail

# prevent double source
[[ -n "${ADM_UPDATE_SH_LOADED:-}" ]] && return 0
ADM_UPDATE_SH_LOADED=1

#-------------------------------------------------------------
# Environment / dependencies
#-------------------------------------------------------------
# Must be run inside ADM environment (env.sh defines ADM_ROOT etc)
if [[ "${BASH_SOURCE[0]}" == "${0}" && ! -f "/usr/src/adm/scripts/env.sh" ]]; then
    echo "❌ Este script deve ser executado dentro do ambiente ADM."
    exit 1
fi

# Load common helpers if present (best-effort)
source /usr/src/adm/scripts/env.sh
source /usr/src/adm/scripts/log.sh 2>/dev/null || true
source /usr/src/adm/scripts/utils.sh 2>/dev/null || true
source /usr/src/adm/scripts/hooks.sh 2>/dev/null || true
# Optional pipeline tools
source /usr/src/adm/scripts/fetch.sh 2>/dev/null || true
source /usr/src/adm/scripts/build.sh 2>/dev/null || true
source /usr/src/adm/scripts/package.sh 2>/dev/null || true
source /usr/src/adm/scripts/install.sh 2>/dev/null || true

# Paths
REPO_DIR="${ADM_REPO_DIR:-/usr/src/adm/repo}"
UPDATE_ROOT="${ADM_ROOT}/update"
LOG_DIR="${ADM_LOG_DIR:-/usr/src/adm/logs}/update"
STATE_DIR="${ADM_ROOT}/state"
BACKUP_DIR="${STATE_DIR}/update-backup"
STATUS_DB="${ADM_STATUS_DB:-/var/lib/adm/status.db}"
PACKAGES_DIR="${ADM_ROOT}/packages"

mkdir -p "$UPDATE_ROOT" "$LOG_DIR" "$BACKUP_DIR" "$STATE_DIR"

# Options defaults
MODE_CHECK=0
MODE_FETCH=0
MODE_UPDATE_ALL=0
MODE_AUTO=0
DEPS_FIRST=0
FORCE=0
INTERACTIVE=1
VERBOSE=0
ROLLBACK=0

# helper date
_now() { date '+%Y%m%d-%H%M%S'; }
_ts()  { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# simple logger
log() { 
    local lvl="$1"; shift
    local msg="$*"
    if declare -f log_info >/dev/null 2>&1; then
        case "$lvl" in
            INFO) log_info "$msg" ;;
            WARN) log_warn "$msg" ;;
            ERROR) log_error "$msg" ;;
            *) log_info "$msg" ;;
        esac
    else
        printf "[%s] %s\n" "$lvl" "$msg"
    fi
}

# JSON helper (append simple actions)
json_init() {
    local out="$1"
    cat > "$out" <<EOF
{
  "id": "$(basename "$out" .json)-$(_now)",
  "start": "$(_ts)",
  "updated": [],
  "skipped": [],
  "failed": [],
  "end": null
}
EOF
}

json_add_updated() {
    local out="$1"; shift
    local pkg="$1"; local from="$2"; local to="$3"; local status="$4"
    # append naive JSON object to updated array
    awk -v pkg="$pkg" -v from="$from" -v to="$to" -v status="$status" '
    BEGIN{added=0}
    /"updated": \[/ && added==0{
        print; getline; print; 
        printf "    {\"package\":\"%s\",\"from\":\"%s\",\"to\":\"%s\",\"status\":\"%s\"},\n", pkg, from, to, status;
        added=1; next
    }
    { print }
    ' "$out" > "${out}.tmp" && mv "${out}.tmp" "$out"
}

json_add_skipped() {
    local out="$1"; shift
    local pkg="$1"; local reason="$2"
    awk -v pkg="$pkg" -v reason="$reason" '
    BEGIN{added=0}
    /"skipped": \[/ && added==0{
        print; getline; print; 
        printf "    {\"package\":\"%s\",\"reason\":\"%s\"},\n", pkg, reason;
        added=1; next
    }
    { print }
    ' "$out" > "${out}.tmp" && mv "${out}.tmp" "$out"
}

json_add_failed() {
    local out="$1"; shift
    local pkg="$1"; local reason="$2"
    awk -v pkg="$pkg" -v reason="$reason" '
    BEGIN{added=0}
    /"failed": \[/ && added==0{
        print; getline; print; 
        printf "    {\"package\":\"%s\",\"reason\":\"%s\"},\n", pkg, reason;
        added=1; next
    }
    { print }
    ' "$out" > "${out}.tmp" && mv "${out}.tmp" "$out"
}

json_finalize() {
    local out="$1"
    awk -v endts="$(_ts)" '
    {
      if($0 ~ /"end": null/){ gsub(/"end": null/,"\"end\": \"" endts "\"") }
      print
    }' "$out" > "${out}.tmp" && mv "${out}.tmp" "$out"
}

#-------------------------------------------------------------
# CLI parse
#-------------------------------------------------------------
ARGS=()
while (( "$#" )); do
    case "$1" in
        --check) MODE_CHECK=1; shift;;
        --fetch) MODE_FETCH=1; shift;;
        --update-all) MODE_UPDATE_ALL=1; shift;;
        --auto) MODE_AUTO=1; INTERACTIVE=0; shift;;
        --deps-first) DEPS_FIRST=1; shift;;
        --force) FORCE=1; shift;;
        --rollback) ROLLBACK=1; shift;;
        --interactive) INTERACTIVE=1; shift;;
        --no-interactive|--non-interactive) INTERACTIVE=0; shift;;
        --verbose) VERBOSE=1; shift;;
        --help|-h) 
            cat <<EOF
Usage: update.sh [options] [pkg...]
Options:
  --check         : list packages that have newer upstream versions
  --fetch         : generate update build.pkg under /usr/src/adm/update/... (no build)
  --update-all    : attempt update for all installed packages
  --auto          : apply updates automatically (no prompts)
  --deps-first    : update dependencies first
  --force         : generate build.pkg even if version not greater
  --rollback      : restore last update snapshot
  --interactive   : prompt before applying each update (default on)
EOF
            exit 0
            ;;
        *) ARGS+=("$1"); shift;;
    esac
done

if [[ "$ROLLBACK" -eq 1 ]]; then
    # simple rollback: restore latest snapshot (status.db + manifests) from BACKUP_DIR
    latest=$(ls -1t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | head -n1 || true)
    if [[ -z "$latest" ]]; then
        echo "No rollback snapshot found."
        exit 1
    fi
    log INFO "Restoring snapshot $latest"
    tar -C / -xzf "$latest"
    log INFO "Rollback completed"
    exit 0
fi

#-------------------------------------------------------------
# Utility: compare versions semver-ish using sort -V
# returns: 0 if v1 < v2 ; 1 otherwise (v1 >= v2)
#-------------------------------------------------------------
ver_lt() {
    local v1="$1"; local v2="$2"
    if [[ "$v1" == "$v2" ]]; then return 1; fi
    # use printf + sort -V to find max
    local max
    max=$(printf "%s\n%s\n" "$v1" "$v2" | sort -V | tail -n1)
    [[ "$max" == "$v2" && "$v1" != "$v2" ]]
}

#-------------------------------------------------------------
# Parse build.pkg metadata without sourcing commands (safe)
# returns key=value pairs on stdout for selected keys
#-------------------------------------------------------------
read_buildpkg_meta() {
    local pkgfile="$1"
    awk -F= '
    function strip(s){ gsub(/^[ \t"'\''"]+|[ \t"'\''"]+$/,"",s); return s }
    /^PKG_NAME/ { print "PKG_NAME=" strip($2) }
    /^PKG_VERSION/ { print "PKG_VERSION=" strip($2) }
    /^PKG_RELEASE/ { print "PKG_RELEASE=" strip($2) }
    /^PKG_GROUP/ { print "PKG_GROUP=" strip($2) }
    /^PKG_DEPENDS/ { 
      # collect array between parentheses
      s=substr($0, index($0,$2))
      gsub(/^[ \t]*\(|\)[ \t]*$/,"",s)
      gsub(/\"/,"",s)
      gsub(/,/," ",s)
      gsub(/\$\(.*\)/,"",s)
      print "PKG_DEPENDS=" s
    }
    /^SOURCE_URL/ { print "SOURCE_URL=" strip($2) }
    /^SOURCE_SHA256/ { print "SOURCE_SHA256=" strip($2) }
    /^BUILD_HINT/ { print "BUILD_HINT=" strip($2) }
    ' "$pkgfile"
}

# read all build.pkg in repo and yield entries "pkgfile|group|pkgname|pkgver"
scan_repo_buildpkg() {
    find "$REPO_DIR" -type f -name "build.pkg" 2>/dev/null | while read -r bp; do
        # safe read metadata
        eval $(read_buildpkg_meta "$bp" | sed -e 's/^\(.*\)=/meta_\1=/')
        # meta_PKG_DEPENDS may have spaces
        echo "${bp}|${meta_PKG_GROUP:-unknown}|${meta_PKG_NAME:-unknown}|${meta_PKG_VERSION:-unknown}"
    done
}

# read installed status.db into associative INSTALLED_VER[pkg]=ver
declare -A INSTALLED_VER
load_installed_versions() {
    INSTALLED_VER=()
    if [[ -f "$STATUS_DB" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            # expected: name|ver|group|date|sha|size|path  (we support older formats)
            name=$(printf '%s' "$line" | awk -F'|' '{print $1}')
            ver=$(printf '%s' "$line" | awk -F'|' '{print $2}')
            INSTALLED_VER["$name"]="$ver"
        done < "$STATUS_DB"
    fi
}

#-------------------------------------------------------------
# Upstream version detection heuristics
# Input: SOURCE_URL (from build.pkg)
# Output: prints best_version (or empty)
# Strategies:
#  - git+https://...  -> git ls-remote --tags -> choose highest tag
#  - http/https ftp  -> get directory listing via curl and parse filenames with versions
#  - if URL points to tarball with version in name -> parse it
#-------------------------------------------------------------
detect_upstream_version() {
    local src="$1"
    # sanitize
    if [[ -z "$src" ]]; then
        echo ""
        return 0
    fi

    # git+ scheme
    if [[ "$src" == git+* ]]; then
        local repo="${src#git+}"
        if command -v git >/dev/null 2>&1; then
            # list tags
            tags=$(git ls-remote --tags --refs "$repo" 2>/dev/null | awk -F/ '{print $NF}' | sed 's/\^{}//' || true)
            if [[ -z "$tags" ]]; then
                echo ""
                return 0
            fi
            # filter stable tags (no rc, beta, alpha)
            best=$(printf "%s\n" $tags | grep -Ev -i 'rc|alpha|beta|pre' || true | sort -V | tail -n1)
            echo "$best"
            return 0
        else
            echo ""
            return 0
        fi
    fi

    # If URL is direct to tarball like .../name-1.2.3.tar.gz
    bn=$(basename "$src")
    if [[ "$bn" =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
        # extract first occurrence
        ver=$(echo "$bn" | sed -n 's/.*\([0-9]\+\.[0-9]\+\(\.[0-9]\+\)\?\).*/\1/p' || true)
        echo "$ver"
        return 0
    fi

    # Otherwise try directory listing parsing
    if command -v curl >/dev/null 2>&1; then
        # attempt to list page and extract filenames containing pkgname-version patterns
        page=$(curl -fsL "$src" 2>/dev/null || true)
        if [[ -n "$page" ]]; then
            # extract tokens that look like versioned filenames
            candidates=$(printf "%s\n" "$page" | grep -Eo '[a-zA-Z0-9._+-]+-[0-9]+\.[0-9]+(\.[0-9]+)?\.(tar\.gz|tar\.xz|zip|tgz|tar\.bz2|tar\.zst)?' || true)
            if [[ -n "$candidates" ]]; then
                # extract versions and pick highest
                vers=$(printf "%s\n" "$candidates" | sed -n 's/.*-\([0-9]\+\.[0-9]\+\(\.[0-9]\+\)\?\).*/\1/p' | sort -V | uniq)
                best=$(printf "%s\n" "$vers" | tail -n1)
                echo "$best"
                return 0
            fi
        fi
    fi

    echo ""
}

#-------------------------------------------------------------
# Recalculate SHA256 of a SOURCE_URL by downloading to tmp (if small)
# Writes computed hash to stdout or empty on failure
#-------------------------------------------------------------
recalc_sha256() {
    local url="$1"
    local tmp
    tmp="$(mktemp --tmpdir=/tmp update-src.XXXXXX)" || tmp="/tmp/update-src.$$"
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL "$url" -o "$tmp" --max-filesize 200000000 2>/dev/null; then
            sha=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')
            rm -f "$tmp"
            printf "%s\n" "$sha"
            return 0
        fi
    fi
    rm -f "$tmp" 2>/dev/null || true
    echo ""
    return 1
}

#-------------------------------------------------------------
# Generate new build.pkg in update area copying all original fields
# Preserves BUILD_HINT and PKG_DEPENDS; if BUILD_HINT=custom, copy custom_build block if present.
#-------------------------------------------------------------
generate_update_buildpkg() {
    local orig_pkgfile="$1"
    local new_version="$2"
    local outdir="$3"   # full path directory where to write new build.pkg

    mkdir -p "$outdir"
    local temp_build="${outdir}/build.pkg.tmp"
    local out_build="${outdir}/build.pkg"

    # read original file and reproduce, replacing PKG_VERSION and possibly SOURCE_URL if pattern exists
    # We'll also attempt to update SOURCE_URL filename if it contains version pattern
    awk -v newver="$new_version" -v OFS="" '
    BEGIN{in_custom=0}
    /^PKG_VERSION/ {
        print "PKG_VERSION=\"" newver "\"\n";
        next
    }
    /^SOURCE_URL/ {
        # do not attempt to change URL generically; print original
        print $0 "\n";
        next
    }
    /^SOURCE_SHA256/ { print $0 "\n"; next }
    /^BUILD_HINT/ { print $0 "\n"; next }
    {
        print $0 "\n";
    }
    ' "$orig_pkgfile" > "$temp_build"

    # If original had a custom_build() function block, copy it intact:
    # we'll append any trailing content after PKG fields (i.e. functions) from the original
    # Detect presence of "custom_build(" and append that function body
    if grep -q -E 'custom_build\(\)' "$orig_pkgfile"; then
        # append function block lines starting from custom_build() to EOF
        awk 'BEGIN{flag=0} /custom_build\(\)/{flag=1} flag{print}' "$orig_pkgfile" >> "$temp_build"
    fi

    # calculate new SOURCE_SHA256 if SOURCE_URL exists and points to file with newver in name
    # extract SOURCE_URL from original
    srcurl=$(awk -F= '/^SOURCE_URL/ { gsub(/^[ \t"]|[ \t"]$/,"",$2); print $2; exit }' "$orig_pkgfile" || true)
    if [[ -n "$srcurl" ]]; then
        # try to replace version substring in URL if present
        # find previous version in original PKG_VERSION
        oldver=$(awk -F= '/^PKG_VERSION/ { gsub(/^[ \t"]|[ \t"]$/,"",$2); print $2; exit }' "$orig_pkgfile")
        # replace first occurrence of oldver with newver in URL (simple heuristic)
        newsrc="${srcurl//$oldver/$new_version}"
        # check if newsrc is reachable (HEAD)
        if command -v curl >/dev/null 2>&1; then
            if curl -fsI "$newsrc" >/dev/null 2>&1; then
                # compute sha
                shaval=$(recalc_sha256 "$newsrc" || true)
                # append or update SOURCE_URL and SOURCE_SHA256 lines (if exist replace)
                # create final file by reading temp and substituting/adding
                awk -v surl="$newsrc" -v sha="$shaval" '
                BEGIN{seen_url=0; seen_sha=0}
                /^SOURCE_URL/ { printf "SOURCE_URL=\"%s\"\n", surl; seen_url=1; next }
                /^SOURCE_SHA256/ { printf "SOURCE_SHA256=\"%s\"\n", sha; seen_sha=1; next }
                { print }
                END{
                    if(seen_url==0 && length(surl)>0) printf "SOURCE_URL=\"%s\"\n", surl;
                    if(seen_sha==0 && length(sha)>0) printf "SOURCE_SHA256=\"%s\"\n", sha;
                }
                ' "$temp_build" > "$out_build"
            else
                # cannot reach new URL; just write temp_build but update PKG_VERSION is done
                mv "$temp_build" "$out_build"
            fi
        else
            mv "$temp_build" "$out_build"
        fi
    else
        mv "$temp_build" "$out_build"
    fi

    chmod 0644 "$out_build"
    echo "$out_build"
}

#-------------------------------------------------------------
# High-level: check one package: returns info as "pkg|group|installed_ver|upstream_ver|pkgfile"
#-------------------------------------------------------------
check_one_pkg() {
    local buildpkg="$1"
    # read meta
    eval $(read_buildpkg_meta "$buildpkg" | sed -e 's/^\(.*\)=/meta_\1=/')
    local pkgname="${meta_PKG_NAME:-}"
    local pkgver="${meta_PKG_VERSION:-}"
    local group="${meta_PKG_GROUP:-unknown}"
    local srcurl="${meta_SOURCE_URL:-}"

    upstream=$(detect_upstream_version "$srcurl")
    echo "${buildpkg}|${group}|${pkgname}|${pkgver}|${upstream}"
}

#-------------------------------------------------------------
# Main scan: find all candidates with upstream > installed
#-------------------------------------------------------------
prepare_update_list() {
    local -n out_list=$1
    out_list=()
    load_installed_versions
    while IFS= read -r entry; do
        bp=$(echo "$entry" | cut -d'|' -f1)
        group=$(echo "$entry" | cut -d'|' -f2)
        pkgname=$(echo "$entry" | cut -d'|' -f3)
        curver=$(echo "$entry" | cut -d'|' -f4)
        # detect upstream
        upstream=$(detect_upstream_version "$(awk -F= '/^SOURCE_URL/ {gsub(/^[ \t"]|[ \t"]$/,"",$2); print $2; exit}' "$bp" || true)")
        if [[ -n "$upstream" ]]; then
            inst_ver="${INSTALLED_VER[$pkgname]:-}"
            if [[ -z "$inst_ver" ]]; then
                # not installed -> treat as candidate if upstream exists
                out_list+=("${bp}|${group}|${pkgname}|${inst_ver}|${upstream}")
            else
                if ver_lt "$inst_ver" "$upstream" || [[ "$FORCE" -eq 1 ]]; then
                    out_list+=("${bp}|${group}|${pkgname}|${inst_ver}|${upstream}")
                fi
            fi
        fi
    done < <(scan_repo_buildpkg)
}

#-------------------------------------------------------------
# Apply update for a single pkg entry
# Params:
#   bp|group|pkgname|curver|upstream
#-------------------------------------------------------------
apply_update_entry() {
    local entry="$1"
    local mode="$2" # fetch-only or full
    IFS='|' read -r bp group pkgname curver upstream <<< "$entry"
    log INFO "Processing $pkgname: installed=${curver:-none} upstream=${upstream:-none}"

    # create update dir
    update_dir="${UPDATE_ROOT}/${group}/${pkgname}"
    mkdir -p "$update_dir"

    # generate new build.pkg
    newpkgfile=$(generate_update_buildpkg "$bp" "$upstream" "$update_dir")
    if [[ -z "$newpkgfile" || ! -f "$newpkgfile" ]]; then
        log WARN "Failed to generate build.pkg for $pkgname"
        return 1
    fi
    log INFO "Generated: $newpkgfile"

    # if mode is fetch-only, done
    if [[ "$mode" == "fetch-only" ]]; then
        return 0
    fi

    # optionally update dependencies first
    # read PKG_DEPENDS from original
    deps_line=$(awk -F= '/^PKG_DEPENDS/ { s=substr($0,index($0,$2)); gsub(/^[ \t]*\(|\)[ \t]*$/,"",s); gsub(/["'"'"',]/,"",s); print s; exit }' "$bp" || true)
    if [[ -n "$deps_line" && "$DEPS_FIRST" -eq 1 ]]; then
        for dep in $deps_line; do
            # find repo build.pkg for dep
            dep_bp=$(find "$REPO_DIR" -type f -name "build.pkg" -exec grep -l "PKG_NAME=\\\"${dep}\\\"" {} \; -print 2>/dev/null | head -n1 || true)
            if [[ -n "$dep_bp" ]]; then
                dep_entry=$(check_one_pkg "$dep_bp")
                # recursive update: fetch-only first to generate build.pkg then call apply if auto
                apply_update_entry "$dep_entry" "$mode" || log WARN "Failed to update dependency $dep for $pkgname"
            else
                log WARN "Dependency $dep for $pkgname not found in repo"
            fi
        done
    fi

    # Now optionally build/package/install if we are in auto or interactive accepted
    if [[ "$MODE_AUTO" -eq 1 || "$INTERACTIVE" -eq 0 ]]; then
        proceed=1
    else
        read -r -p "Apply update for $pkgname ${curver} -> ${upstream}? (y/N): " ans
        case "$ans" in [Yy]*) proceed=1 ;; *) proceed=0 ;; esac
    fi

    if [[ "$proceed" -ne 1 ]]; then
        log INFO "Skipped applying update for $pkgname"
        return 0
    fi

    # Make a snapshot for rollback: snapshot status.db + installed manifests
    snap="${BACKUP_DIR}/update-snap-${pkgname}-$( _now ).tar.gz"
    # include status.db and installed/<pkgname> manifest (if exists)
    tar -C / -czf "$snap" "$(realpath --relative-to=/ "$STATUS_DB" 2>/dev/null || echo "$STATUS_DB")" || true
    # include installed manifest dir if present
    if [[ -d "${INSTALLED_DIR}/${pkgname}" ]]; then
        tar -C / -rzf "$snap" "$(realpath --relative-to=/ "${INSTALLED_DIR}/${pkgname}" 2>/dev/null || echo "${INSTALLED_DIR}/${pkgname}")" || true
    fi
    log INFO "Snapshot saved: $snap"

    # Attempt build -> package -> install using pipeline scripts if available
    # build_package expects a pkg dir (repo path)
    pkg_repo_dir=$(dirname "$bp")
    # call build_package available?
    if declare -f build_package >/dev/null 2>&1; then
        log INFO "Building $pkgname (build_package)"
        if ! build_package "$pkg_repo_dir"; then
            log ERROR "Build failed for $pkgname; rolling back snapshot"
            tar -C / -xzf "$snap" || true
            return 1
        fi
    else
        log WARN "build_package() not available; skipping build for $pkgname"
    fi

    # package
    if declare -f package_main >/dev/null 2>&1; then
        log INFO "Packaging $pkgname"
        if ! package_main "$pkg_repo_dir"; then
            log ERROR "Package failed for $pkgname; rolling back snapshot"
            tar -C / -xzf "$snap" || true
            return 1
        fi
    else
        log WARN "package_main() not available; skipping package for $pkgname"
    fi

    # install
    # try find artifact in packages cache
    artifact=$(find "${PACKAGES_DIR}" -type f -name "${pkgname}-*.pkg.tar.*" 2>/dev/null | sort -V | tail -n1 || true)
    if [[ -n "$artifact" && declare -f install_with_deps >/dev/null 2>&1 ]]; then
        log INFO "Installing $pkgname from artifact $artifact"
        if ! install_with_deps "$artifact"; then
            log ERROR "Install failed for $pkgname; rolling back snapshot"
            tar -C / -xzf "$snap" || true
            return 1
        fi
    else
        log WARN "No artifact found to install $pkgname, or install_with_deps not available"
    fi

    # success -> update status.db entry (append or replace)
    # find package info file in packages dir to get sha and size if available
    pkginfo=$(find "${PACKAGES_DIR}" -type f -name "${pkgname}-*.pkginfo" | sort -V | tail -n1 || true)
    if [[ -n "$pkginfo" ]]; then
        newver=$(awk -F'= ' '/^pkgver/ {print $2; exit}' "$pkginfo")
        # replace line for pkgname in status.db or append
        if grep -q "^${pkgname}|" "$STATUS_DB" 2>/dev/null; then
            awk -v pkg="$pkgname" -v ver="$newver" -F'|' 'BEGIN{OFS=FS} { if($1==pkg) {$2=ver} print }' "$STATUS_DB" > "${STATUS_DB}.tmp" && mv "${STATUS_DB}.tmp" "$STATUS_DB"
        else
            now=$(date '+%Y-%m-%d %H:%M:%S')
            printf "%s|%s|%s|%s\n" "$pkgname" "${newver:-$upstream}" "$group" "$now" >> "$STATUS_DB"
        fi
    fi

    log INFO "Update applied for $pkgname"
    return 0
}

#-------------------------------------------------------------
# Runner: assemble list and act
#-------------------------------------------------------------
main() {
    load_installed_versions

    # create json report
    report="${LOG_DIR}/update-report-$(_now).json"
    mkdir -p "$LOG_DIR"
    json_init "$report"

    # prepare list of candidates
    declare -a candidates
    if [[ "${#ARGS[@]}" -gt 0 ]]; then
        # explicit packages by name
        for name in "${ARGS[@]}"; do
            # find build.pkg for name
            bp=$(find "$REPO_DIR" -type f -name "build.pkg" -exec grep -l "PKG_NAME=\\\"${name}\\\"" {} \; -print 2>/dev/null | head -n1 || true)
            if [[ -n "$bp" ]]; then
                upstream=$(detect_upstream_version "$(awk -F= '/^SOURCE_URL/ {gsub(/^[ \t"]|[ \t"]$/,"",$2); print $2; exit}' "$bp" || true)")
                candidates+=("${bp}|${group:-unknown}|${name}|${INSTALLED_VER[$name]:-}|${upstream}")
            else
                log WARN "Package $name not found in repo; skipping"
                json_add_failed "$report" "$name" "not-found"
            fi
        done
    else
        # scan all repo build.pkg
        prepare_update_list candidates
    fi

    # present candidates (check mode)
    if [[ "${#candidates[@]}" -eq 0 ]]; then
        echo "No updates found."
        json_finalize "$report"
        return 0
    fi

    echo "Updates detected: ${#candidates[@]}"
    for c in "${candidates[@]}"; do
        IFS='|' read -r bp group name cur upstream <<< "$c"
        echo " - $name: ${cur:-none} -> ${upstream:-none}"
        if [[ -n "$upstream" && ( "$MODE_FETCH" -eq 1 || "$MODE_CHECK" -eq 1 ) ]]; then
            # always generate build.pkg in fetch/check
            update_dir="${UPDATE_ROOT}/${group}/${name}"
            mkdir -p "$update_dir"
            newpkgfile=$(generate_update_buildpkg "$bp" "$upstream" "$update_dir")
            if [[ -f "$newpkgfile" ]]; then
                echo "   build.pkg generated: $newpkgfile"
                json_add_updated "$report" "$name" "${cur:-none}" "${upstream:-none}" "fetched"
            else
                json_add_failed "$report" "$name" "gen-failed"
            fi
        fi
    done

    if [[ "$MODE_CHECK" -eq 1 ]]; then
        json_finalize "$report"
        echo "Check complete. Report: $report"
        return 0
    fi

    if [[ "$MODE_FETCH" -eq 1 ]]; then
        json_finalize "$report"
        echo "Fetch-only complete. Update pkgs placed under $UPDATE_ROOT"
        return 0
    fi

    # If update-all mode, ensure candidates built/installed
    # Iterate candidates and apply (honoring deps-first)
    for c in "${candidates[@]}"; do
        if [[ "$DEPS_FIRST" -eq 1 ]]; then
            # apply dependencies first was handled in apply_update_entry
            :
        fi
        if ! apply_update_entry "$c" "full"; then
            json_add_failed "$report" "$(echo "$c" | cut -d'|' -f3)" "apply-failed"
        else
            json_add_updated "$report" "$(echo "$c" | cut -d'|' -f3)" "$(echo "$c" | cut -d'|' -f4)" "$(echo "$c" | cut -d'|' -f5)" "applied"
        fi
    done

    json_finalize "$report"
    echo "Update run complete. Report: $report"
    return 0
}

# Execute main
main "$@"
