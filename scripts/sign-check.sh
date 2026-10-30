#!/usr/bin/env bash
# Sign copies of dist/bin the way the app will ship them (hardened runtime,
# secure timestamp) into build/signed/, and verify. dist/ itself stays as
# built; the app signs the binaries it bundles.
#
# Usage: scripts/sign-check.sh [identity]
#   identity  codesign identity, e.g. "Developer ID Application: Name (TEAMID)";
#             default "-" (ad-hoc, no timestamp)
#
# Then run the live tests on the signed copies, e.g.
#   sudo scripts/smoke-charon.sh --bin build/signed
source "$(dirname "$0")/common.sh"

IDENTITY="${1:--}"
OUT="$BUILD/signed"

for b in charon swanctl openfortivpn; do
  [[ -x "$DIST/bin/$b" ]] || die "missing dist/bin/$b: run scripts/dist.sh"
done
rm -rf "$OUT"
mkdir -p "$OUT"

ts=(--timestamp)
[[ "$IDENTITY" == "-" ]] && ts=(--timestamp=none)

for b in charon swanctl openfortivpn; do
  cp "$DIST/bin/$b" "$OUT/$b"
  codesign --force --sign "$IDENTITY" --options runtime "${ts[@]}" \
    --identifier "app.sluicevpn.engine.$b" "$OUT/$b"
  codesign --verify --strict --verbose=1 "$OUT/$b" 2>&1 | sed 's/^/  /'
  info="$(codesign -dv --verbose=4 "$OUT/$b" 2>&1)"
  grep -q 'flags=0x1[0-9a-f]*(.*runtime' <<<"$info" || die "$b: hardened runtime not set"
  if [[ "$IDENTITY" != "-" ]]; then
    grep -q '^Timestamp=' <<<"$info" || die "$b: no secure timestamp"
  fi
  if codesign -d --entitlements - "$OUT/$b" 2>/dev/null | grep -q get-task-allow; then
    die "$b: get-task-allow entitlement present (notarization would reject it)"
  fi
  log "$b: $(grep -E '^(Authority|TeamIdentifier)=' <<<"$info" | head -2 | tr '\n' ' ')"
done

log "signed copies in $OUT"
