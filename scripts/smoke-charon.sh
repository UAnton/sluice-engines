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

# charon refuses to start while another one owns the compiled-in pidfile.
PIDFILE=/var/run/charon.pid
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  die "another charon is running (pid $(cat "$PIDFILE"): $(ps -o comm= -p "$(cat "$PIDFILE")")); stop it first"
fi

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

# Early startup messages go to stdout/syslog, later ones to the file log.
show_logs() { cat "$T/charon.out" "$T/charon.log" 2>/dev/null || true; }

for arch in $ARCHS; do
  log "charon $arch"
  STRONGSWAN_CONF="$T/strongswan.conf" arch -"$arch" "$BIN/charon" >"$T/charon.out" 2>&1 &
  pid=$!
  # The socket file appears before vici listens on it; retry until stats
  # come back, charon exits, or 10 s pass.
  stats=""
  for _ in $(seq 100); do
    kill -0 "$pid" 2>/dev/null || { show_logs; die "charon $arch: exited during startup"; }
    stats="$(STRONGSWAN_CONF="$T/strongswan.conf" "$BIN/swanctl" --stats 2>/dev/null)" && break
    stats=""
    sleep 0.1
  done
  [[ -n "$stats" ]] || { show_logs; die "charon $arch: vici did not answer"; }
  echo "$stats"
  loaded="$(echo "$stats" | sed -n 's/^loaded plugins: //p' | tr ' ' '\n' | grep -v '^charon$' | sort | tr '\n' ' ')"
  [[ "$loaded" == "$EXPECTED " ]] || die "charon $arch: plugins differ
  expected: $EXPECTED
  loaded:   $loaded"

  kill "$pid"; wait "$pid" 2>/dev/null || true
  rm -f "$T/charon.vici"
  log "charon $arch: ok"
done
