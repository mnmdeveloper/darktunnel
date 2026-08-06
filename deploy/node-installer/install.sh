#!/usr/bin/env bash
set -Eeuo pipefail

ACTION="${1:-install-all}"
BRANCH="${DARKTUNNEL_BRANCH:-server-onboarding-v2}"
REPO_RAW="https://raw.githubusercontent.com/mnmdeveloper/darktunnel/$BRANCH"
AGENT_URL="$REPO_RAW/deploy/node-agent/node_agent.py"
AWG_INSTALLER_URL="$REPO_RAW/deploy/node-installer/install-awg2.sh"
WDTT_INSTALLER_URL="$REPO_RAW/deploy/node-installer/install-wdtt.sh"
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
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl python3 iproute2 openssl
}

public_host() {
  local value
  value="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$value" ] || value="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s' "$value"
}

read_existing() {
  python3 - "$CONFIG_PATH" "$1" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
if path.exists():
    try:
        print(json.loads(path.read_text()).get(sys.argv[2], ""))
    except Exception:
        pass
PY
}

prompt() {
  local label="$1" default="${2:-}" value
  if [ ! -r "$TTY" ]; then printf '%s' "$default"; return; fi
  if [ -n "$default" ]; then printf '%s [%s]: ' "$label" "$default" > "$TTY"; else printf '%s: ' "$label" > "$TTY"; fi
  IFS= read -r value < "$TTY"
  printf '%s' "${value:-$default}"
}

write_config() {
  local old_name old_country old_city old_host old_token
  old_name="$(read_existing name)"; old_country="$(read_existing country)"; old_city="$(read_existing city)"
  old_host="$(read_existing public_host)"; old_token="$(read_existing management_token)"
  local name country city host token node_id
  name="${DARKTUNNEL_NODE_NAME:-$(prompt 'Server name' "$old_name")}" 
  country="${DARKTUNNEL_COUNTRY:-$(prompt 'Country' "$old_country")}" 
  city="${DARKTUNNEL_CITY:-$(prompt 'City' "$old_city")}" 
  host="${DARKTUNNEL_PUBLIC_HOST:-$(prompt 'Public IP/domain' "${old_host:-$(public_host)}")}" 
  token="${DARKTUNNEL_MANAGEMENT_TOKEN:-${old_token:-$(openssl rand -hex 32)}}"
  node_id="$(read_existing node_id)"; [ -n "$node_id" ] || node_id="$(cat /proc/sys/kernel/random/uuid)"
  [ -n "$name" ] || fail "Server name is required"; [ -n "$country" ] || fail "Country is required"
  [ -n "$city" ] || fail "City is required"; [ -n "$host" ] || fail "Public IP/domain is required"
  install -m 700 -d "$CONFIG_DIR"
  python3 - "$CONFIG_PATH" "$node_id" "$name" "$country" "$city" "$host" "$token" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(json.dumps({"node_id":sys.argv[2],"name":sys.argv[3],"country":sys.argv[4],"city":sys.argv[5],"public_host":sys.argv[6],"management_token":sys.argv[7],"listen_host":"127.0.0.1","listen_port":8787}, ensure_ascii=False, indent=2)+"\n")
path.chmod(0o600)
PY
}

run_installer() {
  local url="$1" tmp
  tmp="$(mktemp)"
  curl -fsSL "$url" -o "$tmp"
  chmod 700 "$tmp"
  bash "$tmp"
  rm -f "$tmp"
}

install_awg_if_missing() {
  if command -v awg >/dev/null 2>&1 && find /etc/amnezia /etc/amneziawg /etc/wireguard -maxdepth 2 -name '*.conf' -print -quit 2>/dev/null | grep -q .; then
    log "Existing AmneziaWG detected; no changes made"
    return
  fi
  DARKTUNNEL_AWG_PORT="${DARKTUNNEL_AWG_PORT:-585}" run_installer "$AWG_INSTALLER_URL"
}

install_wdtt_if_missing() {
  if systemctl is-active --quiet wdtt.service || [ -s /etc/wdtt/wdtt.env ]; then
    log "Existing WDTT detected; no changes made"
    return
  fi
  [ -n "${DARKTUNNEL_VK_CALL_LINK:-}" ] || fail "DARKTUNNEL_VK_CALL_LINK is required to install WDTT"
  DARKTUNNEL_PUBLIC_HOST="${DARKTUNNEL_PUBLIC_HOST:-$(read_existing public_host)}" \
  DARKTUNNEL_WDTT_PORT="${DARKTUNNEL_WDTT_PORT:-56000}" \
  DARKTUNNEL_VK_CALL_LINK="$DARKTUNNEL_VK_CALL_LINK" \
  run_installer "$WDTT_INSTALLER_URL"
}

install_agent() {
  install -m 755 -d "$INSTALL_DIR"
  curl -fsSL "$AGENT_URL" -o "$INSTALL_DIR/node_agent.py"
  curl -fsSL "$REPO_RAW/deploy/node-installer/install.sh" -o "$INSTALL_DIR/install.sh"
  chmod 0755 "$INSTALL_DIR/node_agent.py" "$INSTALL_DIR/install.sh"
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
ReadOnlyPaths=-/etc/wdtt -/etc/wireguard -/etc/amnezia -/etc/amneziawg -/etc/darktunnel-node
ReadWritePaths=/run

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now darktunnel-node.service
}

show_status() {
  curl -fsS http://127.0.0.1:8787/health && echo
  local token; token="$(read_existing management_token)"
  [ -z "$token" ] || curl -fsS -H "Authorization: Bearer $token" http://127.0.0.1:8787/v1/status && echo
}

case "$ACTION" in
  install-all|install)
    install_packages
    write_config
    install_awg_if_missing
    install_wdtt_if_missing
    install_agent
    show_status
    ;;
  update)
    install_packages
    [ -f "$CONFIG_PATH" ] || write_config
    install_agent
    show_status
    ;;
  configure)
    write_config
    systemctl restart darktunnel-node.service
    show_status
    ;;
  status) show_status ;;
  *) fail "Usage: $0 {install-all|install|update|configure|status}" ;;
esac
