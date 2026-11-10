# TeamCity 2026.2 на Debian 13 из ProGet с переносом данных

Три плейбука готовят новую ВМ и TeamCity Server с PostgreSQL 16 в Docker, куда затем восстанавливаются данные старого TeamCity 2018.1.3 (проекты, пользователи, история, артефакты):

| Плейбук | Что делает |
|---|---|
| `00-bootstrap-keys.yml` | hostname, `/etc/hosts`, прокси apt, Python, время (chrony), базовые пакеты, сертификат УЦ и ProGet в apt, SSH-ключ control node |
| `01-expand-root.yml` | растягивает корень `/` на весь диск, swap-раздел заменяет файлом `/swapfile` |
| `40-teamcity-backup-upload.yml` | переносит backup и артефакты старого TeamCity из `migration/` на ВМ (rsync, докачка, проверка SHA-256) |
| `53-teamcity-proget.yml` | Docker и Compose v2 из Debian, настройки Docker, образы из ProGet, Compose. При переносе (по умолчанию) TeamCity **не запускается** |

Локальный build agent не создаётся: сборки выполняет внешний агент.

## Что нужно

- **ВМ Debian 13.** Рекомендуется 4 CPU, 8 ГБ RAM, диск 100–200 ГБ. В Debian 12 нет Compose v2, и `53` остановится с ошибкой.
- **Control node** — машина с Ansible и сетевым доступом к ВМ. Запускать от своего пользователя, без `sudo`.
- **SSH-ключ** `~/.ssh/id_ed25519` (создать: `ssh-keygen -t ed25519`).
- **Корневой сертификат УЦ** в `files/ca/ca.crt` (см. `files/ca/README.md`).
- **Образы в ProGet:**
  ```text
  proget.inc.elara.local/main/library/teamcity-server:2026.2-unlimited
  proget.inc.elara.local/main/library/postgres:16-alpine
  ```

## 1. Подготовить ВМ в vSphere

В **Edit Settings**, пока ВМ выключена:

1. Укажите нужный размер диска.
2. Задайте память и CPU.
3. У сетевого адаптера включите **Connected** и **Connect At Power On**.

Если у ВМ есть snapshots, диск не увеличить: сначала удалите их.

Включите ВМ. В консоли узнайте IP (`ip a`) и проверьте, что root входит по SSH с паролем (`PermitRootLogin yes`).

## 2. Настроить проект

```bash
git clone https://github.com/npushkarev/teamcity-ansible.git
cd teamcity-ansible
ansible-galaxy collection install -r requirements.yml -p ./collections

cp inventory/hosts.example.yml inventory/hosts.yml      # имя ВМ и IP
cp inventory/vault.example.yml inventory/vault.yml      # пароли и при необходимости прокси
openssl rand -hex 24                                    # пароль PostgreSQL для vault.yml
ansible-vault encrypt inventory/vault.yml
```

`inventory/hosts.yml` и `inventory/vault.yml` в git не попадают. Оба плейбука, `00` и `53`, читают один и тот же `vault.yml`.

## 3. Подготовить ВМ

Подставьте имя ВМ из `hosts.yml`. Флаг `--limit` обязателен.

```bash
H=deb-13-test-teamcity.inc.elara.local

# Подготовка Debian. Пароль root нужен только здесь.
ansible-playbook playbooks/00-bootstrap-keys.yml --limit $H --ask-pass --ask-vault-pass

# Увеличьте диск в vSphere, сделайте snapshot ВМ, затем расширение диска.
ansible-playbook playbooks/01-expand-root.yml --limit $H -e expand_root_confirm=yes
```

Варианты для `00`:

- нет `ca.crt` — добавьте `-e bootstrap_proget_enabled=false`, а в `hosts.yml` поставьте `teamcity_registry_insecure: true`;
- время уже выставлено и NTP недоступен — добавьте `-e bootstrap_time_sync=false`.

## 4. Backup старого TeamCity и копирование на ВМ

Старый сервер при этом **не меняется** и остаётся точкой отката.

- **Репетиция** — без остановки: **Administration → Backup**, scope *Custom*: база, настройки, логи сборок, personal changes.
- **Финальный перенос** — в окно простоя: дождаться завершения сборок, остановить сервер и сделать backup той же версией 2018.1.3:
  ```bash
  <TeamCity Home>/bin/maintainDB.sh backup -C -D -L -P -U -A <Data Directory> -F TeamCity_Backup
  ```

**Артефакты сборок в ZIP не входят**: их нужно взять отдельно из `<Data Directory>/system/artifacts`. UI-backup лежит на старом сервере в `<Data Directory>/backup/`.

Положите всё в папку `migration/` проекта на control node (в git она не попадает):

```text
migration/
├── TeamCity_Backup.zip   ← backup (переименуйте файл в это имя)
└── artifacts/            ← содержимое <Data Directory>/system/artifacts
```

и перенесите на ВМ (нужен `rsync` на control node: `sudo apt install rsync`):

```bash
ansible-playbook playbooks/40-teamcity-backup-upload.yml --limit $H
```

Плейбук проверит свободное место, скопирует всё в `/srv/teamcity-migration` по rsync и сверит SHA-256 архива. Права выставляются сразу: `1000:1000` (пользователь TeamCity в контейнере), `0700`/`0600` (в ZIP есть пароли и токены). При обрыве просто запустите его ещё раз: он докачает только недостающее. На ВМ он ничего не удаляет.

## 5. Подготовить TeamCity без запуска

```bash
ansible-playbook playbooks/53-teamcity-proget.yml --limit $H --ask-vault-pass
```

В `hosts.yml` уже стоят `teamcity_start_containers: false` и `teamcity_migration_staging_dir: /srv/teamcity-migration`. `53` ставит Docker, скачивает образы и пишет `/opt/teamcity-2026/compose.yaml`, но **не запускает** TeamCity и PostgreSQL. Если запустить их раньше времени, создастся пустая база, и восстанавливать будет некуда. Если каталога `/srv/teamcity-migration` нет, `53` остановится.

## 6. Артефакты и восстановление (на ВМ)

Сначала артефакты, **до** первого запуска сервера:

```bash
cd /opt/teamcity-2026
docker compose create db server                    # создать тома, ничего не запуская
IMG=$(docker compose config --images | grep teamcity-server)
docker run --rm --network none --user 0:0 \
  -v teamcity-2026_server_data:/target \
  -v /srv/teamcity-migration/artifacts:/source:ro \
  --entrypoint sh "$IMG" \
  -ec 'mkdir -p /target/system/artifacts && cp -a /source/. /target/system/artifacts/ && chown -R 1000:1000 /target/system/artifacts'
docker compose up -d db server
```

Откройте `http://<IP>:8111` → **Restore from backup**:

- файл `/migration/TeamCity_Backup.zip`;
- база PostgreSQL: сервер `db:5432`, база и пользователь `teamcity`, пароль — `vault_teamcity_db_password` из `vault.yml`.

Нового администратора **не создавайте**: пользователи придут из backup. После восстановления TeamCity предложит обновить формат данных 2018 → 2026. Это **необратимо**: старый 2018.1.3 на этих данных уже не запустится. Старый сервер со своими данными при этом остаётся нетронутым.

Восстановленный сервер ведёт себя как настоящий: опрашивает VCS, отправляет письма и webhooks. На репетиции отключите сборки по триггерам и уведомления сразу после восстановления.

Проверьте проекты, пользователей, историю и артефакты, запустите пробную сборку на внешнем агенте (**Agents → Unauthorized** → авторизовать).

**Финальный перенос** — из **нового** backup и в **чистые** тома. Данные репетиции для него не годятся: используйте новую ВМ или удалите тома репетиции (`docker compose down -v` удалит базу и данные — только осознанно). Затем переключите агентов и адрес на новый сервер. Откат — снова запустить старый сервер.

**Чистая установка без переноса:** в `hosts.yml` поставьте `teamcity_start_containers: true` и удалите `teamcity_migration_staging_dir`, затем выполните `53`, откройте `http://<IP>:8111` и пройдите мастер настройки.

## Расширение диска (01)

Сначала увеличьте диск в vSphere, **потом** сделайте snapshot. Snapshot до увеличения запретит менять размер диска.

Плейбук рассчитан на разметку debian-installer: корень ext4, за ним swap, обычно внутри extended-раздела.

- Удаляются **только** swap и extended **после** корня.
- Разделы перед корнем, например `/boot/efi`, не трогаются.
- Если после корня есть раздел с данными (`/home`, LVM) или смонтированный раздел, плейбук остановится до любых изменений.
- Корень на LVM или не ext4 — тоже остановка.

Если ядро не перечитает таблицу разделов, ВМ перезагрузится автоматически. Отключить перезагрузку: `-e expand_root_reboot=false`. Повторный запуск безопасен: когда диск уже расширен, плейбук ничего не делает.

## Настройки Docker (53)

В `/etc/docker/daemon.json` плейбук добавляет только свои ключи, остальные сохраняет:

- `log-opts` — 3 файла по 50 МБ на контейнер;
- `default-ulimits` — `nofile 65536`;
- `dns` — `172.17.0.2`, `172.17.0.7` и поиск `inc.elara.local`. Без этого контейнеры, запущенные до выдачи DNS по DHCP, получают `8.8.8.8` и не видят внутренние хосты (Bitbucket и т. п.). `teamcity_docker_dns: []` — не управлять DNS;
- `insecure-registries` — только при `teamcity_registry_insecure: true`.

Docker перезапускается только при изменении этих настроек. Пароли ProGet и PostgreSQL в вывод не попадают, после загрузки образов выполняется `docker logout`.

## Повторный запуск и данные

`53` можно запускать повторно. Если ничего не изменилось, он ничего не меняет и не перезапускает. Новый образ из ProGet подхватывается: Compose пересоздаёт только изменившиеся контейнеры.

Данные хранятся в Docker volumes проекта `teamcity-2026`:

- `db_data` — PostgreSQL;
- `server_data` — TeamCity Data Directory;
- `server_logs` — журналы.

**Не выполняйте `docker compose down -v`**: это удалит базу и данные TeamCity. Пароль PostgreSQL после первого запуска нельзя просто поменять в `vault.yml`. Перед обновлением TeamCity делайте резервную копию БД и Data Directory.

Проверка на ВМ:

```bash
docker compose -f /opt/teamcity-2026/compose.yaml ps
```
