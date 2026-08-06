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
for command in git curl docker tar; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  fail "Docker Compose is required"
fi

compose() {
  "${COMPOSE[@]}" --env-file "$APP_DIR/.env" -f "$APP_DIR/$COMPOSE_FILE" "$@"
}

backup_state() {
  install -m 700 -d "$BACKUP_DIR/config" "$BACKUP_DIR/vpn-snapshots"
  if [ -d "$APP_DIR/.git" ]; then
    OLD_COMMIT="$(git -C "$APP_DIR" rev-parse HEAD)"
    printf '%s\n' "$OLD_COMMIT" > "$BACKUP_DIR/old-commit"
  fi
  [ -f "$APP_DIR/.env" ] && cp -a "$APP_DIR/.env" "$BACKUP_DIR/config/root.env"
  [ -f "$APP_DIR/backend/.env" ] && cp -a "$APP_DIR/backend/.env" "$BACKUP_DIR/config/backend.env"
  [ -f "$APP_DIR/Caddyfile" ] && cp -a "$APP_DIR/Caddyfile" "$BACKUP_DIR/config/Caddyfile"
  [ -d /etc/wdtt ] && tar -C /etc -czf "$BACKUP_DIR/vpn-snapshots/wdtt.tar.gz" wdtt 2>/dev/null || true
  [ -d /etc/wireguard ] && tar -C /etc -czf "$BACKUP_DIR/vpn-snapshots/wireguard.tar.gz" wireguard 2>/dev/null || true
  [ -d /etc/amneziawg ] && tar -C /etc -czf "$BACKUP_DIR/vpn-snapshots/amneziawg.tar.gz" amneziawg 2>/dev/null || true
  systemctl is-active wdtt.service > "$BACKUP_DIR/wdtt-state" 2>/dev/null || true
  systemctl is-active wdtt-firewall.service > "$BACKUP_DIR/wdtt-firewall-state" 2>/dev/null || true
}

restore_config() {
  [ -f "$BACKUP_DIR/config/root.env" ] && cp -a "$BACKUP_DIR/config/root.env" "$APP_DIR/.env"
  [ -f "$BACKUP_DIR/config/backend.env" ] && cp -a "$BACKUP_DIR/config/backend.env" "$APP_DIR/backend/.env"
  [ -f "$BACKUP_DIR/config/Caddyfile" ] && cp -a "$BACKUP_DIR/config/Caddyfile" "$APP_DIR/Caddyfile"
}

rollback() {
  local code=$?
  trap - ERR
  log "Update failed; restoring previous application revision"
  if [ -n "$OLD_COMMIT" ] && [ -d "$APP_DIR/.git" ]; then
    git -C "$APP_DIR" reset --hard "$OLD_COMMIT" || true
    restore_config
    compose build api bot || true
    compose up -d --no-deps api bot caddy || true
  fi
  log "WDTT, VK Turn and AWG host services were not modified"
  exit "$code"
}
trap rollback ERR

backup_state

if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" fetch --prune origin "$BRANCH"
  git -C "$APP_DIR" checkout -B "$BRANCH" "origin/$BRANCH"
else
  parent="$(dirname "$APP_DIR")"
  install -d "$parent"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$APP_DIR"
fi

NEW_COMMIT="$(git -C "$APP_DIR" rev-parse HEAD)"
printf '%s\n' "$NEW_COMMIT" > "$BACKUP_DIR/new-commit"
restore_config

[ -s "$APP_DIR/.env" ] || fail "Missing $APP_DIR/.env"
[ -s "$APP_DIR/backend/.env" ] || fail "Missing $APP_DIR/backend/.env"

compose config >/dev/null
compose build api bot

# Only the application containers are recreated. The vkturn container and all
# host VPN services/interfaces/firewall rules remain untouched.
compose up -d --no-deps api
compose up -d --no-deps bot
compose up -d --no-deps caddy

for _ in $(seq 1 60); do
  if curl -fsS --max-time 5 "$HEALTH_URL" >/dev/null; then
    compose ps api bot caddy
    trap - ERR
    log "Update completed successfully: $NEW_COMMIT"
    log "Backup: $BACKUP_DIR"
    exit 0
  fi
  sleep 2
done

compose logs --tail=160 api bot || true
fail "Backend health check failed"
