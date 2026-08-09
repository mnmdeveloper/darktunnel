#!/usr/bin/env bash
set -Eeuo pipefail

: "${DARKTUNNEL_API_URL:?DARKTUNNEL_API_URL is required}"
: "${DARKTUNNEL_SERVER_ID:?DARKTUNNEL_SERVER_ID is required}"
: "${DARKTUNNEL_NODE_TOKEN:?DARKTUNNEL_NODE_TOKEN is required}"

hostname_value="$(hostname 2>/dev/null || true)"
agent_version="0.1.0"
wdtt_active=0
wdtt_port=""
wdtt_interface=""
wdtt_version=""
wdtt_healthy=0
vkturn_detected=0
vkturn_healthy=0
vkturn_port=56100
vkturn_version=""
vkturn_details='{}'

if systemctl is-active --quiet wdtt 2>/dev/null; then wdtt_active=1; wdtt_healthy=1; fi
if ip link show wdtt0 >/dev/null 2>&1; then wdtt_interface="wdtt0"; fi
if ss -lun 2>/dev/null | grep -Eq '(^|:)56000[[:space:]]'; then wdtt_port=56000; fi
if command -v wdtt-server >/dev/null 2>&1; then wdtt_version="$(wdtt-server --version 2>/dev/null | head -1 || true)"; fi

if command -v docker >/dev/null 2>&1; then
  if docker ps --format '{{.Names}} {{.Command}}' 2>/dev/null | grep -Eq 'vkturn|vk-turn-proxy'; then
    vkturn_detected=1
    vkturn_healthy=1
  fi
fi
if ss -lun 2>/dev/null | grep -Eq '(^|:)56100[[:space:]]'; then vkturn_detected=1; vkturn_healthy=1; fi
if ss -ltn 2>/dev/null | grep -Eq '(^|:)56100[[:space:]]'; then vkturn_detected=1; vkturn_healthy=1; fi

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }
json_string() { printf '%s' "$1" | json_escape; }

payload=$(cat <<JSON
{
  "hostname": $(json_string "$hostname_value"),
  "agent_version": $(json_string "$agent_version"),
  "transports": [
    {"type":"wdtt","enabled":true,"detected":$([ "$wdtt_active" -eq 1 ] && echo true || echo false),"healthy":$([ "$wdtt_healthy" -eq 1 ] && echo true || echo false),"host":$(json_string "$(hostname -f 2>/dev/null || hostname)"),"port":${wdtt_port:-null},"interface":$(json_string "$wdtt_interface"),"version":$(json_string "$wdtt_version"),"details":{"source":"node-agent"}},
    {"type":"vkturn","enabled":true,"detected":$([ "$vkturn_detected" -eq 1 ] && echo true || echo false),"healthy":$([ "$vkturn_healthy" -eq 1 ] && echo true || echo false),"host":$(json_string "$(hostname -f 2>/dev/null || hostname)"),"port":$vkturn_port,"interface":"","version":$(json_string "$vkturn_version"),"details":{"source":"node-agent","srtp":true}},
    {"type":"amneziawg2","enabled":false,"detected":false,"healthy":false,"host":"","port":null,"interface":"","version":"","details":{"source":"node-agent"}}
  ],
  "online":true,
  "uptime_seconds":$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)
}
JSON
)

curl -fsS --connect-timeout 5 --max-time 15 -X POST "$DARKTUNNEL_API_URL/v1/node/$DARKTUNNEL_SERVER_ID/report" -H 'Content-Type: application/json' -H "X-Node-Token: $DARKTUNNEL_NODE_TOKEN" --data "$payload" >/dev/null
