#!/usr/bin/env bash
#
# probe.sh - one-shot verdict for the WARP path.
#
# Reports the current WARP egress, fires exactly ONE model request and prints
# SUCCESS / THROTTLED / TRANSPORT FAILURE / NO VERDICT. It never loops or
# retries.
#
# By default the request goes straight to the same OpenAI-compatible endpoint
# OpenCode uses (https://opencode.ai/inference/openai/v1) with the public
# free-tier credential. That avoids creating an OpenCode session and does not
# depend on the `run` subcommand or the `--standalone` flag. Set PROBE_MODE=cli
# (or PROBE_RUN) to probe through `opencode run` instead.
#
# Exit codes:  0 = success
#              1 = throttled (429 / free-tier quota)
#              2 = no verdict (missing binary, auth error, timeout...)
#              3 = transport failure through WARP (ECONNRESET and friends)
#
# Overrides:   PROBE_MODE     api | cli | auto (default: auto)
#              PROBE_API_URL  chat-completions endpoint
#              PROBE_API_KEY  bearer token (default: public)
#              PROBE_RUN      command to run in CLI mode (default: opencode-warp)
#              PROBE_MODEL    model id (default: opencode/deepseek-v4.1-flash-free)
#              PROXY          proxy url (empty = direct; default: WARP)
#              PROBE_DIRECT   set to 1 to skip the proxy (same as PROXY="")
#              PROBE_TIMEOUT  seconds before giving up (default 45)
#              PROBE_OUT      capture file (default /tmp/probe.out)
#
set -u

# This script is deliberately one-shot: never let the wrapper it launches run
# its own preflight rotation, which would recurse. API mode does not launch
# opencode, but keep the guard for CLI mode and backwards compatibility.
export OPENCODE_WARP_NO_ROTATE=1

PROXY="${PROXY-http://127.0.0.1:${WARP_PROXY_PORT:-40000}}"
[ "${PROBE_DIRECT:-0}" = "1" ] && PROXY=""
MODEL="${PROBE_MODEL:-opencode/deepseek-v4.1-flash-free}"
MODE="${PROBE_MODE:-auto}"
API_URL="${PROBE_API_URL:-https://opencode.ai/inference/openai/v1/chat/completions}"
API_KEY="${PROBE_API_KEY:-public}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-45}"
OUT="${PROBE_OUT:-/tmp/probe.out}"
HDR="${PROBE_HDR:-${OUT}.headers}"
RUN="${PROBE_RUN:-opencode-warp}"
TRANSPORT_RE='ECONNRESET|ECONNREFUSED|ETIMEDOUT|ENETUNREACH|EHOSTUNREACH|socket connection was closed|fetch failed|[Cc]onnection reset by peer|[Rr]ecv failure|[Ss]end failure|[Cc]onnection refused|[Cc]ould not connect'
# Optional: the opencode-warp plugin's 429 log (same schema as the older
# ratelimit-retry plugin). Only used to enrich the verdict with the unblock
# time - the verdict itself never depends on it existing.
LOG="${OPENCODE_RATELIMIT_LOG:-$HOME/.local/share/opencode/ratelimit-retry.jsonl}"

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

case "$MODE" in
  api|cli) ;;
  *)
    MODE=auto
    ;;
esac

# `auto` keeps the old PROBE_RUN contract working, uses the raw API for
# opencode models, and falls back to the CLI for third-party providers.
if [ "$MODE" = "auto" ]; then
  if [ -n "${PROBE_RUN:-}" ]; then
    MODE=cli
  elif [ -n "${PROBE_API_URL:-}" ]; then
    MODE=api
  else
    case "$MODEL" in
      opencode/*) MODE=api ;;
      *) MODE=cli ;;
    esac
  fi
fi

# curl with the WARP proxy, or direct when PROXY is empty (useful for tests).
proxy_curl() {
  if [ -n "$PROXY" ]; then
    curl -x "$PROXY" "$@"
  else
    curl "$@"
  fi
}

print_egress() {
  echo "--- egress (WARP) ---"
  if [ -n "$PROXY" ]; then
    proxy_curl -s --max-time 10 https://www.cloudflare.com/cdn-cgi/trace \
      | grep -E '^(ip|loc|warp)=' || true
  else
    echo "  (direct; PROXY is empty)"
  fi
}

# Print the plugin log's unblock estimate when it has a fresh 429. This is
# best-effort: the verdict never depends on the log file.
print_log_hint() {
  [ -f "$LOG" ] || return 0
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
}

probe_api() {
  local api_model="$MODEL" payload status rc retry cfray deadline api_type api_msg
  case "$api_model" in
    opencode/*) api_model="${api_model#opencode/}" ;;
  esac
  api_model="${api_model%%#*}"

  payload="$(printf '{"model":"%s","messages":[{"role":"user","content":"reply with exactly: PONG"}],"max_tokens":16,"stream":false}' "$api_model")"

  print_egress
  echo "--- one request through WARP ---"
  : >"$OUT"
  : >"$HDR"

  status="$(proxy_curl -sS --max-time "$PROBE_TIMEOUT" \
    -D "$HDR" -o "$OUT" -w '%{http_code}' \
    -H "Authorization: Bearer $API_KEY" \
    -H 'Content-Type: application/json' \
    -d "$payload" "$API_URL" 2>>"$OUT")"
  rc=$?
  case "$status" in
    ''|*[!0-9]*) status=000 ;;
  esac

  if [ "$status" = "200" ]; then
    if grep -q 'PONG' "$OUT" 2>/dev/null; then
      echo "RESULT: SUCCESS (HTTP 200) -> PONG"
    else
      echo "RESULT: SUCCESS (HTTP 200)"
    fi
    exit 0
  fi

  # 429 is the shared free bucket. Match the API's own wording as well, in
  # case a proxy or future server returns the limit with another status.
  if [ "$status" = "429" ] \
     || grep -qiE 'free usage limit reached|freeusagelimiterror|free messages|rate limit exceeded|too many requests' "$OUT" 2>/dev/null; then
    echo "RESULT: THROTTLED (HTTP $status)"
    # The real body is {"type":"error","error":{"type":...,"message":...}}.
    # Prefer the nested limit wording over the outer generic "error" type.
    api_type="$(grep -oiE '"type"[[:space:]]*:[[:space:]]*"[^"]{0,120}"' "$OUT" 2>/dev/null \
      | tail -1 | sed -E 's/^"[^"]+"[[:space:]]*:[[:space:]]*"//; s/"$//')"
    api_msg="$(grep -oiE '"message"[[:space:]]*:[[:space:]]*"[^"]{0,300}"' "$OUT" 2>/dev/null \
      | tail -1 | sed -E 's/^"[^"]+"[[:space:]]*:[[:space:]]*"//; s/"$//')"
    if [ -n "$api_type" ] && [ -n "$api_msg" ]; then
      echo "  api said: ${api_type}: ${api_msg}"
    elif [ -n "$api_msg" ]; then
      echo "  api said: ${api_msg}"
    elif [ -n "$api_type" ]; then
      echo "  api said: ${api_type}"
    fi
    retry="$(grep -i '^retry-after:' "$HDR" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}')"
    cfray="$(grep -i '^cf-ray:' "$HDR" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}')"
    case "$retry" in
      ''|*[!0-9]*) : ;;
      *)
        deadline="$(date -u -d "@$(( $(date +%s) + retry ))" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || true)"
        [ -n "$deadline" ] && echo "  unblocks   : $deadline"
        ;;
    esac
    [ -n "$cfray" ] && echo "  cf-ray     : $cfray"
    print_log_hint
    exit 1
  fi

  if grep -qiE "$TRANSPORT_RE" "$OUT" 2>/dev/null; then
    echo "RESULT: TRANSPORT FAILURE (HTTP $status) -- the connection through WARP died:"
    grep -iE "$TRANSPORT_RE" "$OUT" | head -2 | sed 's/^/  curl said: /'
    exit 3
  fi

  case "$rc" in
    7|35|52|55|56)
      echo "RESULT: TRANSPORT FAILURE (curl exit $rc) -- the connection through WARP died:"
      tail -2 "$OUT" | sed 's/^/  curl said: /'
      exit 3
      ;;
  esac

  echo "RESULT: NO VERDICT (HTTP $status, curl exit $rc) -- last lines of output:"
  tail -5 "$OUT" | sed 's/^/  /'
  exit 2
}

probe_cli() {
  print_egress
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
  if grep -qiE 'rate limit exceeded|free usage limit reached|freeusagelimiterror|free messages|too many requests|429' "$OUT" 2>/dev/null; then
    echo "RESULT: THROTTLED (exit $rc)"
    grep -iE 'rate limit exceeded|free usage limit reached|freeusagelimiterror|free messages|too many requests|429' "$OUT" | head -2 | sed 's/^/  opencode said: /'
    print_log_hint
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
}

if [ "$MODE" = "api" ]; then
  probe_api
else
  probe_cli
fi
