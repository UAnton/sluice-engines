#!/usr/bin/env bash
# Download pinned source archives into sources/ and verify sha256.
# Usage: scripts/fetch.sh [openssl|strongswan ...]   (default: all)
source "$(dirname "$0")/common.sh"

fetch() {
  local name="$1" url="$2" sha="$3" file
  file="$SOURCES/$(basename "$url")"
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
[[ ${#targets[@]} -gt 0 ]] || targets=(openssl strongswan)
for t in "${targets[@]}"; do
  case "$t" in
    openssl)    fetch openssl    "$OPENSSL_URL"    "$OPENSSL_SHA256" ;;
    strongswan) fetch strongswan "$STRONGSWAN_URL" "$STRONGSWAN_SHA256" ;;
    *) die "unknown target $t" ;;
  esac
done
