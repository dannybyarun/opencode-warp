#!/usr/bin/env bash
#
# usque-setup.sh - install the usque MASQUE HTTP proxy as a systemd service.
#
# usque is an open-source reimplementation of Cloudflare WARP's MASQUE mode.
# It egresses over IPv4, which avoids the official WARP IPv6 range that some
# providers flag. The proxy listens on 127.0.0.1:40001 by default and is used
# automatically by opencode-warp when it is running.
#
# The WARP registration is written to /etc/usque/config.json with mode 600.
# It is never stored in this repository.
#
# Idempotent: an existing config is kept, so re-running does not create a new
# WARP identity. Use USQUE_REREGISTER=1 to deliberately replace it.
#
set -euo pipefail

VERSION="${USQUE_VERSION:-v4.2.1}"
PORT="${USQUE_PROXY_PORT:-40001}"
BIND="${USQUE_BIND:-127.0.0.1}"
CONFIG_DIR="${USQUE_CONFIG_DIR:-/etc/usque}"
CONFIG="$CONFIG_DIR/config.json"
BIN="${USQUE_BIN:-/usr/local/bin/usque}"
SERVICE="/etc/systemd/system/usque-proxy.service"
WRAPPER="/usr/local/bin/opencode-usque"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY_HOST="$BIND"
if [ "$PROXY_HOST" = "0.0.0.0" ]; then
  PROXY_HOST=127.0.0.1
fi
PROXY="http://${PROXY_HOST}:${PORT}"

say()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  --uninstall|--purge)
    MODE=uninstall
    PURGE=0
    if [ "$1" = "--purge" ]; then
      PURGE=1
    fi
    ;;
  "")
    MODE=install
    PURGE=0
    ;;
  *)
    die "unknown option: $1 (use --uninstall or --purge)"
    ;;
esac

case "$(uname -s 2>/dev/null || echo unknown)" in
  Linux) ;;
  *) die "usque-setup.sh supports Linux only" ;;
esac

[ "$(id -u)" -eq 0 ] || die "re-run as root (sudo ./usque-setup.sh)"
command -v systemctl >/dev/null 2>&1 || die "systemd is required"
[ "$(cat /proc/1/comm 2>/dev/null || echo unknown)" = "systemd" ] \
  || die "PID 1 is not systemd; usque-proxy.service needs a systemd host"

if [ "$MODE" = "uninstall" ]; then
  say "Removing the usque service"
  systemctl disable --now usque-proxy.service >/dev/null 2>&1 || true
  rm -f "$SERVICE" "$WRAPPER"
  systemctl daemon-reload
  ok "service and opencode-usque removed"

  if [ "$PURGE" -eq 1 ]; then
    say "Removing the usque binary and registration"
    rm -f "$BIN"
    rm -rf "$CONFIG_DIR"
    ok "removed $BIN and $CONFIG_DIR"
  else
    printf '\n  Kept %s and %s.\n' "$CONFIG" "$BIN"
    printf '  Re-run with --purge to remove the binary and registration too.\n'
  fi
  exit 0
fi

command -v curl >/dev/null || die "curl is required"
command -v sha256sum >/dev/null || die "sha256sum is required"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l|armv7) ARCH=armv7 ;;
  armv6l|armv6) ARCH=armv6 ;;
  armv5l|armv5) ARCH=armv5 ;;
  mips64) ARCH=mips64 ;;
  mips) ARCH=mips ;;
  *) die "unsupported architecture: $ARCH" ;;
esac

case "$VERSION" in
  v*) ;;
  *) VERSION="v$VERSION" ;;
esac
ASSET="usque_${VERSION#v}_linux_${ARCH}.zip"
BASE="https://github.com/Diniboy1123/usque/releases/download/${VERSION}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/usque-setup.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

say "Downloading usque ${VERSION} (${ARCH})"
curl -fsSL --max-time 120 -o "$TMP/$ASSET" "$BASE/$ASSET" \
  || die "download failed: $BASE/$ASSET"
curl -fsSL --max-time 60 -o "$TMP/checksums.txt" "$BASE/checksums.txt" \
  || die "could not download checksums.txt"

EXPECTED="$(awk -v a="$ASSET" '$2 == a { print $1; exit }' "$TMP/checksums.txt")"
[ -n "$EXPECTED" ] || die "no checksum for $ASSET"
ACTUAL="$(sha256sum "$TMP/$ASSET" | awk '{print $1}')"
[ "$EXPECTED" = "$ACTUAL" ] || die "checksum mismatch for $ASSET"
ok "checksum verified"

if command -v unzip >/dev/null 2>&1; then
  unzip -q -o "$TMP/$ASSET" -d "$TMP/extract"
elif command -v python3 >/dev/null 2>&1; then
  mkdir -p "$TMP/extract"
  python3 -m zipfile -e "$TMP/$ASSET" "$TMP/extract"
else
  die "unzip or python3 is required"
fi
[ -f "$TMP/extract/usque" ] || die "usque binary not found in the archive"
install -m 0755 "$TMP/extract/usque" "$BIN"
ok "installed $BIN"

say "Preparing the WARP registration"
install -d -m 0750 "$CONFIG_DIR"
if [ -f "$CONFIG" ] && [ "${USQUE_REREGISTER:-0}" != "1" ]; then
  ok "keeping existing $CONFIG"
else
  if [ -f "$CONFIG" ]; then
    say "Re-registering at the request of USQUE_REREGISTER=1"
    rm -f "$CONFIG"
  fi
  "$BIN" -c "$CONFIG" register -a -n "$(hostname 2>/dev/null || echo opencode-warp)-opencode-warp"
  ok "registered a new WARP account"
fi
chmod 600 "$CONFIG"

say "Installing the systemd service"
sed \
  -e "s|@USQUE_BIN@|$BIN|g" \
  -e "s|@USQUE_CONFIG@|$CONFIG|g" \
  -e "s|@USQUE_BIND@|$BIND|g" \
  -e "s|@USQUE_PORT@|$PORT|g" \
  "$SCRIPT_DIR/usque-proxy.service.in" >"$SERVICE"
chmod 0644 "$SERVICE"
systemctl daemon-reload

if command -v pgrep >/dev/null 2>&1 \
   && pgrep -x usque >/dev/null 2>&1 \
   && ! systemctl is-active --quiet usque-proxy.service 2>/dev/null; then
  say "Stopping an existing manual usque process"
  pkill -x usque || true
  sleep 1
fi

systemctl enable usque-proxy.service >/dev/null 2>&1 || true
if ! systemctl restart usque-proxy.service; then
  systemctl status usque-proxy.service --no-pager -n 20 >&2 || true
  die "could not start usque-proxy.service"
fi
ok "usque-proxy.service enabled on ${BIND}:${PORT}"

say "Installing opencode-usque"
install -m 0755 "$SCRIPT_DIR/opencode-usque" "$WRAPPER"
ok "installed $WRAPPER"

say "Waiting for the proxy"
READY=0
for _ in $(seq 1 30); do
  TRACE="$(curl -s --max-time 2 -x "$PROXY" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
  case "$TRACE" in
    *warp=on*)
      READY=1
      break
      ;;
  esac
  sleep 1
done
if [ "$READY" -ne 1 ]; then
  systemctl status usque-proxy.service --no-pager -n 20 >&2 || true
  die "usque proxy did not become reachable on $PROXY"
fi
ok "proxy reachable"

TRACE="$(curl -s --max-time 10 -x "$PROXY" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
IP="$(printf '%s\n' "$TRACE" | sed -n 's/^ip=//p' | head -1)"
COLO="$(printf '%s\n' "$TRACE" | sed -n 's/^colo=//p' | head -1)"
printf '    egress: %s (colo %s, warp=on)\n' "${IP:-?}" "${COLO:-?}"

printf '\n'
say "Done."
cat <<EOF
  usque is running on ${PROXY}.

  opencode-warp auto-detects it, so the normal command works unchanged:

    opencode --stand run -m opencode/deepseek-v4.1-flash-free "hello"

  Force usque in any shell:

    opencode-usque run -m opencode/deepseek-v4.1-flash-free "hello"

  Config: ${CONFIG} (mode 600) - never commit it.
  Logs:   journalctl -u usque-proxy.service -f
EOF
