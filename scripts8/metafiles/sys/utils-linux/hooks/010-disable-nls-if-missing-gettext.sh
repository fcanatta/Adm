#!/usr/bin/env bash
set -Eeuo pipefail
if ! command -v msgfmt >/dev/null 2>&1; then
  export CONFIGURE_OPTS="${CONFIGURE_OPTS:-} --disable-nls"
  echo "[hook util-linux] gettext ausente -> --disable-nls"
fi
