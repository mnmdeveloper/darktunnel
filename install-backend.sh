#!/usr/bin/env bash
set -Eeuo pipefail

REPO="https://github.com/mnmdeveloper/darktunnel.git"
BRANCH="${DARKTUNNEL_BRANCH:-backend-bot-mvp}"
APP_DIR="/opt/darktunnel"
TTY="/dev/tty"

if [ "${EUID}" -ne 0 ]; then
  echo "Run this installer with sudo/root."
  exit 1
fi
if [ ! -r "$TTY" ]; then
  echo "An interactive terminal is required."
  exit 1
fi

apt-get update
apt-get install -y ca-certificates curl git openssl
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

echo "Installing DarkTunnel from branch: $BRANCH"
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" fetch origin "$BRANCH"
  git -C "$APP_DIR" checkout -B "$BRANCH" "origin/$BRANCH"
else
  rm -rf "$APP_DIR"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$APP_DIR"
fi

printf "Telegram bot token: " > "$TTY"
IFS= read -r TELEGRAM_BOT_TOKEN < "$TTY"
printf "Telegram owner numeric ID: " > "$TTY"
IFS= read -r TELEGRAM_OWNER_ID < "$TTY"
printf "Public API URL (example https://api.play2go.cloud): " > "$TTY"
IFS= read -r PUBLIC_API_URL < "$TTY"

case "$TELEGRAM_OWNER_ID" in
  ''|*[!0-9]*) echo "Telegram owner ID must be numeric."; exit 1 ;;
esac
if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
  echo "Telegram bot token is required."
  exit 1
fi
if [[ ! "$PUBLIC_API_URL" =~ ^https:// ]]; then
  echo "Public API URL must start with https://"
  exit 1
fi

POSTGRES_PASSWORD="$(openssl rand -hex 24)"
ACTIVATION_ENCRYPTION_KEY="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"

install -m 700 -d "$APP_DIR/backend"
cat > "$APP_DIR/.env" <<EOF
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
EOF
cat > "$APP_DIR/backend/.env" <<EOF
ENVIRONMENT=production
PUBLIC_API_URL=$PUBLIC_API_URL
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
DATABASE_URL=postgresql+asyncpg://darktunnel:$POSTGRES_PASSWORD@db:5432/darktunnel
REDIS_URL=redis://redis:6379/0
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_OWNER_ID=$TELEGRAM_OWNER_ID
ACTIVATION_ENCRYPTION_KEY=$ACTIVATION_ENCRYPTION_KEY
WDTT_ENV_PATH=/host/etc/wdtt/wdtt.env
WDTT_PUBLIC_HOST=31.77.148.80
WDTT_PUBLIC_PORT=56000
WDTT_MODE=srtp-wrap-a
WDTT_CONNECTIONS_BALANCED=3
WDTT_CONNECTIONS_MAXIMUM=10
WDTT_MTU=1280
WDTT_DNS=1.1.1.1
EOF
chmod 600 "$APP_DIR/.env" "$APP_DIR/backend/.env"

cd "$APP_DIR"
docker compose --env-file .env -f docker-compose.backend.yml up -d --build

for _ in $(seq 1 45); do
  if curl -fsS http://127.0.0.1:8000/health >/dev/null; then
    echo "DarkTunnel backend and Telegram bot installed successfully."
    docker compose --env-file .env -f docker-compose.backend.yml ps
    exit 0
  fi
  sleep 2
done

echo "Health check failed. Recent logs:"
docker compose --env-file .env -f docker-compose.backend.yml logs --tail=160 api bot
exit 1
