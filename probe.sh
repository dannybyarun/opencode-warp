#!/usr/bin/env bash
#
# probe.sh - one-shot verdict for the WARP path.
#
# Reports the current WARP egress, fires exactly ONE opencode request and
# prints SUCCESS / THROTTLED / NO VERDICT. It never loops or retries.
#
# Exit codes:  0 = success   1 = throttled   2 = no verdict
#
# Overrides:   PROBE_RUN    command to run (default: opencode-warp)
#              PROBE_MODEL  model id
#              PROXY        proxy url to report egress from
#
set -u

# This script is deliberately one-shot: never let the wrapper it launches run
# its own preflight rotation, which would recurse.
export OPENCODE_WARP_NO_ROTATE=1

PROXY="${PROXY:-http://127.0.0.1:${WARP_PROXY_PORT:-40000}}"
MODEL="${PROBE_MODEL:-opencode/deepseek-v4.1-flash-free}"
RUN="${PROBE_RUN:-opencode-warp}"
# Optional: the ratelimit-retry plugin's log. Only used to enrich the verdict
# with the unblock time - the verdict itself never depends on it existing.
LOG="${OPENCODE_RATELIMIT_LOG:-$HOME/.local/share/opencode/ratelimit-retry.jsonl}"

echo "--- egress (WARP) ---"
curl -s --max-time 10 -x "$PROXY" https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|loc|warp)='

echo "--- one request through WARP ---"
timeout 45 "$RUN" run -m "$MODEL" "reply with exactly: PONG" >/tmp/probe.out 2>&1
rc=$?

# 1. success: the model actually answered
if grep -q 'PONG' /tmp/probe.out 2>/dev/null; then
  echo "RESULT: SUCCESS (exit $rc) -> PONG"
  exit 0
fi

# 2. throttled: match opencode's own wording, not any plugin's bookkeeping
#    ("Rate limit exceeded" is the 429 text; "Free usage limit reached" is the
#    daily-free-tier text - both mean the shared bucket is empty for you now)
if grep -qiE 'rate limit exceeded|free usage limit reached|too many requests|429' /tmp/probe.out; then
  echo "RESULT: THROTTLED (exit $rc)"
  grep -iE 'rate limit exceeded|free usage limit reached|too many requests|429' /tmp/probe.out | head -2 | sed 's/^/  opencode said: /'
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

# 3. anything else (proxy down, binary missing, timeout, auth error...)
echo "RESULT: NO VERDICT (exit $rc) -- last lines of output:"
tail -5 /tmp/probe.out | sed 's/^/  /'
exit 2
