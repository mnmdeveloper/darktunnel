#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="${DARKTUNNEL_APP_DIR:-/opt/darktunnel}"
BRANCH="${DARKTUNNEL_BRANCH:-server-onboarding-v2}"
REPO="https://github.com/mnmdeveloper/darktunnel.git"
COMPOSE_FILE="$APP_DIR/docker-compose.backend.yml"

log() { printf '[DarkTunnel] %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }

ensure_compose_v2() {
  if docker compose version >/dev/null 2>&1; then
    return
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
    apt-get install -y docker-compose-v2
  elif apt-cache show docker-compose-plugin >/dev/null 2>&1; then
    apt-get install -y docker-compose-plugin
  else
    echo "Docker Compose v2 package is unavailable" >&2
    exit 1
  fi
  docker compose version >/dev/null 2>&1 || { echo "Docker Compose v2 installation failed" >&2; exit 1; }
}

ensure_compose_v2
COMPOSE=(docker compose)

compose() {
  "${COMPOSE[@]}" --env-file "$APP_DIR/.env" -f "$COMPOSE_FILE" "$@"
}

log "Updating code"
git config --global --add safe.directory "$APP_DIR" >/dev/null 2>&1 || true
git -C "$APP_DIR" remote set-url origin "$REPO"
git -C "$APP_DIR" fetch origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
git -C "$APP_DIR" reset --hard "refs/remotes/origin/$BRANCH"

[ -s "$APP_DIR/.env" ] || { echo "Missing $APP_DIR/.env" >&2; exit 1; }
[ -s "$APP_DIR/backend/.env" ] || { echo "Missing $APP_DIR/backend/.env" >&2; exit 1; }

log "Validating compose"
compose config >/dev/null

log "Starting database and redis"
compose up -d db redis

log "Building API and bot"
compose build --no-cache api bot

log "Removing stale application containers"
for service in api bot caddy; do
  ids="$(docker ps -aq --filter "label=com.docker.compose.project=darktunnel" --filter "label=com.docker.compose.service=$service")"
  [ -z "$ids" ] || docker rm -f $ids

done

log "Starting API, bot and Caddy"
compose up -d --no-deps api bot caddy

sleep 8

log "Container status"
compose ps

log "API health"
compose exec -T api python - <<'PY'
import urllib.request
print(urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=10).read().decode())
PY

log "Bot process"
bot_id="$(compose ps -q bot)"
[ -n "$bot_id" ] || { echo "Bot container not found" >&2; exit 1; }
[ "$(docker inspect -f '{{.State.Running}}' "$bot_id")" = "true" ] || { docker logs --tail=200 "$bot_id"; exit 1; }

log "Update completed successfully"
