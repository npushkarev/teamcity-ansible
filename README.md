# TeamCity 2026.2 на Debian 13 из ProGet с переносом данных

Новая ВМ с TeamCity Server и PostgreSQL 16 в Docker, данные старого TeamCity 2018.1.3 (проекты, пользователи, история, артефакты) и https. Подготовка ВМ — `00` и `01`, всё остальное — **одна команда** `50`.

> **Переезд пошагово** (подготовка, репетиция, день переезда, агенты, откат) — **[MIGRATION.md](MIGRATION.md)**.

| Плейбук | Что делает |
|---|---|
| `00-bootstrap-keys.yml` | hostname, `/etc/hosts`, прокси apt, Python, время (chrony), базовые пакеты, сертификат УЦ и ProGet в apt, SSH-ключ control node |
| `01-expand-root.yml` | растягивает корень `/` на весь диск, swap-раздел заменяет файлом `/swapfile` |
| **`50-teamcity-migrate.yml`** | **всё остальное**: `40` + `53` + https на nginx + восстановление backup + обновление данных 2018 → 2026 + запуск |
| `40-teamcity-backup-upload.yml` | (часть `50`) переносит backup и артефакты из `migration/` на ВМ: rsync, докачка, проверка SHA-256 |
| `53-teamcity-proget.yml` | (часть `50`) Docker и Compose v2 из Debian, настройки Docker, образы из ProGet, `compose.yaml` |
| `60-teamcity-agents-linux.yml` | Linux-агенты на новый сервер по https: агент 2026 рядом со старым (или перенаправление уже перенесённого), старый выключается после сборки, авторизация и пул |

Локальный build agent не создаётся: сборки выполняет внешний агент.

## Что нужно

- **ВМ Debian 13.** Рекомендуется 4 CPU, 8 ГБ RAM, диск 100–200 ГБ. В Debian 12 нет Compose v2, и `53` остановится с ошибкой.
- **Control node** — машина с Ansible и сетевым доступом к ВМ. Запускать от своего пользователя, без `sudo`.
- **SSH-ключ** `~/.ssh/id_ed25519` (создать: `ssh-keygen -t ed25519`).
- **Корневой сертификат УЦ** в `files/ca/ca.crt` (см. `files/ca/README.md`).
- **Сертификат для https** — wildcard `*.inc.elara.local`: `files/tls/inc.elara.local.cer` и `files/tls/inc.elara.local.key` (см. `files/tls/README.md`).
- **Образы в ProGet:**
  ```text
  proget.inc.elara.local/main/library/teamcity-server:2026.2-unlimited
  proget.inc.elara.local/main/library/postgres:16
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

`inventory/hosts.yml` и `inventory/vault.yml` в git не попадают. Все плейбуки (`00`, `50`, `53`) читают один и тот же `vault.yml`.

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

## 4. Backup старого TeamCity

Старый сервер при этом **не меняется** и остаётся точкой отката.

- **Репетиция** — без остановки: **Administration → Backup**, scope *Custom*: база, настройки, логи сборок, personal changes. Файл появится в `<Data Directory>/backup/` (на текущем сервере — `/data/teamcity-data/backup/`).
- **Финальный перенос** — в окно простоя: дождаться завершения сборок, остановить сервер и сделать backup той же версией 2018.1.3:
  ```bash
  <TeamCity Home>/bin/maintainDB.sh backup -C -D -L -P -U -A <Data Directory> -F TeamCity_Backup
  ```

Положите на control node (в git не попадает):

```text
migration/TeamCity_Backup.zip   ← backup (переименуйте файл в это имя)
migration/artifacts/            ← <Data Directory>/system/artifacts (необязательно: артефактов нет в ZIP)
files/tls/inc.elara.local.cer   ← сертификат https
files/tls/inc.elara.local.key   ← ключ
```

Например:

```bash
mkdir -p migration
scp root@<старый-сервер>:/data/teamcity-data/backup/<имя>.zip migration/TeamCity_Backup.zip
```

На control node нужен `rsync`: `sudo apt install rsync`.

## 5. Перенос одной командой

```bash
ansible-playbook playbooks/50-teamcity-migrate.yml --limit $H --ask-vault-pass
```

Что происходит:

1. Проверки: архив, сертификат и ключ на месте.
2. Backup и артефакты копируются на ВМ в `/srv/teamcity-migration` (как `40`).
3. Docker, образы из ProGet, `/opt/teamcity-2026/compose.yaml` (как `53`). TeamCity слушает только `127.0.0.1:8111`.
4. **https**: nginx на 443 с сертификатом из `files/tls/`, `http` → `https`. Проверяется, что ключ подходит к сертификату, сертификат не просрочен и подходит к имени ВМ.
5. **Восстановление** backup в PostgreSQL (`maintainDB restore`), артефакты, адрес сервера `https://<имя ВМ>`.
6. **Первый запуск**: принимается лицензионное соглашение TeamCity, данные обновляются 2018 → 2026 без ручного подтверждения, сервер перезапускается в обычном режиме.

Итог: `https://deb-13-test-teamcity.inc.elara.local`, вход — пользователями старого сервера. Обновление данных **необратимо** для этой ВМ; старый сервер не затрагивается.

Запуская `50`, вы принимаете [TeamCity License Agreement](https://www.jetbrains.com/legal/docs/teamcity/license/): плейбук принимает его сам. Если нужно принимать в браузере — `teamcity_accept_license_agreement: false` в `hosts.yml`: плейбук остановится на ожидании, подскажет, что сделать, и продолжит сам.

Повторный запуск безопасен: восстановление (`/opt/teamcity-2026/.restored`) и первый запуск (`.upgraded`) выполняются один раз; если прошлый запуск оборвался — продолжит с места остановки. Тома Docker плейбук не удаляет. Если восстановление упало, журнал — `/opt/teamcity-2026/restore.log`, а плейбук подскажет, как начать заново.

## 6. После переноса

Восстановленный сервер — копия рабочего: опрашивает VCS, отправляет письма и webhooks. На репетиции сразу отключите триггеры сборок и уведомления.

- Проверьте проекты, пользователей, историю и артефакты.
- **Агенты** (для CI/CD): в `<агент>/conf/buildAgent.properties` укажите `serverUrl=https://deb-13-test-teamcity.inc.elara.local`. Java агента должна доверять корпоративному УЦ. Затем **Agents → Unauthorized → Authorize** и пробная сборка.

**Финальный перенос** — из **нового** backup и в **чистые** тома: новая ВМ или `cd /opt/teamcity-2026 && docker compose down -v && rm -f .restored .upgraded` (удалит базу и данные этой ВМ — только осознанно), затем снова `50`. Потом переключите агентов и адрес на новый сервер. Откат — снова запустить старый сервер.

**Чистая установка без переноса:** в `hosts.yml` поставьте `teamcity_start_containers: true` и удалите `teamcity_migration_staging_dir`, затем выполните только `53` и пройдите мастер настройки на `http://<IP>:8111` (для этого `teamcity_bind_address: 0.0.0.0`).

## 7. Агенты (Linux)

Запускать **после** переключения адреса на новый сервер: старые агенты останавливаются (после текущей сборки) и перестают работать со старым сервером.

Что положить на control node:

- `files/teamcity-agent/jdk/` — пакеты Java 21 `teamcity-agent-jdk21_*_amd64.deb` (Debian 12+) и `..._~deb9_amd64.deb` (Debian 9–11, Ubuntu 22.04, Astra) из GitLab `root/teamcity` (см. `files/teamcity-agent/README.md`);
- `files/ca/ca.crt` — корпоративный УЦ (уже есть после `00`);
- в `vault.yml` — `vault_teamcity_admin_token`: токен администратора **нового** TeamCity (**Profile → Access Tokens**), чтобы плейбук сам авторизовал агентов и поставил их в пул старых;
- в `hosts.yml` — группа `teamcity_agents_linux` с агентами (пример в `hosts.example.yml`).

```bash
# первый агент, вход root по паролю (плейбук разложит SSH-ключ)
ansible-playbook playbooks/60-teamcity-agents-linux.yml --limit ba-deb12-01.inc.elara.local \
  --ask-pass --ask-vault-pass -e agents_confirm=yes

# остальные — по одному, сами
ansible-playbook playbooks/60-teamcity-agents-linux.yml --limit teamcity_agents_linux \
  --ask-pass --ask-vault-pass -e agents_confirm=yes
```

На каждом агенте плейбук:

1. кладёт скрипт `teamcity-agent-linux-migrate.sh`, подходящий пакет Java (по версии libc6) и `buildAgentFull.zip` с нового сервера — с корпоративным УЦ в `conf/trustedCertificates` (агент сразу доверяет https; Java и системная Java не меняются);
2. добавляет УЦ в систему агента (`update-ca-certificates`);
3. запускает скрипт с `--check`, затем перенос: новый агент `/opt/buildAgent2026` (служба `teamcity-agent2026`), параметры старого переносятся, старый останавливается **после текущей сборки**, его автозапуск выключается. Папка старого агента не меняется; при сбое скрипт сам возвращает старого;
4. авторизует нового агента (`<имя>-2026`) и ставит его в пул старого.

Если на агенте **уже стоит** агент 2026 от этих скриптов, но смотрит на другой сервер (например, тестовый `http://172.17.6.61:8111`), он не ставится заново, а **перенаправляется**: копия `buildAgent.properties`, новый `serverUrl`, старый токен удаляется (агент получит новый), УЦ в `conf/trustedCertificates`, перезапуск службы после текущей сборки; старый агент 2018 выключается скриптом `teamcity-agent-linux-disable-old.sh`. Журналы и команды возврата — на агенте в `/root/teamcity-agent-migrate/`.

Агенты переносятся по одному. Если на агенте сборка идёт дольше 10 минут, он пропускается с пометкой «ЖДЁТ СБОРКУ» — запустите плейбук для него позже. Python на агентах не нужен (подходит и Debian 9).

Не переносятся этим плейбуком: `ba-rosa-01` (ROSA, не dpkg) и Windows-агенты — вручную, см. [MIGRATION.md](MIGRATION.md), разделы 5–6. Репетиция без остановки старых агентов: `-e teamcity_agents_keep_old=true` (новый агент работает рядом на порту 9091).

Вернуть старого агента и удалить нового — команды печатает скрипт; подробно: `docs/teamcity-agent-linux-migrate.md`.

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
