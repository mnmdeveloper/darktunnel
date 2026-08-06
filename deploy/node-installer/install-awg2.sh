#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="/etc/amneziawg"
CONFIG_PATH="$CONFIG_DIR/awg0.conf"
PORT="${DARKTUNNEL_AWG_PORT:-585}"
ADDRESS="${DARKTUNNEL_AWG_ADDRESS:-10.77.0.1/24}"

log() { printf '[DarkTunnel AWG2] %s\n' "$*"; }
fail() { printf '[DarkTunnel AWG2] ERROR: %s\n' "$*" >&2; exit 1; }

[ "${EUID}" -eq 0 ] || fail "Run as root"
. /etc/os-release
case "${ID:-}" in ubuntu|debian) ;; *) fail "Supported OS: Ubuntu/Debian" ;; esac

if command -v awg >/dev/null 2>&1 && [ -s "$CONFIG_PATH" ]; then
  log "Existing AmneziaWG configuration detected; leaving it unchanged"
  exit 0
fi

if ss -lunH | awk '{print $5}' | grep -Eq "(^|:)$PORT$"; then
  fail "UDP port $PORT is already occupied"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg2 software-properties-common python3-launchpadlib iptables iproute2 linux-headers-"$(uname -r)"

KEYRING=/usr/share/keyrings/amnezia-archive-keyring.gpg
if [ ! -s "$KEYRING" ]; then
  gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys 75C9DD72C799870E310542E24166F2C257290828
  gpg --batch --export 75C9DD72C799870E310542E24166F2C257290828 > "$KEYRING"
fi

if [ "$ID" = ubuntu ]; then
  CODENAME="${VERSION_CODENAME:-noble}"
else
  CODENAME="focal"
fi
cat > /etc/apt/sources.list.d/amnezia.list <<EOF
deb [signed-by=$KEYRING] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu $CODENAME main
deb-src [signed-by=$KEYRING] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu $CODENAME main
EOF

apt-get update
apt-get install -y amneziawg
command -v awg >/dev/null 2>&1 || fail "awg utility was not installed"
command -v awg-quick >/dev/null 2>&1 || fail "awg-quick utility was not installed"

install -m 700 -d "$CONFIG_DIR"
umask 077
PRIVATE_KEY="$(awg genkey)"
PUBLIC_KEY="$(printf '%s' "$PRIVATE_KEY" | awg pubkey)"
H1="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
H2="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
H3="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
H4="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"

cat > "$CONFIG_PATH" <<EOF
[Interface]
Address = $ADDRESS
ListenPort = $PORT
PrivateKey = $PRIVATE_KEY
Jc = 5
Jmin = 40
Jmax = 70
S1 = 64
S2 = 96
S3 = 32
S4 = 16
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4
PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -t nat -C POSTROUTING -s ${ADDRESS%/*}0/24 -o \$(ip route show default | awk '{print \$5; exit}') -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${ADDRESS%.*}.0/24 -o \$(ip route show default | awk '{print \$5; exit}') -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${ADDRESS%.*}.0/24 -o \$(ip route show default | awk '{print \$5; exit}') -j MASQUERADE 2>/dev/null || true
EOF
chmod 600 "$CONFIG_PATH"

cat > /etc/sysctl.d/90-darktunnel-awg.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null

systemctl enable --now awg-quick@awg0
systemctl is-active --quiet awg-quick@awg0 || fail "awg0 service did not start"

install -m 700 -d /etc/darktunnel-node
cat > /etc/darktunnel-node/awg2.json <<EOF
{"interface":"awg0","port":$PORT,"address":"$ADDRESS","public_key":"$PUBLIC_KEY","config_path":"$CONFIG_PATH"}
EOF
chmod 600 /etc/darktunnel-node/awg2.json
log "AmneziaWG 2 installed on UDP $PORT"
