#!/usr/bin/env bash
set -Eeuo pipefail

API_URL="${1:-}"
SERVER_ID="${2:-}"
TOKEN="${3:-}"

[ -n "$API_URL" ] && [ -n "$SERVER_ID" ] && [ -n "$TOKEN" ] || { echo 'Usage: install.sh API_URL SERVER_ID NODE_TOKEN'; exit 2; }

install -d -m 700 /opt/darktunnel-node-agent /etc/darktunnel
curl -fsSL https://raw.githubusercontent.com/mnmdeveloper/darktunnel/main/node-agent/report.sh -o /opt/darktunnel-node-agent/report.sh
chmod 700 /opt/darktunnel-node-agent/report.sh
cat > /etc/darktunnel/node-agent.env <<EOF
DARKTUNNEL_API_URL=$API_URL
DARKTUNNEL_SERVER_ID=$SERVER_ID
DARKTUNNEL_NODE_TOKEN=$TOKEN
EOF
chmod 600 /etc/darktunnel/node-agent.env
cat > /etc/systemd/system/darktunnel-node-agent.service <<'EOF'
[Unit]
Description=DarkTunnel Node Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/darktunnel/node-agent.env
ExecStart=/opt/darktunnel-node-agent/report.sh
EOF
cat > /etc/systemd/system/darktunnel-node-agent.timer <<'EOF'
[Unit]
Description=DarkTunnel Node Agent Reporter

[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
Unit=darktunnel-node-agent.service

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now darktunnel-node-agent.timer
systemctl start darktunnel-node-agent.service
systemctl --no-pager --full status darktunnel-node-agent.timer | head -20
