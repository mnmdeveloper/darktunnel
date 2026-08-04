#!/usr/bin/env bash
set -Eeuo pipefail

REPO="https://github.com/mnmdeveloper/darktunnel.git"
BRANCH="backend-bot-mvp"
APP_DIR="/opt/darktunnel"

if [ "${EUID}" -ne 0 ]; then
  echo "Run as root: sudo bash install-backend.sh"
  exit 1
fi

apt-get update
apt-get install -y ca-certificates curl git openssl
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" fetch origin "$BRANCH"
  git -C "$APP_DIR" checkout "$BRANCH"
  git -C "$APP_DIR" reset --hard "origin/$BRANCH"
else
  rm -rf "$APP_DIR"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$APP_DIR"
fi

read -rsp "Telegram bot token: " TELEGRAM_BOT_TOKEN; echo
read -rp "Telegram owner numeric ID: " TELEGRAM_OWNER_ID
read -rp "Public API URL (example https://api.play2go.cloud): " PUBLIC_API_URL

POSTGRES_PASSWORD="$(openssl rand -base64 36 | tr -d '\n=/+' | cut -c1-40)"
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

for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8000/health >/dev/null; then
    echo "DarkTunnel backend and bot installed successfully."
    docker compose --env-file .env -f docker-compose.backend.yml ps
    exit 0
  fi
  sleep 2
done

echo "Health check failed. Recent logs:"
docker compose --env-file .env -f docker-compose.backend.yml logs --tail=120 api bot
exit 1
