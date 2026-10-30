#!/usr/bin/env bash
# Build static universal OpenSSL into build/openssl/universal.
#
# Per arch: build/openssl/<arch>/{src,prefix}; then lipo into universal/.
# - no-shared/no-module: libcrypto.a with the legacy provider linked in
#   (strongSwan eap-mschapv2 needs MD4/DES from it).
# - openssldir=/var/empty: no openssl.cnf is picked up from a writable
#   location on the user's machine.
source "$(dirname "$0")/common.sh"

NAME="openssl-$OPENSSL_VERSION"
TARBALL="$SOURCES/$NAME.tar.gz"
OUT="$BUILD/openssl"

"$ROOT/scripts/fetch.sh" openssl

configure_target() {
  case "$1" in
    arm64)  echo darwin64-arm64-cc ;;
    x86_64) echo darwin64-x86_64-cc ;;
  esac
}

for arch in $ARCHS; do
  src="$OUT/$arch/src"
  prefix="$OUT/$arch/prefix"
  if [[ -f "$prefix/lib/libcrypto.a" ]]; then
    log "openssl $arch: already built"
    continue
  fi
  log "openssl $arch: configure"
  rm -rf "$OUT/$arch"
  mkdir -p "$src"
  tar -xzf "$TARBALL" -C "$src" --strip-components 1
  (
    cd "$src"
    ./Configure "$(configure_target "$arch")" \
      --prefix="$prefix" \
      --openssldir=/var/empty \
      --libdir=lib \
      no-shared no-module no-tests no-docs no-apps \
      -mmacosx-version-min="$MACOS_MIN"
    log "openssl $arch: build"
    make -j"$JOBS" build_libs >/dev/null
    make install_dev >/dev/null
  )
done

log "openssl: lipo"
uni="$OUT/universal"
rm -rf "$uni"
mkdir -p "$uni/lib"
first=""
for arch in $ARCHS; do
  if [[ -z "$first" ]]; then
    first="$arch"
    cp -R "$OUT/$arch/prefix/include" "$uni/include"
  else
    # Headers must be identical across archs to share one include/.
    diff -r "$OUT/$first/prefix/include" "$OUT/$arch/prefix/include" >/dev/null \
      || die "openssl headers differ between $first and $arch"
  fi
done
for lib in libcrypto.a libssl.a; do
  lipo -create $(for a in $ARCHS; do echo "$OUT/$a/prefix/lib/$lib"; done) -output "$uni/lib/$lib"
  check_macho "$uni/lib/$lib"
done

mkdir -p "$DIST/licenses"
cp "$OUT/$first/src/LICENSE.txt" "$DIST/licenses/openssl-LICENSE.txt"

log "openssl $OPENSSL_VERSION: $uni ($(lipo -archs "$uni/lib/libcrypto.a"))"
