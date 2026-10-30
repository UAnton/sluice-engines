#!/usr/bin/env bash
# Build everything from pinned sources and assemble dist/.
# Each step skips work that is already done; delete build/ for a clean build.
source "$(dirname "$0")/common.sh"

for step in fetch build-openssl build-strongswan build-tools build-openfortivpn dist; do
  log "== $step"
  "$ROOT/scripts/$step.sh"
done
