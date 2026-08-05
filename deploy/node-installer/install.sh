#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-install}"
REPO_RAW="https://raw.githubusercontent.com/mnmdeveloper/darktunnel/${DARKTUNNEL_BRANCH:-main}"
AGENT_URL="$REPO_RAW/deploy/node-agent/node_agent.py"
INSTALL_DIR="/opt/darktunnel-node"
CONFIG_DIR="/etc/darktunnel-node"
CONFIG_PATH="$CONFIG_DIR/node.json"
SERVICE_PATH="/etc/systemd/system/darktunnel-node.service"
TTY="/dev/tty"

log() { printf '[DarkTunnel] %s\n' "$*"; }
fail() { printf '[DarkTunnel] ERROR: %s\n' "$*" >&2; exit 1; }

[ "${EUID}" -eq 0 ] || fail "Run with sudo/root"
command -v systemctl >/dev/null 2>&1 || fail "systemd is required"

install_packages() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl python3 iproute2 wireguard-tools openssl
}

public_host() {
  local value
  value="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$value" ]; then
    value="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "$value"
}

read_existing() {
  python3 - "$CONFIG_PATH" "$1" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
if path.exists():
    try:
        print(json.loads(path.read_text()).get(key, ""))
    except Exception:
        pass
PY
}

prompt() {
  local label="$1" default="${2:-}" value
  if [ ! -r "$TTY" ]; then
    printf '%s' "$default"
    return
  fi
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$label" "$default" > "$TTY"
  else
    printf '%s: ' "$label" > "$TTY"
  fi
  IFS= read -r value < "$TTY"
  printf '%s' "${value:-$default}"
}

write_config() {
  local old_name old_country old_city old_host old_token
  old_name="$(read_existing name)"
  old_country="$(read_existing country)"
  old_city="$(read_existing city)"
  old_host="$(read_existing public_host)"
  old_token="$(read_existing management_token)"

  local name country city host token node_id
  name="${DARKTUNNEL_NODE_NAME:-$(prompt 'Server name' "$old_name")}" 
  country="${DARKTUNNEL_COUNTRY:-$(prompt 'Country' "$old_country")}" 
  city="${DARKTUNNEL_CITY:-$(prompt 'City' "$old_city")}" 
  host="${DARKTUNNEL_PUBLIC_HOST:-$(prompt 'Public IP/domain' "${old_host:-$(public_host)}")}" 
  token="${DARKTUNNEL_MANAGEMENT_TOKEN:-${old_token:-$(openssl rand -hex 32)}}"
  node_id="$(read_existing node_id)"
  [ -n "$node_id" ] || node_id="$(cat /proc/sys/kernel/random/uuid)"

  [ -n "$name" ] || fail "Server name is required"
  [ -n "$country" ] || fail "Country is required"
  [ -n "$city" ] || fail "City is required"
  [ -n "$host" ] || fail "Public IP/domain is required"

  install -m 700 -d "$CONFIG_DIR"
  python3 - "$CONFIG_PATH" "$node_id" "$name" "$country" "$city" "$host" "$token" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
payload = {
    "node_id": sys.argv[2],
    "name": sys.argv[3],
    "country": sys.argv[4],
    "city": sys.argv[5],
    "public_host": sys.argv[6],
    "management_token": sys.argv[7],
    "listen_host": "127.0.0.1",
    "listen_port": 8787,
}
path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
path.chmod(0o600)
PY
}

install_agent() {
  install -m 755 -d "$INSTALL_DIR"
  curl -fsSL "$AGENT_URL" -o "$INSTALL_DIR/node_agent.py"
  chmod 0755 "$INSTALL_DIR/node_agent.py"

  cat > "$SERVICE_PATH" <<'UNIT'
[Unit]
Description=DarkTunnel VPN node discovery agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/darktunnel-node/node_agent.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/etc/wdtt /etc/wireguard /etc/amnezia /etc/amneziawg
ReadWritePaths=/run

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now darktunnel-node.service
}

show_status() {
  systemctl --no-pager --full status darktunnel-node.service || true
  curl -fsS http://127.0.0.1:8787/health && echo
  local token
  token="$(read_existing management_token)"
  if [ -n "$token" ]; then
    curl -fsS -H "Authorization: Bearer $token" http://127.0.0.1:8787/v1/status && echo
  fi
}

case "$ACTION" in
  install)
    install_packages
    write_config
    install_agent
    log "Node installed without changing existing AWG/WDTT configuration."
    show_status
    ;;
  update)
    install_packages
    [ -f "$CONFIG_PATH" ] || write_config
    install_agent
    log "Node agent updated. Existing VPN transports were not restarted."
    show_status
    ;;
  configure)
    write_config
    systemctl restart darktunnel-node.service
    show_status
    ;;
  status)
    show_status
    ;;
  *)
    fail "Usage: $0 {install|update|configure|status}"
    ;;
esac
