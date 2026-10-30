#!/usr/bin/env bash
# Bring up an IKEv2 tunnel to a FortiGate with the built charon, report what
# the gateway gave us (virtual IP, routes, DNS), then disconnect and check
# cleanup. Mirrors a configuration verified against a FortiGate. Needs sudo.
#
# Usage: sudo scripts/connect-test.sh <env-file> [--arch arm64|x86_64] [--hold] [--public-ip]
#   env-file     credentials, see scripts/connect-test.env.example (keep outside the repo)
#   --arch       which slice of the universal charon to run (default: this Mac's)
#   --hold       keep the tunnel up until Enter is pressed
#   --public-ip  compare public IP before/after via ifconfig.me (third-party request)
source "$(dirname "$0")/common.sh"

[[ $EUID -eq 0 ]] || die "run as root: sudo $0 $*"
[[ $# -ge 1 && -f "$1" ]] || die "usage: sudo $0 <env-file> [--arch A] [--hold] [--public-ip]"
ENV_FILE="$1"; shift
arch="$(uname -m)"; hold=""; public_ip=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) arch="$2"; shift 2 ;;
    --hold) hold=1; shift ;;
    --public-ip) public_ip=1; shift ;;
    *) die "unknown option $1" ;;
  esac
done

[[ "$(stat -f %Lp "$ENV_FILE")" =~ ^[0-7]00$ ]] || log "warning: $ENV_FILE is readable by others (chmod 600)"
GATEWAY= PSK= EAP_ID= EAP_PASSWORD= REMOTE_TS=0.0.0.0/0
# shellcheck disable=SC1090
source "$ENV_FILE"
for v in GATEWAY PSK EAP_ID EAP_PASSWORD; do [[ -n "${!v}" ]] || die "$v not set in $ENV_FILE"; done

BIN="$BUILD/strongswan/universal/bin"
[[ -x "$BIN/charon" ]] || die "charon not built: run scripts/build-strongswan.sh"
PIDFILE="$CHARON_PIDDIR/charon.pid"
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  die "another charon is running (pid $(cat "$PIDFILE")); stop it first"
fi
install -d -o root -g wheel -m 0755 "$CHARON_PIDDIR"

# Logs are kept for inspection; they hold the login and addresses, not secrets.
OUTDIR="$BUILD/connect-test"
mkdir -p "$OUTDIR"
T="$(mktemp -d)"; chmod 700 "$T"
pid=""
cleanup() {
  [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
  cp "$T/charon.log" "$OUTDIR/charon-$arch.log" 2>/dev/null || true
  [[ -n "${SUDO_USER:-}" ]] && chown -R "$SUDO_USER" "$OUTDIR"
  rm -rf "$T"
}
trap cleanup EXIT

quote() { local s="${1//\\/\\\\}"; printf '"%s"' "${s//\"/\\\"}"; }
b64() { printf '%s' "$1" | base64; }

PROPOSALS="aes256-sha256-ecp384, aes128-sha256-ecp384"
cat >"$T/strongswan.conf" <<CONF
charon {
  filelog {
    log {
      path = $T/charon.log
      time_format = %T
      default = 1
      ike = 2
      cfg = 2
      knl = 1
    }
  }
}
CONF
# strongSwan config syntax: one setting per line; ';' is NOT a separator.
cat >"$T/swanctl.conf" <<CONF
connections {
  fortigate {
    version = 2
    remote_addrs = $(quote "$GATEWAY")
    proposals = $PROPOSALS
    vips = 0.0.0.0
    local {
      auth = eap
      eap_id = $(quote "$EAP_ID")
    }
    remote {
      auth = psk
      id = %any
    }
    children {
      fortigate {
        remote_ts = $REMOTE_TS
        esp_proposals = $PROPOSALS
      }
    }
  }
}
secrets {
  ike-gw {
    secret = 0s$(b64 "$PSK")
  }
  eap-user {
    id = $(quote "$EAP_ID")
    secret = 0s$(b64 "$EAP_PASSWORD")
  }
}
CONF
chmod 600 "$T/swanctl.conf"

swanctl() { STRONGSWAN_CONF="$T/strongswan.conf" "$BIN/swanctl" "$@"; }
default_route_if() { route -n get default 2>/dev/null | awk '/interface:/{print $2}'; }
show_log() { log "charon log: $OUTDIR/charon-$arch.log"; }

[[ -n "$public_ip" ]] && log "public IP before: $(curl -s --max-time 5 https://ifconfig.me || echo '?')"
utun_routes() { netstat -rn -f inet | grep -c utun || true; }
if_before="$(default_route_if)"
utun_before="$(utun_routes)"
log "default route before: $if_before"

log "start charon ($arch)"
STRONGSWAN_CONF="$T/strongswan.conf" arch -"$arch" "$BIN/charon" >"$T/charon.out" 2>&1 &
pid=$!
for _ in $(seq 100); do
  kill -0 "$pid" 2>/dev/null || { cat "$T/charon.out"; die "charon exited during startup"; }
  swanctl --stats >/dev/null 2>&1 && break
  sleep 0.1
done

log "load config"
# swanctl also scans x509/, private/ etc. next to the file; create them to
# keep the output clean.
mkdir -p "$T"/{x509,x509ca,x509ocsp,x509aa,x509ac,x509crl,pubkey,private,rsa,ecdsa,pkcs8,pkcs12}
swanctl --load-all --file "$T/swanctl.conf"

log "initiate"
if ! swanctl --initiate --child fortigate --timeout 30; then
  show_log; die "initiate failed (see log above)"
fi

echo
swanctl --list-sas
echo
log "gateway attributes (charon cannot apply DNS without a handler; the line proves it was sent)"
grep -E 'installing new virtual IP|handling .* attribute|INTERNAL_IP4' "$T/charon.log" || echo "  (none logged)"
log "routes via tunnel"
netstat -rn -f inet | awk 'NR<=4 || /utun/' | grep -E 'utun|Destination' || true
log "default route now: $(default_route_if) (before: $if_before)"
[[ -n "$public_ip" ]] && log "public IP in tunnel: $(curl -s --max-time 5 https://ifconfig.me || echo '?')"

if [[ -n "$hold" ]]; then
  log "tunnel is up; press Enter to disconnect"
  read -r </dev/tty
fi

log "terminate"
swanctl --terminate --ike fortigate --timeout 15 || log "warning: terminate reported an error"
sleep 1
grep -E 'sending DELETE|received DELETE|IKE_SA .* deleted|deleting IKE_SA' "$T/charon.log" | tail -3 || true
left="$(utun_routes)"
if [[ "$left" -le "$utun_before" ]]; then log "routes cleaned up"
else log "warning: $((left - utun_before)) tunnel routes remain"; fi
log "default route after: $(default_route_if)"
show_log
log "done"
