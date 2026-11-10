# TeamCity 2026.2 на чистом Debian 13 из ProGet

Три плейбука поднимают TeamCity Server и PostgreSQL 16 в Docker на новой ВМ:

| Плейбук | Что делает |
|---|---|
| `00-bootstrap-keys.yml` | hostname, `/etc/hosts`, прокси apt, Python, время (chrony), базовые пакеты, сертификат УЦ и ProGet в apt, SSH-ключ control node |
| `01-expand-root.yml` | растягивает корень `/` на весь диск, swap-раздел заменяет файлом `/swapfile` |
| `53-teamcity-proget.yml` | Docker и Compose v2 из Debian, настройки Docker, `docker login` в ProGet, запуск TeamCity и PostgreSQL |

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

## 3. Запуск

Подставьте имя ВМ из `hosts.yml`. Флаг `--limit` обязателен.

```bash
H=deb-13-test-teamcity.inc.elara.local

# Подготовка Debian. Пароль root нужен только здесь.
ansible-playbook playbooks/00-bootstrap-keys.yml --limit $H --ask-pass --ask-vault-pass

# Snapshot ВМ в vSphere! Затем расширение диска.
ansible-playbook playbooks/01-expand-root.yml --limit $H -e expand_root_confirm=yes

# TeamCity.
ansible-playbook playbooks/53-teamcity-proget.yml --limit $H --ask-vault-pass
```

Откройте `http://<IP>:8111` и завершите мастер настройки TeamCity. Затем подключите внешний агент и авторизуйте его в **Agents → Unauthorized**.

Варианты для `00`:

- нет `ca.crt` — добавьте `-e bootstrap_proget_enabled=false`, а в `hosts.yml` поставьте `teamcity_registry_insecure: true`;
- время уже выставлено и NTP недоступен — добавьте `-e bootstrap_time_sync=false`.

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
