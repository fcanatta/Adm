#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C TZ=UTC
# Coreutils sofre com LDFLAGS agressivos em alguns hosts
: "${CFLAGS:=-O2 -pipe}"; export CFLAGS
: "${CXXFLAGS:=-O2 -pipe}"; export CXXFLAGS
export LDFLAGS="${LDFLAGS:-}"
echo "[hook coreutils] flags sane"
