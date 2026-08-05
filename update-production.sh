#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/darktunnel"

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
  echo "Docker Compose is unavailable."
  exit 1
fi

"${COMPOSE[@]}" -f docker-compose.backend.yml build api bot

# docker-compose v1 may crash with KeyError: ContainerConfig while recreating
# containers. Remove only this project's containers; named volumes and WDTT
# remain untouched.
"${COMPOSE[@]}" -f docker-compose.backend.yml down --remove-orphans || true
docker ps -aq --filter 'name=darktunnel_' | xargs -r docker rm -f

"${COMPOSE[@]}" -f docker-compose.backend.yml up -d --force-recreate

for _ in $(seq 1 60); do
  if curl -fsS https://api.31-77-148-80.sslip.io/health >/dev/null 2>&1; then
    echo "DarkTunnel production updated successfully."
    "${COMPOSE[@]}" -f docker-compose.backend.yml ps
    exit 0
  fi
  sleep 2
done

"${COMPOSE[@]}" -f docker-compose.backend.yml logs --tail=180 api bot caddy
exit 1
