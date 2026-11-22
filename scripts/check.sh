#!/bin/sh
set -eu

# Не преобразовывать пути Docker в Git Bash на Windows.
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."

error() {
    echo "Ошибка: $1" >&2
    exit 1
}

command -v docker >/dev/null || error "Docker не найден"
command -v curl >/dev/null || error "curl не найден"
docker compose version >/dev/null || error "Docker Compose не найден"

N=${CHECK_N:-5}
case "$N" in
    ''|*[!0-9]*) error "CHECK_N должен быть целым числом" ;;
esac
[ "$N" -gt 0 ] || error "CHECK_N должен быть больше нуля"

PROJECT="hw3check$(date +%s)$$"
RESTORE="${PROJECT}restore"
HOST_PORT=${CHECK_PORT:-$((20000 + $$ % 20000))}
case "$HOST_PORT" in
    ''|*[!0-9]*) error "CHECK_PORT должен быть числом" ;;
esac
[ "$HOST_PORT" -ge 1024 ] && [ "$HOST_PORT" -le 65535 ] || error "CHECK_PORT должен быть от 1024 до 65535"
export HOST_PORT
URL="http://localhost:$HOST_PORT"

mkdir -p backups
BACKUP="$(pwd)/backups/$PROJECT.tar"

compose() {
    docker compose -p "$PROJECT" "$@"
}

compose_restore() {
    docker compose -p "$RESTORE" "$@"
}

cleanup() {
    result=$?
    trap - 0
    compose down -v --remove-orphans >/dev/null 2>&1 || true
    compose_restore down -v --remove-orphans >/dev/null 2>&1 || true
    exit "$result"
}
trap cleanup 0

wait_app() {
    i=0
    while [ "$i" -lt 60 ]; do
        if curl -fsS --max-time 3 "$URL/readyz" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    error "Приложение не стало готовым"
}

count() {
    answer=$(curl -fsS --max-time 5 "$URL/") || error "GET / не сработал"
    value=${answer#*\"count\": }
    [ "$value" != "$answer" ] || error "Не нашёл count в ответе: $answer"
    value=${value%%,*}
    case "$value" in
        ''|*[!0-9]*) error "Некорректный count: $value" ;;
    esac
    echo "$value"
}

post() {
    curl -fsS --max-time 5 -X POST "$URL/increment" >/dev/null || error "POST /increment не сработал"
}

check_count() {
    actual=$(count)
    [ "$actual" = "$1" ] || error "Ожидалось $1, получилось $actual"
    echo "count = $actual, OK"
}

check_status() {
    response=$(curl -sS --max-time 5 -w ' CURL_STATUS:%{http_code}' -X "$1" "$URL$2") || error "$1 $2 не ответил"
    code=${response##*CURL_STATUS:}
    [ "$code" = "$3" ] || error "$1 $2: ожидался код $3, пришёл $code"
    echo "$1 $2: $code, OK"
}

echo "1. Запускаю тестовый проект"
compose up -d --build || error "Не удалось запустить контейнеры"
wait_app
check_count 0

echo "1a. Проверяю ограничения контейнера"
APP_ID=$(compose ps -q app)
[ -n "$APP_ID" ] || error "Не найден контейнер app"
UID_VALUE=$(compose exec -T app id -u) || error "Не получилось узнать UID"
[ "$UID_VALUE" != 0 ] || error "Приложение работает от root"
echo "UID = $UID_VALUE, OK"
LIMITS=$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.Memory}} {{.HostConfig.NanoCpus}}' "$APP_ID") || error "Не получилось проверить ограничения"
set -- $LIMITS
[ "$#" -eq 3 ] || error "Не удалось прочитать ограничения: $LIMITS"
[ "$1" = true ] || error "Корневая файловая система не read-only"
[ "$2" -gt 0 ] && [ "$2" -le 268435456 ] || error "Лимит памяти должен быть не выше 256 MiB: $2"
[ "$3" -gt 0 ] && [ "$3" -le 1000000000 ] || error "Лимит CPU должен быть не выше 1: $3"
echo "ReadonlyRootfs=$1 Memory=$2 NanoCpus=$3, OK"

echo "2. Увеличиваю счётчик $N раз"
i=0
while [ "$i" -lt "$N" ]; do
    post
    i=$((i + 1))
done
check_count "$N"

echo "3. Пересоздаю только приложение"
compose up -d --no-deps --force-recreate app || error "Не удалось пересоздать app"
wait_app
check_count "$N"

echo "3a. Проверяю сохранность Redis после down/up без -v"
compose down || error "Не удалось остановить проект"
compose up -d || error "Не удалось поднять проект повторно"
wait_app
check_count "$N"

echo "4. Останавливаю Redis"
compose stop redis || error "Не удалось остановить Redis"
check_status GET /healthz 200
check_status GET /readyz 503
check_status POST /increment 503

echo "5. Запускаю Redis обратно"
compose start redis || error "Не удалось запустить Redis"
wait_app
check_count "$N"
post
NEXT=$((N + 1))
check_count "$NEXT"

echo "6. Делаю резервную копию"
compose stop app redis || error "Не удалось остановить контейнеры"
docker run --rm -v "${PROJECT}_redis_data:/data:ro" alpine:3.20 tar -C /data -cf - . > "$BACKUP" || error "Ошибка копирования"
[ -s "$BACKUP" ] || error "Резервная копия пустая"
echo "Файл: $BACKUP"
compose down -v || error "Не удалось удалить тестовый проект"

echo "7. Восстанавливаю копию в новом проекте"
compose_restore up -d redis || error "Не удалось создать Redis"
compose_restore stop redis || error "Не удалось остановить Redis"
docker run --rm -i -v "${RESTORE}_redis_data:/data" alpine:3.20 sh -c \
    'cd /data && rm -rf -- ./* ./.[!.]* ./..?* && tar -xpf -' < "$BACKUP" || error "Не удалось восстановить файлы"
compose_restore up -d || error "Не удалось запустить восстановленный проект"
wait_app
check_count "$NEXT"
post
LAST=$((NEXT + 1))
check_count "$LAST"

echo "Все проверки прошли успешно"
