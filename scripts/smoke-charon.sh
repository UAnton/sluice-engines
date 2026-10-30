#!/usr/bin/env bash
# Start the built charon as root with a throwaway config, check via vici that
# exactly the expected plugins are loaded, then stop it. Needs sudo.
# Usage: sudo scripts/smoke-charon.sh
source "$(dirname "$0")/common.sh"

[[ $EUID -eq 0 ]] || die "run as root: sudo $0"
BIN="$BUILD/strongswan/universal/bin"
[[ -x "$BIN/charon" ]] || die "charon not built: run scripts/build-strongswan.sh"

# Plugins compiled into charon (counters is forced on by vici in configure.ac).
EXPECTED="constraints counters eap-identity eap-mschapv2 kdf kernel-pfkey kernel-pfroute nonce openssl pem pkcs1 pkcs8 pubkey revocation socket-default vici x509"

T="$(mktemp -d)"
trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -rf "$T"' EXIT
cat >"$T/strongswan.conf" <<CONF
charon {
  filelog { log { path = $T/charon.log; default = 1 } }
  plugins { vici { socket = unix://$T/charon.vici } }
  port = 0
  port_nat_t = 0
}
swanctl { socket = unix://$T/charon.vici }
CONF

for arch in $ARCHS; do
  log "charon $arch"
  STRONGSWAN_CONF="$T/strongswan.conf" arch -"$arch" "$BIN/charon" &
  pid=$!
  for _ in $(seq 50); do [[ -S "$T/charon.vici" ]] && break; sleep 0.1; done
  [[ -S "$T/charon.vici" ]] || { cat "$T/charon.log"; die "charon $arch: vici socket did not appear"; }

  stats="$(STRONGSWAN_CONF="$T/strongswan.conf" "$BIN/swanctl" --stats)"
  echo "$stats"
  loaded="$(echo "$stats" | sed -n 's/^loaded plugins: //p' | tr ' ' '\n' | grep -v '^charon$' | sort | tr '\n' ' ')"
  [[ "$loaded" == "$EXPECTED " ]] || die "charon $arch: plugins differ
  expected: $EXPECTED
  loaded:   $loaded"

  kill "$pid"; wait "$pid" 2>/dev/null || true
  rm -f "$T/charon.vici"
  log "charon $arch: ok"
done
