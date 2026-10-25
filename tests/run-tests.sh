#!/usr/bin/env bash
#
# run-tests.sh - offline regression tests for the probe verdicts, the rotation
# helper, and the wrapper's startup policy.
#
# Nothing here talks to WARP or to opencode: every external command is stubbed.
# Run from anywhere:  ./tests/run-tests.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/opencode-warp-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
RC=0

ok()   { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$*"; }

check_rc() {
  local want=$1 label=$2
  if [ "$RC" -eq "$want" ]; then ok "$label"; else bad "$label (wanted rc $want, got $RC)"; fi
}

check_contains() {
  local file=$1 pattern=$2 label=$3
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    ok "$label"
  else
    bad "$label (missing /$pattern/ in $file)"
    sed 's/^/       /' "$file" | tail -8
  fi
}

check_not_contains() {
  local file=$1 pattern=$2 label=$3
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    bad "$label (unexpected /$pattern/ in $file)"
    sed 's/^/       /' "$file" | tail -8
  else
    ok "$label"
  fi
}

write_fake() {
  local path=$1 body=$2
  printf '%s\n' "$body" >"$path"
  chmod +x "$path"
}

# --------------------------------------------------------------- probe.sh
say_probe() {
  local name=$1 body=$2
  printf '%s\n' "$body" >"$TMP/run-$name"
  chmod +x "$TMP/run-$name"
}

run_probe() {
  local name=$1 timeout=${2:-20}
  PROBE_RUN="$TMP/run-$name" \
  PROBE_OUT="$TMP/probe.out" \
  PROBE_TIMEOUT="$timeout" \
  PROXY="http://127.0.0.1:1" \
    "$ROOT/probe.sh" >"$TMP/probe.stdout" 2>"$TMP/probe.stderr"
  RC=$?
}

say_probe success '#!/usr/bin/env bash
echo PONG
exit 0'

say_probe throttled '#!/usr/bin/env bash
echo "Error: Free usage limit reached"
exit 1'

say_probe free_messages '#!/usr/bin/env bash
echo "You'"'"'ve used today'"'"'s free messages. They reset at 12:00 AM."
echo "Upgrade to OpenCode Go"
exit 1'

say_probe transport '#!/usr/bin/env bash
trap "exit 143" TERM
echo "Error: Transport: ECONNRESET: The socket connection was closed unexpectedly."
sleep 30'

say_probe auth '#!/usr/bin/env bash
echo "Error: unauthorized: invalid API key"
exit 1'

say_probe hang '#!/usr/bin/env bash
trap "exit 143" TERM
sleep 30'

run_probe success
check_rc 0 "probe: PONG is success"
check_contains "$TMP/probe.stdout" 'RESULT: SUCCESS' "probe: success verdict printed"

run_probe throttled
check_rc 1 "probe: 429 wording is throttled"
check_contains "$TMP/probe.stdout" 'RESULT: THROTTLED' "probe: throttled verdict printed"

run_probe free_messages
check_rc 1 "probe: today's-free-messages notice is throttled"
check_contains "$TMP/probe.stdout" 'RESULT: THROTTLED' "probe: free-messages verdict printed"

started=$(date +%s)
run_probe transport 20
elapsed=$(( $(date +%s) - started ))
check_rc 3 "probe: ECONNRESET is a transport failure"
check_contains "$TMP/probe.stdout" 'RESULT: TRANSPORT FAILURE' "probe: transport verdict printed"
if [ "$elapsed" -le 5 ]; then
  ok "probe: socket error returns immediately (${elapsed}s)"
else
  bad "probe: socket error took ${elapsed}s despite early kill"
fi

run_probe auth
check_rc 2 "probe: auth error remains no verdict"
check_contains "$TMP/probe.stdout" 'RESULT: NO VERDICT' "probe: no-verdict wording preserved"

started=$(date +%s)
run_probe hang 2
elapsed=$(( $(date +%s) - started ))
check_rc 2 "probe: silent hang remains no verdict"
check_contains "$TMP/probe.stdout" 'RESULT: NO VERDICT' "probe: hang verdict printed"
if [ "$elapsed" -le 6 ]; then
  ok "probe: PROBE_TIMEOUT is honoured (${elapsed}s)"
else
  bad "probe: timeout took ${elapsed}s"
fi

# --------------------------------------------------------- warp-rotate.sh
mkdir -p "$TMP/fakebin" "$TMP/cache"

write_fake "$TMP/fakebin/warp-cli" '#!/usr/bin/env bash
printf "%s\n" "$*" >>"$WARPTEST_LOG"
case "$*" in
  *"status"*)   echo "Status update: Connected"; exit 0 ;;
  *"settings"*) echo "Mode: proxy"; exit 0 ;;
  *) exit 0 ;;
esac'

write_fake "$TMP/fakebin/curl" '#!/usr/bin/env bash
exit 0'

# The fake probe reads its verdicts from $PROBE_RCS, one exit code per line.
write_fake "$TMP/fake-probe" '#!/usr/bin/env bash
n=$(cat "$PROBE_SEQ" 2>/dev/null || echo 0)
n=$((n + 1))
printf "%s\n" "$n" >"$PROBE_SEQ"
rc=$(sed -n "${n}p" "$PROBE_RCS")
[ -n "$rc" ] || rc=2
echo "--- egress (WARP) ---"
echo "ip=203.0.113.${n}"
echo "loc=US"
echo "warp=on"
case "$rc" in
  0) echo "RESULT: SUCCESS (exit 0) -> PONG" ;;
  1) echo "RESULT: THROTTLED (exit 1)" ;;
  3) echo "RESULT: TRANSPORT FAILURE (exit 3)" ;;
  *) echo "RESULT: NO VERDICT (exit 2)" ;;
esac
exit "$rc"'

run_rotate() {
  local rcs=$1 attempts=${2:-2}
  printf '%s\n' "$rcs" >"$TMP/probe-rcs"
  : >"$TMP/probe-seq"
  : >"$TMP/warp-cli.log"
  PATH="$TMP/fakebin:$PATH" \
  XDG_CACHE_HOME="$TMP/cache" \
  OPENCODE_WARP_PROBE="$TMP/fake-probe" \
  WARP_ROTATE_ATTEMPTS="$attempts" \
  WARPTEST_LOG="$TMP/warp-cli.log" \
  PROBE_SEQ="$TMP/probe-seq" \
  PROBE_RCS="$TMP/probe-rcs" \
    "$ROOT/warp-rotate.sh" >"$TMP/rotate.stdout" 2>"$TMP/rotate.stderr"
  RC=$?
}

run_rotate "0"
check_rc 0 "rotate: healthy ingress needs no rotation"
check_not_contains "$TMP/warp-cli.log" 'registration new' "rotate: healthy ingress leaves registration alone"

run_rotate "1
0"
check_rc 0 "rotate: throttled then healthy recovers"
check_contains "$TMP/warp-cli.log" 'registration new' "rotate: throttle creates a new registration"
check_contains "$TMP/rotate.stderr" 'recovered: the new ingress passes' "rotate: recovery is reported"

run_rotate "3
0"
check_rc 0 "rotate: transport failure then healthy recovers"
check_contains "$TMP/rotate.stderr" 'transport failure through WARP; rotating' "rotate: transport failure triggers rotation"

run_rotate "3
3
3"
check_rc 1 "rotate: exhausted transport failures are not fatal"
check_contains "$TMP/rotate.stderr" 'still not passing after 2 rotation attempt' "rotate: neutral exhaustion message"
count=$(grep -c 'registration new' "$TMP/warp-cli.log" 2>/dev/null || true)
if [ "$count" -eq 2 ]; then ok "rotate: attempts are bounded"; else bad "rotate: expected 2 rotations, got $count"; fi

run_rotate "2"
check_rc 2 "rotate: preflight no verdict stays fatal"
check_not_contains "$TMP/warp-cli.log" 'registration new' "rotate: no verdict does not rotate"

run_rotate "3
2"
check_rc 2 "rotate: post-rotation no verdict stays fatal"
check_contains "$TMP/rotate.stderr" 'no verdict after rotation' "rotate: post-rotation no verdict is reported"

run_rotate "1
3
0" 3
check_rc 0 "rotate: throttle, transport, then success recovers across attempts"

# ----------------------------------------------------------- opencode-warp
mkdir -p "$TMP/wrap" "$TMP/fakeopencode" "$TMP/fakecurl"
cp "$ROOT/opencode-warp" "$TMP/wrap/opencode-warp"
chmod +x "$TMP/wrap/opencode-warp"

# The wrapper picks warp-rotate.sh from its own directory first.
write_fake "$TMP/wrap/warp-rotate.sh" '#!/usr/bin/env bash
echo "fake rotate rc=$FAKE_ROTATE_RC" >&2
exit "$FAKE_ROTATE_RC"'

write_fake "$TMP/fakeopencode/opencode" '#!/usr/bin/env bash
case "${1:-}" in
  run)
    if [ "${2:-}" = "--help" ]; then echo "opencode run --standalone"; exit 0; fi
    ;;
  --version) echo "opencode fake"; exit 0 ;;
esac
printf "%s\n" "$*" >>"$OPENCODE_CALL_LOG"
echo "FAKE_OPENCODE_OK"
exit 0'

write_fake "$TMP/fakecurl/curl" '#!/usr/bin/env bash
n=$(cat "$CURL_SEQ" 2>/dev/null || echo 0)
n=$((n + 1))
printf "%s\n" "$n" >"$CURL_SEQ"
rc=$(sed -n "${n}p" "$CURL_RCS")
[ -n "$rc" ] || rc=0
exit "$rc"'

run_wrapper() {
  local rotate_rc=$1 curl_rcs=$2 strict=${3:-0} force_probe=${4:-1} log_path=${5:-}
  printf '%s\n' "$curl_rcs" >"$TMP/curl-rcs"
  : >"$TMP/curl-seq"
  : >"$TMP/opencode.log"
  PATH="$TMP/fakeopencode:$TMP/fakecurl:$PATH" \
  OPCODE_REAL="$TMP/fakeopencode/opencode" \
  HOME="$TMP/fakehome" \
  XDG_DATA_HOME="$TMP/xdgdata" \
  XDG_CACHE_HOME="$TMP/wcache" \
  OPENCODE_WARP_FORCE_PROBE="$force_probe" \
  OPENCODE_WARP_LOG="$log_path" \
  OPENCODE_WARP_ROTATE_STRICT="$strict" \
  FAKE_ROTATE_RC="$rotate_rc" \
  CURL_SEQ="$TMP/curl-seq" \
  CURL_RCS="$TMP/curl-rcs" \
  OPENCODE_CALL_LOG="$TMP/opencode.log" \
    "$TMP/wrap/opencode-warp" --stand run -m opencode/deepseek-v4.1-flash-free "hi" \
      >"$TMP/wrap.stdout" 2>"$TMP/wrap.stderr"
  RC=$?
}

run_wrapper 0 "0"
check_rc 0 "wrapper: healthy rotation starts opencode"
check_contains "$TMP/opencode.log" 'standalone' "wrapper: --standalone still injected"
check_contains "$TMP/wrap.stdout" 'FAKE_OPENCODE_OK' "wrapper: opencode actually ran"

run_wrapper 2 "0
0"
check_rc 0 "wrapper: no verdict starts opencode when proxy is reachable"
check_contains "$TMP/wrap.stderr" 'could not get a model verdict' "wrapper: no-verdict warning printed"
check_contains "$TMP/wrap.stderr" 'starting opencode anyway' "wrapper: warning explains the fallback"
check_contains "$TMP/opencode.log" 'standalone' "wrapper: fallback still uses WARP env"

run_wrapper 2 "0
1"
check_rc 2 "wrapper: no verdict aborts when proxy is unreachable"
check_contains "$TMP/wrap.stderr" 'proxy is' "wrapper: proxy failure is named"
check_not_contains "$TMP/opencode.log" 'standalone' "wrapper: opencode does not run on a broken proxy"

run_wrapper 2 "0
0" 1
check_rc 2 "wrapper: strict mode keeps no verdict fatal"
check_contains "$TMP/wrap.stderr" 'OPENCODE_WARP_ROTATE_STRICT=1' "wrapper: strict mode is explained"

run_wrapper 1 "0"
check_rc 0 "wrapper: exhausted recovery still starts opencode"
check_contains "$TMP/wrap.stderr" 'did not produce a healthy ingress' "wrapper: neutral recovery warning"
check_contains "$TMP/opencode.log" 'standalone' "wrapper: exhausted recovery still uses WARP"

run_wrapper 1 "0" 1
check_rc 1 "wrapper: strict mode keeps exhausted recovery fatal"

# The TUI's "today's free messages" notice must also trigger the preflight,
# without OPENCODE_WARP_FORCE_PROBE.
stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat >"$TMP/wrap-rate.log" <<EOF
timestamp=$stamp level=ERROR message="You've used today's free messages. They reset at 12:00 AM."
EOF
run_wrapper 0 "0" 0 "" "$TMP/wrap-rate.log"
check_rc 0 "wrapper: free-message log triggers recovery"
check_contains "$TMP/wrap.stderr" 'fake rotate rc=0' "wrapper: free-message log rotated WARP"

# ------------------------------------------------------------------ summary
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
