#!/usr/bin/env bash
# Build static universal charon + swanctl into build/strongswan/universal.
#
# Requires build/openssl/universal (scripts/build-openssl.sh).
# - monolithic + static: plugins live inside the executables; the loader finds
#   them by symbol, so nothing is dlopen'ed from disk.
# - --prefix=/var/empty: every compiled-in path (strongswan.conf, plugindir,
#   swanctl dir) points into a root-owned empty directory. The app passes the
#   real config via STRONGSWAN_CONF / swanctl --file.
# - piddir=/var/run/sluice: own pidfile and default vici socket, so bundled
#   charon coexists with any other strongSwan. The helper must create the
#   directory (root:wheel 0755) before starting charon, or charon aborts.
# - plugins/sluice-dns (ours) is compiled next to charon.c and linked into the
#   charon executable only; no autotools needed. It registers itself like the
#   built-in plugins and is appended to charon's default load list.
# - -Wl,-dead_strip drops unreferenced code from the static libraries; plugin
#   constructors (__mod_init_func) and what they reference are kept.
source "$(dirname "$0")/common.sh"

NAME="strongswan-$STRONGSWAN_VERSION"
TARBALL="$SOURCES/$NAME.tar.bz2"
OUT="$BUILD/strongswan"
OPENSSL="$BUILD/openssl/universal"

# Must match EXPECTED in scripts/smoke-charon.sh.
PLUGINS=(
  ikev2 openssl nonce kdf
  kernel-pfkey kernel-pfroute socket-default
  vici swanctl
  eap-identity eap-mschapv2
  x509 pem pkcs1 pkcs8 pubkey constraints revocation
)

"$ROOT/scripts/fetch.sh" strongswan
[[ -f "$OPENSSL/lib/libcrypto.a" ]] || die "openssl not built: run scripts/build-openssl.sh"

build_triple="$(host_triple "$(uname -m)")"

for arch in $ARCHS; do
  src="$OUT/$arch/src"
  prefix="$OUT/$arch/prefix"
  if [[ -x "$prefix/var/empty/libexec/ipsec/charon" ]]; then
    log "strongswan $arch: already built"
    continue
  fi
  log "strongswan $arch: configure"
  rm -rf "$OUT/$arch"
  mkdir -p "$src"
  tar -xjf "$TARBALL" -C "$src" --strip-components 1
  cp "$ROOT/plugins/sluice-dns/sluice_dns_plugin.c" "$src/src/charon/"
  (
    cd "$src"
    flags="-arch $arch -mmacosx-version-min=$MACOS_MIN"
    ./configure \
      --build="$build_triple" --host="$(host_triple "$arch")" \
      CC="clang $flags" \
      PKG_CONFIG="$ROOT/scripts/pkg-config-stub" \
      CFLAGS="-O2 -I$OPENSSL/include" \
      LDFLAGS="$flags -L$OPENSSL/lib -Wl,-dead_strip" \
      --prefix=/var/empty \
      --sysconfdir=/var/empty \
      --with-strongswan-conf=/var/empty/strongswan.conf \
      --with-swanctldir=/var/empty/swanctl \
      --with-plugindir=/var/empty \
      --with-ipseclibdir=/var/empty \
      --with-piddir="$CHARON_PIDDIR" \
      --disable-dependency-tracking \
      --enable-static --disable-shared --enable-monolithic \
      --disable-defaults \
      --enable-charon \
      $(printf -- '--enable-%s ' "${PLUGINS[@]}") \
      >"$OUT/$arch/configure.log" 2>&1 \
      || { tail -30 "$OUT/$arch/configure.log"; die "strongswan $arch: configure failed"; }
    log "strongswan $arch: build"
    charon_plugins="$(sed -n 's/^charon_plugins = *//p' src/charon/Makefile)"
    [[ -n "$charon_plugins" ]] || die "strongswan $arch: charon_plugins not found"
    make -j"$JOBS" \
      am_charon_OBJECTS='charon.$(OBJEXT) sluice_dns_plugin.$(OBJEXT)' \
      charon_plugins="$charon_plugins sluice-dns" \
      >"$OUT/$arch/make.log" 2>&1 \
      || { grep -m20 -E 'error|Error' "$OUT/$arch/make.log"; die "strongswan $arch: build failed"; }
    make install DESTDIR="$prefix" >"$OUT/$arch/install.log" 2>&1
  )
done

log "strongswan: lipo"
uni="$OUT/universal"
rm -rf "$uni"
mkdir -p "$uni/bin"
for exe in libexec/ipsec/charon sbin/swanctl; do
  lipo -create $(for a in $ARCHS; do echo "$OUT/$a/prefix/var/empty/$exe"; done) \
    -output "$uni/bin/$(basename "$exe")"
  check_macho "$uni/bin/$(basename "$exe")"
  check_deps "$uni/bin/$(basename "$exe")"
  check_no_build_paths "$uni/bin/$(basename "$exe")"
done

log "strongswan $STRONGSWAN_VERSION: $uni/bin ($(ls "$uni/bin" | tr '\n' ' '))"
