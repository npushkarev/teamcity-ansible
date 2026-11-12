# Справочник: настройки и подробности

Как всё устроено внутри и что можно настроить. Шаги переезда — [MIGRATION.md](../MIGRATION.md).

- [Control node](#control-node)
- [Inventory и vault](#inventory-и-vault)
- [Сертификаты](#сертификаты)
- [00: подготовка ВМ](#00-подготовка-вм)
- [01: расширение диска](#01-расширение-диска)
- [50: что происходит](#50-что-происходит)
- [Повторный запуск и данные](#повторный-запуск-и-данные)
- [53: Docker и образы](#53-docker-и-образы)
- [Переменные сервера](#переменные-сервера)
- [Агенты: как работает 60](#агенты-как-работает-60)
- [Агенты: переменные](#агенты-переменные)
- [Агенты: что где лежит](#агенты-что-где-лежит)
- [Windows-агенты](#windows-агенты)
- [ROSA и RPM-системы](#rosa-и-rpm-системы)

## Control node

| Пакет | Зачем |
|---|---|
| `ansible` | Debian 13: пакет `ansible` 12 = ansible-core 2.19, вместе с коллекциями `ansible.posix`, `community.general`, `ansible.windows` |
| `python3-winrm` | WinRM к Windows-агентам (`62`) |
| `sshpass` | `--ask-pass`: вход по паролю (`00`, первый запуск `60` на Linux-агентах) |
| `rsync` | `40`/`50`: копирование backup на ВМ |

- Запускать от своего пользователя, без `sudo`: `00` и `61` берут ключ `$HOME/.ssh/id_ed25519.pub`. Другой ключ — `-e ssh_pubkey_path=<путь>.pub`, приватный — тот же путь без `.pub`.
- `ansible-galaxy collection install -r requirements.yml -p ./collections` нужен, только если Ansible не из пакета Debian (нужен доступ к galaxy.ansible.com). Он ставит `ansible.posix` и `community.general`; `ansible.windows` для `62` — `ansible-galaxy collection install ansible.windows -p ./collections`.
- Проект из ZIP: `chmod -R go-w .` — из папки, открытой на запись всем, Ansible не читает `ansible.cfg`.
- Пароль vault файлом (необязательно; тогда `--ask-vault-pass` можно не указывать):

```bash
mkdir -p ~/.ansible && install -m 600 /dev/null ~/.ansible/vault_pass_migration
read -rs P; printf '%s\n' "$P" > ~/.ansible/vault_pass_migration; unset P
```

Затем в `ansible.cfg` раскомментировать `vault_password_file = ~/.ansible/vault_pass_migration`.

## Inventory и vault

| Группа | Хосты | Доступ |
|---|---|---|
| `teamcity` | `deb-13-test-teamcity.inc.elara.local` | SSH, root |
| `teamcity_agents_linux` | 20, вместе с `ba-rosa-01` и `ba-deb-test` | SSH, root; keepalive 30 с (ожидание сборки идёт молча) |
| `teamcity_agents_windows` | 11 | WinRM: http 5985, NTLM, шифрование сообщений |
| `pilot` | 7: `ba-deb-02`, `ba-deb-06`, `ba-deb-test`, `ba-w22-01`, `ba-w22-03`, `ba-win-01`, `ba-win-10` | — |

- Имена хостов — FQDN: `--limit ba-deb-01` ничего не найдёт, нужно `--limit ba-deb-01.inc.elara.local`.
- Переменная для одного хоста — у него в `hosts.yml`; `-e` действует на все хосты запуска.
- `vault.yml` читают сами `00`, `50`, `53`, `60`/`61`/`62` (`01` и `40` — нет). Он не в `group_vars`: `00` останавливается, если есть `inventory/group_vars/all/vault.yml`. Разовым командам `ansible` нужен `-e @inventory/vault.yml --ask-vault-pass`.
- Ключи vault и когда они нужны — [MIGRATION.md](../MIGRATION.md), 1.3.

## Сертификаты

| Файл | Где оказывается | Зачем |
|---|---|---|
| `files/ca/ca.crt` (PEM) | ВМ: `/usr/local/share/ca-certificates/elara-ca.crt` и пакет `ca-certificates-elara` (`00`); агенты: `conf/trustedCertificates/elara-ca.pem` и системное хранилище; control node: проверка https и REST нового сервера (`60`) | доверие |
| сертификат из `files/tls/` | ВМ: `/etc/ssl/elara/<имя>.crt` (DER переводится в PEM); агенты: `conf/trustedCertificates/teamcity-server.pem` | https на nginx |
| ключ из `files/tls/` | ВМ: `/etc/ssl/elara/<имя>.key`, права 600 | https на nginx |

`<имя>` — `teamcity_public_name`, пока он не задан — имя ВМ.

- Порядок в `00`: `ca.crt` файлом → ProGet в источниках apt и его GPG-ключ → пакет `ca-certificates-elara`. Пакет с УЦ лежит на самом ProGet, поэтому первый раз УЦ кладётся файлом.
- Системное хранилище агентов: Debian, Ubuntu, Astra — `update-ca-certificates`; ROSA — `update-ca-trust`; Windows — `LocalMachine\Root`.
- `50` проверяет: ключ подходит к сертификату, сертификат не просрочен и подходит к `<имя>`. https работает, но цепочка не проверяется по доверенным УЦ — `50` предупреждает: нужен сертификат с промежуточным УЦ в том же файле.

## 00: подготовка ВМ

По порядку: проверки на control node (ключ, `files/ca/ca.crt`); hostname = имя из inventory, строка `127.0.1.1` в `/etc/hosts`; прокси apt из vault (`/etc/apt/apt.conf.d/00-platform-proxy`); python3; время — chrony на `172.17.0.2`, `172.17.0.7` до любого `apt update` (иначе apt отвергает подпись ProGet); базовые пакеты и утилиты диска; УЦ и ProGet в apt; ключ control node в `/root/.ssh/authorized_keys`; проверка входа по ключу. Вход root по паролю не закрывается.

| Вариант | Как |
|---|---|
| нет `ca.crt` | `-e bootstrap_proget_enabled=false`, в `hosts.yml` `teamcity_registry_insecure: true`. Не для этого переезда: `60` без `ca.crt` не запустится |
| время уже выставлено, NTP недоступен | `-e bootstrap_time_sync=false` |

В конце вывода `00` (и `01`) следующим назван `53` — при переносе вместо него `50`.

## 01: расширение диска

Сначала увеличьте диск в vSphere, **потом** сделайте snapshot. Snapshot до увеличения запретит менять размер диска.

Плейбук рассчитан на разметку debian-installer: корень ext4, за ним swap, обычно внутри extended-раздела.

- Удаляются **только** swap и extended **после** корня.
- Разделы перед корнем, например `/boot/efi`, не трогаются.
- Если после корня есть раздел с данными (`/home`, LVM) или смонтированный раздел, плейбук остановится до изменения разделов.
- Корень на LVM или не ext4 — тоже остановка.

Swap возвращается файлом `/swapfile` на 2048 МиБ (`swapfile_size_mb`). Если ядро не перечитает таблицу разделов, ВМ перезагрузится автоматически. Отключить перезагрузку: `-e expand_root_reboot=false`. Повторный запуск безопасен: когда корень уже занимает 90 % диска и больше, плейбук ничего не делает.

> [!WARNING]
> У `01` нет проверки `--limit` (`hosts: all`): без `--limit` он пойдёт на все хосты inventory, включая Debian-агентов.

## 50: что происходит

1. Проверки: архив, сертификат и ключ на месте.
2. Backup и артефакты копируются на ВМ в `/srv/teamcity-migration` (как `40`).
3. Docker, образы из ProGet, `/opt/teamcity-2026/compose.yaml` (как `53`). TeamCity слушает только `127.0.0.1:8111`.
4. **https**: nginx на 443 с сертификатом из `files/tls/`, `http` → `https` (308). Проверяется, что ключ подходит к сертификату, сертификат не просрочен и подходит к `teamcity_public_name` или имени ВМ.
5. **Восстановление** backup в PostgreSQL (`maintainDB restore`), артефакты, адрес сервера `https://<teamcity_public_name или имя ВМ>`.
6. **Первый запуск**: принимается лицензионное соглашение TeamCity, данные обновляются 2018 → 2026 без ручного подтверждения, сервер перезапускается в обычном режиме.

Итог: `https://deb-13-test-teamcity.inc.elara.local`, вход — пользователями старого сервера. Обновление данных **необратимо** для этой ВМ; старый сервер не затрагивается.

Запуская `50`, вы принимаете [TeamCity License Agreement](https://www.jetbrains.com/legal/docs/teamcity/license/): плейбук принимает его сам. Если нужно принимать в браузере — `teamcity_accept_license_agreement: false` в `hosts.yml`: плейбук остановится на ожидании, подскажет, что сделать, и продолжит сам.

Пределы ожидания: восстановление — до 4 ч, первый запуск с обновлением данных — до 1 ч, запуск после него — до 20 мин.

| На ВМ | Что |
|---|---|
| `/opt/teamcity-2026/` | `compose.yaml`, `.env` (пароль БД, права 600), `jdbc/`, метки `.restored` и `.upgraded`, `restore.log` |
| `/srv/teamcity-migration/` | backup и артефакты (`1000:1000`, 700/600); в контейнере — `/migration`, только чтение |
| Docker volumes `teamcity-2026_*` | `db_data` — PostgreSQL, `server_data` — Data Directory, `server_logs` — журналы |
| `/etc/nginx/sites-available/<имя>.conf` | сайт: 80 → 308 на https, 443 → `127.0.0.1:8111` |
| `/etc/ssl/elara/` | сертификат и ключ https |
| `/var/log/nginx/<имя>-access.log`, `<имя>-error.log` | журналы nginx |

### Backup без UI (запасной вариант)

Если UI-backup на старом сервере не запускается: сервер остановлен, backup — той же версией 2018.1.3:

```bash
<TeamCity Home>/bin/maintainDB.sh backup -C -D -L -P -U -A <Data Directory> -F TeamCity_Backup
```

Файл — в `<Data Directory>/backup/`. ВМ не выключать: откат тот же (сеть в vSphere), но перед ним старый TeamCity нужно снова запустить.

## Повторный запуск и данные

- `50` повторять безопасно: восстановление (`/opt/teamcity-2026/.restored`) и первый запуск (`.upgraded`) выполняются один раз; оборвавшийся первый запуск продолжится. Тома Docker плейбук не удаляет.
- Восстанавливать можно только в пустые тома. Тома есть, а метки `.restored` нет (ручной запуск или оборванное восстановление) — `50` остановится; как начать заново — [MIGRATION.md](../MIGRATION.md), раздел 2, «Откат».
- **Не выполняйте `docker compose down -v`** на рабочем сервере: это удалит базу и данные TeamCity. Допустимо только для копии (репетиция, шаг 4.5).
- Пароль PostgreSQL после первого запуска нельзя просто поменять в `vault.yml`. Перед обновлением TeamCity делайте резервную копию БД и Data Directory.
- При переносе (`teamcity_start_containers: false`) `53` только скачивает образы и пишет `compose.yaml`; создаёт и пересоздаёт контейнеры `50`. Новый тег образа после переезда (`teamcity_registry_server_image` в `hosts.yml`): backup, затем `50`. Новая версия TeamCity встанет на страницу обслуживания и попросит подтвердить обновление в браузере, вход — как Super user (токен на ВМ: `docker compose -f /opt/teamcity-2026/compose.yaml logs server | grep 'Super user authentication token' | tail -n 1`); затем при необходимости `50` ещё раз.

Что уже сделано на ВМ (IP — `172.17.5.68`, после 4.8 — `<СТАРЫЙ_IP>`):

```bash
ssh root@<IP> 'hostname -f; df -h /; swapon --show; ls -l /opt/teamcity-2026/.restored /opt/teamcity-2026/.upgraded; docker compose -f /opt/teamcity-2026/compose.yaml ps'
```

FQDN — сделан `00`; `/` на весь диск и `/swapfile` — `01`; метки `.restored` и `.upgraded` — `50`; в `ps` — `db` (healthy) и `server` в состоянии Up. Журнал сервера: `docker compose -f /opt/teamcity-2026/compose.yaml logs --tail 200 server`.

## 53: Docker и образы

Docker и Compose v2 ставятся из репозитория Debian 13. В Debian 12 нет Compose v2, и `53` остановится с ошибкой.

В `/etc/docker/daemon.json` плейбук добавляет только свои ключи, остальные сохраняет:

- `log-opts` — 3 файла по 50 МБ на контейнер;
- `default-ulimits` — `nofile 65536`;
- `dns` — `172.17.0.2`, `172.17.0.7` и поиск `inc.elara.local`. Без этого контейнеры, запущенные до выдачи DNS по DHCP, получают `8.8.8.8` и не видят внутренние хосты (Bitbucket и т. п.). `teamcity_docker_dns: []` — не управлять DNS;
- `insecure-registries` — только при `teamcity_registry_insecure: true`.

Docker перезапускается только при изменении этих настроек. Пароли ProGet и PostgreSQL в вывод не попадают, после загрузки образов выполняется `docker logout`. Образы — `teamcity_registry_server_image` и `teamcity_registry_db_image`; что должно быть в ProGet — [MIGRATION.md](../MIGRATION.md), 1.2. Пример в шапке `53` с `-i inventory/teamcity-proget.yml` устарел: inventory — `inventory/hosts.yml` (из `ansible.cfg`).

**Чистая установка без переноса:** в `hosts.yml` поставьте `teamcity_start_containers: true` и удалите `teamcity_migration_staging_dir`, затем выполните только `53` и пройдите мастер настройки на `http://<IP>:8111` (для этого `teamcity_bind_address: 0.0.0.0`). Повторный `53` тогда ничего не меняет и не перезапускает, если ничего не изменилось; новый образ из ProGet подхватывается — Compose пересоздаёт только изменившиеся контейнеры.

## Переменные сервера

В `vars` группы `teamcity` в `hosts.yml`; `00` и `01` — через `-e`.

| Переменная | По умолчанию | Что делает |
|---|---|---|
| `teamcity_public_name` | имя ВМ | адрес `https://<имя>`: nginx, проверка сертификата, Server URL, адрес для агентов; в день переезда — `teamcity.inc.elara.local` (MIGRATION.md, 4.6) |
| `teamcity_bind_address` | `127.0.0.1` (`50` ставит сам) | адрес, на котором слушает TeamCity |
| `teamcity_port` | `8111` | порт TeamCity |
| `teamcity_deploy_dir` | `/opt/teamcity-2026` | каталог стека на ВМ |
| `teamcity_start_containers` | `false` в примере | `true` — `53` запускает контейнеры (чистая установка) |
| `teamcity_migration_staging_dir` | `/srv/teamcity-migration` | backup на ВМ; в контейнере — `/migration`, только чтение |
| `teamcity_migration_source_dir` | `migration/` проекта | откуда `40` берёт backup на control node |
| `teamcity_migration_backup_name` | `TeamCity_Backup.zip` | имя архива |
| `teamcity_accept_license_agreement` | `true` | `false` — принимать соглашение в браузере |
| `teamcity_local_agent_count` | `0` в примере | локальные агенты в Compose |
| `teamcity_registry` | `proget.inc.elara.local/main/library` | реестр образов |
| `teamcity_registry_server_image`, `teamcity_registry_db_image` | образы из MIGRATION.md, 1.2 | свой тег |
| `teamcity_registry_insecure` | `false` | `true` — реестр без проверки сертификата (`insecure-registries`) |
| `teamcity_docker_dns`, `teamcity_docker_dns_search` | `[172.17.0.2, 172.17.0.7]`, `[inc.elara.local]` | DNS контейнеров; `[]` — не управлять |
| `teamcity_docker_nofile` | `65536` | ulimit `nofile` контейнеров |
| `teamcity_docker_log_max_size`, `teamcity_docker_log_max_file` | `50m`, `3` | журналы контейнеров |
| `bootstrap_proget_enabled` | `true` | `00`: УЦ и ProGet в apt |
| `bootstrap_time_sync` | `true` | `00`: chrony на внутренние NTP |
| `expand_root_confirm` | `no` | `01`: `yes` — подтверждение, что snapshot сделан |
| `expand_root_reboot` | `true` | `01`: перезагрузка, если ядро не перечитало таблицу разделов |
| `swapfile_size_mb` | `2048` | `01`: размер `/swapfile` |

## Агенты: как работает 60

`60` = `61` (Linux: SSH под root, на агенте нужны только SSH и scp, Python не нужен) + `62` (Windows: WinRM). Проверки и копирование идут параллельно, сам перенос — по одному агенту (`teamcity_agents_parallel`). Сбой или недоступность одного агента не останавливает остальных: причина — в итоге, хост помечается упавшим в самом конце.

### Режим агента

Плейбук читает `serverUrl` в `conf/buildAgent.properties` нового агента (`/opt/buildAgent2026`, `C:\BuildAgent2026`).

| Новый агент | Режим | Что делается |
|---|---|---|
| нет | установка | Linux — `teamcity-agent-linux-migrate.sh`, Windows — `teamcity-agent-windows-migrate.ps1 -KeepOldService`: агент рядом со старым, Java 21, параметры `system.*`/`env.*` старого агента, УЦ в `conf/trustedCertificates` |
| есть, `serverUrl` другой (`172.17.6.61`, копия) | перенаправление | ждёт, пока на новом агенте нет сборки; копия `buildAgent.properties.bak-repoint-*`; новый `serverUrl`, старый токен удаляется, УЦ; перезапуск; успех — только с `Registered on server` в журнале агента. Параметры старого агента не переносятся |
| есть, `serverUrl` этого сервера | уже здесь | Linux: скрипт переноса берёт агента как есть и дописывает недостающие параметры старого (копия `buildAgent.properties.bak-*`); Windows: проверяет регистрацию, при необходимости перезапускает службу |
| `C:\BuildAgent2026` или служба есть, `conf` нет (Windows) | недоделан | отказ: `teamcity-agent-windows-remove-new.ps1 -Yes` из `C:\ProgramData\teamcity-agent-migrate`, затем повтор |

### Когда выключается старый агент

- **Linux, установка:** Java 21, распаковка, настройки, служба (включена, не запущена) → старый агент штатно останавливается после текущей сборки (до `teamcity_agents_wait`) и теряет автозапуск → новый запускается и ждёт `Registered on server` до 120 с (до 10 мин, если обновляется с сервера). Не зарегистрировался — скрипт сам возвращает старого. Пока новый запускается, работающего агента на машине нет.
- **Linux, перенаправление:** сначала новый агент регистрируется на новом сервере (иначе прежний `buildAgent.properties` возвращается), только потом старый выключается `teamcity-agent-linux-disable-old.sh` после текущей сборки.
- **Windows:** новый агент ставится рядом (старый работает, порт нового — 9091) или перенаправляется; регистрация — до 5 мин при установке, до `teamcity_agents_wait` при перенаправлении; при токене сервер должен видеть нового подключённым (REST, до 1 мин). Затем состояние старой службы сохраняется в `old-service.json`, ожидание сборки на старом агенте (до `teamcity_agents_wait`), `teamcity-agent-windows-disable-old.ps1`.
- `teamcity_agents_keep_old=true` — старый агент не трогается нигде.

### Проверки

До переключения агентов проверяется: система (Linux — bash 4.4+, systemd 230+, glibc 2.17+, curl, wget или python3; Windows — PowerShell 5.1, политика выполнения, FullLanguage, от 3 ГБ свободно, нет `JAVA_TOOL_OPTIONS`), имя сервера и https с агента, Java 21 (только для установки), автозапуск старого агента не в обход службы.

Часть изменений — раньше проверок. Linux: ключ control node — до проверки системы; рабочий каталог, файлы и УЦ в системе — до проверки https и `--check` скрипта; на RPM — Java 21 в `/opt` до проверки автозапуска. Windows: рабочий каталог, файлы и УЦ в `LocalMachine\Root` — до всех проверок.

### Авторизация (REST)

С control node, после группы, для каждого агента, чей новый агент на сервере. Нужен `vault_teamcity_admin_token` — токен администратора этого сервера.

1. Ждёт, пока новый агент подключится (до 3 мин).
2. Читает пул старой записи (по имени старого агента).
3. Старая запись (авторизована и не подключена) теряет авторизацию — освобождается лицензия. История сборок остаётся; неавторизованную отключённую запись сервер потом удаляет сам.
4. Авторизует нового — даже если старого выключить не удалось.
5. Ставит его в пул старого.
6. Репетиция (`teamcity_agents_rehearsal`, по умолчанию равен `keep_old`): выключает (Disabled) агента, авторизованного в этом запуске. Авторизованного раньше или включённого вручную не трогает.

`keep_old` бережёт только старых агентов на машинах: записи 2018 на копии сервера всё равно теряют авторизацию. `keep_old` на рабочем сервере выключит и новых агентов — тогда `-e teamcity_agents_rehearsal=false`.

### Итог

`Итог переноса агентов` печатается по блоку на группу: Linux — сразу после Linux-агентов, в середине вывода; Windows — в конце. Строка: `<хост>: <статус>; <новый агент>: <результат REST>` (результат REST — если новый агент на сервере). Хост помечается упавшим в самом конце, если статус — ошибка или новый агент не авторизован; `ЖДЁТ СБОРКУ` и `старый агент ещё занят сборкой` ошибками не считаются.

| Статус | Значит |
|---|---|
| `перенесён, старый выключен` (Linux), `перенесён (новый агент рядом со старым), старый выключен` (Windows) | установка, старый выключен |
| `перенаправлен на новый сервер, старый выключен` | перенаправление, старый выключен |
| `уже на новом сервере, …` (Windows) | агент уже был на этом сервере |
| `…, старый оставлен (keep_old)` | старый не трогался |
| `…; старый агент ещё занят сборкой — запустите плейбук позже, чтобы выключить его` | новый работает и авторизуется, старый ещё включён — повтор после сборки |
| `…; старого агента <каталог> нет` (Linux), `…; старый агент не найден — проверьте вручную (teamcity_agent_old_dir)` (Windows) | новый работает, старого на месте нет |
| `ЖДЁТ СБОРКУ — ничего не изменено, …` (Linux) | установка — сборка на старом агенте, но Java 21 и `/opt/buildAgent2026` уже на месте (служба выключена); перенаправление — сборка на новом агенте. Повтор после сборки |
| `ЖДЁТ СБОРКУ на новом агенте — ничего не изменено, …` (Windows) | сборка на новом агенте при перенаправлении |
| `ОШИБКА («<шаг>»): …` | ошибка на этом шаге; в начале строки `новый агент работает, авторизуется;` — если новый агент уже на сервере |

| Результат REST | Значит |
|---|---|
| `авторизован, пул <пул>` | готово |
| `…, ВЫКЛЮЧЕН — репетиция: для пробной сборки Agents → Enable` | выключен в этом запуске (репетиция) |
| `…, выключен (Agents → Enable)` | был выключен раньше |
| `(записи старого агента <имя> на сервере нет — пул выберите вручную)` | агент в пуле Default |
| `(НЕ удалось поставить в пул: HTTP <код>)` | пул — вручную |
| `подключён, но НЕ АВТОРИЗОВАН (HTTP <код>; лимит лицензии?) — Agents → Unauthorized` | 500 — лицензии, 403 — права токена |
| `НЕ ПОДКЛЮЧИЛСЯ к серверу за 3 минуты — смотрите журнал агента` | новый агент не дошёл до сервера |
| `REST HTTP <код> — проверьте vault_teamcity_admin_token …`, `НЕ авторизован: REST HTTP <код> — см. выше` | токен не этого сервера, истёк или нет УЦ |
| `авторизуйте в TeamCity вручную (нет vault_teamcity_admin_token)` | токена нет |

### Время на агента

Максимумы из кода; агенты идут по одному.

| Шаг | Linux | Windows |
|---|---|---|
| ожидание текущей сборки | до `teamcity_agents_wait` (600 с) на каждое ожидание | то же: на новом агенте (перенаправление) и на старом |
| копирование | скрипты, архив агента, `.deb` — по 3 машины | архив агента и Corretto, ~600 МБ — по 2 машины |
| установка | — | до 1 ч |
| регистрация | до 120 с, до 10 мин при самообновлении | до 5 мин при установке, до `teamcity_agents_wait` при перенаправлении |
| REST | подключение — до 3 мин | проверка подключения — до 1 мин, затем подключение — до 3 мин |

### Дистрибутив, Java, пользователь, порт

- `buildAgentFull.zip` скачивается с сервера (`teamcity_agents_server_url`) один раз в `files/teamcity-agent/build/` и дальше берётся оттуда; новая версия сервера — `-e teamcity_agents_redownload=true`. В `buildAgentFull-https.zip` добавлены `conf/trustedCertificates/elara-ca.pem` и `teamcity-server.pem`: агент сразу доверяет https, системная Java не меняется.
- Java 21 нужна только для установки. Linux: Java 21–25 уже в `/opt/teamcity-agent-jdk21` — не ставится; иначе пакет по libc6 агента: от 2.36 — обычный, старше — `~deb9`; RPM — архив из `.deb`. Windows: Corretto распаковывается в `C:\BuildAgent2026\jre`.
- Новый агент работает от того же пользователя, что старый. Linux: от root агент не запускается — тогда `teamcity_agent_user`. Windows: служба не от LocalSystem — нужен `teamcity_agent_service_password`.
- Порт нового агента: Linux — 9090 (занят — следующий свободный), с `keep_old` — 9091; Windows — 9091 (всегда `-KeepOldService`).

[docs/teamcity-agent-linux-migrate.md](teamcity-agent-linux-migrate.md) — исходное описание Linux-скриптов из GitLab: пути `scripts/…` там — `files/teamcity-agent/linux/` здесь; адрес по умолчанию `http://172.17.6.61:8111` — тестовый сервер, плейбук передаёт свой `--server`.

## Агенты: переменные

`-e` действует на все хосты запуска; переменные «у хоста» — в `hosts.yml` под этим хостом.

| Переменная | По умолчанию | Где | Что делает |
|---|---|---|---|
| `agents_confirm` | — | `-e agents_confirm=yes` | обязательна для настоящего переноса (без `keep_old`) |
| `teamcity_agents_keep_old` | `false` | `-e` | старых агентов не трогать (пилот); новый Linux-агент — на порту 9091 |
| `teamcity_agents_rehearsal` | = `teamcity_agents_keep_old` | `-e` | выключать (Disabled) только что авторизованных |
| `teamcity_agents_server_url` | `https://<teamcity_public_name или имя ВМ>` | `-e` | адрес сервера для агентов |
| `teamcity_agents_wait` | `600` | `-e` | сколько секунд ждать текущую сборку |
| `teamcity_agents_parallel` | `1` | `-e` | сколько агентов переносить одновременно |
| `teamcity_agents_copy_parallel` | Linux `3`, Windows `2` | `-e` | сколько машин копируют файлы одновременно |
| `teamcity_agents_verbose` | `false` | `-e` | полный вывод скриптов и безопасные поля REST |
| `teamcity_agents_redownload` | `false` | `-e` | скачать `buildAgentFull.zip` заново |
| `ssh_pubkey_path` | `~/.ssh/id_ed25519.pub` | `-e` | ключ control node (`00`, `61`) |
| `teamcity_agent_old_dir` | Linux `/opt/buildAgent`; Windows — каталог единственной службы агента или `C:\BuildAgent` | у хоста | каталог старого агента |
| `teamcity_agent_user` | пользователь старого агента | у хоста (Linux) | пользователь нового агента, если старый работает от root |
| `teamcity_agent_service_password` | — | у хоста (Windows): `"{{ vault_agent_service_password }}"` | пароль учётки службы старого агента, если она не LocalSystem; нужен только при установке |
| `teamcity_agent_old_autostart_checked` | `false` | у хоста (Windows) | не проверять автозапуск старого агента из планировщика и `Run` |
| `teamcity_agent_rpm_autostart_checked` | `false` | у хоста (RPM) | не проверять автозапуск из crontab и supervisord |
| `teamcity_agent_jdk_tarball` | `files/teamcity-agent/build/teamcity-agent-jdk21-linux-x64.tar.gz` (из `.deb`) | у хоста (RPM) | свой архив Java 21 |
| `ansible_host` | имя хоста | у хоста | IP, если имени нет в DNS |

## Агенты: что где лежит

| | Linux | Windows |
|---|---|---|
| новый агент | `/opt/buildAgent2026`, служба `teamcity-agent2026` | `C:\BuildAgent2026`, служба `TCBuildAgent2026` |
| Java 21 | `/opt/teamcity-agent-jdk21` | `C:\BuildAgent2026\jre` |
| старый агент по умолчанию | `/opt/buildAgent` | каталог единственной службы агента или `C:\BuildAgent` |
| рабочий каталог плейбука | `/root/teamcity-agent-migrate` (700) | `C:\ProgramData\teamcity-agent-migrate` (Administrators и SYSTEM) |
| журналы переноса | `migrate-*.log`, `disable-old-*.log`, `repoint.log` | `migrate-*.log`, `disable-old-*.log` |
| для отката старого агента | команды в конце журналов; копии crontab, cron-файлов и `rc.local` — `/var/backups/teamcity-agent-linux/`; выключенные строки помечены `#tcagent-off#` | `old-service.json` — имя и тип запуска старой службы (пишется, только когда `62` выключает старого); команда в конце `disable-old-*.log` |
| копия настроек при перенаправлении | `conf/buildAgent.properties.bak-repoint-*` | `conf\buildAgent.properties.bak-repoint-*` |
| копия настроек при доработке агента | `conf/buildAgent.properties.bak-*` | — |
| журнал агента | `/opt/buildAgent2026/logs/teamcity-agent.log` | `C:\BuildAgent2026\logs\teamcity-agent.log` |
| УЦ | `conf/trustedCertificates/elara-ca.pem` и `teamcity-server.pem`; система: `/usr/local/share/ca-certificates/elara-teamcity-ca.crt` или `/etc/pki/ca-trust/source/anchors/elara-teamcity-ca.crt` | `conf\trustedCertificates\`; `LocalMachine\Root` |
| удалить нового агента | `teamcity-agent-linux-remove-new.sh` на агенты не копируется: `scp` с control node, команда с параметрами — в `migrate-*.log` | `teamcity-agent-windows-remove-new.ps1 -Yes` в рабочем каталоге |

`buildAgent.properties` целиком не выводить: в нём токен агента.

## Windows-агенты

- Скрипты копируются в `C:\ProgramData\teamcity-agent-migrate` байт в байт: в них UTF-8 с BOM, иначе PowerShell 5.1 исказит русский текст.
- `teamcity-agent-windows-migrate.ps1` — из GitLab, правки в двух местах, помеченных `ansible:`: TLS 1.2 и без индикатора прогресса; пароль службы из окружения (`TC_AGENT_SERVICE_PASSWORD`; ветка `if ($svcPassword)` вместо окна `Get-Credential`).
- Рабочий каталог — только Administrators и SYSTEM (по SID, работает и на русской Windows). Каталог, заранее созданный не администратором, — отказ `UNSAFE`: удалить его от администратора и повторить.
- Журнал установки — в рабочем каталоге целиком; в вывод Ansible попадают последние строки со скрытыми токенами.
- Установка прошла, но агент не зарегистрировался за 5 минут — новый агент остаётся установленным и запущенным рядом со старым, повтор берёт его как есть. Сам недоделанный агент удаляется, только если упал скрипт установки.
- Неудачное перенаправление: прежний `buildAgent.properties` сам не возвращается (в отличие от Linux), копия — `…bak-repoint-*`.

<details>
<summary>Ручной перенос без WinRM</summary>

**1.** На control node после любого запуска `60`, `61` или `62` есть `files/teamcity-agent/build/buildAgentFull-https.zip`. Скопировать на машину в одну папку: `teamcity-agent-windows-migrate.ps1` и `teamcity-agent-windows-disable-old.ps1` (`files/teamcity-agent/windows/`), `buildAgentFull-https.zip`, `amazon-corretto-21*-windows-x64-jdk.zip` (`files/teamcity-agent/jdk/`), `files/ca/ca.crt`.

**2.** PowerShell от администратора, в этой папке:

```powershell
Import-Certificate -FilePath .\ca.crt -CertStoreLocation Cert:\LocalMachine\Root
powershell -ExecutionPolicy Bypass -File .\teamcity-agent-windows-migrate.ps1 -ServerUrl https://teamcity.inc.elara.local -Zip .\buildAgentFull-https.zip -KeepOldService -Check
powershell -ExecutionPolicy Bypass -File .\teamcity-agent-windows-migrate.ps1 -ServerUrl https://teamcity.inc.elara.local -Zip .\buildAgentFull-https.zip -KeepOldService
```

Без УЦ в `LocalMachine\Root` проверка пишет `Новый TeamCity недоступен с этой машины`. Corretto скрипт берёт рядом с собой. Без `-KeepOldService` скрипт выключает старую службу сразу после установки новой, ещё до проверки регистрации.

**3.** В TeamCity: **Agents → Unauthorized → `<имя>-2026` → Authorize**, пул — как у старого агента; со старой записи снять авторизацию.

**4.** Новый агент Connected — выключить старого:

```powershell
powershell -ExecutionPolicy Bypass -File .\teamcity-agent-windows-disable-old.ps1 -Check
powershell -ExecutionPolicy Bypass -File .\teamcity-agent-windows-disable-old.ps1
```

`old-service.json` при ручном пути не пишется: команду возврата печатает `disable-old` (`Включить старого агента обратно: …`).

</details>

## ROSA и RPM-системы

`ba-rosa-01` входит в `teamcity_agents_linux`.

- Java 21 ставится архивом в `/opt/teamcity-agent-jdk21` (тот же JDK, что в `.deb`). Архив собирается на control node из первого по имени `teamcity-agent-jdk21_*.deb` в `files/teamcity-agent/jdk/` (подойдёт любой из двух) в `files/teamcity-agent/build/teamcity-agent-jdk21-linux-x64.tar.gz`; свой архив — `teamcity_agent_jdk_tarball`.
- УЦ — через `update-ca-trust`.
- Скриптам переноса нужны bash 4.4+ и systemd 230+: ROSA 2021.1/13 — подходит; ROSA 7.x/Cobalt — нет, такой агент переносится только вручную.
- Скрипт на RPM-системах не видит автозапуск из crontab пользователя и supervisord: плейбук проверяет их сам и останавливается, если старый агент запускается оттуда. Это не агент — `teamcity_agent_rpm_autostart_checked: true` у хоста.
