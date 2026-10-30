#!/usr/bin/env bash
# Assemble the shippable engines into dist/ from the universal builds:
#
#   dist/bin/{charon,swanctl,openfortivpn}
#   dist/licenses/          upstream license texts (+ our plugin's license)
#   dist/BUILDINFO          what was built, from what, with which toolchain
#   dist/SHA256SUMS         hashes of everything above (shasum -a 256 -c)
#
# dist/ is recreated from scratch; run after the build scripts
# (or use scripts/build-all.sh).
source "$(dirname "$0")/common.sh"

STRONGSWAN="$BUILD/strongswan"
OPENFORTIVPN="$BUILD/openfortivpn"
OPENSSL="$BUILD/openssl"
first="${ARCHS%% *}"

BINS=(
  "$STRONGSWAN/universal/bin/charon"
  "$STRONGSWAN/universal/bin/swanctl"
  "$OPENFORTIVPN/universal/bin/openfortivpn"
)
for b in "${BINS[@]}"; do
  [[ -x "$b" ]] || die "missing $b: run the build scripts first"
done

log "dist: assemble"
rm -rf "$DIST"
mkdir -p "$DIST/bin" "$DIST/licenses"
for b in "${BINS[@]}"; do
  cp "$b" "$DIST/bin/"
  check_macho "$DIST/bin/$(basename "$b")"
  check_deps "$DIST/bin/$(basename "$b")"
  check_no_build_paths "$DIST/bin/$(basename "$b")"
done

cp "$OPENSSL/$first/src/LICENSE.txt"         "$DIST/licenses/openssl-LICENSE.txt"
cp "$STRONGSWAN/$first/src/COPYING"          "$DIST/licenses/strongswan-COPYING.txt"
cp "$STRONGSWAN/$first/src/LICENSE"          "$DIST/licenses/strongswan-LICENSE.txt"
cp "$OPENFORTIVPN/$first/src/LICENSE"        "$DIST/licenses/openfortivpn-LICENSE.txt"
cp "$OPENFORTIVPN/$first/src/LICENSE.OpenSSL" "$DIST/licenses/openfortivpn-LICENSE.OpenSSL.txt"

log "dist: BUILDINFO"
commit="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then
  commit="$commit (dirty: uncommitted changes)"
fi
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
src_line() { printf '  %-13s %-8s sha256 %s\n                %s\n' "$1" "$2" "$3" "$4"; }

{
  echo "sluice-engines build"
  echo
  echo "source:   $(git -C "$ROOT" remote get-url origin 2>/dev/null || echo "this repository (no remote configured)")"
  echo "commit:   $commit"
  echo "built:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "build host"
  echo "  macOS     $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
  echo "  Xcode     $(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
  echo "  SDK       macosx $(xcrun --sdk macosx --show-sdk-version) ($(xcrun --sdk macosx --show-sdk-build-version))"
  echo "  clang     $(clang --version | head -1)"
  echo
  echo "targets"
  echo "  archs     $ARCHS"
  echo "  macOS     $MACOS_MIN or later"
  echo
  echo "upstream sources (verified by sha256 before building)"
  src_line openssl      "$OPENSSL_VERSION"      "$OPENSSL_SHA256"      "$OPENSSL_URL"
  src_line strongswan   "$STRONGSWAN_VERSION"   "$STRONGSWAN_SHA256"   "$STRONGSWAN_URL"
  src_line openfortivpn "$OPENFORTIVPN_VERSION" "$OPENFORTIVPN_SHA256" "$OPENFORTIVPN_URL"
  echo
  echo "build-only tools (openfortivpn bootstrap, not shipped)"
  src_line m4           "$M4_VERSION"           "$M4_SHA256"           "$M4_URL"
  src_line autoconf     "$AUTOCONF_VERSION"     "$AUTOCONF_SHA256"     "$AUTOCONF_URL"
  src_line automake     "$AUTOMAKE_VERSION"     "$AUTOMAKE_SHA256"     "$AUTOMAKE_URL"
  src_line pkg-config   "$PKGCONFIG_VERSION"    "$PKGCONFIG_SHA256"    "$PKGCONFIG_URL"
  echo
  echo "own code linked into charon"
  echo "  plugins/sluice-dns/sluice_dns_plugin.c  sha256 $(sha "$ROOT/plugins/sluice-dns/sluice_dns_plugin.c")"
  echo
  echo "runtime paths compiled in"
  echo "  charon piddir     $CHARON_PIDDIR (pidfile, default vici socket)"
  echo "  sluice-dns        $CHARON_PIDDIR/dns"
  echo "  config/plugins    /var/empty (real config via STRONGSWAN_CONF / -c)"
  echo "  pppd              /usr/sbin/pppd (system)"
  echo
  echo "binaries"
  for b in "$DIST"/bin/*; do
    printf '  %-13s %s  %s bytes  sha256 %s\n' "$(basename "$b")" \
      "$(lipo -archs "$b")" "$(stat -f %z "$b")" "$(sha "$b")"
  done
  echo
  echo "charon plugins"
  echo "  $(strings -a -arch "$first" "$DIST/bin/charon" | grep -m1 -E '^nonce .* sluice-dns$')"
} >"$DIST/BUILDINFO"

log "dist: SHA256SUMS"
(cd "$DIST" && find bin licenses BUILDINFO -type f | LC_ALL=C sort | xargs shasum -a 256 >SHA256SUMS)

log "dist ready: $DIST"
cat "$DIST/BUILDINFO"
