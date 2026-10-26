#!/usr/bin/env bash
#
# warp-rotate.sh - recover a throttled WARP ingress.
#
# Probes the current WARP egress once. If the free tier is throttled, removes
# the anonymous WARP device registration, creates a new one, reconnects in
# proxy mode, and probes again. Repeats up to WARP_ROTATE_ATTEMPTS times.
#
# This is the automated version of:
#
#   warp-cli --accept-tos registration delete \
#     && warp-cli --accept-tos registration new \
#     && warp-cli --accept-tos mode proxy \
#     && warp-cli --accept-tos connect \
#     && ./probe.sh
#
# Exit codes:  0 = healthy or recovered
#              1 = still throttled / still failing after all rotations
#              2 = no verdict (probe/warp-cli/proxy failure)
#
# Options:     --force         rotate first, without probing the current ingress
#              --rotate-only   replace the registration and verify the proxy,
#                              but do not run a model probe (used by the
#                              real-time plugin during a live session)
#
# Environment:
#   WARP_ROTATE_ATTEMPTS   rotation attempts (default 2)
#   WARP_PROXY_PORT        WARP proxy port (default 40000)
#   OPENCODE_WARP_PROBE    probe.sh path (default: next to this script,
#                          then /usr/local/lib/opencode-warp/probe.sh)
#   PROBE_MODEL            forwarded to probe.sh
#   PROBE_RUN              forwarded to probe.sh
#
set -uo pipefail

PORT="${WARP_PROXY_PORT:-40000}"
PROXY="http://127.0.0.1:${PORT}"
ATTEMPTS="${WARP_ROTATE_ATTEMPTS:-2}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/opencode-warp"

# Serialise concurrent `opencode --stand` launches: two rotations deleting each
# other's registrations would be worse than either one alone.
mkdir -p "$STATE_DIR" 2>/dev/null || true
if command -v flock >/dev/null 2>&1 && [ -d "$STATE_DIR" ]; then
  if exec 9>"$STATE_DIR/rotate.lock"; then
    if ! flock -w 90 9; then
      printf 'opencode-warp: another rotation is already in progress\n' >&2
      exit 2
    fi
  fi
fi

FORCE=0
ROTATE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --force)       FORCE=1 ;;
    --rotate-only) ROTATE_ONLY=1 ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'opencode-warp: unknown option: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

say()  { printf 'opencode-warp: %s\n' "$*" >&2; }
warn() { printf 'opencode-warp: warning: %s\n' "$*" >&2; }

# An invalid attempt count must not turn into "no rotation at all".
case "$ATTEMPTS" in
  ''|*[!0-9]*|0) ATTEMPTS=1 ;;
esac

find_probe() {
  local p="${OPENCODE_WARP_PROBE:-}"
  if [ -n "$p" ] && [ -x "$p" ]; then printf '%s\n' "$p"; return 0; fi
  for p in "$SELF_DIR/probe.sh" "/usr/local/lib/opencode-warp/probe.sh"; do
    if [ -x "$p" ]; then printf '%s\n' "$p"; return 0; fi
  done
  return 1
}

PROBE=""
if [ "$ROTATE_ONLY" -eq 0 ]; then
  PROBE="$(find_probe)" || {
    say "cannot find probe.sh (set OPENCODE_WARP_PROBE)"
    exit 2
  }
fi

state_write() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  date +%s >"$STATE_DIR/$1" 2>/dev/null || true
}

probe_ingress() {
  # OPENCODE_WARP_NO_ROTATE prevents a recursive preflight when the CLI probe
  # mode launches the wrapper. API mode does not launch opencode, but the guard
  # is harmless and keeps both modes consistent.
  OPENCODE_WARP_NO_ROTATE=1 "$PROBE" >"$1" 2>&1
}

# Read the public egress IP through the WARP proxy. A rotation only helps if
# this changes; a new registration that leaves the old tunnel up (or a host
# already behind another WARP/NAT) keeps the same throttled bucket.
egress_ip() {
  local ip
  # Use Cloudflare's trace endpoint, not ipify: it reports the same address
  # family Cloudflare sees for the inference endpoint, and it is what
  # probe.sh prints as the egress.
  ip="$(curl -s --max-time 5 -x "$PROXY" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
    | sed -n 's/^ip=//p' | head -1 | tr -d '[:space:]')" || return 1
  case "$ip" in
    ''|*[!0-9a-fA-F:.]*) return 1 ;;
  esac
  printf '%s\n' "$ip"
}

rotate_registration() {
  local i status settings before_ip after_ip

  command -v warp-cli >/dev/null 2>&1 || { say "warp-cli not found"; return 1; }

  before_ip="$(egress_ip 2>/dev/null || true)"
  if [ -n "$before_ip" ]; then
    say "current egress IP: $before_ip"
  else
    warn "could not read the current egress IP; rotation cannot be verified"
  fi

  # Best effort: a connected client can refuse to delete its registration.
  if ! warp-cli --accept-tos disconnect >/dev/null 2>&1; then
    warn "warp-cli disconnect returned non-zero; continuing"
  fi

  say "deleting the WARP device registration"
  warp-cli --accept-tos registration delete >/dev/null 2>&1 \
    || warn "registration delete returned non-zero; continuing"

  say "creating a new anonymous registration"
  if ! warp-cli --accept-tos registration new >/dev/null 2>&1; then
    say "registration new failed (run as root, or check 'warp-cli status')"
    return 1
  fi

  say "setting proxy mode on 127.0.0.1:${PORT}"
  if ! warp-cli --accept-tos mode proxy >/dev/null 2>&1 \
     && ! warp-cli --accept-tos set-mode proxy >/dev/null 2>&1; then
    say "could not set WARP proxy mode; refusing to connect"
    return 1
  fi

  if ! warp-cli --accept-tos connect >/dev/null 2>&1; then
    warn "warp-cli connect returned non-zero; checking the egress anyway"
  fi

  # Capture, then match with `case`: pipelines plus `grep -q` under pipefail
  # report a false failure when warp-cli dies on SIGPIPE.
  status=""
  for i in $(seq 1 30); do
    status="$(warp-cli --accept-tos status 2>&1 || true)"
    case "$status" in *Connected*) break ;; esac
    sleep 1
  done
  case "$status" in
    *Connected*) ;;
    *) say "WARP did not reach Connected after rotation"; return 1 ;;
  esac

  # A failed proxy-mode switch plus a successful connect would turn WARP into
  # a full tunnel and change the machine's routing. Refuse that combination.
  settings="$(warp-cli --accept-tos settings 2>&1 || true)"
  case "$settings" in
    *WarpProxy*|*[Mm]ode:*[Pp]roxy*) ;;
    *[Mm]ode:*)
      say "WARP is not in proxy mode after reconnect; disconnecting"
      warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
      return 1
      ;;
    *) : ;;   # unknown settings format; the proxy probe below is the real test
  esac

  # Status can say Connected before the local proxy accepts traffic. Reading
  # the egress IP also proves the new registration is carrying traffic instead
  # of the old tunnel staying connected.
  after_ip=""
  for i in $(seq 1 15); do
    if after_ip="$(egress_ip 2>/dev/null)"; then
      break
    fi
    sleep 1
  done
  if [ -z "$after_ip" ]; then
    say "proxy $PROXY is unreachable after rotation"
    return 1
  fi

  if [ -n "$before_ip" ] && [ "$after_ip" = "$before_ip" ]; then
    say "rotation did not change the WARP egress IP (still ${after_ip})"
    say "the new registration is not carrying traffic; the old tunnel is still in use"
    return 1
  fi

  say "new egress IP: $after_ip"
  return 0
}

# Live-session path used by the OpenCode plugin. It must not run a model probe:
# the session that is waiting for this rotation will retry the real request,
# and that retry is the throttle test. Reaching the local proxy is enough.
if [ "$ROTATE_ONLY" -eq 1 ]; then
  say "rotate-only: replacing the WARP registration"
  for attempt in $(seq 1 "$ATTEMPTS"); do
    say "rotation attempt ${attempt}/${ATTEMPTS}"
    if rotate_registration; then
      state_write last-rotated
      say "rotation complete; proxy ${PROXY} is reachable"
      exit 0
    fi
    say "rotation attempt ${attempt} failed"
    [ "$attempt" -lt "$ATTEMPTS" ] && sleep 2
  done

  state_write last-throttled
  say "could not rotate the WARP egress after ${ATTEMPTS} attempt(s)"
  exit 2
fi

rotated_ok=0
probe_out="$(mktemp "${TMPDIR:-/tmp}/opencode-warp-probe.XXXXXX")" || {
  say "cannot create a temporary file"
  exit 2
}
trap 'rm -f "$probe_out"' EXIT

if [ "$FORCE" -eq 0 ]; then
  say "checking the WARP ingress"
  probe_ingress "$probe_out"
  rc=$?

  case "$rc" in
    0)
      say "ingress is healthy; no rotation needed"
      state_write last-ok
      rm -f "$STATE_DIR/last-throttled" 2>/dev/null || true
      exit 0
      ;;
    1) : ;;
    3)
      # The WARP tunnel itself is resetting connections. That is exactly the
      # kind of broken ingress a fresh registration fixes, so rotate instead
      # of treating it as an unclassifiable failure.
      say "transport failure through WARP; rotating"
      ;;
    *)
      say "no verdict from probe.sh; not rotating"
      tail -8 "$probe_out" | sed 's/^/  /' >&2
      exit 2
      ;;
  esac

  state_write last-throttled
  say "ingress is throttled or failing"
fi

probe_failures=0
for attempt in $(seq 1 "$ATTEMPTS"); do
  say "rotation attempt ${attempt}/${ATTEMPTS}"
  if ! rotate_registration; then
    state_write last-throttled
    say "rotation attempt ${attempt} failed"
    [ "$attempt" -lt "$ATTEMPTS" ] && sleep 2
    continue
  fi

  say "probing the new ingress"
  probe_ingress "$probe_out"
  rc=$?
  case "$rc" in
    0) : ;;
    1) say "the new ingress is still throttled"; probe_failures=$((probe_failures + 1)) ;;
    3) say "the new ingress is resetting connections"; probe_failures=$((probe_failures + 1)) ;;
    *)
      say "no verdict after rotation; not retrying"
      tail -8 "$probe_out" | sed 's/^/  /' >&2
      state_write last-throttled
      exit 2
      ;;
  esac
  if [ "$rc" -eq 0 ]; then
    say "recovered: the new ingress passes"
    grep -E '^(ip|loc|warp)=' "$probe_out" 2>/dev/null | sed 's/^/  /' >&2 || true
    state_write last-ok
    rm -f "$STATE_DIR/last-throttled" 2>/dev/null || true
    rotated_ok=1
    break
  fi
done

if [ "$rotated_ok" -eq 1 ]; then
  exit 0
fi

state_write last-throttled
if [ "$probe_failures" -gt 0 ]; then
  say "the WARP ingress is still not passing after ${ATTEMPTS} rotation attempt(s)"
  tail -8 "$probe_out" | sed 's/^/  /' >&2
  exit 1
fi
say "could not rotate the WARP egress after ${ATTEMPTS} attempt(s)"
exit 2
