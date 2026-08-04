#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/darktunnel"
DOMAIN="${DARKTUNNEL_API_DOMAIN:-api.31-77-148-80.sslip.io}"

if [ "${EUID}" -ne 0 ]; then
  echo "Run with sudo/root."
  exit 1
fi
if [ ! -d "$APP_DIR/.git" ]; then
  echo "DarkTunnel is not installed in $APP_DIR."
  exit 1
fi

cd "$APP_DIR"
git fetch origin main
git checkout -B main origin/main

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  echo "Docker Compose is not installed."
  exit 1
fi

if ss -ltnp | grep -Eq ':(80|443) ' && ! ss -ltnp | grep -Eq ':(80|443) .*docker'; then
  echo "Port 80 or 443 is already occupied by another service."
  ss -ltnp | grep -E ':(80|443) ' || true
  exit 1
fi

if grep -q '^API_DOMAIN=' .env 2>/dev/null; then
  sed -i "s#^API_DOMAIN=.*#API_DOMAIN=$DOMAIN#" .env
else
  printf '\nAPI_DOMAIN=%s\n' "$DOMAIN" >> .env
fi

if grep -q '^PUBLIC_API_URL=' backend/.env 2>/dev/null; then
  sed -i "s#^PUBLIC_API_URL=.*#PUBLIC_API_URL=https://$DOMAIN#" backend/.env
else
  printf '\nPUBLIC_API_URL=https://%s\n' "$DOMAIN" >> backend/.env
fi
chmod 600 .env backend/.env

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 443/udp
fi

# docker-compose v1 can fail with KeyError: ContainerConfig when recreating
# containers made from newer image metadata. Removing only project containers
# fixes that while preserving named database/Caddy volumes.
"${COMPOSE[@]}" -f docker-compose.backend.yml down --remove-orphans || true
docker ps -aq --filter 'name=darktunnel_' | xargs -r docker rm -f

"${COMPOSE[@]}" -f docker-compose.backend.yml pull caddy db redis || true
"${COMPOSE[@]}" -f docker-compose.backend.yml up -d --build --force-recreate

for _ in $(seq 1 60); do
  if curl -fsS "https://$DOMAIN/health" >/dev/null 2>&1; then
    echo "HTTPS enabled successfully: https://$DOMAIN"
    "${COMPOSE[@]}" -f docker-compose.backend.yml ps
    exit 0
  fi
  sleep 3
done

echo "HTTPS check failed. Recent Caddy logs:"
"${COMPOSE[@]}" -f docker-compose.backend.yml logs --tail=160 caddy
exit 1
