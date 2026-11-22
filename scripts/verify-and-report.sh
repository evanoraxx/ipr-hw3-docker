#!/bin/sh
set -eu

# Не преобразовывать пути Docker в Git Bash на Windows.
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."

fail() {
    echo "Ошибка: $1" >&2
    exit 1
}

command -v docker >/dev/null || fail "Docker не найден"
command -v curl >/dev/null || fail "curl не найден"
docker compose version >/dev/null || fail "Docker Compose не найден"

PROJECT="hw3evidence$(date +%s)$$"
SINGLE="${PROJECT}single"
SQLITE="${PROJECT}sqlite"
IMAGE="hw3-single:${PROJECT}"
HOST_PORT=${CHECK_PORT:-$((24000 + $$ % 12000))}
case "$HOST_PORT" in
    ''|*[!0-9]*) fail "CHECK_PORT должен быть числом" ;;
esac
[ "$HOST_PORT" -ge 1024 ] && [ "$HOST_PORT" -le 65535 ] || fail "Нужен порт от 1024 до 65535"
export HOST_PORT
URL="http://127.0.0.1:$HOST_PORT"

cleanup() {
    status=$?
    trap - 0
    docker rm -f "$SINGLE" >/dev/null 2>&1 || true
    docker compose -p "$SQLITE" -f compose.sqlite.yaml down -v --remove-orphans >/dev/null 2>&1 || true
    docker image rm "$IMAGE" >/dev/null 2>&1 || true
    if [ "$status" -ne 0 ]; then
        echo "Проверка прервана. См. файлы в reports/, REPORT.md не обновлялся." >&2
    fi
    exit "$status"
}
trap cleanup 0

wait_ready() {
    i=0
    while [ "$i" -lt 60 ]; do
        if curl -fsS --max-time 3 "$URL/readyz" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    fail "Сервис не стал готовым за 60 секунд"
}

get_count() {
    answer=$(curl -fsS --max-time 5 "$URL/") || fail "GET / не ответил"
    value=${answer#*\"count\": }
    [ "$value" != "$answer" ] || fail "Нет поля count: $answer"
    value=${value%%,*}
    case "$value" in
        ''|*[!0-9]*) fail "Некорректное значение count: $value" ;;
    esac
    printf '%s\n' "$value"
}

check_count() {
    got=$(get_count)
    [ "$got" = "$1" ] || fail "Ожидался count=$1, получился $got"
    echo "count = $got, OK"
}

post() {
    curl -fsS --max-time 5 -X POST "$URL/increment"
    echo
}

mkdir -p reports

echo "Проверяю уровень 4 (Dockerfile и логи)..."
{
    echo '$ docker build -t IMAGE .'
    docker build -t "$IMAGE" .
    echo '$ docker run -d ... -e GREETING=Hello_from_Docker IMAGE'
    docker run -d --name "$SINGLE" -p "127.0.0.1:$HOST_PORT:8000" \
        -e 'GREETING=Hello from Docker' "$IMAGE"
    wait_ready
    echo '$ curl GET /'
    curl -fsS --max-time 5 "$URL/"
    echo
    check_count 0
    echo '$ curl POST /increment (дважды)'
    post
    post
    check_count 2
    echo '$ docker logs'
    docker logs "$SINGLE" 2>&1
} > reports/level4.txt 2>&1

docker rm -f "$SINGLE" >/dev/null

echo "Проверяю уровень 6 (SQLite и volume)..."
{
    echo '$ docker compose -f compose.sqlite.yaml up -d --build'
    docker compose -p "$SQLITE" -f compose.sqlite.yaml up -d --build
    wait_ready
    check_count 0
    echo '$ curl POST /increment (дважды)'
    post
    post
    check_count 2
    echo '$ docker compose down (без -v)'
    docker compose -p "$SQLITE" -f compose.sqlite.yaml down
    echo '$ docker compose up -d'
    docker compose -p "$SQLITE" -f compose.sqlite.yaml up -d
    wait_ready
    echo '$ curl GET / после пересоздания'
    curl -fsS --max-time 5 "$URL/"
    echo
    check_count 2
} > reports/level6.txt 2>&1

docker compose -p "$SQLITE" -f compose.sqlite.yaml down -v >/dev/null

echo "Проверяю уровень 8/10 и восстановление (первый запуск)..."
sh scripts/check.sh > reports/check1.txt 2>&1 || fail "Первый check.sh не прошёл (reports/check1.txt)"

echo "Проверяю уровень 8/10 и восстановление (второй запуск)..."
sh scripts/check.sh > reports/check2.txt 2>&1 || fail "Второй check.sh не прошёл (reports/check2.txt)"

cat > REPORT.md <<'EOF'
# Отчёт по ДЗ 3

Проверки были выполнены локально скриптом `sh scripts/verify-and-report.sh`.
Все указанные ниже результаты подтверждаются приложенными логами в `reports/`.

## 4 балла — Dockerfile

В `reports/level4.txt` есть сборка образа, запуск с переменной `GREETING`,
ответ `GET /`, два ответа `POST /increment` (счётчик: 1 и 2), а также
настоящий вывод `docker logs`.

## 6 баллов — Compose и SQLite

В `reports/level6.txt` сохранены команды и результаты: начальное значение 0,
после двух POST — 2, после `docker compose down` без `-v` и нового `up -d` — 2.

## 8 баллов — Redis

В `reports/check1.txt` и `reports/check2.txt` показаны:

- подключение `STORAGE=redis`, `REDIS_URL=redis://redis:6379/0`;
- сохранение счётчика после пересоздания `app` и `docker compose down/up`;
- ответы при остановленном Redis: `/healthz` — 200, `/readyz` — 503,
  `POST /increment` — 503;
- восстановление Redis без ручного перезапуска `app`, продолжение счётчика.

## 10 баллов — ограничения и восстановление

Скрипт `scripts/check.sh` запущен дважды подряд, оба запуска завершились
нулевым кодом и строкой `Все проверки прошли успешно`.

Вывод: `reports/check1.txt` и `reports/check2.txt`.
Скрипт проверяет UID, read-only, лимиты памяти/CPU, изолированный Compose-проект,
резервную копию Redis во внешний `backups/*.tar`, удаление исходных volumes
и восстановление счётчика в новом проекте.

Тестовые контейнеры и volumes удалены автоматически. Файлы резервных копий
оставлены локально в `backups/` (в Git не добавляются).
EOF

echo "Успех: отчёт обновлён, логи лежат в reports/."
