#!/usr/bin/env bash
#
# usque-rotate.sh - recover a throttled usque MASQUE ingress.
#
# Probes the current usque egress once. If the free tier is throttled, moves
# the usque registration aside, registers a new anonymous WARP account, starts
# usque-proxy.service again, and verifies the new registration id plus a
# reachable warp=on proxy. Repeats up to USQUE_ROTATE_ATTEMPTS times.
#
# This is the usque equivalent of warp-rotate.sh. The wrapper points both its
# launch-time preflight and the live 429 plugin at this script when usque is
# selected.
#
# Exit codes:  0 = healthy or recovered
#              1 = still throttled / still failing after all rotations
#              2 = no verdict (probe/service/registration failure)
#
# Options:     --force         rotate first, without probing the current ingress
#              --rotate-only   replace the registration and verify the proxy,
#                              but do not run a model probe (used by the
#                              real-time plugin during a live session)
#
# Environment:
#   USQUE_ROTATE_ATTEMPTS  rotation attempts (default 1)
#   USQUE_PROXY_PORT       usque proxy port (default: WARP_PROXY_PORT, then 40001)
#   USQUE_CONFIG           registration file (default /etc/usque/config.json)
#   USQUE_BIN              usque binary (default /usr/local/bin/usque, then PATH)
#   USQUE_SERVICE          systemd unit (default usque-proxy.service)
#   OPENCODE_WARP_PROBE    probe.sh path (default: next to this script,
#                          then /usr/local/lib/opencode-warp/probe.sh)
#   PROBE_MODE             api | cli | auto (default: cli here)
#   PROBE_MODEL            forwarded to probe.sh
#   PROBE_RUN              forwarded to probe.sh
#
# The registration contains a private key, license, and access token. It is
# kept outside this repository and is never printed by this script.
#
set -uo pipefail
umask 077

export PROBE_MODE="${PROBE_MODE:-cli}"

PORT="${USQUE_PROXY_PORT:-${WARP_PROXY_PORT:-40001}}"
PROXY="http://127.0.0.1:${PORT}"
CONFIG="${USQUE_CONFIG:-/etc/usque/config.json}"
SERVICE="${USQUE_SERVICE:-usque-proxy.service}"
ATTEMPTS="${USQUE_ROTATE_ATTEMPTS:-${WARP_ROTATE_ATTEMPTS:-1}}"
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/opencode-warp"
export WARP_PROXY_PORT="$PORT"

say()  { printf 'opencode-warp: %s\n' "$*" >&2; }
warn() { printf 'opencode-warp: warning: %s\n' "$*" >&2; }

# Registration and service management are privileged. Keep the rest of the
# script (probe, state, curl) running as the invoking user so the state files
# stay in that user's cache and the CLI probe uses that user's OpenCode config.
as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo -n -- "$@"
  fi
}

if [ "$(id -u)" -ne 0 ]; then
  if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; then
    say "usque rotation needs root; run as root or allow passwordless sudo"
    exit 2
  fi
fi

# Serialise concurrent rotations. Two registrations replacing each other would
# be worse than either one alone.
mkdir -p "$STATE_DIR" 2>/dev/null || true
if command -v flock >/dev/null 2>&1 && [ -d "$STATE_DIR" ]; then
  if exec 9>"$STATE_DIR/usque-rotate.lock"; then
    if ! flock -w 90 9; then
      say "another usque rotation is already in progress"
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
      sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      say "unknown option: $arg"
      exit 2
      ;;
  esac
done

# Show the egress that probe.sh recorded in its capture file. This runs for
# every probe, not just a successful one, so a still-throttled rotation can be
# checked against the previous IP/location instead of being a black box.
show_egress() {
  local label="$1" file="$2" ip loc warp
  ip="$(grep -m1 '^ip=' "$file" 2>/dev/null || true)"
  loc="$(grep -m1 '^loc=' "$file" 2>/dev/null || true)"
  warp="$(grep -m1 '^warp=' "$file" 2>/dev/null || true)"
  [ -n "$ip$loc$warp" ] || return 0
  printf 'opencode-warp: %s\n' "$label" >&2
  [ -n "$ip" ] && printf '  %s\n' "$ip" >&2
  [ -n "$loc" ] && printf '  %s\n' "$loc" >&2
  [ -n "$warp" ] && printf '  %s\n' "$warp" >&2
  return 0
}

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

find_usque() {
  local p="${USQUE_BIN:-}"
  if [ -n "$p" ] && [ -x "$p" ]; then printf '%s\n' "$p"; return 0; fi
  for p in /usr/local/bin/usque /usr/bin/usque; do
    if [ -x "$p" ]; then printf '%s\n' "$p"; return 0; fi
  done
  if command -v usque >/dev/null 2>&1; then
    command -v usque
    return 0
  fi
  return 1
}

PROBE=""
if [ "$ROTATE_ONLY" -eq 0 ]; then
  PROBE="$(find_probe)" || {
    say "cannot find probe.sh (set OPENCODE_WARP_PROBE)"
    exit 2
  }
fi

USQUE_BIN_PATH=""
if ! USQUE_BIN_PATH="$(find_usque)"; then
  say "cannot find the usque binary (set USQUE_BIN)"
  exit 2
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

# Read the public egress IP through the usque proxy. Cloudflare often assigns
# the same egress IP to different usque registrations in the same colo, so this
# is used for reporting, not as the rotation-success test.
egress_ip() {
  local ip trace
  command -v curl >/dev/null 2>&1 || return 1
  # Use Cloudflare's trace endpoint, not ipify: it reports the same address
  # family Cloudflare sees for the inference endpoint.
  trace="$(curl -s --max-time 5 -x "$PROXY" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)" || return 1
  case "$trace" in
    *warp=on*|*warp=plus*) ;;
    *) return 1 ;;
  esac
  ip="$(printf '%s\n' "$trace" | sed -n 's/^ip=//p' | head -1 | tr -d '[:space:]')"
  case "$ip" in
    ''|*[!0-9a-fA-F:.]*) return 1 ;;
  esac
  printf '%s\n' "$ip"
}

# The registration id changes when usque enrolls a new device. This is the
# reliable success signal for usque: the egress IP can stay the same.
config_id() {
  as_root cat "$1" 2>/dev/null \
    | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1
}

wait_for_proxy() {
  local i ip
  for i in $(seq 1 30); do
    # Do not gate on `systemctl is-active`: an unprivileged caller can read
    # the proxy even when systemd refuses to report unit state.
    if ip="$(egress_ip 2>/dev/null)"; then
      printf '%s\n' "$ip"
      return 0
    fi
    sleep 1
  done
  return 1
}

SERVICE_STOPPED=0
BACKUP=""

# Put the previous registration back and make sure the service is running.
# Called on registration/start failures and from the exit trap, so an
# interrupted rotation never leaves usque down or without a config.
restore_config() {
  local had_backup=0
  if [ -n "$BACKUP" ] && as_root test -f "$BACKUP"; then
    had_backup=1
    as_root systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    as_root rm -f "$CONFIG" 2>/dev/null || true
    if as_root cp -p "$BACKUP" "$CONFIG"; then
      as_root rm -f "$BACKUP" 2>/dev/null || true
      as_root chmod 600 "$CONFIG" 2>/dev/null || true
      say "restored the previous usque registration"
    else
      warn "could not restore $BACKUP; it was left in place"
    fi
  fi
  if [ "$had_backup" -eq 1 ] || [ "$SERVICE_STOPPED" -eq 1 ]; then
    if ! as_root systemctl start "$SERVICE" >/dev/null 2>&1; then
      warn "could not start $SERVICE"
    fi
  fi
  SERVICE_STOPPED=0
  BACKUP=""
}

cleanup() {
  restore_config
}
trap cleanup EXIT
trap 'exit 143' TERM INT HUP

rotate_registration() {
  local before_ip after_ip before_id after_id name

  command -v systemctl >/dev/null 2>&1 || { say "systemctl not found"; return 1; }

  if ! as_root test -f "$CONFIG"; then
    say "usque registration $CONFIG not found; run usque-setup.sh"
    return 1
  fi

  before_ip="$(egress_ip 2>/dev/null || true)"
  if [ -n "$before_ip" ]; then
    say "current egress IP: $before_ip"
  else
    warn "could not read the current egress IP; checking the new account instead"
  fi
  before_id="$(config_id "$CONFIG")"
  if [ -z "$before_id" ]; then
    warn "could not read the current usque registration id"
  fi

  say "stopping $SERVICE"
  if ! as_root systemctl stop "$SERVICE" >/dev/null 2>&1; then
    warn "systemctl stop returned non-zero; continuing"
  fi
  SERVICE_STOPPED=1

  BACKUP="${CONFIG}.rotate.$$"
  if ! as_root mv "$CONFIG" "$BACKUP"; then
    say "could not move $CONFIG aside"
    restore_config
    return 1
  fi

  name="$(hostname 2>/dev/null || echo opencode-warp)-opencode-warp"
  say "registering a new usque WARP account"
  # Clear proxy variables: the usque service is stopped, and a registration
  # request sent through the proxy would fail. usque writes the new file with
  # the restrictive umask above.
  if ! as_root env \
      -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
      -u http_proxy -u https_proxy -u all_proxy \
      "$USQUE_BIN_PATH" -c "$CONFIG" register -a -n "$name"; then
    say "usque registration failed"
    restore_config
    return 1
  fi
  if ! as_root chmod 600 "$CONFIG"; then
    warn "could not set mode 600 on $CONFIG"
  fi

  after_id="$(config_id "$CONFIG")"
  if [ -z "$after_id" ]; then
    say "could not read the new usque registration id"
    restore_config
    return 1
  fi
  if [ -n "$before_id" ] && [ "$after_id" = "$before_id" ]; then
    say "registration did not change the usque account id (still ${after_id})"
    restore_config
    return 1
  fi

  say "starting $SERVICE"
  if ! as_root systemctl start "$SERVICE"; then
    say "could not start $SERVICE after registration"
    restore_config
    return 1
  fi
  SERVICE_STOPPED=0

  after_ip="$(wait_for_proxy || true)"
  if [ -z "$after_ip" ]; then
    say "proxy $PROXY is unreachable after rotation"
    restore_config
    return 1
  fi

  as_root rm -f "$BACKUP" 2>/dev/null || true
  BACKUP=""
  if [ -n "$before_ip" ] && [ "$after_ip" = "$before_ip" ]; then
    # This is normal for usque: Cloudflare shares egress IPs between accounts
    # in the same colo. The new registration id plus a restarted, reachable
    # tunnel is the proof that the rotation took effect.
    say "egress IP is unchanged (${after_ip}); Cloudflare shares usque egress IPs"
  else
    say "new egress IP: $after_ip"
  fi
  say "new registration id: $after_id"
  return 0
}

# Live-session path used by the OpenCode plugin. It must not run a model probe:
# the session that is waiting for this rotation will retry the real request,
# and that retry is the throttle test. Reaching the local proxy is enough.
if [ "$ROTATE_ONLY" -eq 1 ]; then
  say "rotate-only: replacing the usque registration"
  for attempt in $(seq 1 "$ATTEMPTS"); do
    say "rotation attempt ${attempt}/${ATTEMPTS}"
    if rotate_registration; then
      state_write last-rotated
      # The retry that follows in the live session is the throttle test. Mark
      # the rotation itself as healthy so the next launch does not preflight
      # on a stale pre-rotation rate-limit log entry. A still-throttled retry
      # writes a newer log entry and triggers the next preflight normally.
      state_write last-ok
      rm -f "$STATE_DIR/last-throttled" 2>/dev/null || true
      say "rotation complete; proxy ${PROXY} is reachable"
      exit 0
    fi
    say "rotation attempt ${attempt} failed"
    [ "$attempt" -lt "$ATTEMPTS" ] && sleep 2
  done

  state_write last-throttled
  say "could not rotate the usque egress after ${ATTEMPTS} attempt(s)"
  exit 2
fi

rotated_ok=0
probe_out="$(mktemp "${TMPDIR:-/tmp}/opencode-warp-probe.XXXXXX")" || {
  say "cannot create a temporary file"
  exit 2
}
trap 'rm -f "$probe_out"; cleanup' EXIT

if [ "$FORCE" -eq 0 ]; then
  say "checking the usque ingress"
  probe_ingress "$probe_out"
  rc=$?
  show_egress "current ingress" "$probe_out"

  case "$rc" in
    0)
      say "ingress is healthy; no rotation needed"
      state_write last-ok
      rm -f "$STATE_DIR/last-throttled" 2>/dev/null || true
      exit 0
      ;;
    1) : ;;
    3)
      # The usque tunnel itself is resetting connections. That is exactly the
      # kind of broken ingress a fresh registration fixes, so rotate instead
      # of treating it as an unclassifiable failure.
      say "transport failure through usque; rotating"
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
  show_egress "new ingress (attempt ${attempt}/${ATTEMPTS})" "$probe_out"
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
  say "the usque ingress is still not passing after ${ATTEMPTS} rotation attempt(s)"
  tail -8 "$probe_out" | sed 's/^/  /' >&2
  exit 1
fi
say "could not rotate the usque egress after ${ATTEMPTS} attempt(s)"
exit 2
