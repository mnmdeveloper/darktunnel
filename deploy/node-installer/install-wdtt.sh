#!/usr/bin/env bash
set -Eeuo pipefail

VK_LINK="${DARKTUNNEL_VK_CALL_LINK:-}"
PUBLIC_HOST="${DARKTUNNEL_PUBLIC_HOST:-}"
PUBLIC_PORT="${DARKTUNNEL_WDTT_PORT:-56000}"
META_DIR="/etc/darktunnel-node"
META_PATH="$META_DIR/wdtt.json"

log() { printf '[DarkTunnel WDTT] %s\n' "$*"; }
fail() { printf '[DarkTunnel WDTT] ERROR: %s\n' "$*" >&2; exit 1; }

[ "${EUID}" -eq 0 ] || fail "Run as root"

if systemctl is-active --quiet wdtt.service || [ -s /etc/wdtt/wdtt.env ]; then
  log "Existing WDTT installation detected; leaving it unchanged"
  exit 0
fi

[ -n "$VK_LINK" ] || fail "DARKTUNNEL_VK_CALL_LINK is required"
case "$VK_LINK" in
  https://vk.ru/*|https://vk.com/*|https://vk.me/*) ;;
  *) fail "Invalid VK Call link" ;;
esac

if [ -z "$PUBLIC_HOST" ]; then
  PUBLIC_HOST="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
fi
[ -n "$PUBLIC_HOST" ] || fail "Public host could not be detected"

if ss -lunH | awk '{print $5}' | grep -Eq "(^|:)$PUBLIC_PORT$"; then
  fail "UDP port $PUBLIC_PORT is already occupied"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl openssl iproute2

SECRET="$(openssl rand -base64 36 | tr -d '\n')"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsSL -o "$TMP" https://raw.githubusercontent.com/XXcipherX/vkturn-vps-setup/main/install.sh
chmod 700 "$TMP"
"$TMP" install --password "$SECRET" --host "$PUBLIC_HOST" --vk-link "$VK_LINK"

systemctl is-active --quiet wdtt.service || fail "wdtt.service is not active"
ip link show wdtt0 >/dev/null 2>&1 || fail "wdtt0 interface is missing"
ss -lunH | awk '{print $5}' | grep -Eq "(^|:)$PUBLIC_PORT$" || fail "WDTT UDP port is not listening"

install -m 700 -d "$META_DIR"
python3 - "$META_PATH" "$PUBLIC_HOST" "$PUBLIC_PORT" "$SECRET" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(json.dumps({
    "public_host": sys.argv[2],
    "port": int(sys.argv[3]),
    "password": sys.argv[4],
    "service": "wdtt.service",
    "interface": "wdtt0",
}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
path.chmod(0o600)
PY
log "WDTT/VK Turn installed on UDP $PUBLIC_PORT"
