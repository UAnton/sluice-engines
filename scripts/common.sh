# Sourced by build scripts. Paths, logging, pinned versions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$ROOT/sources"
BUILD="$ROOT/build"
DIST="$ROOT/dist"

# shellcheck source=../versions.env
source "$ROOT/versions.env"

JOBS="$(sysctl -n hw.ncpu)"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# host triple for autoconf-style --host
host_triple() {
  case "$1" in
    arm64)  echo aarch64-apple-darwin ;;
    x86_64) echo x86_64-apple-darwin ;;
    *) die "unknown arch $1" ;;
  esac
}

# Assert a Mach-O file contains every arch in ARCHS and targets MACOS_MIN.
check_macho() {
  local f="$1" archs
  archs="$(lipo -archs "$f")"
  for a in $ARCHS; do
    [[ " $archs " == *" $a "* ]] || die "$f: missing arch $a (has: $archs)"
  done
  # Every object (static archives hold many) must target exactly MACOS_MIN.
  for a in $ARCHS; do
    local minos
    minos="$(otool -arch "$a" -l "$f" | awk '/ minos /{print $2}' | sort -u | tr '\n' ' ')"
    [[ "$minos" == "$MACOS_MIN " ]] || die "$f ($a): minos [$minos], expected $MACOS_MIN"
  done
}
