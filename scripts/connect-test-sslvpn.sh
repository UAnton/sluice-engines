#!/usr/bin/env bash
# Bring up a FortiGate SSL-VPN tunnel with the built openfortivpn, report what
# the gateway gave us (IP, DNS, routes), then disconnect and check cleanup.
# DNS is not applied (--set-dns=0), as in the app. Needs sudo (pppd).
#
# Usage: sudo scripts/connect-test-sslvpn.sh <env-file> [--arch arm64|x86_64] [--hold] [--otp]
#   env-file  credentials, see scripts/connect-test-sslvpn.env.example (keep outside the repo)
#   --arch    which slice of the universal binary to run (default: this Mac's)
#   --hold    keep the tunnel up until Enter is pressed
#   --otp     ask for a one-time password before connecting
source "$(dirname "$0")/common.sh"

[[ $EUID -eq 0 ]] || die "run as root: sudo $0 $*"
[[ $# -ge 1 && -f "$1" ]] || die "usage: sudo $0 <env-file> [--arch A] [--hold] [--otp]"
ENV_FILE="$1"; shift
arch="$(uname -m)"; hold=""; otp=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) arch="$2"; shift 2 ;;
    --hold) hold=1; shift ;;
    --otp) otp=1; shift ;;
    *) die "unknown option $1" ;;
  esac
done

[[ "$(stat -f %Lp "$ENV_FILE")" =~ ^[0-7]00$ ]] || log "warning: $ENV_FILE is readable by others (chmod 600)"
GATEWAY= PORT=443 USERNAME= PASSWORD= REALM= TRUSTED_CERT=
# shellcheck disable=SC1090
source "$ENV_FILE"
for v in GATEWAY USERNAME PASSWORD; do [[ -n "${!v}" ]] || die "$v not set in $ENV_FILE"; done
# Placeholders from connect-test-sslvpn.env.example
[[ "$GATEWAY" != vpn.example.com && "$PASSWORD" != ... ]] \
  || die "$ENV_FILE still has example values: fill in GATEWAY, USERNAME, PASSWORD"
# The config file format is one "key = value" per line, no quoting.
for v in GATEWAY USERNAME PASSWORD REALM TRUSTED_CERT; do
  [[ "${!v}" != *$'\n'* ]] || die "$v must not contain a newline"
done

BIN="$BUILD/openfortivpn/universal/bin/openfortivpn"
[[ -x "$BIN" ]] || die "openfortivpn not built: run scripts/build-openfortivpn.sh"
if pgrep -x openfortivpn >/dev/null; then
  die "another openfortivpn is running; stop it first"
fi

otp_value=""
if [[ -n "$otp" ]]; then
  read -r -p "OTP: " otp_value </dev/tty
fi

# Logs are kept for inspection; they hold the login and addresses, not secrets.
OUTDIR="$BUILD/connect-test"
mkdir -p "$OUTDIR"
LOG="$OUTDIR/openfortivpn-$arch.log"
T="$(mktemp -d)"; chmod 700 "$T"
pid=""
cleanup() {
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -INT "$pid" 2>/dev/null
    for _ in $(seq 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -rf "$T"
  [[ -n "${SUDO_USER:-}" ]] && chown -R "$SUDO_USER" "$OUTDIR"
}
trap cleanup EXIT

# Credentials go through a 0600 config file, not argv (visible in ps).
{
  echo "host = $GATEWAY"
  echo "port = $PORT"
  echo "username = $USERNAME"
  echo "password = $PASSWORD"
  [[ -n "$REALM" ]] && echo "realm = $REALM"
  [[ -n "$TRUSTED_CERT" ]] && echo "trusted-cert = $TRUSTED_CERT"
  [[ -n "$otp_value" ]] && echo "otp = $otp_value"
  echo "set-dns = 0"
  echo "pppd-use-peerdns = 0"
  echo "set-routes = 1"
} >"$T/config"
chmod 600 "$T/config"

default_route_if() { route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}'; }
ppp_ifaces() { ifconfig -l | tr ' ' '\n' | grep '^ppp' | sort || true; }
if_before="$(default_route_if)"
ppp_before="$(ppp_ifaces)"
resolv_before="$(shasum -a 256 /etc/resolv.conf 2>/dev/null | cut -d' ' -f1)"
log "default route before: $if_before"

log "start openfortivpn ($arch)"
arch -"$arch" "$BIN" -c "$T/config" -v >"$LOG" 2>&1 &
pid=$!

# Wait for the tunnel, a failure, or 60 s.
state=""
for _ in $(seq 600); do
  if grep -q 'Tunnel is up and running' "$LOG"; then state=up; break; fi
  if ! kill -0 "$pid" 2>/dev/null; then state=exited; break; fi
  sleep 0.1
done

if [[ "$state" != up ]]; then
  if grep -q 'trusted-cert = ' "$LOG"; then
    log "gateway certificate is not trusted yet; if this is your gateway, put into $ENV_FILE:"
    grep -m1 -oE 'trusted-cert = [0-9a-f]+' "$LOG" | sed -E 's/trusted-cert = /  TRUSTED_CERT=/'
    grep -A12 'Gateway certificate:' "$LOG" | sed 's/^/  /'
    die "rerun after checking the certificate above"
  fi
  tail -30 "$LOG"
  [[ "$state" == exited ]] && die "openfortivpn exited (log: $LOG)"
  die "tunnel did not come up within 60 s (log: $LOG)"
fi

echo
log "gateway configuration"
grep -E 'Got addresses|Found dns|dns suffix|Interface .* is UP|Remote gateway has allocated' "$LOG" \
  | sed -E 's/^(INFO|DEBUG|WARN):[[:space:]]*/  /' || true
iface="$(comm -13 <(echo "$ppp_before") <(ppp_ifaces) | head -1)"
if [[ -n "$iface" ]]; then
  log "interface $iface"
  ifconfig "$iface" | sed 's/^/  /'
  log "routes via $iface"
  netstat -rn -f inet | awk -v i="$iface" 'NR<=4 || $0 ~ i' | grep -E "$iface|Destination" || true
fi
log "default route now: $(default_route_if) (before: $if_before)"
if [[ "$(shasum -a 256 /etc/resolv.conf 2>/dev/null | cut -d' ' -f1)" == "$resolv_before" ]]; then
  log "/etc/resolv.conf untouched (set-dns = 0)"
else
  log "warning: /etc/resolv.conf changed"
fi

if [[ -n "$hold" ]]; then
  log "tunnel is up; press Enter to disconnect"
  read -r </dev/tty
fi

log "disconnect"
kill -INT "$pid"
for _ in $(seq 150); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$pid" 2>/dev/null && log "warning: openfortivpn still running after 15 s"
grep -E 'Setting original routes|Closed connection|Logged out' "$LOG" \
  | sed -E 's/^(INFO|DEBUG|WARN):[[:space:]]*/  /' || true
if [[ -n "$iface" ]] && ifconfig "$iface" >/dev/null 2>&1; then
  log "warning: $iface still exists"
else
  log "interface removed"
fi
log "default route after: $(default_route_if)"
log "openfortivpn log: $LOG"
log "done"
