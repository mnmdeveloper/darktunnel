#!/usr/bin/env bash
set -Eeuo pipefail

REPO="https://github.com/mnmdeveloper/darktunnel.git"
BRANCH="${DARKTUNNEL_BRANCH:-main}"
APP_DIR="${DARKTUNNEL_APP_DIR:-/opt/darktunnel}"
BACKUP_ROOT="${DARKTUNNEL_BACKUP_DIR:-/opt/darktunnel-backups}"
COMPOSE_FILE="docker-compose.backend.yml"
HEALTH_URL="${DARKTUNNEL_HEALTH_URL:-http://127.0.0.1:8000/health}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_ROOT/$STAMP"
OLD_COMMIT=""
NEW_COMMIT=""

log() { printf '[DarkTunnel] %s\n' "$*"; }
fail() { printf '[DarkTunnel] ERROR: %s\n' "$*" >&2; exit 1; }

[ "${EUID}" -eq 0 ] || fail "Run with sudo/root"
command -v git >/dev/null 2>&1 || fail "git is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v docker >/dev/null 2>&1 || fail "docker is required"

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  fail "Docker Compose is required"
fi

backup_state() {
  install -m 700 -d "$BACKUP_DIR"
  if [ -d "$APP_DIR/.git" ]; then
    OLD_COMMIT="$(git -C "$APP_DIR" rev-parse HEAD)"
    printf '%s\n' "$OLD_COMMIT" > "$BACKUP_DIR/old-commit"
  fi
  for file in "$APP_DIR/.env" "$APP_DIR/backend/.env" "$APP_DIR/Caddyfile"; do
    if [ -f "$file" ]; then
      cp -a "$file" "$BACKUP_DIR/$(basename "$file")"
    fi
  done
  if [ -d /etc/wdtt ]; then
    tar -C /etc -czf "$BACKUP_DIR/wdtt-readonly-snapshot.tar.gz" wdtt 2>/dev/null || true
  fi
  if [ -d /etc/wireguard ]; then
    tar -C /etc -czf "$BACKUP_DIR/wireguard-readonly-snapshot.tar.gz" wireguard 2>/dev/null || true
  fi
  if [ -d /etc/amneziawg ]; then
    tar -C /etc -czf "$BACKUP_DIR/amneziawg-readonly-snapshot.tar.gz" amneziawg 2>/dev/null || true
  fi
}

restore_files() {
  [ -f "$BACKUP_DIR/.env" ] && cp -a "$BACKUP_DIR/.env" "$APP_DIR/.env"
  [ -f "$BACKUP_DIR/backend.env" ] && cp -a "$BACKUP_DIR/backend.env" "$APP_DIR/backend/.env"
  [ -f "$BACKUP_DIR/Caddyfile" ] && cp -a "$BACKUP_DIR/Caddyfile" "$APP_DIR/Caddyfile"
}

rollback() {
  log "Update failed. Rolling application code back..."
  if [ -n "$OLD_COMMIT" ] && [ -d "$APP_DIR/.git" ]; then
    git -C "$APP_DIR" reset --hard "$OLD_COMMIT" || true
    restore_files
    cd "$APP_DIR"
    "${COMPOSE[@]}" -f "$COMPOSE_FILE" up -d --build api bot caddy || true
  fi
  log "Rollback attempt finished. Existing WDTT/AWG services were never stopped or restarted by this script."
}
trap rollback ERR

backup_state

if [ -d "$APP_DIR/.git" ]; then
  log "Fetching $BRANCH"
  git -C "$APP_DIR" fetch --prune origin "$BRANCH"
  git -C "$APP_DIR" checkout -B "$BRANCH" "origin/$BRANCH"
else
  log "Cloning $BRANCH"
  rm -rf "$APP_DIR"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$APP_DIR"
fi

NEW_COMMIT="$(git -C "$APP_DIR" rev-parse HEAD)"
printf '%s\n' "$NEW_COMMIT" > "$BACKUP_DIR/new-commit"

restore_files
cd "$APP_DIR"

log "Validating Compose configuration"
"${COMPOSE[@]}" -f "$COMPOSE_FILE" config >/dev/null

log "Compiling Python sources"
"${COMPOSE[@]}" -f "$COMPOSE_FILE" build api bot

log "Updating backend and bot only"
"${COMPOSE[@]}" -f "$COMPOSE_FILE" up -d --no-deps api bot
"${COMPOSE[@]}" -f "$COMPOSE_FILE" up -d --no-deps caddy

log "Waiting for health check"
for _ in $(seq 1 60); do
  if curl -fsS --max-time 5 "$HEALTH_URL" >/dev/null; then
    trap - ERR
    log "Update completed successfully"
    log "Previous commit: ${OLD_COMMIT:-none}"
    log "Current commit:  $NEW_COMMIT"
    log "Backup:          $BACKUP_DIR"
    log "WDTT/VK Turn/AWG services and configs were not changed or restarted"
    exit 0
  fi
  sleep 2
done

fail "Health check failed"
