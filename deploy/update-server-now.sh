#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="${DARKTUNNEL_APP_DIR:-/opt/darktunnel}"
BRANCH="${DARKTUNNEL_BRANCH:-server-onboarding-v2}"
REPO="https://github.com/mnmdeveloper/darktunnel.git"
COMPOSE_FILE="$APP_DIR/docker-compose.backend.yml"

log() { printf '[DarkTunnel] %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }

if ! docker compose version >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
    apt-get install -y docker-compose-v2
  else
    apt-get install -y docker-compose-plugin
  fi
fi

docker compose version >/dev/null 2>&1 || { echo "Docker Compose v2 is required" >&2; exit 1; }

compose() {
  docker compose --env-file "$APP_DIR/.env" -f "$COMPOSE_FILE" "$@"
}

log "Updating code"
git config --global --add safe.directory "$APP_DIR" >/dev/null 2>&1 || true
git -C "$APP_DIR" remote set-url origin "$REPO"
git -C "$APP_DIR" fetch origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
git -C "$APP_DIR" reset --hard "refs/remotes/origin/$BRANCH"

[ -s "$APP_DIR/.env" ] || { echo "Missing $APP_DIR/.env" >&2; exit 1; }
[ -s "$APP_DIR/backend/.env" ] || { echo "Missing $APP_DIR/backend/.env" >&2; exit 1; }

compose config >/dev/null
compose up -d db redis
compose build --no-cache vkturn api bot

log "Removing stale app containers"
for service in bot vkturn api caddy; do
  ids="$(docker ps -aq --filter "label=com.docker.compose.project=darktunnel" --filter "label=com.docker.compose.service=$service")"
  [ -z "$ids" ] || docker rm -f $ids
done

log "Creating VK Turn and bot together"
compose up -d --no-deps vkturn bot

log "Starting API and Caddy"
compose up -d --no-deps api caddy

sleep 10
compose ps

compose exec -T api python - <<'PY'
import urllib.request
print(urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=10).read().decode())
PY

for service in vkturn bot api caddy; do
  id="$(compose ps -q "$service")"
  [ -n "$id" ] || { echo "$service container not found" >&2; exit 1; }
  [ "$(docker inspect -f '{{.State.Running}}' "$id")" = "true" ] || { docker logs --tail=200 "$id"; exit 1; }
done

log "Update completed successfully"
