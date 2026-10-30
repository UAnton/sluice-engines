#!/usr/bin/env bash
# Build static-OpenSSL universal openfortivpn into build/openfortivpn/universal.
#
# Requires build/openssl/universal (scripts/build-openssl.sh) and
# build/tools (scripts/build-tools.sh): upstream ships only tag archives,
# so configure is generated here with our pinned autotools.
# - OPENSSL_CFLAGS/LIBS are passed directly; PKG_CONFIG is the stub, so
#   nothing outside build/ is found (libsystemd neither).
# - Every platform probe is answered explicitly: configure can't check files
#   when cross-compiling (x86_64 on arm64), and the answers must not depend on
#   the build machine.
#   * /usr/sbin/pppd is Apple's 2.4.2 -> --enable-legacy-pppd
#   * routes via /usr/sbin/netstat, no /proc, no rtentry.rt_dst (Linux only)
#   * resolvconf disabled: DNS is applied by the host app, not openfortivpn
# - prefix/sysconfdir=/var/empty: no config file is read from a default path.
source "$(dirname "$0")/common.sh"

NAME="openfortivpn-$OPENFORTIVPN_VERSION"
TARBALL="$SOURCES/$NAME.tar.gz"
OUT="$BUILD/openfortivpn"
OPENSSL="$BUILD/openssl/universal"
TOOLS="$BUILD/tools"

"$ROOT/scripts/fetch.sh" openfortivpn
[[ -f "$OPENSSL/lib/libcrypto.a" ]] || die "openssl not built: run scripts/build-openssl.sh"
[[ -x "$TOOLS/bin/automake" && -f "$TOOLS/share/aclocal/pkg.m4" ]] \
  || die "autotools not built: run scripts/build-tools.sh"
export PATH="$TOOLS/bin:$PATH"

build_triple="$(host_triple "$(uname -m)")"

for arch in $ARCHS; do
  src="$OUT/$arch/src"
  destdir="$OUT/$arch/prefix"
  if [[ -x "$destdir/var/empty/bin/openfortivpn" ]]; then
    log "openfortivpn $arch: already built"
    continue
  fi
  log "openfortivpn $arch: bootstrap"
  rm -rf "$OUT/$arch"
  mkdir -p "$src"
  tar -xzf "$TARBALL" -C "$src" --strip-components 1
  (
    cd "$src"
    { aclocal && autoconf && automake --add-missing --copy; } >"$OUT/$arch/bootstrap.log" 2>&1 \
      || { tail -20 "$OUT/$arch/bootstrap.log"; die "openfortivpn $arch: bootstrap failed"; }

    log "openfortivpn $arch: configure"
    flags="-arch $arch -mmacosx-version-min=$MACOS_MIN"
    ./configure \
      --build="$build_triple" --host="$(host_triple "$arch")" \
      CC="clang $flags" \
      LDFLAGS="$flags" \
      PKG_CONFIG="$ROOT/scripts/pkg-config-stub" \
      OPENSSL_CFLAGS="-I$OPENSSL/include" \
      OPENSSL_LIBS="$OPENSSL/lib/libssl.a $OPENSSL/lib/libcrypto.a" \
      --prefix=/var/empty \
      --sysconfdir=/var/empty \
      --disable-dependency-tracking \
      --with-pppd=/usr/sbin/pppd \
      --enable-legacy-pppd \
      --with-netstat=/usr/sbin/netstat \
      --disable-proc \
      --with-rt_dst=no \
      --with-resolvconf=DISABLED \
      --disable-resolvconf \
      --without-systemdsystemunitdir \
      >"$OUT/$arch/configure.log" 2>&1 \
      || { tail -30 "$OUT/$arch/configure.log"; die "openfortivpn $arch: configure failed"; }

    log "openfortivpn $arch: build"
    make -j"$JOBS" >"$OUT/$arch/make.log" 2>&1 \
      || { grep -m20 -E 'error' "$OUT/$arch/make.log"; die "openfortivpn $arch: build failed"; }
    make install DESTDIR="$destdir" >"$OUT/$arch/install.log" 2>&1
  )
done

log "openfortivpn: lipo"
uni="$OUT/universal"
rm -rf "$uni"
mkdir -p "$uni/bin"
lipo -create $(for a in $ARCHS; do echo "$OUT/$a/prefix/var/empty/bin/openfortivpn"; done) \
  -output "$uni/bin/openfortivpn"
check_macho "$uni/bin/openfortivpn"
check_deps "$uni/bin/openfortivpn"
check_no_build_paths "$uni/bin/openfortivpn"

mkdir -p "$DIST/licenses"
first="${ARCHS%% *}"
cp "$OUT/$first/src/LICENSE" "$DIST/licenses/openfortivpn-LICENSE.txt"
cp "$OUT/$first/src/LICENSE.OpenSSL" "$DIST/licenses/openfortivpn-LICENSE.OpenSSL.txt"

log "openfortivpn $OPENFORTIVPN_VERSION: $uni/bin/openfortivpn"
