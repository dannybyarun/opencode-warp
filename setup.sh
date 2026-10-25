#!/usr/bin/env bash
#
# setup.sh - install Cloudflare WARP (proxy mode), opencode if missing, and
#            the `opencode --stand` shortcut.
#
# Supported distros (official Cloudflare packages):
#   - Debian / Ubuntu / Raspbian              -> .deb
#   - RHEL / Rocky / Alma / CentOS / Fedora   -> .rpm
#     / Oracle Linux
#
# Hard requirements: root, /dev/net/tun, systemd as PID 1. Containers almost
# always lack one or both, so they are rejected with an explanation rather
# than failing halfway through.
#
# Idempotent: safe to re-run.
#
set -euo pipefail

PORT="${WARP_PROXY_PORT:-40000}"
PROXY="http://127.0.0.1:${PORT}"
OPENCODE_INSTALL_URL="https://opencode.ai/v2/install"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "re-run as root (sudo ./setup.sh)"
export DEBIAN_FRONTEND=noninteractive

command -v curl >/dev/null || die "curl is required"
command -v gpg  >/dev/null || die "gnupg is required (apt install gnupg / dnf install gnupg2)"

# ------------------------------------------------------------- environment
say "Checking environment"
[ -e /dev/net/tun ] \
  && ok "/dev/net/tun present" \
  || die "/dev/net/tun is missing.
  WARP needs a TAP/TUN device. In a container this usually means it was not
  created with --device /dev/net/tun (and --cap-add NET_ADMIN). This tool is
  unlikely to work inside a container."

PID1="$(cat /proc/1/comm 2>/dev/null || echo unknown)"
if [ "$PID1" != "systemd" ]; then
  die "PID 1 is '$PID1', not systemd.
  warp-svc is a systemd service; WARP will not start without systemd.
  Use a VM or a systemd-enabled container."
fi
ok "systemd is PID 1"

if [ -e /.dockerenv ] || [ -e /run/.containerenv ] \
   || grep -qaE 'docker|lxc|kubepods|containerd' /proc/1/cgroup 2>/dev/null; then
  printf '    !  container detected - continuing because tun+systemd both passed,\n'
  printf '       but expect this to be unusual.\n'
fi

# --------------------------------------------------------- distro detection
say "Detecting distro"
FAMILY=""
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  _probe=" ${ID:-} ${ID_LIKE:-} "
  case "$_probe" in
    *debian*|*ubuntu*|*raspbian*) FAMILY=deb ;;
    *rhel*|*fedora*|*centos*|*rocky*|*almalinux*|*" oracle "*) FAMILY=rpm ;;
  esac
  ok "ID=${ID:-?} ID_LIKE=${ID_LIKE:-<none>} -> family=${FAMILY:-unsupported}"
else
  die "/etc/os-release not readable; cannot detect distro"
fi

[ -n "$FAMILY" ] || die "Unsupported distro ('${ID:-unknown}').
  Official packages exist only for Debian/Ubuntu (.deb) and RHEL-family (.rpm).
  On Arch/openSUSE/Alpine/macOS/Windows, install Cloudflare WARP yourself,
  ensure it is in proxy mode on 127.0.0.1:${PORT}, then run:
      ./setup.sh --skip-warp-package"

SKIP_PACKAGE=0
[ "${1:-}" = "--skip-warp-package" ] && SKIP_PACKAGE=1

# ------------------------------------------------------------ WARP package
if [ "$SKIP_PACKAGE" -eq 0 ]; then
  if [ "$FAMILY" = "deb" ]; then
    say "Installing Cloudflare WARP (.deb)"
    install -d -m 0755 /usr/share/keyrings
    curl -fsSL --max-time 60 https://pkg.cloudflareclient.com/pubkey.gpg \
      | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    CODENAME="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo stable)}"
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main" \
      > /etc/apt/sources.list.d/cloudflare-client.list
    apt-get update -qq
    apt-get install -y -qq cloudflare-warp
  else
    say "Installing Cloudflare WARP (.rpm)"
    curl -fsSL --max-time 60 https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo \
      -o /etc/yum.repos.d/cloudflare-warp.repo
    if command -v dnf >/dev/null; then dnf install -y -q cloudflare-warp
    else yum install -y -q cloudflare-warp
    fi
  fi
  ok "installed: $(warp-cli --version 2>/dev/null | head -1)"
else
  say "Skipping WARP package install (--skip-warp-package)"
fi

command -v warp-cli >/dev/null || die "warp-cli not found on PATH"

# ------------------------------------------------------------------ service
say "Starting warp-svc"
systemctl enable --now warp-svc >/dev/null 2>&1 || systemctl start warp-svc
sleep 2
systemctl is-active --quiet warp-svc && ok "warp-svc active" || die "warp-svc failed to start"

# ------------------------------------------------------- register + proxy mode
say "Registering device (anonymous, no email/account)"
if warp-cli --accept-tos registration show >/dev/null 2>&1; then
  ok "already registered - leaving existing registration intact"
else
  warp-cli --accept-tos registration new >/dev/null
  ok "registered"
fi

say "Setting WARP to proxy mode on 127.0.0.1:${PORT} (no route changes)"
warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
warp-cli --accept-tos set-mode proxy >/dev/null 2>&1 || true
warp-cli --accept-tos connect >/dev/null 2>&1 || true

# NOTE: two traps avoided below, both of which made this check report failure
# while WARP was in fact connected:
#   1. `cmd | grep -q X && break` under `set -e` aborts the script when status
#      is still "Connecting", because the AND-list returns non-zero.
#   2. `cmd | grep -q X` under `set -o pipefail`: grep -q exits on first match,
#      warp-cli dies on SIGPIPE, and pipefail propagates that non-zero - so an
#      exact match still evaluates false.
# Hence: capture first, match with `case`. No pipeline at all.
connected=0
for _ in $(seq 1 30); do
  _status="$(warp-cli --accept-tos status 2>&1 || true)"
  case "$_status" in
    *Connected*) connected=1; break ;;
  esac
  sleep 2
done
[ "$connected" -eq 1 ] || { die "WARP did not connect after waiting"; }
ok "WARP connected"

# -------------------------------------------------------------- opencode
say "Checking opencode"
find_opencode() {
  local p
  p="$(command -v opencode 2>/dev/null || true)"
  if [ -n "$p" ] && [ -x "$p" ]; then printf '%s' "$p"; return 0; fi
  for p in "$HOME/.opencode/bin/opencode" /root/.opencode/bin/opencode; do
    if [ -x "$p" ]; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

if OC="$(find_opencode)"; then
  ok "found at $OC"
  FRESH_INSTALL=0
else
  say "opencode not found - installing from the official installer"
  tmp="$(mktemp)"
  curl -fsSL --max-time 120 "$OPENCODE_INSTALL_URL" -o "$tmp"
  # Refuse to execute anything that is not plainly a bash script. curl|bash
  # would happily run an HTML error page.
  head -1 "$tmp" | grep -q '^#!.*bash' \
    || { rm -f "$tmp"; die "downloaded installer is not a bash script; refusing to run it"; }
  bash "$tmp" || { rm -f "$tmp"; die "opencode installer failed"; }
  rm -f "$tmp"
  hash -r
  OC="$(find_opencode)" || die "opencode installer ran but no binary was found"
  ok "installed at $OC"
  FRESH_INSTALL=1
fi

OPCODE_VERSION="$("$OC" --version 2>/dev/null | head -1 || echo unknown)"
ok "version: $OPCODE_VERSION"

# The V2 installer should always produce OpenCode 2. If it did not, fail
# loudly: `serve`/`--server` and the v2 API route do not exist in OpenCode 1.
# An existing v1 is left alone, but the user is told what will not work.
_oc_version="${OPCODE_VERSION##* }"
_oc_version="${_oc_version#v}"
_oc_major="${_oc_version%%.*}"
case "$_oc_major" in
  ''|*[!0-9]*) _oc_major=0 ;;
esac
if [ "$_oc_major" -lt 2 ]; then
  if [ "$FRESH_INSTALL" -eq 1 ]; then
    die "the installer produced $OPCODE_VERSION, not OpenCode 2.
  The serve/API modes need OpenCode 2. Check:
      https://opencode.ai/v2/install"
  fi
  printf '    !  OpenCode 1 detected (%s); serve/API mode needs OpenCode 2.\n' "$OPCODE_VERSION"
  printf '       upgrade with: %s upgrade --major\n' "$OC"
fi

# --------------------------------------------------- version resilience
# The wrapper depends on `--standalone`. If a future opencode drops it the
# wrapper would silently stop using the proxy and burn the normal quota, so
# refuse to continue instead of degrading quietly.
say "Verifying the wrapper's required flags still exist"
_run_help="$("$OC" run --help 2>&1 || true)"
case "$_run_help" in
  *--standalone*) ok "'run --standalone' available" ;;
  *) die "This opencode version does not support 'run --standalone'.
  The wrapper relies on it for run/TUI sessions, and without it proxy env vars
  would be ignored silently (the background service makes the actual inference
  calls).
  opencode version: $OPCODE_VERSION" ;;
esac

# ---------------------------------------------------------------- wrapper
say "Installing /usr/local/bin/opencode-warp"
install -m 0755 "${SCRIPT_DIR}/opencode-warp" /usr/local/bin/opencode-warp
ok "installed"

# The wrapper looks for these next to itself, then in this lib directory.
# probe.sh has to be installed too: the preflight uses it to decide whether
# the ingress is throttled before doing anything destructive.
say "Installing probe.sh and warp-rotate.sh"
install -d -m 0755 /usr/local/lib/opencode-warp
install -m 0755 "${SCRIPT_DIR}/probe.sh" /usr/local/lib/opencode-warp/probe.sh
install -m 0755 "${SCRIPT_DIR}/warp-rotate.sh" /usr/local/lib/opencode-warp/warp-rotate.sh
ok "installed in /usr/local/lib/opencode-warp"

# OpenCode discovers direct .ts files under <config>/plugins automatically.
# The plugin is inert unless it sees the wrapper's local proxy env, so it is
# safe to leave installed for normal (non-WARP) sessions.
say "Installing the live 429-recovery plugin"
PLUGIN_DIR="${OPENCODE_WARP_PLUGIN_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins}"
install -d -m 0755 "$PLUGIN_DIR"
install -m 0644 "${SCRIPT_DIR}/opencode-warp-rotate.ts" "$PLUGIN_DIR/opencode-warp-rotate.ts"
ok "installed in $PLUGIN_DIR"

# ---------------------------------------------------------------- bashrc fn
say "Adding opencode() shortcut to ~/.bashrc"
touch ~/.bashrc
if grep -q '# >>> opencode-warp shortcut >>>' ~/.bashrc; then
  ok "already present - skipping"
else
  cp ~/.bashrc ~/.bashrc.bak.opencode-warp.$(date +%s)
  cat >> ~/.bashrc <<'EOF'

# >>> opencode-warp shortcut >>>
# `opencode --stand [args...]` routes opencode through WARP (127.0.0.1:40000).
# run/TUI sessions get --standalone; `serve` and `--server` do not.
opencode() {
  if [ "${1:-}" = "--stand" ]; then
    shift
    opencode-warp "$@"
    return $?
  fi
  command opencode "$@"
}
# <<< opencode-warp shortcut <<<
EOF
  ok "added (timestamped backup of ~/.bashrc made)"
fi

# ------------------------------------------------------------------- verify
say "Verifying"
bash -n ~/.bashrc && ok "~/.bashrc parses cleanly" || die "~/.bashrc has a syntax error"

_warp_ip="$(curl -s --max-time 15 -x "$PROXY" https://api.ipify.org 2>/dev/null || true)"
_direct_ip="$(curl -s --max-time 15 https://api.ipify.org 2>/dev/null || true)"
[ -n "$_warp_ip" ] || die "proxy not reachable on ${PROXY}"
ok "proxy reachable"

printf '\n'
say "Done."
cat <<EOF
  Normal egress   : ${_direct_ip:-?}
  Through WARP    : ${_warp_ip:-?}

  Start a new shell (or run: source ~/.bashrc) before using --stand.

  "opencode --stand" is a shell function, not an opencode flag. If it is not
  loaded yet, opencode itself reports "Unrecognized flag: --stand".

    opencode --stand run -m opencode/deepseek-v4.1-flash-free "hello"
    opencode-warp run -m <model> "hello"      # same thing, any shell
    opencode --stand                          # TUI through WARP
    opencode --stand serve --port 4096        # API-only server through WARP
    opencode --stand run --server <url> ...   # client for an existing server

  serve prints a password; set OPENCODE_PASSWORD when connecting clients
  with an explicit --server URL.

  If opencode's log shows a recent rate-limit error, --stand first checks the
  WARP ingress and rotates the anonymous registration when it is throttled:

    WARP_ROTATE_ATTEMPTS=2 opencode --stand   # retries (default 2)
    OPENCODE_WARP_AUTO_ROTATE=0 opencode ...  # disable auto-rotation
    OPENCODE_WARP_FORCE_PROBE=1 opencode ...  # check even without a log hint

  Manual check / recovery, useful in any shell:

    /usr/local/lib/opencode-warp/probe.sh
    /usr/local/lib/opencode-warp/warp-rotate.sh

  A live 429 plugin was installed for --stand sessions:

    ${PLUGIN_DIR}/opencode-warp-rotate.ts

  NOTE: the 'run' subcommand is still required for one-shot prompts; --stand
  only adds --standalone (except for serve/--server, which must not get it).
EOF
