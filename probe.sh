#!/usr/bin/env bash
#
# probe.sh - one-shot verdict for the WARP path.
#
# Reports the current WARP egress, fires exactly ONE opencode request and
# prints SUCCESS / THROTTLED / TRANSPORT FAILURE / NO VERDICT. It never loops
# or retries.
#
# Exit codes:  0 = success
#              1 = throttled (429 / free-tier quota)
#              2 = no verdict (missing binary, auth error, timeout...)
#              3 = transport failure through WARP (ECONNRESET and friends)
#
# Overrides:   PROBE_RUN      command to run (default: opencode-warp)
#              PROBE_MODEL    model id
#              PROXY          proxy url to report egress from
#              PROBE_TIMEOUT  seconds before giving up (default 45)
#              PROBE_OUT      capture file (default /tmp/probe.out)
#
set -u

# This script is deliberately one-shot: never let the wrapper it launches run
# its own preflight rotation, which would recurse.
export OPENCODE_WARP_NO_ROTATE=1

PROXY="${PROXY:-http://127.0.0.1:${WARP_PROXY_PORT:-40000}}"
MODEL="${PROBE_MODEL:-opencode/deepseek-v4.1-flash-free}"
RUN="${PROBE_RUN:-opencode-warp}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-45}"
OUT="${PROBE_OUT:-/tmp/probe.out}"
TRANSPORT_RE='ECONNRESET|ECONNREFUSED|ETIMEDOUT|ENETUNREACH|EHOSTUNREACH|socket connection was closed|fetch failed'
# Optional: the opencode-warp plugin's 429 log (same schema as the older
# ratelimit-retry plugin). Only used to enrich the verdict with the unblock
# time - the verdict itself never depends on it existing.
LOG="${OPENCODE_RATELIMIT_LOG:-$HOME/.local/share/opencode/ratelimit-retry.jsonl}"

echo "--- egress (WARP) ---"
curl -s --max-time 10 -x "$PROXY" https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|loc|warp)='

echo "--- one request through WARP ---"
: >"$OUT"
timeout "$PROBE_TIMEOUT" "$RUN" run -m "$MODEL" "reply with exactly: PONG" >"$OUT" 2>&1 &
pid=$!

# OpenCode can print a transport error and then sit in its retry/shutdown path
# until the timeout. Once the socket error is visible, kill it and report the
# failure immediately.
early=0
while kill -0 "$pid" 2>/dev/null; do
  if grep -qiE "$TRANSPORT_RE" "$OUT" 2>/dev/null; then
    early=1
    kill "$pid" 2>/dev/null || true
    break
  fi
  sleep 0.5
done
wait "$pid" 2>/dev/null
rc=$?
[ "$early" -eq 1 ] && rc=124

# 1. success: the model actually answered
if grep -q 'PONG' "$OUT" 2>/dev/null; then
  echo "RESULT: SUCCESS (exit $rc) -> PONG"
  exit 0
fi

# 2. throttled: match opencode's own wording, not any plugin's bookkeeping
#    ("Rate limit exceeded" is the 429 text; "Free usage limit reached" is the
#    daily-free-tier text; the TUI may instead say "You've used today's free
#    messages" - all mean the shared bucket is empty for you now)
if grep -qiE 'rate limit exceeded|free usage limit reached|free messages|too many requests|429' "$OUT" 2>/dev/null; then
  echo "RESULT: THROTTLED (exit $rc)"
  grep -iE 'rate limit exceeded|free usage limit reached|free messages|too many requests|429' "$OUT" | head -2 | sed 's/^/  opencode said: /'
  if [ -f "$LOG" ]; then
    python3 - "$LOG" <<'PY' 2>/dev/null || true
import json, sys, datetime
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
hits = [o for o in rows if o.get('event') == 'http.response.429']
if hits:
    r = hits[-1]
    h = r.get('headers') or {}
    try:
        ts = datetime.datetime.strptime(r['ts'], '%Y-%m-%dT%H:%M:%S.%fZ')
        deadline = ts + datetime.timedelta(milliseconds=r.get('parsedDelayMs') or 0)
        print("  unblocks   :", deadline.strftime('%Y-%m-%d %H:%M:%S UTC'))
    except Exception:
        pass
    if h.get('cf-ray'):
        print("  cf-ray     :", h.get('cf-ray'))
PY
  fi
  exit 1
fi

# 3. transport failure: the WARP path accepted the connection and then the
#    socket died. This is not a "no verdict": a fresh registration is the
#    usual fix, so the wrapper may rotate on it.
if grep -qiE "$TRANSPORT_RE" "$OUT" 2>/dev/null; then
  echo "RESULT: TRANSPORT FAILURE (exit $rc) -- the connection through WARP died:"
  grep -iE "$TRANSPORT_RE" "$OUT" | head -2 | sed 's/^/  opencode said: /'
  exit 3
fi

# 4. anything else (proxy down, binary missing, timeout, auth error...)
echo "RESULT: NO VERDICT (exit $rc) -- last lines of output:"
tail -5 "$OUT" | sed 's/^/  /'
exit 2
