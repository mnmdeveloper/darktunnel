#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/darktunnel"
PUBLIC_IP="31.77.148.80"
DOMAIN="${DARKTUNNEL_API_DOMAIN:-api.31-77-148-80.sslip.io}"

if [ "${EUID}" -ne 0 ]; then
  echo "Run with sudo/root."
  exit 1
fi
if [ ! -d "$APP_DIR/.git" ]; then
  echo "DarkTunnel is not installed in $APP_DIR"
  exit 1
fi

if ss -ltn '( sport = :80 or sport = :443 )' | tail -n +2 | grep -q .; then
  echo "Ports 80 or 443 are already occupied. Nothing was changed."
  ss -ltnp | grep -E ':(80|443) ' || true
  exit 1
fi

RESOLVED="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}')"
if [ "$RESOLVED" != "$PUBLIC_IP" ]; then
  echo "Domain $DOMAIN resolves to ${RESOLVED:-nothing}, expected $PUBLIC_IP."
  exit 1
fi

cd "$APP_DIR"
git fetch origin main
git checkout -B main origin/main

cat > Caddyfile <<EOF
$DOMAIN {
    encode zstd gzip
    reverse_proxy api:8000
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "no-referrer"
    }
}
EOF
chmod 644 Caddyfile

if grep -q '^PUBLIC_API_URL=' backend/.env; then
  sed -i "s|^PUBLIC_API_URL=.*|PUBLIC_API_URL=https://$DOMAIN|" backend/.env
else
  printf '\nPUBLIC_API_URL=https://%s\n' "$DOMAIN" >> backend/.env
fi
chmod 600 backend/.env

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  echo "Docker Compose is not installed."
  exit 1
fi

"${COMPOSE[@]}" -f docker-compose.backend.yml up -d --build

for _ in $(seq 1 60); do
  if curl -fsS "https://$DOMAIN/health" | grep -q '"status":"ok"'; then
    echo "Public HTTPS API is ready: https://$DOMAIN"
    "${COMPOSE[@]}" -f docker-compose.backend.yml ps
    exit 0
  fi
  sleep 2
done

echo "HTTPS health check failed. Recent Caddy/API logs:"
"${COMPOSE[@]}" -f docker-compose.backend.yml logs --tail=160 caddy api
exit 1
