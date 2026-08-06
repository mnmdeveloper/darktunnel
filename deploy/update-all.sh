#!/usr/bin/env bash
set -Eeuo pipefail

REPO="https://github.com/mnmdeveloper/darktunnel.git"
BRANCH="${DARKTUNNEL_BRANCH:-server-onboarding-v2}"
APP_DIR="${DARKTUNNEL_APP_DIR:-/opt/darktunnel}"
BACKUP_ROOT="${DARKTUNNEL_BACKUP_DIR:-/opt/darktunnel-backups}"
COMPOSE_FILE="docker-compose.backend.yml"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_ROOT/$STAMP"
OLD_COMMIT=""
ROLLING_BACK=0

log() { printf '[DarkTunnel] %s\n' "$*"; }
fail() { printf '[DarkTunnel] ERROR: %s\n' "$*" >&2; return 1; }

[ "${EUID}" -eq 0 ] || { echo "Run with sudo/root" >&2; exit 1; }
for command in git curl docker tar; do command -v "$command" >/dev/null 2>&1 || { echo "$command is required" >&2; exit 1; }; done

if docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE=(docker-compose)
else echo "Docker Compose is required" >&2; exit 1; fi

compose() { "${COMPOSE[@]}" --env-file "$APP_DIR/.env" -f "$APP_DIR/$COMPOSE_FILE" "$@"; }

restore_config() {
  [ -f "$BACKUP_DIR/config/root.env" ] && cp -a "$BACKUP_DIR/config/root.env" "$APP_DIR/.env"
  [ -f "$BACKUP_DIR/config/backend.env" ] && cp -a "$BACKUP_DIR/config/backend.env" "$APP_DIR/backend/.env"
  [ -f "$BACKUP_DIR/config/Caddyfile" ] && cp -a "$BACKUP_DIR/config/Caddyfile" "$APP_DIR/Caddyfile"
}

rollback() {
  local code="${1:-1}"
  [ "$ROLLING_BACK" -eq 0 ] || exit "$code"
  ROLLING_BACK=1
  trap - ERR
  log "Update failed; restoring previous application revision"
  if [ -n "$OLD_COMMIT" ] && [ -d "$APP_DIR/.git" ]; then
    git -C "$APP_DIR" reset --hard "$OLD_COMMIT" || true
    restore_config
    compose build api bot || true
    compose up -d --no-deps api bot caddy || true
  fi
  log "Host WDTT/VK Turn/AWG services and configs were not modified"
  exit "$code"
}

on_error() {
  local code=$?
  local line="$1"
  local command="$2"
  log "Failed at line $line: $command (exit $code)"
  rollback "$code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

install -m 700 -d "$BACKUP_DIR/config" "$BACKUP_DIR/vpn-snapshots"
if [ -d "$APP_DIR/.git" ]; then
  git config --global --add safe.directory "$APP_DIR" >/dev/null 2>&1 || true
  OLD_COMMIT="$(git -C "$APP_DIR" rev-parse HEAD)"
  printf '%s\n' "$OLD_COMMIT" > "$BACKUP_DIR/old-commit"
  git -C "$APP_DIR" status --porcelain=v1 > "$BACKUP_DIR/git-status.txt" || true
  git -C "$APP_DIR" diff --binary > "$BACKUP_DIR/local-changes.patch" || true
fi
[ -f "$APP_DIR/.env" ] && cp -a "$APP_DIR/.env" "$BACKUP_DIR/config/root.env"
[ -f "$APP_DIR/backend/.env" ] && cp -a "$APP_DIR/backend/.env" "$BACKUP_DIR/config/backend.env"
[ -f "$APP_DIR/Caddyfile" ] && cp -a "$APP_DIR/Caddyfile" "$BACKUP_DIR/config/Caddyfile"
[ -d /etc/wdtt ] && tar -C /etc -czf "$BACKUP_DIR/vpn-snapshots/wdtt.tar.gz" wdtt 2>/dev/null || true
[ -d /etc/wireguard ] && tar -C /etc -czf "$BACKUP_DIR/vpn-snapshots/wireguard.tar.gz" wireguard 2>/dev/null || true
[ -d /etc/amneziawg ] && tar -C /etc -czf "$BACKUP_DIR/vpn-snapshots/amneziawg.tar.gz" amneziawg 2>/dev/null || true
if [ -f "$APP_DIR/.env" ] && [ -f "$APP_DIR/$COMPOSE_FILE" ]; then
  compose exec -T db pg_dump -U darktunnel -d darktunnel -Fc > "$BACKUP_DIR/database.dump" 2>/dev/null || true
fi

if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" remote set-url origin "$REPO"
  git -C "$APP_DIR" fetch --prune origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
  git -C "$APP_DIR" reset --hard "refs/remotes/origin/$BRANCH"
  git -C "$APP_DIR" clean -fdx -e .env -e backend/.env -e Caddyfile
else
  install -d "$(dirname "$APP_DIR")"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$APP_DIR"
fi

NEW_COMMIT="$(git -C "$APP_DIR" rev-parse HEAD)"
printf '%s\n' "$NEW_COMMIT" > "$BACKUP_DIR/new-commit"
restore_config

[ -s "$APP_DIR/.env" ] || { log "Missing $APP_DIR/.env"; rollback 1; }
[ -s "$APP_DIR/backend/.env" ] || { log "Missing $APP_DIR/backend/.env"; rollback 1; }

compose config >/dev/null
compose up -d db redis
compose build api bot
compose up -d --no-deps api bot caddy

healthy=0
for _ in $(seq 1 90); do
  api_id="$(compose ps -q api 2>/dev/null || true)"
  bot_id="$(compose ps -q bot 2>/dev/null || true)"
  if [ -n "$api_id" ] && [ -n "$bot_id" ] \
     && [ "$(docker inspect -f '{{.State.Running}}' "$api_id" 2>/dev/null || true)" = "true" ] \
     && [ "$(docker inspect -f '{{.State.Running}}' "$bot_id" 2>/dev/null || true)" = "true" ] \
     && compose exec -T api python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3).read()" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done

if [ "$healthy" -ne 1 ]; then
  compose ps || true
  compose logs --tail=250 api bot || true
  rollback 1
fi

trap - ERR
compose ps db redis api bot caddy
log "Full central server update completed: $NEW_COMMIT"
log "Backup: $BACKUP_DIR"
log "Activation links remain darktunnel://activate?d=TOKEN"
exit 0
