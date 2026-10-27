#!/usr/bin/env bash
#
# run-tests.sh - offline regression tests for the probe verdicts, the rotation
# helper, and the wrapper's startup policy and run modes.
#
# Nothing here talks to WARP, opencode, or the inference API: every external
# command is stubbed. Run from anywhere:  ./tests/run-tests.sh
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
  PROBE_MODE=cli \
  PROBE_RUN="$TMP/run-$name" \
  PROBE_OUT="$TMP/probe.out" \
  PROBE_TIMEOUT="$timeout" \
  PROXY="http://127.0.0.1:1" \
  OPENCODE_RATELIMIT_LOG="$TMP/missing-ratelimit.jsonl" \
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

say_probe http429 '#!/usr/bin/env bash
echo "Error: request failed with HTTP status 429"
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
check_rc 0 "probe cli: PONG is success"
check_contains "$TMP/probe.stdout" 'RESULT: SUCCESS' "probe cli: success verdict printed"

run_probe throttled
check_rc 1 "probe cli: 429 wording is throttled"
check_contains "$TMP/probe.stdout" 'RESULT: THROTTLED' "probe cli: throttled verdict printed"

run_probe free_messages
check_rc 1 "probe cli: today's-free-messages notice is throttled"
check_contains "$TMP/probe.stdout" 'RESULT: THROTTLED' "probe cli: free-messages verdict printed"

run_probe http429
check_rc 1 "probe cli: a bare HTTP 429 is throttled"
check_contains "$TMP/probe.stdout" 'RESULT: THROTTLED' "probe cli: bare-429 verdict printed"

"$ROOT/probe.sh" --help >"$TMP/probe-help" 2>&1
RC=$?
check_rc 0 "probe: --help exits 0"
check_contains "$TMP/probe-help" 'PROBE_MODE' "probe: --help documents API mode"
check_not_contains "$TMP/probe-help" '^set -u$' "probe: --help stops at the header"

started=$(date +%s)
run_probe transport 20
elapsed=$(( $(date +%s) - started ))
check_rc 3 "probe cli: ECONNRESET is a transport failure"
check_contains "$TMP/probe.stdout" 'RESULT: TRANSPORT FAILURE' "probe cli: transport verdict printed"
if [ "$elapsed" -le 5 ]; then
  ok "probe cli: socket error returns immediately (${elapsed}s)"
else
  bad "probe cli: socket error took ${elapsed}s despite early kill"
fi

run_probe auth
check_rc 2 "probe cli: auth error remains no verdict"
check_contains "$TMP/probe.stdout" 'RESULT: NO VERDICT' "probe cli: no-verdict wording preserved"

started=$(date +%s)
run_probe hang 2
elapsed=$(( $(date +%s) - started ))
check_rc 2 "probe cli: silent hang remains no verdict"
check_contains "$TMP/probe.stdout" 'RESULT: NO VERDICT' "probe cli: hang verdict printed"
if [ "$elapsed" -le 6 ]; then
  ok "probe cli: PROBE_TIMEOUT is honoured (${elapsed}s)"
else
  bad "probe cli: timeout took ${elapsed}s"
fi

# ------------------------------------------------------- probe.sh (API mode)
mkdir -p "$TMP/fakecurlapi"

# One queued HTTP response per probe. Egress is skipped because PROXY is empty.
write_fake "$TMP/fakecurlapi/curl" '#!/usr/bin/env bash
out=""; hdr=""; fmt=""; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -D) hdr=$2; shift 2 ;;
    -w) fmt=$2; shift 2 ;;
    -H|-d|-x|--max-time) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
n=$(cat "$API_SEQ" 2>/dev/null || echo 0)
n=$((n + 1))
printf "%s\n" "$n" >"$API_SEQ"
rc=$(sed -n "${n}p" "$API_RC" 2>/dev/null); [ -n "$rc" ] || rc=0
status=$(sed -n "${n}p" "$API_STATUS" 2>/dev/null); [ -n "$status" ] || status=200
body=$(sed -n "${n}p" "$API_BODY" 2>/dev/null)
[ -n "$hdr" ] && printf "HTTP/1.1 %s\r\nretry-after: 120\r\ncf-ray: test-ray\r\n\r\n" "$status" >"$hdr"
[ -n "$out" ] && printf "%s" "$body" >"$out"
[ -n "$fmt" ] && printf "%s" "$status"
[ "$rc" = 56 ] && echo "curl: (56) Recv failure: Connection reset by peer" >&2
exit "$rc"'

run_probe_api() {
  local status=$1 rc=$2 body=$3 timeout=${4:-20} mode=${5:-api}
  printf '%s\n' "$status" >"$TMP/api-status"
  printf '%s\n' "$rc" >"$TMP/api-rc"
  printf '%s\n' "$body" >"$TMP/api-body"
  : >"$TMP/api-seq"
  PATH="$TMP/fakecurlapi:$PATH" \
  PROBE_MODE="$mode" \
  PROBE_API_URL="http://api.test/v1/chat/completions" \
  PROBE_MODEL="opencode/deepseek-v4.1-flash-free" \
  PROBE_OUT="$TMP/probe-api.out" \
  PROBE_TIMEOUT="$timeout" \
  PROXY="" \
  OPENCODE_RATELIMIT_LOG="$TMP/missing-ratelimit.jsonl" \
  API_SEQ="$TMP/api-seq" \
  API_STATUS="$TMP/api-status" \
  API_RC="$TMP/api-rc" \
  API_BODY="$TMP/api-body" \
    "$ROOT/probe.sh" >"$TMP/probe.stdout" 2>"$TMP/probe.stderr"
  RC=$?
}

run_probe_api 200 0 '{"choices":[{"message":{"content":"PONG"}}]}'
check_rc 0 "probe api: HTTP 200 is success"
check_contains "$TMP/probe.stdout" 'RESULT: SUCCESS' "probe api: success verdict printed"
check_contains "$TMP/probe.stdout" 'PONG' "probe api: PONG is reported"

run_probe_api 200 0 '{"choices":[{"message":{"content":"hello"}}]}'
check_rc 0 "probe api: HTTP 200 without PONG is still success"

run_probe_api 429 0 '{"error":{"type":"FreeUsageLimitError","message":"Free usage limit reached."}}'
check_rc 1 "probe api: HTTP 429 is throttled"
check_contains "$TMP/probe.stdout" 'RESULT: THROTTLED' "probe api: throttled verdict printed"
check_contains "$TMP/probe.stdout" 'HTTP 429' "probe api: HTTP status is reported"
check_contains "$TMP/probe.stdout" 'unblocks' "probe api: retry-after is decoded"
check_contains "$TMP/probe.stdout" 'test-ray' "probe api: cf-ray is reported"
check_contains "$TMP/probe.stdout" 'FreeUsageLimitError: Free usage limit reached' "probe api: the limit wording is reported"

run_probe_api 403 0 '{"error":{"message":"You have used today'"'"'s free messages."}}'
check_rc 1 "probe api: free-messages wording is throttled"

run_probe_api 000 56 ''
check_rc 3 "probe api: curl reset is a transport failure"
check_contains "$TMP/probe.stdout" 'RESULT: TRANSPORT FAILURE' "probe api: transport verdict printed"

run_probe_api 000 28 ''
check_rc 2 "probe api: curl timeout remains no verdict"
check_contains "$TMP/probe.stdout" 'RESULT: NO VERDICT' "probe api: timeout verdict printed"

run_probe_api 401 0 '{"error":{"message":"unauthorized"}}'
check_rc 2 "probe api: 401 remains no verdict"

run_probe_api 500 0 '{"error":"internal"}'
check_rc 2 "probe api: 500 remains no verdict"

run_probe_api 200 0 '{"choices":[{"message":{"content":"PONG"}}]}' 20 auto
check_rc 0 "probe api: auto selects the API for opencode models"

# --------------------------------------------------------- warp-rotate.sh
mkdir -p "$TMP/fakebin" "$TMP/cache"

write_fake "$TMP/fakebin/warp-cli" '#!/usr/bin/env bash
printf "%s\n" "$*" >>"$WARPTEST_LOG"
case "$*" in
  *"registration new"*)
    # A successful rotation must move the egress IP; tests can pin it with
    # WARPTEST_IP_STATIC=1 to exercise the no-op guard.
    if [ "${WARPTEST_IP_STATIC:-0}" != "1" ]; then
      n=$(cat "$WARPTEST_IP_SEQ" 2>/dev/null || echo 0)
      n=$((n + 1))
      printf "%s\n" "$n" >"$WARPTEST_IP_SEQ"
      printf "203.0.113.%s\n" "$n" >"$WARPTEST_EGRESS_FILE"
    fi
    ;;
esac
case "$*" in
  *"status"*)   echo "Status update: Connected"; exit 0 ;;
  *"settings"*) echo "Mode: proxy"; exit 0 ;;
  *) exit 0 ;;
esac'

write_fake "$TMP/fakebin/curl" '#!/usr/bin/env bash
if [ -n "${WARPTEST_EGRESS_FILE:-}" ] && [ -f "$WARPTEST_EGRESS_FILE" ]; then
  printf "ip=%s\n" "$(cat "$WARPTEST_EGRESS_FILE")"
  echo "warp=on"
fi
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
  local rcs=$1 attempts=${2:-2} static=${3:-0}
  printf '%s\n' "$rcs" >"$TMP/probe-rcs"
  : >"$TMP/probe-seq"
  : >"$TMP/warp-cli.log"
  printf '203.0.113.0\n' >"$TMP/egress-ip"
  : >"$TMP/egress-seq"
  PATH="$TMP/fakebin:$PATH" \
  XDG_CACHE_HOME="$TMP/cache" \
  OPENCODE_WARP_PROBE="$TMP/fake-probe" \
  WARP_ROTATE_ATTEMPTS="$attempts" \
  WARPTEST_LOG="$TMP/warp-cli.log" \
  WARPTEST_EGRESS_FILE="$TMP/egress-ip" \
  WARPTEST_IP_SEQ="$TMP/egress-seq" \
  WARPTEST_IP_STATIC="$static" \
  PROBE_SEQ="$TMP/probe-seq" \
  PROBE_RCS="$TMP/probe-rcs" \
    "$ROOT/warp-rotate.sh" >"$TMP/rotate.stdout" 2>"$TMP/rotate.stderr"
  RC=$?
}

run_rotate_only() {
  local attempts=${1:-2} static=${2:-0}
  : >"$TMP/warp-cli.log"
  printf '203.0.113.0\n' >"$TMP/egress-ip"
  : >"$TMP/egress-seq"
  PATH="$TMP/fakebin:$PATH" \
  XDG_CACHE_HOME="$TMP/cache" \
  WARP_ROTATE_ATTEMPTS="$attempts" \
  WARPTEST_LOG="$TMP/warp-cli.log" \
  WARPTEST_EGRESS_FILE="$TMP/egress-ip" \
  WARPTEST_IP_SEQ="$TMP/egress-seq" \
  WARPTEST_IP_STATIC="$static" \
    "$ROOT/warp-rotate.sh" --rotate-only >"$TMP/rotate.stdout" 2>"$TMP/rotate.stderr"
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
check_contains "$TMP/rotate.stderr" 'new egress IP: 203.0.113.1' "rotate: new egress IP is reported"
check_contains "$TMP/rotate.stderr" 'new ingress \(attempt 1/2\)' "rotate: recovered egress is labelled"
check_contains "$TMP/rotate.stderr" 'ip=203\.0\.113\.2' "rotate: recovered egress IP is shown"

run_rotate "1
1
1"
check_rc 1 "rotate: exhausted throttles stays throttled"
check_contains "$TMP/rotate.stderr" 'current ingress' "rotate: initial egress is shown"
check_contains "$TMP/rotate.stderr" 'ip=203\.0\.113\.1' "rotate: initial egress IP is shown"
check_contains "$TMP/rotate.stderr" 'new ingress \(attempt 1/2\)' "rotate: first rotated ingress is labelled"
check_contains "$TMP/rotate.stderr" 'ip=203\.0\.113\.2' "rotate: first rotated ingress IP is shown"
check_contains "$TMP/rotate.stderr" 'new ingress \(attempt 2/2\)' "rotate: second rotated ingress is labelled"
check_contains "$TMP/rotate.stderr" 'ip=203\.0\.113\.3' "rotate: second rotated ingress IP is shown"

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

run_rotate "1
1" 2 1
check_rc 2 "rotate: unchanged egress IP is a hard failure"
check_contains "$TMP/rotate.stderr" 'did not change the WARP egress IP' "rotate: unchanged egress IP is explained"
check_contains "$TMP/rotate.stderr" 'still 203.0.113.0' "rotate: unchanged egress IP is named"
check_contains "$TMP/rotate.stderr" 'could not rotate the WARP egress after 2 attempt' "rotate: rotation failure is summarized"
count=$(grep -c 'registration new' "$TMP/warp-cli.log" 2>/dev/null || true)
if [ "$count" -eq 2 ]; then ok "rotate: unchanged-IP attempts are bounded"; else bad "rotate: expected 2 unchanged-IP attempts, got $count"; fi

run_rotate_only 2 0
check_rc 0 "rotate-only: changed egress IP succeeds"
check_contains "$TMP/rotate.stderr" 'new egress IP: 203.0.113.1' "rotate-only: new egress IP is reported"

run_rotate_only 2 1
check_rc 2 "rotate-only: unchanged egress IP is a hard failure"
check_contains "$TMP/rotate.stderr" 'did not change the WARP egress IP' "rotate-only: unchanged egress IP is explained"

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
if [ -n "${ROTATE_ENV_LOG:-}" ]; then
  printf "PROBE_RUN=%s\nPROBE_MODEL=%s\nPROBE_MODE=%s\n" "${PROBE_RUN:-}" "${PROBE_MODEL:-}" "${PROBE_MODE:-}" >"$ROTATE_ENV_LOG"
fi
exit "$FAKE_ROTATE_RC"'

write_fake "$TMP/fakeopencode/opencode" '#!/usr/bin/env bash
case "${1:-}" in
  run)
    if [ "${2:-}" = "--help" ]; then
      if [ "${FAKE_NO_STANDALONE:-0}" = "1" ]; then
        echo "opencode run (no standalone)"; exit 1
      fi
      echo "opencode run --standalone"; exit 0
    fi
    ;;
  --version) echo "opencode fake"; exit 0 ;;
esac
printf "HTTPS_PROXY=%s\n" "${HTTPS_PROXY:-}" >>"$OPENCODE_CALL_LOG"
printf "AUTO_ROTATE=%s\n" "${OPENCODE_WARP_AUTO_ROTATE:-}" >>"$OPENCODE_CALL_LOG"
printf "PLUGIN=%s\n" "${OPENCODE_WARP_PLUGIN:-}" >>"$OPENCODE_CALL_LOG"
printf "ARGS=%s\n" "$*" >>"$OPENCODE_CALL_LOG"
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
  local rotate_rc=$1 curl_rcs=$2 strict=${3:-0}
  shift 3
  printf '%s\n' "$curl_rcs" >"$TMP/curl-rcs"
  : >"$TMP/curl-seq"
  : >"$TMP/opencode.log"
  : >"$TMP/rotate-env.log"
  PATH="$TMP/fakeopencode:$TMP/fakecurl:$PATH" \
  OPCODE_REAL="$TMP/fakeopencode/opencode" \
  XDG_CACHE_HOME="$TMP/wcache" \
  HTTPS_PROXY="" HTTP_PROXY="" https_proxy="" http_proxy="" \
  NO_PROXY="" no_proxy="" \
  PROBE_RUN="" PROBE_MODEL="" \
  OPENCODE_WARP_USQUE=0 \
  OPENCODE_WARP_FORCE_PROBE="${FORCE_PROBE:-1}" \
  OPENCODE_WARP_LOG="${LOG_PATH:-}" \
  OPENCODE_WARP_ROTATE_STRICT="$strict" \
  FAKE_ROTATE_RC="$rotate_rc" \
  FAKE_NO_STANDALONE="${FAKE_NO_STANDALONE:-0}" \
  ROTATE_ENV_LOG="$TMP/rotate-env.log" \
  CURL_SEQ="$TMP/curl-seq" \
  CURL_RCS="$TMP/curl-rcs" \
  OPENCODE_CALL_LOG="$TMP/opencode.log" \
    "$TMP/wrap/opencode-warp" "$@" >"$TMP/wrap.stdout" 2>"$TMP/wrap.stderr"
  RC=$?
}

run_wrapper_usque() {
  mkdir -p "$TMP/fakeusque" "$TMP/fakeusquecurl"
  write_fake "$TMP/fakeusque/pgrep" '#!/usr/bin/env bash
[ "${1:-}" = "-x" ] && [ "${2:-}" = "usque" ] && exit 0
exit 1'
  write_fake "$TMP/fakeusque/systemctl" '#!/usr/bin/env bash
[ "${1:-}" = "is-active" ] && [ "${2:-}" = "--quiet" ] \
  && [ "${3:-}" = "usque-proxy.service" ] && exit 0
exit 1'
  write_fake "$TMP/fakeusquecurl/curl" '#!/usr/bin/env bash
prev=""
for arg in "$@"; do
  if [ "$prev" = "-x" ] && [ "$arg" = "http://127.0.0.1:40001" ]; then
    exit 0
  fi
  prev="$arg"
done
exit 1'
  : >"$TMP/opencode.log"
  PATH="$TMP/fakeopencode:$TMP/fakeusque:$TMP/fakeusquecurl:$PATH" \
  OPCODE_REAL="$TMP/fakeopencode/opencode" \
  XDG_CACHE_HOME="$TMP/wcache" \
  HTTPS_PROXY="" HTTP_PROXY="" https_proxy="" http_proxy="" \
  NO_PROXY="" no_proxy="" \
  PROBE_RUN="" PROBE_MODEL="" \
  OPENCODE_WARP_USQUE=1 \
  OPENCODE_WARP_FORCE_PROBE=0 \
  OPENCODE_WARP_LOG="" \
  OPENCODE_WARP_ROTATE_STRICT=0 \
  ROTATE_ENV_LOG="$TMP/rotate-env.log" \
  CURL_SEQ="$TMP/curl-seq" \
  CURL_RCS="$TMP/curl-rcs" \
  OPENCODE_CALL_LOG="$TMP/opencode.log" \
    "$TMP/wrap/opencode-warp" run -m opencode/deepseek-v4.1-flash-free "hi" \
      >"$TMP/wrap.stdout" 2>"$TMP/wrap.stderr"
  RC=$?
}

run_wrapper 0 "0" 0 run -m opencode/deepseek-v4.1-flash-free "hi"
check_rc 0 "wrapper: healthy rotation starts opencode"
check_contains "$TMP/opencode.log" 'ARGS=.*standalone' "wrapper: --standalone still injected"
check_contains "$TMP/opencode.log" 'HTTPS_PROXY=http://127.0.0.1:40000' "wrapper: run gets WARP env"
check_contains "$TMP/wrap.stdout" 'FAKE_OPENCODE_OK' "wrapper: opencode actually ran"
check_contains "$TMP/rotate-env.log" '^PROBE_MODE=cli$' "wrapper: opencode models use the CLI probe"
check_contains "$TMP/rotate-env.log" '^PROBE_RUN=$' "wrapper: opencode models leave PROBE_RUN to probe.sh"
check_contains "$TMP/rotate-env.log" '^PROBE_MODEL=opencode/deepseek-v4.1-flash-free$' "wrapper: the free model is forwarded to the probe"

run_wrapper_usque
check_rc 0 "wrapper: usque auto-detection starts opencode"
check_contains "$TMP/opencode.log" 'HTTPS_PROXY=http://127.0.0.1:40001' "wrapper: usque proxy is selected"
check_contains "$TMP/opencode.log" '^AUTO_ROTATE=0$' "wrapper: usque disables official rotation"
check_contains "$TMP/opencode.log" '^PLUGIN=0$' "wrapper: usque disables the live rotation plugin"
check_contains "$TMP/opencode.log" 'ARGS=.*standalone' "wrapper: usque still injects --standalone"

run_wrapper 0 "0" 0 run -m openrouter/some-free-model "hi"
check_rc 0 "wrapper: third-party free models still run"
check_contains "$TMP/rotate-env.log" '^PROBE_RUN=.*/opencode-warp$' "wrapper: third-party models force the CLI probe"
check_contains "$TMP/rotate-env.log" '^PROBE_MODEL=openrouter/some-free-model$' "wrapper: the third-party model is forwarded"

run_wrapper 2 "0
0" 0 run -m opencode/deepseek-v4.1-flash-free "hi"
check_rc 0 "wrapper: no verdict starts opencode when proxy is reachable"
check_contains "$TMP/wrap.stderr" 'could not get a model verdict' "wrapper: no-verdict warning printed"
check_contains "$TMP/wrap.stderr" 'starting opencode anyway' "wrapper: warning explains the fallback"
check_contains "$TMP/opencode.log" 'standalone' "wrapper: fallback still uses WARP env"

run_wrapper 2 "0
1" 0 run -m opencode/deepseek-v4.1-flash-free "hi"
check_rc 2 "wrapper: no verdict aborts when proxy is unreachable"
check_contains "$TMP/wrap.stderr" 'proxy is' "wrapper: proxy failure is named"
check_not_contains "$TMP/opencode.log" 'ARGS=' "wrapper: opencode does not run on a broken proxy"

run_wrapper 2 "0
0" 1 run -m opencode/deepseek-v4.1-flash-free "hi"
check_rc 2 "wrapper: strict mode keeps no verdict fatal"
check_contains "$TMP/wrap.stderr" 'OPENCODE_WARP_ROTATE_STRICT=1' "wrapper: strict mode is explained"

run_wrapper 1 "0" 0 run -m opencode/deepseek-v4.1-flash-free "hi"
check_rc 0 "wrapper: exhausted recovery still starts opencode"
check_contains "$TMP/wrap.stderr" 'did not produce a healthy ingress' "wrapper: neutral recovery warning"
check_contains "$TMP/opencode.log" 'standalone' "wrapper: exhausted recovery still uses WARP"

run_wrapper 1 "0" 1 run -m opencode/deepseek-v4.1-flash-free "hi"
check_rc 1 "wrapper: strict mode keeps exhausted recovery fatal"

# `serve` is already a foreground server: WARP env, but no --standalone.
run_wrapper 0 "0" 0 serve --port 4096
check_rc 0 "wrapper: serve starts opencode"
check_contains "$TMP/opencode.log" 'ARGS=serve --port 4096' "wrapper: serve args are passed through"
check_not_contains "$TMP/opencode.log" 'standalone' "wrapper: serve does not get --standalone"
check_contains "$TMP/opencode.log" 'HTTPS_PROXY=http://127.0.0.1:40000' "wrapper: serve gets the WARP env"
check_contains "$TMP/wrap.stderr" 'fake rotate rc=0' "wrapper: serve still runs the preflight"

run_wrapper 0 "1
1" 0 serve --port 4096
check_rc 1 "wrapper: serve refuses a dead WARP proxy"
check_not_contains "$TMP/opencode.log" 'ARGS=serve' "wrapper: serve does not run on a broken proxy"

FAKE_NO_STANDALONE=1 run_wrapper 0 "0" 0 serve --port 4096
check_rc 0 "wrapper: serve does not require run --standalone"
check_contains "$TMP/opencode.log" 'ARGS=serve --port 4096' "wrapper: serve still runs without the flag"

FAKE_NO_STANDALONE=1 run_wrapper 0 "0" 0 run -m opencode/deepseek-v4.1-flash-free "hi"
check_rc 1 "wrapper: run still requires --standalone"
check_contains "$TMP/wrap.stderr" 'no "run --standalone" flag' "wrapper: missing flag is explained"
check_not_contains "$TMP/opencode.log" 'ARGS=' "wrapper: run refuses to fall through silently"

# `--server` points at a server that owns its own egress: pure passthrough.
run_wrapper 9 "1" 0 run --server http://127.0.0.1:4096 -m opencode/deepseek-v4.1-flash-free "hi"
check_rc 0 "wrapper: --server is a passthrough"
check_contains "$TMP/opencode.log" 'ARGS=run --server http://127.0.0.1:4096 -m' "wrapper: --server args are passed through"
check_not_contains "$TMP/opencode.log" 'standalone' "wrapper: --server does not get --standalone"
check_not_contains "$TMP/opencode.log" 'HTTPS_PROXY=http' "wrapper: --server does not get the proxy env"
check_not_contains "$TMP/wrap.stderr" 'fake rotate' "wrapper: --server skips the preflight"

run_wrapper 9 "1" 0 api --server http://127.0.0.1:4096 get /api/info
check_rc 0 "wrapper: api --server is a passthrough"
check_contains "$TMP/opencode.log" 'ARGS=api --server http://127.0.0.1:4096 get /api/info' "wrapper: api args are passed through"
check_not_contains "$TMP/opencode.log" 'standalone' "wrapper: api --server does not get --standalone"

# The TUI's "today's free messages" notice must trigger the preflight even
# without OPENCODE_WARP_FORCE_PROBE.
stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat >"$TMP/wrap-rate.log" <<EOF
timestamp=$stamp level=ERROR message="You've used today's free messages. They reset at 12:00 AM."
EOF
FORCE_PROBE=0 LOG_PATH="$TMP/wrap-rate.log" run_wrapper 0 "0" 0 run -m opencode/deepseek-v4.1-flash-free "hi"
check_rc 0 "wrapper: free-message log triggers recovery"
check_contains "$TMP/wrap.stderr" 'fake rotate rc=0' "wrapper: free-message log rotated WARP"

# An explicit paid model disables the free-tier rotation.
FORCE_PROBE=0 LOG_PATH="$TMP/wrap-rate.log" run_wrapper 0 "0" 0 run -m anthropic/claude-sonnet-4 "hi"
check_rc 0 "wrapper: paid models still run"
check_not_contains "$TMP/wrap.stderr" 'fake rotate' "wrapper: paid model skips free-tier rotation"

# ------------------------------------------------------------ installer URLs
check_contains "$ROOT/setup.sh" 'OPENCODE_INSTALL_URL="https://opencode\.ai/v2/install"' "setup: uses the OpenCode 2 installer"
check_not_contains "$ROOT/setup.sh" 'OPENCODE_INSTALL_URL="https://opencode\.ai/install"' "setup: does not use the OpenCode 1 installer"

# ------------------------------------------------------------------- usque
bash -n "$ROOT/usque-setup.sh"
check_rc 0 "usque: installer parses"
bash -n "$ROOT/opencode-usque"
check_rc 0 "usque: wrapper parses"
check_contains "$ROOT/usque-setup.sh" 'sha256sum' "usque: installer verifies the checksum"
check_contains "$ROOT/usque-proxy.service.in" '@USQUE_PORT@' "usque: service template is parameterized"

# ------------------------------------------------------------------ summary
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
