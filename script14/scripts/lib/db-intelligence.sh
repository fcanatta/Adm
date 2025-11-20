#!/usr/bin/env bash
# shellcheck shell=bash
#
# Camada de acesso à base de inteligência (intelligence.db)

set -Eeuo pipefail

# shellcheck source=/usr/src/adm/scripts/lib/common.sh
. "/usr/src/adm/scripts/lib/common.sh"

ADM_INTEL_DIR="${ADM_INTEL_DIR:-/usr/src/adm/intelligence}"
ADM_INTEL_DB="${ADM_INTEL_DB:-$ADM_INTEL_DIR/intelligence.db}"

adm_intel_init() {
  adm_mkdir_safe "$ADM_INTEL_DIR"
  if ! command -v sqlite3 >/dev/null 2>&1; then
    log_warn "sqlite3 não encontrado; inteligência ficará limitada."
    return 0
  fi

  if [[ ! -f "$ADM_INTEL_DB" ]]; then
    log_info "Criando banco de inteligência em $ADM_INTEL_DB"
    sqlite3 "$ADM_INTEL_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS builds (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  package TEXT NOT NULL,
  version TEXT,
  profile TEXT,
  status TEXT NOT NULL,
  duration_sec INTEGER,
  started_at TEXT NOT NULL,
  finished_at TEXT,
  log_path TEXT,
  flags TEXT
);

CREATE INDEX IF NOT EXISTS idx_builds_pkg ON builds(package);
SQL
  fi
}

adm_intel_record_build_start() {
  local package="$1" version="$2" profile="$3" flags="$4" log_path="$5"

  [[ -x "$(command -v sqlite3 || true)" ]] || return 0

  adm_intel_init

  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  sqlite3 "$ADM_INTEL_DB" <<SQL
INSERT INTO builds (package, version, profile, status, started_at, flags, log_path)
VALUES ('$package', '$version', '$profile', 'running', '$ts', '$flags', '$log_path');
SQL
}

adm_intel_record_build_end() {
  local package="$1" status="$2" duration_sec="$3"

  [[ -x "$(command -v sqlite3 || true)" ]] || return 0
  adm_intel_init

  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  sqlite3 "$ADM_INTEL_DB" <<SQL
UPDATE builds
   SET status='$status',
       duration_sec=$duration_sec,
       finished_at='$ts'
 WHERE id = (SELECT id FROM builds
             WHERE package='$package'
             ORDER BY id DESC LIMIT 1);
SQL
}

adm_intel_last_status() {
  local package="$1"
  [[ -x "$(command -v sqlite3 || true)" ]] || return 1
  adm_intel_init

  sqlite3 "$ADM_INTEL_DB" <<SQL
SELECT status FROM builds
 WHERE package='$package'
 ORDER BY id DESC
 LIMIT 1;
SQL
}
