#!/usr/bin/env bash
#
# setup.sh - install Cloudflare WARP (proxy mode) and the `opencode --stand`
#            shortcut on a Debian/Ubuntu machine.
#
# What this does:
#   1. adds Cloudflare's apt repo + keyring
#   2. installs cloudflare-warp
#   3. registers an ANONYMOUS device (no email, no account login)
#   4. sets WARP to *proxy* mode on 127.0.0.1:40000  (does NOT hijack routes)
#   5. installs /usr/local/bin/opencode-warp
#   6. adds the `opencode()` function to ~/.bashrc
#   7. verifies end to end
#
# Idempotent: safe to re-run. Existing registration/config is left in place.
#
set -euo pipefail

PORT="${WARP_PROXY_PORT:-40000}"
PROXY="http://127.0.0.1:${PORT}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
warn() { printf '    !  %s\n' "$*" >&2; }

# ---------------------------------------------------------------- preflight
[ "$(id -u)" -eq 0 ] || { printf 're-run as root (sudo ./setup.sh)\n' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive

command -v curl  >/dev/null || { printf 'curl is required\n' >&2; exit 1; }
command -v gpg   >/dev/null || { printf 'gnupg is required (apt install gnupg)\n' >&2; exit 1; }

if ! command -v opencode >/dev/null 2>&1 && [ ! -x "$HOME/.opencode/bin/opencode" ]; then
  warn "opencode not found on PATH or in ~/.opencode/bin."
  warn "The wrapper will be installed anyway; it resolves the binary at runtime."
fi

CODENAME="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")"
[ -n "$CODENAME" ] || CODENAME="$(lsb_release -cs 2>/dev/null || echo jammy)"

# ---------------------------------------------------------- 1+2. apt repo
say "Installing Cloudflare WARP (codename: ${CODENAME})"
install -d -m 0755 /usr/share/keyrings
curl -fsSL --max-time 60 https://pkg.cloudflareclient.com/pubkey.gpg \
  | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main" \
  > /etc/apt/sources.list.d/cloudflare-client.list
apt-get update -qq
apt-get install -y -qq cloudflare-warp
ok "cloudflare-warp $(warp-cli --version 2>/dev/null | head -1)"

# --------------------------------------------------------------- 3. service
say "Starting warp-svc"
systemctl enable --now warp-svc >/dev/null 2>&1 || systemctl start warp-svc
sleep 2
systemctl is-active --quiet warp-svc && ok "warp-svc active" || { warn "warp-svc failed to start"; exit 1; }

# --------------------------------------------------- 4. register + proxy mode
say "Registering device (anonymous, no email/account)"
if warp-cli --accept-tos registration show >/dev/null 2>&1; then
  ok "already registered - leaving existing registration intact"
else
  warp-cli --accept-tos registration new
  ok "registered"
fi

say "Setting WARP to proxy mode on 127.0.0.1:${PORT} (no route changes)"
warp-cli --accept-tos mode proxy
warp-cli --accept-tos set-mode proxy 2>/dev/null || true
warp-cli --accept-tos connect >/dev/null
# Two traps avoided here, both of which made this check report failure while
# WARP was in fact connected:
#
#  1. `cmd | grep -q X && break` under `set -e`: when status is still
#     "Connecting" the AND-list returns non-zero as the loop body's last
#     command, aborting the whole script.
#
#  2. `cmd | grep -q X` under `set -o pipefail`: grep -q exits as soon as it
#     matches, warp-cli then dies on SIGPIPE, and pipefail propagates that
#     non-zero -- so the `if` sees a FALSE even on an exact match.
#
# So: capture the output first and match it with `case`. No pipeline, no
# pipefail, no early-exit, no SIGPIPE.
connected=0
for _ in $(seq 1 30); do
  _status="$(warp-cli --accept-tos status 2>&1 || true)"
  case "$_status" in
    *Connected*) connected=1; break ;;
  esac
  sleep 2
done
if [ "$connected" -eq 1 ]; then
  ok "WARP connected"
else
  warn "WARP did not connect after waiting"
  warp-cli --accept-tos status 2>&1 || true
  exit 1
fi

# ------------------------------------------------------------ 5. the wrapper
say "Installing /usr/local/bin/opencode-warp"
install -m 0755 "${SCRIPT_DIR}/opencode-warp" /usr/local/bin/opencode-warp
ok "installed"

# ------------------------------------------------------------ 6. bashrc fn
say "Adding opencode() shortcut to ~/.bashrc"
touch ~/.bashrc
if grep -q '# >>> opencode-warp shortcut >>>' ~/.bashrc; then
  ok "already present - skipping"
else
  cp ~/.bashrc ~/.bashrc.bak.opencode-warp.$(date +%s)
  cat >> ~/.bashrc <<'EOF'

# >>> opencode-warp shortcut >>>
# `opencode --stand [args...]` routes opencode through WARP (127.0.0.1:40000)
# and adds --standalone. Without --stand it behaves like normal opencode.
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
  ok "added (a timestamped backup of ~/.bashrc was made)"
fi

# ----------------------------------------------------------------- 7. verify
say "Verifying"
if bash -n ~/.bashrc; then ok "~/.bashrc parses cleanly"; else warn "~/.bashrc has a syntax error"; fi

if curl -s --max-time 15 -x "$PROXY" https://api.ipify.org >/dev/null 2>&1; then
  ok "proxy reachable: $(curl -s --max-time 15 -x "$PROXY" https://api.ipify.org)"
else
  warn "proxy not reachable on ${PROXY}"
fi

printf '\n'
say "Done."
cat <<EOF
  Normal egress   : $(curl -s --max-time 15 https://api.ipify.org 2>/dev/null || echo '(unavailable)')
  Through WARP    : $(curl -s --max-time 15 -x "$PROXY" https://api.ipify.org 2>/dev/null || echo '(unavailable)')

  Start a new shell (or: source ~/.bashrc), then:

    opencode --stand run -m opencode/deepseek-v4.1-flash-free "hello"
    opencode-warp run -m <model> "hello"      # same thing, any shell
    opencode --stand                          # TUI through WARP

  NOTE: the 'run' subcommand is still required - --stand only injects
  --standalone, it does not invent the subcommand.
EOF
