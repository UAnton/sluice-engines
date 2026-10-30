#!/usr/bin/env bash
# Download pinned source archives into sources/ and verify sha256.
# Usage: scripts/fetch.sh [target ...]   (default: all)
# Archives are saved as <name>-<version>.<ext> (tag archives have no name).
source "$(dirname "$0")/common.sh"

fetch() {
  local name="$1" version="$2" url="$3" sha="$4" file ext
  ext="${url##*.tar.}"
  file="$SOURCES/$name-$version.tar.$ext"
  mkdir -p "$SOURCES"
  if [[ ! -f "$file" ]]; then
    log "download $name: $url"
    curl -fL --retry 3 -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  local got
  got="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  if [[ "$got" != "$sha" ]]; then
    die "$name: sha256 mismatch for $file
  expected $sha
  got      $got"
  fi
  log "ok $name $(basename "$file")"
}

targets=("$@")
[[ ${#targets[@]} -gt 0 ]] || targets=(openssl strongswan openfortivpn m4 autoconf automake pkg-config)
for t in "${targets[@]}"; do
  case "$t" in
    openssl)      fetch openssl      "$OPENSSL_VERSION"      "$OPENSSL_URL"      "$OPENSSL_SHA256" ;;
    strongswan)   fetch strongswan   "$STRONGSWAN_VERSION"   "$STRONGSWAN_URL"   "$STRONGSWAN_SHA256" ;;
    openfortivpn) fetch openfortivpn "$OPENFORTIVPN_VERSION" "$OPENFORTIVPN_URL" "$OPENFORTIVPN_SHA256" ;;
    m4)           fetch m4           "$M4_VERSION"           "$M4_URL"           "$M4_SHA256" ;;
    autoconf)     fetch autoconf     "$AUTOCONF_VERSION"     "$AUTOCONF_URL"     "$AUTOCONF_SHA256" ;;
    automake)     fetch automake     "$AUTOMAKE_VERSION"     "$AUTOMAKE_URL"     "$AUTOMAKE_SHA256" ;;
    pkg-config)   fetch pkg-config   "$PKGCONFIG_VERSION"    "$PKGCONFIG_URL"    "$PKGCONFIG_SHA256" ;;
    *) die "unknown target $t" ;;
  esac
done
