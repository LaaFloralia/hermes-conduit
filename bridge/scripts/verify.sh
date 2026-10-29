#!/bin/sh
# Read-only acceptance checks for the installed Bridge.
#
#   scripts/verify.sh                 loopback + tailnet (if served)
#   scripts/verify.sh --loopback      loopback only
#
# Exits non-zero on the first failed check. Prints no tokens and no state.

set -eu

BRIDGE_DIR=$(cd -P "$(dirname "$0")/.." && pwd)
LABEL=${LAA_BRIDGE_LABEL:-com.laa.bridge}
PORT=${LAA_BRIDGE_PORT:-9137}
HTTPS_PORT=${LAA_BRIDGE_HTTPS_PORT:-8445}
TS=${LAA_BRIDGE_TAILSCALE_BIN:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}
MODE=${1:-all}
FAILED=0

check() {
  name=$1
  expected=$2
  actual=$3
  if [ "$actual" = "$expected" ]; then
    echo "  ok    $name ($actual)"
  else
    echo "  FAIL  $name (expected $expected, got $actual)"
    FAILED=1
  fi
}

echo "process"
check "launchd job loaded" "0" "$(launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; echo $?)"
PID=$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | awk '/^\tpid = /{print $3}')
echo "  info  pid ${PID:-unknown}"
echo "  info  bindings"
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | sed 's/^/        /' || true

echo "loopback 127.0.0.1:$PORT"
check "GET /v1/health" "200" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/v1/health")"
check "GET /v1/me without token" "401" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/v1/me")"
check "GET /v1/me with a wrong token" "401" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer not-a-real-token' --max-time 5 "http://127.0.0.1:$PORT/v1/me")"
check "GET /v1/nope" "404" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/v1/nope")"
check "GET /v1/projects without token" "401" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/v1/projects")"
check "GET /v1/workspaces without token" "401" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/v1/workspaces")"
check "GET /v1/usage without token" "401" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/v1/usage")"
check "GET /v1/mac/status without token" "401" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/v1/mac/status")"
check "PATCH /v1/projects/prj_0 without token" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X PATCH --max-time 5 "http://127.0.0.1:$PORT/v1/projects/prj_000000000000")"
check "POST /v1/_test/echo is absent" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST --max-time 5 "http://127.0.0.1:$PORT/v1/_test/echo")"
echo "  info  health body: $(curl -s --max-time 5 "http://127.0.0.1:$PORT/v1/health")"

if [ "$MODE" = "--loopback" ]; then
  exit "$FAILED"
fi

echo "tailnet (Tailscale Serve)"
if ! "$TS" serve status | grep -q ":$HTTPS_PORT "; then
  echo "  skip  https:$HTTPS_PORT is not served"
  exit "$FAILED"
fi
HOST=$("$TS" status --json | python3 -c 'import json,sys; print((json.load(sys.stdin)["Self"]["DNSName"]).rstrip("."))')
check "GET /v1/health" "200" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$HOST:$HTTPS_PORT/v1/health")"
check "GET /v1/me without token" "401" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$HOST:$HTTPS_PORT/v1/me")"
echo "  info  host: $HOST:$HTTPS_PORT"
echo "  info  existing serve entries kept:"
"$TS" serve status | sed 's/^/        /'
exit "$FAILED"
