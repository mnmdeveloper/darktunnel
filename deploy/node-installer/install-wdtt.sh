#!/usr/bin/env bash
set -Eeuo pipefail

PUBLIC_HOST="${DARKTUNNEL_PUBLIC_HOST:-}"
PUBLIC_PORT="${DARKTUNNEL_WDTT_PORT:-56000}"
META_DIR="/etc/darktunnel-node"
META_PATH="$META_DIR/wdtt.json"
ENV_PATH="/etc/wdtt/wdtt.env"

log() { printf '[DarkTunnel WDTT] %s\n' "$*"; }
fail() { printf '[DarkTunnel WDTT] ERROR: %s\n' "$*" >&2; exit 1; }

[ "${EUID}" -eq 0 ] || fail "Run as root"

read_env() {
  local key="$1"
  [ -s "$ENV_PATH" ] || return 0
  sed -n "s/^${key}=//p" "$ENV_PATH" | tail -n 1 | tr -d '\r' | sed "s/^['\"]//;s/['\"]$//"
}

udp_listening() {
  ss -lunH | awk '{print $5}' | grep -Eq "(^|:|\])${PUBLIC_PORT}$"
}

write_metadata() {
  local secret="$1"
  install -m 700 -d "$META_DIR"
  python3 - "$META_PATH" "$PUBLIC_HOST" "$PUBLIC_PORT" "$secret" <<'PY'
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
}

if [ -z "$PUBLIC_HOST" ]; then
  PUBLIC_HOST="$(read_env WDTT_PUBLIC_HOST)"
fi
if [ -z "$PUBLIC_HOST" ]; then
  PUBLIC_HOST="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
fi
[ -n "$PUBLIC_HOST" ] || fail "Public host could not be detected"

existing_port="$(read_env WDTT_DTLS_PORT)"
[ -z "$existing_port" ] || PUBLIC_PORT="$existing_port"

if systemctl is-active --quiet wdtt.service && udp_listening; then
  secret="$(read_env WDTT_PASSWORD)"
  [ -n "$secret" ] && write_metadata "$secret"
  log "Existing WDTT installation is active on UDP $PUBLIC_PORT; leaving it unchanged"
  exit 0
fi

if udp_listening; then
  fail "UDP port $PUBLIC_PORT is already occupied"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl openssl iproute2 python3

SECRET="$(openssl rand -hex 32)"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsSL -o "$TMP" https://raw.githubusercontent.com/XXcipherX/vkturn-vps-setup/main/install.sh
chmod 700 "$TMP"

"$TMP" install \
  --password "$SECRET" \
  --host "$PUBLIC_HOST" \
  --dtls-port "$PUBLIC_PORT"

for _ in $(seq 1 30); do
  if systemctl is-active --quiet wdtt.service && ip link show wdtt0 >/dev/null 2>&1 && udp_listening; then
    write_metadata "$SECRET"
    log "WDTT/VK Turn installed on UDP $PUBLIC_PORT"
    exit 0
  fi
  sleep 1
done

systemctl status wdtt.service --no-pager -l >&2 || true
ss -lunp >&2 || true
fail "WDTT did not become ready within 30 seconds"
