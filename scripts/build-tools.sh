#!/usr/bin/env bash
# Build the autotools needed to bootstrap openfortivpn into build/tools.
# Build-time only, native arch, never shipped. Keeps the build free of Homebrew.
source "$(dirname "$0")/common.sh"

TOOLS="$BUILD/tools"
SRC="$TOOLS/src"
export PATH="$TOOLS/bin:$PATH"

"$ROOT/scripts/fetch.sh" m4 autoconf automake pkg-config

build_gnu() {
  local name="$1" version="$2" check="$3"
  if [[ -x "$TOOLS/bin/$check" ]]; then
    log "$name: already built"
    return
  fi
  log "$name $version"
  rm -rf "$SRC/$name"
  mkdir -p "$SRC/$name"
  tar -xf "$SOURCES/$name-$version.tar.xz" -C "$SRC/$name" --strip-components 1
  (
    cd "$SRC/$name"
    ./configure --prefix="$TOOLS" >"$SRC/$name.configure.log" 2>&1 \
      || { tail -20 "$SRC/$name.configure.log"; die "$name: configure failed"; }
    make -j"$JOBS" >"$SRC/$name.make.log" 2>&1 \
      || { grep -m20 -iE 'error' "$SRC/$name.make.log"; die "$name: build failed"; }
    make install >/dev/null
  )
}

# Order matters: autoconf needs the new m4, automake needs autoconf.
build_gnu m4       "$M4_VERSION"       m4
build_gnu autoconf "$AUTOCONF_VERSION" autoconf
build_gnu automake "$AUTOMAKE_VERSION" automake

# PKG_CHECK_MODULES & co. Only the macro file is needed, not pkg-config itself.
aclocal_dir="$TOOLS/share/aclocal"
if [[ ! -f "$aclocal_dir/pkg.m4" ]]; then
  log "pkg.m4 from pkg-config $PKGCONFIG_VERSION"
  mkdir -p "$aclocal_dir"
  tar -xOzf "$SOURCES/pkg-config-$PKGCONFIG_VERSION.tar.gz" "pkg-config-$PKGCONFIG_VERSION/pkg.m4.in" \
    | sed "s/@VERSION@/$PKGCONFIG_VERSION/g" >"$aclocal_dir/pkg.m4"
fi

log "tools: $(m4 --version | head -1); $(autoconf --version | head -1); $(automake --version | head -1)"
