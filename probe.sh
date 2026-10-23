#!/usr/bin/env bash
# One-shot probe: which ingress am I on, and does this request pass?
# No loop, no retries -- it fires exactly ONE request and reports the verdict.
set -u

PROXY=http://127.0.0.1:40000
MODEL=opencode/deepseek-v4.1-flash-free
LOG="$HOME/.local/share/opencode/ratelimit-retry.jsonl"

echo "--- egress (WARP) ---"
curl -s --max-time 10 -x "$PROXY" https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|loc|warp)='

before=$(grep -c 'http.response.429' "$LOG" 2>/dev/null || true)

echo "--- one request through WARP ---"
timeout 45 opencode-warp run -m "$MODEL" "reply with exactly: PONG" >/tmp/probe.out 2>&1
rc=$?
if grep -q 'PONG' /tmp/probe.out 2>/dev/null; then
  echo "RESULT: SUCCESS (exit $rc) -> $(grep -o 'PONG' /tmp/probe.out | head -1)"
  exit 0
fi

sleep 2
after=$(grep -c 'http.response.429' "$LOG" 2>/dev/null || true)
if [ "$after" -gt "$before" ]; then
  python3 - <<'PY'
import json, datetime
rows = [json.loads(l) for l in open('/root/.local/share/opencode/ratelimit-retry.jsonl') if l.strip()]
r = [o for o in rows if o.get('event') == 'http.response.429'][-1]
h = r.get('headers') or {}
ts = datetime.datetime.strptime(r['ts'], '%Y-%m-%dT%H:%M:%S.%fZ')
deadline = ts + datetime.timedelta(milliseconds=r.get('parsedDelayMs') or 0)
print("RESULT: 429 rate-limited")
print("  at        :", r['ts'])
print("  cf-ray    :", h.get('cf-ray'))
print("  retry-after:", h.get('retry-after'), "s")
print("  unblocks  :", deadline.strftime('%Y-%m-%d %H:%M:%S UTC'))
PY
  exit 1
fi
echo "RESULT: no verdict (exit $rc) -- see /tmp/probe.out"
tail -3 /tmp/probe.out
exit 2
