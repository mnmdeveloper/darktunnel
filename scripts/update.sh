#!/usr/bin/env bash
# DarkTunnel — умный обновлятор с откатом
# Использование: curl -fsSL https://raw.githubusercontent.com/mnmdeveloper/darktunnel/main/scripts/update.sh | bash
# Или локально: bash /opt/darktunnel/scripts/update.sh

set -Eeuo pipefail

# ── Цвета ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[FAIL]${NC} $*" >&2; }

# ── Конфиг ─────────────────────────────────────────────────────────────────────
APP_DIR="${DT_DIR:-/opt/darktunnel}"
COMPOSE_FILE="docker-compose.backend.yml"
COMPOSE="docker compose --env-file .env -f $COMPOSE_FILE"
HEALTH_URL="http://127.0.0.1:8000/health"
HEALTH_RETRIES=40       # 40 × 3s = 2 мин
HEALTH_INTERVAL=3
BACKUP_DIR="/opt/darktunnel-backups"

# ── Функции ────────────────────────────────────────────────────────────────────

timestamp() { date '+%Y%m%d_%H%M%S'; }

wait_healthy() {
    info "Жду /health (до $((HEALTH_RETRIES * HEALTH_INTERVAL))с)..."
    for i in $(seq 1 "$HEALTH_RETRIES"); do
        if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
            ok "API отвечает (попытка $i)"
            return 0
        fi
        sleep "$HEALTH_INTERVAL"
    done
    return 1
}

rollback() {
    local reason="${1:-unknown}"
    die "Откат: $reason"
    echo ""
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    warn " ОТКАТ К ПРЕДЫДУЩЕЙ ВЕРСИИ"
    warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 1. Откат git
    if [[ -n "${PREV_COMMIT:-}" ]]; then
        info "Возвращаю git к $PREV_COMMIT..."
        git reset --hard "$PREV_COMMIT" || warn "git reset не удался"
    fi

    # 2. Восстановление образов из бэкапа
    if [[ -f "$BACKUP_DIR/images_${BACKUP_TS}.tar" ]]; then
        info "Восстанавливаю docker-образы..."
        docker load -i "$BACKUP_DIR/images_${BACKUP_TS}.tar" || warn "docker load не удался"
    fi

    # 3. Поднимаем старые контейнеры
    info "Поднимаю старые контейнеры..."
    $COMPOSE up -d --no-build 2>&1 | tail -5 || warn "up --no-build не удался, пробую с build..."
    $COMPOSE up -d --build 2>&1 | tail -5 || warn "up --build тоже не удался"

    # 4. Проверяем что откат сработал
    if wait_healthy; then
        ok "Откат успешен. Сервис восстановлен."
    else
        die "Откат ПРОВАЛИЛСЯ. Нужно ручное вмешательство!"
        die "Логи: $COMPOSE logs --tail=100 api bot"
        exit 2
    fi

    exit 1
}

# ── Проверки ───────────────────────────────────────────────────────────────────
if [[ ! -d "$APP_DIR" ]]; then
    die "Папка $APP_DIR не найдена. Сначала запустите install-backend.sh."
    exit 1
fi

if ! command -v docker &>/dev/null; then
    die "docker не найден."
    exit 1
fi

cd "$APP_DIR"

if [[ ! -f ".env" ]]; then
    die ".env не найден в $APP_DIR."
    exit 1
fi

# ── Старт ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN} DarkTunnel Updater${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

BACKUP_TS="$(timestamp)"
PREV_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo '')"
info "Текущий коммит: ${PREV_COMMIT:0:12}"

# ── Шаг 1: Бэкап образов ──────────────────────────────────────────────────────
info "Шаг 1/6 — Бэкап docker-образов..."
mkdir -p "$BACKUP_DIR"
IMAGES=$(docker images --filter "reference=darktunnel*" --format "{{.Repository}}:{{.Tag}}" 2>/dev/null || true)
if [[ -n "$IMAGES" ]]; then
    # shellcheck disable=SC2086
    docker save $IMAGES -o "$BACKUP_DIR/images_${BACKUP_TS}.tar" 2>/dev/null || warn "Не удалось сохранить образы (пропускаем)"
    ok "Образы сохранены → $BACKUP_DIR/images_${BACKUP_TS}.tar"
else
    warn "Образы не найдены, пропускаем бэкап"
fi

# Чистим старые бэкапы (оставляем 5 последних)
ls -t "$BACKUP_DIR"/images_*.tar 2>/dev/null | tail -n +6 | xargs rm -f || true

# ── Шаг 2: Получение обновлений ───────────────────────────────────────────────
info "Шаг 2/6 — Получаю обновления из git..."
git fetch origin main 2>&1 | tail -3

NEW_COMMIT="$(git rev-parse origin/main)"
if [[ "$PREV_COMMIT" == "$NEW_COMMIT" ]]; then
    ok "Уже актуальная версия (${NEW_COMMIT:0:12}). Принудительно пересобираю контейнеры..."
else
    info "Новый коммит: ${NEW_COMMIT:0:12}"
    git reset --hard origin/main
    ok "Код обновлён"
fi

# ── Шаг 3: Пересборка образов ────────────────────────────────────────────────
info "Шаг 3/6 — Собираю новые образы..."
if ! $COMPOSE build --pull 2>&1 | tail -10; then
    rollback "Сборка образов провалилась"
fi
ok "Образы собраны"

# ── Шаг 4: Запуск новых контейнеров ──────────────────────────────────────────
info "Шаг 4/6 — Запускаю контейнеры..."
if ! $COMPOSE up -d --no-deps --remove-orphans api bot 2>&1 | tail -10; then
    rollback "docker compose up провалился"
fi
ok "Контейнеры запущены"

# ── Шаг 5: Healthcheck ───────────────────────────────────────────────────────
info "Шаг 5/6 — Проверяю здоровье API..."
if ! wait_healthy; then
    die "API не ответил за отведённое время. Логи:"
    $COMPOSE logs --tail=50 api bot 2>&1 | tail -60
    rollback "API не прошёл healthcheck"
fi

# ── Шаг 6: Проверка бота ─────────────────────────────────────────────────────
info "Шаг 6/6 — Проверяю бота..."
sleep 3
if ! $COMPOSE ps bot | grep -q "running\|Up"; then
    warn "Бот не запущен. Логи бота:"
    $COMPOSE logs --tail=30 bot
    rollback "Бот упал после деплоя"
fi
ok "Бот работает"

# ── Итог ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} ✅ ОБНОВЛЕНИЕ УСПЕШНО${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Коммит: ${NEW_COMMIT:0:12}"
echo "  Время:  $(date '+%d.%m.%Y %H:%M:%S')"
echo ""
$COMPOSE ps
echo ""
