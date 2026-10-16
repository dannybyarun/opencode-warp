#!/usr/bin/env bash
#
# uninstall.sh - remove the opencode-warp shortcut and (optionally) WARP.
#
#   ./uninstall.sh            remove wrapper + .bashrc block + apt repo
#   ./uninstall.sh --purge    also remove the cloudflare-warp package,
#                             the device registration, and warp-svc data
#
set -euo pipefail

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

say()  { printf '==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { printf 're-run as root (sudo ./uninstall.sh)\n' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------- wrapper
say "Removing /usr/local/bin/opencode-warp"
if [ -f /usr/local/bin/opencode-warp ]; then
  rm -f /usr/local/bin/opencode-warp
  ok "removed"
else
  ok "not present"
fi

# ----------------------------------------------------------------- bashrc
say "Removing the opencode() block from ~/.bashrc"
if [ -f ~/.bashrc ] && grep -q '# >>> opencode-warp shortcut >>>' ~/.bashrc; then
  # delete the marked block, markers included
  sed -i '/# >>> opencode-warp shortcut >>>/,/# <<< opencode-warp shortcut <<</d' ~/.bashrc
  ok "removed (timestamped backups made by setup.sh are left untouched)"
else
  ok "no block found"
fi

# ------------------------------------------------------------------- repo
say "Removing the Cloudflare apt repo"
if [ -f /etc/apt/sources.list.d/cloudflare-client.list ]; then
  rm -f /etc/apt/sources.list.d/cloudflare-client.list
  ok "removed"
else
  ok "not present"
fi

# ------------------------------------------------------------------ purge
if [ "$PURGE" -eq 1 ]; then
  say "Purging WARP"
  warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
  warp-cli --accept-tos registration delete >/dev/null 2>&1 || true
  systemctl disable --now warp-svc >/dev/null 2>&1 || true
  apt-get purge -y -qq cloudflare-warp 2>/dev/null || true
  apt-get autoremove -y -qq 2>/dev/null || true
  rm -rf /var/lib/cloudflare-warp
  rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  ok "package, registration and data removed"
else
  printf '\n  (WARP itself was left installed and connected.\n'
  printf '   Re-run with --purge to remove the package + device registration.)\n'
fi

say "Done. Open a new shell for the change to take effect."
