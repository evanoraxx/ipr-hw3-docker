# ДЗ 3 — Docker

Здесь я запускаю приложение-счётчик в Docker. Само приложение лежит в папке `app`, его код не менялся.

Для работы нужны Docker, Docker Compose и `curl`. Скрипт проверки запускается через Linux, WSL или Git Bash.

## Файлы

- `Dockerfile` — образ с приложением.
- `compose.sqlite.yaml` — приложение с SQLite и volume (задание на 6 баллов).
- `compose.yaml` — приложение и Redis (задания на 8–10 баллов).
- `.env.example` — настройки порта и приветствия.
- `scripts/check.sh` — проверка для 10 баллов.
- `scripts/verify-and-report.sh` — собирает настоящие логи и делает два запуска проверки.
- `REPORT.md` — отчёт; автоматически заполняется только после успешных проверок.

## Быстрая проверка всей работы

Из корня проекта запусти:

```sh
sh scripts/verify-and-report.sh
```

Скрипт проверяет уровни 4 и 6, затем дважды запускает сценарий на 10 баллов.
Когда все проверки прошли, он **сам** заполнит `REPORT.md` и создаст
`reports/level4.txt`, `reports/level6.txt`, `reports/check1.txt`,
`reports/check2.txt`. Эти файлы нужно закоммитить вместе с работой.

**Важно:** Docker должен быть запущен, а порт из `CHECK_PORT` — свободен.
Пока этот скрипт не выполнен успешно, нельзя утверждать, что проект полностью
проверен. Если порт занят, например, используй `CHECK_PORT=28555 sh scripts/verify-and-report.sh`
(в PowerShell для такой команды удобнее открыть WSL или Git Bash).

## 1. Запуск контейнера (4 балла)

```sh
docker build -t counter-app .
docker run -d --name counter -p 8080:8000 -e GREETING="Hello from Docker" counter-app
curl http://localhost:8080/
curl -X POST http://localhost:8080/increment
curl -X POST http://localhost:8080/increment
docker logs counter
docker rm -f counter
```

При запуске `verify-and-report.sh` настоящие логи контейнера автоматически сохраняются в `reports/level4.txt`.

## 2. Docker Compose и SQLite (6 баллов)

Создать `.env` из примера:

```sh
cp .env.example .env
```

В PowerShell вместо `cp` можно написать `Copy-Item .env.example .env`.

```sh
docker compose -f compose.sqlite.yaml up -d --build
curl -X POST http://localhost:8080/increment
curl http://localhost:8080/
docker compose -f compose.sqlite.yaml down
docker compose -f compose.sqlite.yaml up -d
curl http://localhost:8080/
docker compose -f compose.sqlite.yaml down
```

Значение `count` после второго `up` должно остаться таким же. Данные хранятся в `sqlite_data`. При проверке нельзя использовать `down -v` — эта команда удаляет volume.

## 3. Redis (8 баллов)

Основной вариант запуска:

```sh
docker compose up -d --build
docker compose ps
curl http://localhost:8080/
curl -X POST http://localhost:8080/increment
curl -X POST http://localhost:8080/increment
docker compose down
docker compose up -d
curl http://localhost:8080/
```

В `compose.yaml` есть два сервиса: `app` и `redis`. Приложение подключается к Redis по адресу `redis://redis:6379/0`. Redis использует volume `redis_data` и сохраняет данные на диск с помощью AOF. Наружу открыт только порт приложения.

Проверка остановки Redis:

```sh
docker compose stop redis
curl -i http://localhost:8080/healthz
curl -i http://localhost:8080/readyz
curl -i -X POST http://localhost:8080/increment
docker compose start redis
curl http://localhost:8080/
curl -X POST http://localhost:8080/increment
```

Ожидаемые коды при остановленном Redis: `200` для `/healthz` и `503` для `/readyz` и `/increment`. После запуска Redis счётчик должен продолжить работу без перезапуска `app`.

## 4. Проверка на 10 баллов

В основном Compose-файле для `app` стоят ограничения: пользователь с UID `10001`, файловая система только для чтения, 256 MiB памяти и 1 CPU.

Проверить их можно так:

```sh
docker compose exec app id -u
docker inspect "$(docker compose ps -q app)" --format '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.Memory}} {{.HostConfig.NanoCpus}}'
```

Запуск автоматической проверки:

```sh
sh scripts/check.sh
sh scripts/check.sh
```

Скрипт создаёт отдельный тестовый проект, проверяет счётчик, ограничения контейнера, пересоздаёт приложение, проверяет `down/up`, останавливает и запускает Redis, делает резервную копию данных и восстанавливает их в новом проекте. Тестовые контейнеры и volumes после проверки удаляются. Резервная копия остаётся в `backups/`.

Для отчёта нужно сохранить вывод двух **действительно успешных** запусков. Команда `verify-and-report.sh` делает это сама. Если запускать `check.sh` вручную, можно сохранить логи так:

```sh
mkdir -p reports
sh scripts/check.sh > reports/check1.txt 2>&1
sh scripts/check.sh > reports/check2.txt 2>&1
```

Если работаешь в PowerShell, удобнее выполнить эти команды в WSL или Git Bash.

## Настройки

В `.env` можно менять `HOST_PORT` и `GREETING`. По умолчанию порт — `8080`, приветствие — `Hello, Docker!`. В примерах выше используется именно порт `8080`.

После успешного `verify-and-report.sh` проверь результаты в `REPORT.md` и `reports/`, затем загрузи файлы в свой репозиторий GitHub. Для сдачи достаточно одного финального коммита.

Если коммитишь с Windows, убедись, что скрипт сохранится в Git как исполняемый:

```sh
git add .
git update-index --chmod=+x scripts/check.sh scripts/verify-and-report.sh
git commit -m "Docker HW3"
git push
```

Перед этим нужно создать свой репозиторий и настроить `git remote`, как указано в задании.
Файлы `app/` оставь без изменений.
