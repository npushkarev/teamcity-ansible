# Переезд TeamCity 2018.1.3 → 2026.2: пошагово

**Как устроен переезд.** Новая ВМ (`deb-13-test-teamcity`, сейчас `172.17.5.68`) с TeamCity 2026.2 и https **забирает IP и имя** старого сервера `teamcity.inc.elara.local`. Старый сервер в этот момент отключается от сети в vSphere, но не выключается и не меняется: это точка отката. DNS менять не нужно.

```text
до:     teamcity.inc.elara.local → <СТАРЫЙ_IP> → старый TeamCity 2018 (http)
после:  teamcity.inc.elara.local → <СТАРЫЙ_IP> → новая ВМ, TeamCity 2026 (https, http → https)
откат:  сеть новой ВМ выкл., сеть старого сервера вкл.
```

> **Главное правило:** обе машины никогда не должны быть в сети с одним IP одновременно.

Все команды Ansible выполняются на control node (машина с Ansible) из папки проекта.

---

## 1. Подготовка (один раз)

- [ ] **ВМ готова:** `00` и `01` выполнены (README, раздел 3).
- [ ] **Проект свежий:** `git pull`. Если проект из ZIP — скачайте заново, распакуйте и выполните `chmod -R go-w .` (иначе Ansible не прочитает `ansible.cfg`). Перенесите в новую папку `inventory/hosts.yml`, `inventory/vault.yml`, `migration/`, `files/tls/`, `files/ca/ca.crt`.
- [ ] **Коллекции:** `ansible-galaxy collection install -r requirements.yml -p ./collections`.
- [ ] **rsync на control node:** `sudo apt install -y rsync`.
- [ ] **`files/ca/ca.crt`** — корпоративный УЦ.
- [ ] **`files/tls/`** — сертификат `*.inc.elara.local` (`.cer`/`.crt`/`.pem`/`.der`) и ключ `.key`.
- [ ] **`files/teamcity-agent/jdk/`** — пакеты Java 21 из GitLab `root/teamcity`, кнопкой **Download** (не указатель LFS):
  - `teamcity-agent-jdk21_21.0.12.12.1-1_amd64.deb` (Debian 12+);
  - `teamcity-agent-jdk21_21.0.12.12.1-1~deb9_amd64.deb` (Debian 9–11, Ubuntu 22.04, Astra).
- [ ] **`inventory/vault.yml`** (`ansible-vault edit inventory/vault.yml`):
  - `vault_teamcity_db_password` — пароль PostgreSQL;
  - `vault_proget_registry_user` / `vault_proget_registry_password` — вход в ProGet (по API-ключу обычно логин `api`, пароль — ключ);
  - `vault_teamcity_admin_token` — заполняется в день переезда (шаг 4.10).
- [ ] **Образы в ProGet:** `library/teamcity-server` с тегом `2026.2-unlimited` и `library/postgres:16`. Если тег сервера другой — в `hosts.yml`: `teamcity_registry_server_image: proget.inc.elara.local/main/library/teamcity-server:<тег>`.
- [ ] **Linux-агенты в `inventory/hosts.yml`** (ROSA не включать — её вручную, раздел 6):

  ```yaml
      teamcity_agents_linux:
        hosts:
          ba-deb-01.inc.elara.local:
          ba-deb-02.inc.elara.local:
          ba-deb-03.inc.elara.local:
          ba-deb-04.inc.elara.local:
          ba-deb-05.inc.elara.local:
          ba-deb-06.inc.elara.local:
          ba-deb12-01.inc.elara.local:
          ba-deb12-02.inc.elara.local:
          ba-deb12-03.inc.elara.local:
          ba-deb12-04.inc.elara.local:
          ba-deb12-05.inc.elara.local:
          ba-deb12-06.inc.elara.local:
          ba-deb12-07.inc.elara.local:
          ba-deb12-08.inc.elara.local:
          ba-temp-deb12-nodejs.inc.elara.local:
          ba-deb-pvs.inc.elara.local:
          ba-ubu-01.inc.elara.local:
          ba-tst-astra-01.inc.elara.local:
  ```

  Если у агента старый каталог не `/opt/buildAgent` — у хоста `teamcity_agent_old_dir: <каталог>`; если старый агент работает от root — `teamcity_agent_user: <пользователь>`.

- [ ] **Сеть:** узнайте IP старого сервера (`nslookup teamcity.inc.elara.local`) и убедитесь, что на старой машине **нет других сервисов** (после отключения сети они станут недоступны).
- [ ] **arping на новой ВМ** (нужен при смене IP): `ssh root@172.17.5.68 'apt-get install -y iputils-arping'`.
- [ ] **Как ВМ получает адрес:** `ssh root@172.17.5.68 'ip -br a; grep -B1 -A4 "^iface" /etc/network/interfaces'`. `inet static` — меняете сами (шаг 4.8); `inet dhcp` — заранее попросите сетевых админов перенести резервирование `<СТАРЫЙ_IP>` на MAC новой ВМ.

## 2. Репетиция (без простоя, старый сервер работает)

1. **Backup на старом сервере:** **Administration → Backup**, scope *Custom*, все галочки, **Start Backup**. Файл появится в `/data/teamcity-data/backup/`.
2. **Забрать на control node:**

   ```bash
   OLD=root@teamcity.inc.elara.local
   mkdir -p migration/artifacts
   ssh $OLD 'ls -t /data/teamcity-data/backup/*.zip | head -1'
   scp $OLD:/data/teamcity-data/backup/<имя>.zip migration/TeamCity_Backup.zip
   rsync -a --partial $OLD:/data/teamcity-data/system/artifacts/ migration/artifacts/   # необязательно
   ```

3. **Перенос на ВМ** (имя ВМ — по умолчанию, `teamcity_public_name` пока **не задавать**):

   ```bash
   H=deb-13-test-teamcity.inc.elara.local
   ansible-playbook playbooks/50-teamcity-migrate.yml --limit $H --ask-vault-pass
   ```

4. **Проверка** `https://deb-13-test-teamcity.inc.elara.local`: вход старыми пользователями, проекты, история, артефакты. Сразу на **этом** сервере: **Administration → Cloud Profiles** — выключить, уведомления — выключить (это копия рабочего сервера).
5. **Репетиция агента** на запасном агенте (например, `ba-tst-astra-01`), старый агент при этом продолжает работать:

   ```bash
   ansible-playbook playbooks/60-teamcity-agents-linux.yml --limit ba-tst-astra-01.inc.elara.local \
     --ask-pass --ask-vault-pass -e teamcity_agents_keep_old=true \
     -e teamcity_agents_server_url=https://deb-13-test-teamcity.inc.elara.local
   ```

   В день переезда `60` сам перенаправит этого агента на финальный адрес.
6. **Запишите время** backup, копирования и `50` — это длительность окна простоя.

## 3. Накануне

- [ ] Объявить окно простоя (время — из репетиции + 30 минут).
- [ ] **Артефакты заранее**, чтобы в окне докачать только разницу:

  ```bash
  H=deb-13-test-teamcity.inc.elara.local
  rsync -a --partial root@teamcity.inc.elara.local:/data/teamcity-data/system/artifacts/ migration/artifacts/
  ansible-playbook playbooks/40-teamcity-backup-upload.yml --limit $H
  ```

  (в `migration/` ещё лежит архив репетиции — так и нужно, в окне он заменится).
- [ ] На Windows-агенты положить файлы для раздела 5 (скрипты из GitLab, `files/teamcity-agent/build/buildAgentFull-https.zip`, `files/teamcity-agent/build/trusted/*.pem`, Corretto zip).
- [ ] Открыть доступ в vSphere к обеим ВМ (сетевой адаптер и консоль).

## 4. День переезда (окно простоя)

| № | Действие | Где |
|---|---|---|
| 4.1 | Остановить запуск сборок: **Build Queue → Pause** (если кнопки нет — **Agents** → выключить агентов). Дождаться окончания идущих сборок. Предупредить: настройки больше не менять | старый TeamCity |
| 4.2 | **Backup:** Administration → Backup, *Custom*, все галочки. Дождаться «Backup completed successfully» | старый TeamCity |
| 4.3 | Забрать backup и разницу артефактов (команды из 2.2: `scp` нового архива в `migration/TeamCity_Backup.zip`, `rsync` артефактов) | control node |
| 4.4 | **Отключить старый сервер от сети:** Edit Settings → сетевой адаптер → снять **Connected**. ВМ не выключать | vSphere |
| 4.5 | Удалить данные репетиции на новой ВМ (**удаляет базу и данные этой ВМ**): `ssh root@172.17.5.68 'cd /opt/teamcity-2026 && docker compose down -v && rm -f .restored .upgraded'` | control node |
| 4.6 | В `inventory/hosts.yml`, в `vars` группы `teamcity`: `teamcity_public_name: teamcity.inc.elara.local` | control node |
| 4.7 | `ansible-playbook playbooks/50-teamcity-migrate.yml --limit $H --ask-vault-pass` — восстановление, обновление 2018 → 2026, https | control node |
| 4.8 | **Сменить IP новой ВМ на `<СТАРЫЙ_IP>`** (см. ниже) | консоль vSphere |
| 4.9 | В `hosts.yml`: `ansible_host: <СТАРЫЙ_IP>`; затем `ssh-keygen -R <СТАРЫЙ_IP>`. Проверить: `curl -sI http://teamcity.inc.elara.local/ \| head -1` → `308`, в браузере `https://teamcity.inc.elara.local` — вход | control node |
| 4.10 | Токен администратора: в новом TeamCity **Profile → Access Tokens → Create**, вписать в `vault_teamcity_admin_token` (`ansible-vault edit inventory/vault.yml`) | браузер, control node |
| 4.11 | **Linux-агенты:** `ansible-playbook playbooks/60-teamcity-agents-linux.yml --limit teamcity_agents_linux --ask-pass --ask-vault-pass -e agents_confirm=yes`. В конце — таблица по каждому агенту | control node |
| 4.12 | **Windows-агенты** — раздел 5; **ROSA** — раздел 6 | агенты |
| 4.13 | Проверка: все агенты в **Agents → Connected**, в своих пулах; пробная сборка на Linux и на Windows; затем открыть сборки (снять паузу/включить агентов) и объявить конец работ | новый TeamCity |

**4.8. Смена IP** (в консоли vSphere — SSH по старому адресу отвалится):

```bash
ip -br a                              # имя интерфейса, например ens192
nano /etc/network/interfaces          # inet static: address <СТАРЫЙ_IP>, gateway — как был
systemctl restart networking          # или reboot
arping -U -c 3 -I ens192 <СТАРЫЙ_IP>  # сообщить сети новый MAC (иначе до нескольких минут недоступности)
ip -br a                              # проверить адрес
```

Если адрес по DHCP — после переноса резервирования сетевыми админами: `systemctl restart networking` и `arping`.

**Что делает `60` с агентами (4.11).** По одному агенту:

- агент **ещё не переносился** — ставит агента 2026 рядом со старым (`/opt/buildAgent2026`, Java 21, УЦ для https), старый штатно останавливается после сборки;
- агент **уже перенесён на тестовый `172.17.6.61`** (`ba-deb-02`, `ba-deb-06`, `ba-deb-test`, агент репетиции) — перенаправляет его: `serverUrl` → `https://teamcity.inc.elara.local`, УЦ в `conf/trustedCertificates`, перезапуск службы; старый агент 2018 выключается;
- затем авторизует агента и ставит в пул старого.

Агент со сборкой дольше 10 минут пропускается («ЖДЁТ СБОРКУ») — запустите `60` для него ещё раз. Журналы на агенте: `/root/teamcity-agent-migrate/*.log` (в них же команды возврата).

## 5. Windows-агенты (11, вручную)

На каждой машине — PowerShell **от администратора**, в папке с файлами. Перед действием убедитесь в TeamCity, что агент **Idle**.

**Уже перенесены на `172.17.6.61`** — `ba-w22-01`, `ba-w22-03`, `ba-win-01`, `ba-win-10`. Перенаправить на новый сервер:

```powershell
$url = 'https://teamcity.inc.elara.local'
$d = 'C:\BuildAgent2026'; $f = "$d\conf\buildAgent.properties"
$latin1 = [Text.Encoding]::GetEncoding(28591)
Copy-Item $f "$f.bak-repoint-$(Get-Date -Format yyyyMMdd-HHmmss)"
$lines = [IO.File]::ReadAllLines($f, $latin1) |
  Where-Object { $_ -notmatch '^\s*authorizationToken\s*[=:]' } |
  ForEach-Object { if ($_ -match '^\s*serverUrl\s*[=:]') { "serverUrl=$url" } else { $_ } }
[IO.File]::WriteAllLines($f, [string[]]$lines, $latin1)
New-Item -ItemType Directory -Force "$d\conf\trustedCertificates" | Out-Null
Copy-Item .\elara-ca.pem, .\teamcity-server.pem "$d\conf\trustedCertificates\"
Restart-Service TCBuildAgent2026
# старый агент 2018 (если ещё работает): выключить, команду возврата скрипт напечатает
powershell -ExecutionPolicy Bypass -File .\teamcity-agent-windows-disable-old.ps1 -Check
powershell -ExecutionPolicy Bypass -File .\teamcity-agent-windows-disable-old.ps1
```

**Ещё не перенесены** — `ba-w22-02`, `ba-w22-04`, `ba-win-02`, `ba-win-03`, `ba-win-04`, `ba-win-05`, `ba-win-06`. Архив `buildAgentFull-https.zip` уже содержит УЦ:

```powershell
powershell -ExecutionPolicy Bypass -File .\teamcity-agent-windows-migrate.ps1 -ServerUrl https://teamcity.inc.elara.local -Zip .\buildAgentFull-https.zip -Check
powershell -ExecutionPolicy Bypass -File .\teamcity-agent-windows-migrate.ps1 -ServerUrl https://teamcity.inc.elara.local -Zip .\buildAgentFull-https.zip
```

Если скрипт пишет, что сервер недоступен из-за сертификата, — Windows не доверяет корпоративному УЦ: `certutil -addstore Root .\elara-ca.pem`.

Затем в TeamCity: **Agents → Unauthorized → Authorize**, пул — как у старого агента с тем же именем.

## 6. ROSA (`ba-rosa-01`, вручную)

Пакет `.deb` с Java сюда не встанет. Распакуйте Java 21 (Amazon Corretto 21, Linux x64 `.tar.gz`) в `/opt/teamcity-agent-jdk21`, затем запустите на ней скрипт сами:

```bash
sudo bash teamcity-agent-linux-migrate.sh --check --server https://teamcity.inc.elara.local --zip buildAgentFull-https.zip
sudo bash teamcity-agent-linux-migrate.sh --server https://teamcity.inc.elara.local --zip buildAgentFull-https.zip
```

(файлы — из `files/teamcity-agent/linux/` и `files/teamcity-agent/build/`; УЦ для системы: `/etc/pki/ca-trust/source/anchors/` + `update-ca-trust`). На ROSA скрипт не проверялся — начните с `--check`.

## 7. Откат

В любой момент окна или после него:

1. **vSphere:** у новой ВМ снять **Connected**, у старого сервера поставить. Если старый сервер пару минут недоступен по IP — на нём `arping -U -c 3 -I <интерфейс> <СТАРЫЙ_IP>` (или перезапуск сети).
2. **Linux-агенты:** команды возврата — в журналах скриптов. Показать для всех:

   ```bash
   ansible teamcity_agents_linux -m raw -a 'for f in $(ls -t /root/teamcity-agent-migrate/*.log | head -n 2); do echo "== $f"; tail -n 15 "$f"; done'
   ```

   Обычно это `systemctl disable --now teamcity-agent2026` и включение старого агента (`systemctl enable --now <служба>` или раскомментировать строку `#tcagent-off#` в cron/rc.local).
3. **Windows-агенты:** `Set-Service TCBuildAgent2026 -StartupType Disabled; Stop-Service TCBuildAgent2026` и команда включения старой службы, которую напечатал скрипт.
4. Снять паузу очереди на старом сервере. Данные старого сервера не менялись.

## 8. После переезда

- Ссылки `http://teamcity.inc.elara.local/...` работают (перенаправление 308). Webhooks в Bitbucket со временем перевести на `https://`.
- Старый сервер держать отключённым 2–4 недели, потом списать.
- Тестовый сервер `172.17.6.61` больше не нужен агентам.

## Частые ошибки

| Сообщение | Что делать |
|---|---|
| `Ansible is being run in a world writable directory` | `chmod -R go-w .` в папке проекта |
| `No such file or directory: b'rsync'` | `sudo apt install -y rsync` на control node |
| `сертификаты []` в `files/tls/` | расширение сертификата `.cer`/`.crt`/`.pem`/`.der`, ключ `.key` |
| `docker login ... не прошёл` | логин/пароль ProGet в `vault.yml` (см. подсказки в сообщении) |
| `В /opt/buildAgent2026 агент другого сервера` | обновите проект: в `60` такой агент перенаправляется автоматически |
| `ЖДЁТ СБОРКУ` в итоге `60` | дождаться сборки и запустить `60` для этого агента ещё раз |
