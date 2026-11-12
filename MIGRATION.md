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
- [ ] **Пакеты на control node (Debian 13):** `sudo apt install -y ansible python3-winrm rsync` — `ansible` уже содержит коллекции для Windows (`ansible.windows`), `python3-winrm` нужен для Windows-агентов. Плюс `ansible-galaxy collection install -r requirements.yml -p ./collections`.
- [ ] **`files/ca/ca.crt`** — корпоративный УЦ.
- [ ] **`files/tls/`** — сертификат `*.inc.elara.local` (`.cer`/`.crt`/`.pem`/`.der`) и ключ `.key`.
- [ ] **`files/teamcity-agent/jdk/`** — Java 21 из GitLab `root/teamcity`, кнопкой **Download** (не указатель LFS):
  - `teamcity-agent-jdk21_21.0.12.12.1-1_amd64.deb` (Debian 12+);
  - `teamcity-agent-jdk21_21.0.12.12.1-1~deb9_amd64.deb` (Debian 9–11, Ubuntu 22.04, Astra; из него же собирается Java для ROSA);
  - `amazon-corretto-21.0.12.12.1-windows-x64-jdk.zip` (Windows).
- [ ] **`inventory/vault.yml`** (`ansible-vault edit inventory/vault.yml`):
  - `vault_teamcity_db_password` — пароль PostgreSQL;
  - `vault_proget_registry_user` / `vault_proget_registry_password` — вход в ProGet (по API-ключу обычно логин `api`, пароль — ключ);
  - `vault_teamcity_admin_token` — заполняется в день переезда (шаг 4.10);
  - `vault_windows_admin_password` — пароль доменной учётки для WinRM (Windows-агенты);
  - пароль учётной записи службы старого Windows-агента, если она не LocalSystem (`teamcity_agent_service_password` у хоста).
- [ ] **Образы в ProGet:** `library/teamcity-server` с тегом `2026.2-unlimited` и `library/postgres:16`. Если тег сервера другой — в `hosts.yml`: `teamcity_registry_server_image: proget.inc.elara.local/main/library/teamcity-server:<тег>`.
- [ ] **Агенты в `inventory/hosts.yml`** — готовый список в `inventory/hosts.example.yml`: группы `teamcity_agents_linux` (19 машин, вместе с `ba-rosa-01` и `ba-deb-test`), `teamcity_agents_windows` (11, с настройками WinRM) и `pilot` (7 агентов, уже переведённых на тестовый `172.17.6.61`). Если у агента старый каталог не стандартный — у хоста `teamcity_agent_old_dir`; если старый Linux-агент работает от root — `teamcity_agent_user`.
- [ ] **WinRM на Windows-агентах:** на Windows Server включён по умолчанию; на Windows 10/11 один раз в консоли `Enable-PSRemoting -Force`. Учётка Ansible — доменная, в локальных Administrators. Проверка: `ansible teamcity_agents_windows -m ansible.windows.win_ping -e @inventory/vault.yml --ask-vault-pass` (пароль WinRM — из `vault.yml`, поэтому `-e @inventory/vault.yml`).

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
5. **Проба агентов — группа `pilot`** (7 агентов с тестового `172.17.6.61`: 3 Linux, 4 Windows). Старые агенты 2018 при этом продолжают работать со старым сервером:

   ```bash
   ansible-playbook playbooks/60-teamcity-agents.yml --limit pilot \
     --ask-pass --ask-vault-pass -e teamcity_agents_keep_old=true \
     -e teamcity_agents_server_url=https://deb-13-test-teamcity.inc.elara.local
   ```

   Для токена администратора здесь нужен токен **репетиционного** сервера. В конце — итог по каждому агенту. На копии сервера новые агенты **авторизуются, но выключаются** (`ВЫКЛЮЧЕН — репетиция` в итоге): иначе на копии пошли бы настоящие сборки — по триггерам и из очереди backup, с деплоем и публикацией. Для пробной сборки включите одного агента (**Agents → агент → Enable**) и запустите безопасную сборку; очередь, восстановленную из backup, перед этим очистите (**Build Queue**). Повторный запуск включённого вручную агента не выключает. В день переезда `60` сам перенаправит эти агенты на финальный адрес.
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
- [ ] Windows: проверить WinRM на всех (`ansible teamcity_agents_windows -m ansible.windows.win_ping -e @inventory/vault.yml --ask-vault-pass`).
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
| 4.11 | **Все агенты:** `ansible-playbook playbooks/60-teamcity-agents.yml --limit 'teamcity_agents_linux:teamcity_agents_windows' --ask-pass --ask-vault-pass -e agents_confirm=yes`. В конце — итог по каждому агенту; хосты с ошибкой помечаются упавшими в самом конце (остальные при этом обработаны) | control node |
| 4.12 | Агенты с «ЖДЁТ СБОРКУ» или «ОШИБКА» в итоге — исправить причину (она в итоге) и запустить `60` для них ещё раз (`--limit <агент>`) | control node |
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

**Что делает `60` с агентами (4.11).** Проверки и копирование — параллельно, сам перенос — по одному агенту; сбой одного агента не останавливает остальных:

- агент **ещё не переносился** — ставит агента 2026 рядом со старым (Linux: `/opt/buildAgent2026`, Windows: `C:\BuildAgent2026`), с Java 21 и корпоративным УЦ для https; старый выключается **только после того, как новый зарегистрировался**, и после текущей сборки;
- агент **уже перенесён на тестовый `172.17.6.61`** (`ba-deb-02`, `ba-deb-06`, `ba-deb-test`, `ba-w22-01`, `ba-w22-03`, `ba-win-01`, `ba-win-10`) — перенаправляет его: УЦ в `conf/trustedCertificates`, `serverUrl` → `https://teamcity.inc.elara.local`, старый токен удаляется; Linux — перезапуск службы, когда нет сборки, Windows — агент сам перезапускается после сборки. Успех — только когда в журнале агента появилось «Registered on server» (Linux: иначе прежний файл возвращается, агент снова на прежнем сервере); только после этого выключается старый агент 2018;
- затем авторизует нового агента (даже если старого выключить не удалось), ставит его в пул старого и **снимает авторизацию со старой записи** (агент 2018 к новому серверу уже не подключится, а лицензию занимает). Неавторизованную запись сервер потом удаляет сам; история сборок остаётся.

Агент со сборкой дольше 10 минут пропускается («ЖДЁТ СБОРКУ»): ничего не меняется. Недоступный хост (SSH/WinRM) не мешает остальным — он в итоге как «НЕДОСТУПЕН». Журналы на агентах: Linux `/root/teamcity-agent-migrate/*.log`, Windows `C:\ProgramData\teamcity-agent-migrate\*.log` и `old-service.json` (исходное состояние службы старого агента).

## 5. Windows-агенты (11) — через `60`/`62`

Делаются той же командой 4.11 (группа `teamcity_agents_windows`, WinRM). Отдельно — только `62-teamcity-agents-windows.yml`. Что важно:

- скрипты из GitLab копируются байт в байт в `C:\ProgramData\teamcity-agent-migrate`; в `teamcity-agent-windows-migrate.ps1` три помеченные `ansible:` правки — пароль службы из окружения (без окна), TLS 1.2 для проверки https, без индикатора прогресса;
- корпоративный УЦ ставится в `LocalMachine\Root` (проверка https скриптом) и в `conf\trustedCertificates` агента (Java агента);
- новый агент ставится с `-KeepOldService`: старый работает, пока новый не зарегистрировался на сервере; при неудаче недоделанный новый агент удаляется, старый не трогается;
- служба старого агента от пользователя (не LocalSystem) — нужен `teamcity_agent_service_password` у хоста (в vault), иначе хост остановится с подсказкой;
- проверки до изменений: PowerShell 5.1, политика выполнения по GPO, место на диске, `JAVA_TOOL_OPTIONS`, доступность https с машины (с причиной: УЦ / TLS / DNS / сеть), автозапуск старого агента не через службу (задание планировщика, `HKLM\…\Run` — после выключения службы он вернул бы старого агента);
- рабочий каталог `C:\ProgramData\teamcity-agent-migrate` — только Administrators и SYSTEM (по SID, работает и на русской Windows); если каталог заранее создал не администратор — отказ, удалите его вручную;
- журнал установки — в рабочем каталоге целиком; в вывод Ansible попадают последние строки со скрытыми токенами;
- перед выключением старого агента сервер должен видеть нового подключённым (REST, если задан `vault_teamcity_admin_token`).

Если на какой-то машине нет WinRM — вручную, скриптами из `files/teamcity-agent/windows/` (PowerShell от администратора):

```powershell
powershell -ExecutionPolicy Bypass -File .\teamcity-agent-windows-migrate.ps1 -ServerUrl https://teamcity.inc.elara.local -Zip .\buildAgentFull-https.zip -Check
powershell -ExecutionPolicy Bypass -File .\teamcity-agent-windows-migrate.ps1 -ServerUrl https://teamcity.inc.elara.local -Zip .\buildAgentFull-https.zip
```

## 6. ROSA (`ba-rosa-01`) — через `60`/`61`

Входит в `teamcity_agents_linux`. Java 21 ставится архивом в `/opt/teamcity-agent-jdk21` (тот же JDK, что в `.deb`), УЦ — через `update-ca-trust`. Плейбук проверяет, что система подходит скриптам переноса: bash 4.4+, systemd 230+ (ROSA 2021.1/13 — да; ROSA 7.x/Cobalt — нет, тогда только вручную), и что старый агент не запускается из crontab пользователя или supervisord (скрипт их на RPM-системах не видит).

## 7. Откат

В любой момент окна или после него:

1. **vSphere:** у новой ВМ снять **Connected**, у старого сервера поставить. Если старый сервер пару минут недоступен по IP — на нём `arping -U -c 3 -I <интерфейс> <СТАРЫЙ_IP>` (или перезапуск сети).
2. **Linux-агенты:** команды возврата — в журналах скриптов. Показать для всех:

   ```bash
   ansible teamcity_agents_linux -m raw -a 'for f in $(ls -t /root/teamcity-agent-migrate/*.log | head -n 2); do echo "== $f"; tail -n 15 "$f"; done'
   ```

   Обычно это `systemctl disable --now teamcity-agent2026` и включение старого агента (`systemctl enable --now <служба>` или раскомментировать строку `#tcagent-off#` в cron/rc.local).
3. **Windows-агенты:** `Set-Service TCBuildAgent2026 -StartupType Disabled; Stop-Service TCBuildAgent2026`, затем включить старую службу: её имя и прежний тип запуска — в `C:\ProgramData\teamcity-agent-migrate\old-service.json` (`Set-Service <имя> -StartupType Automatic; Start-Service <имя>`).
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
| `НЕ АВТОРИЗОВАН (HTTP 500; лимит лицензии?)` | не хватает лицензий на агентов: Administration → Licenses; затем `60` ещё раз |
| Windows: `недоступен (TrustFailure / SecureChannelFailure / NameResolutionFailure)` | нет УЦ / TLS / DNS на машине — см. сообщение; затем `60` ещё раз |
| Windows: `нужен пароль: teamcity_agent_service_password` | служба старого агента работает от пользователя — добавьте его пароль в vault и у хоста |
| `НЕДОСТУПЕН по SSH` / `НЕДОСТУПЕН по WinRM` | машина выключена, нет сети, неверный пароль (`--ask-pass`, `vault_windows_admin_password`) или нет WinRM (`Enable-PSRemoting -Force`) |
| Windows: `старый агент запускается ещё и отсюда: task …` | отключите задание планировщика / запись `Run` старого агента и запустите снова (или `-e teamcity_agent_old_autostart_checked=true`, если так и нужно) |
| Windows: `UNSAFE … owner …` (шаг 1b) | рабочий каталог создан не администратором — удалите `C:\ProgramData\teamcity-agent-migrate` от администратора и запустите снова |
| RPM: `похоже, старый агент запускается отсюда: /var/spool/cron/…` | закомментируйте эту строку автозапуска (или `-e teamcity_agent_rpm_autostart_checked=true`, если это не агент) |
| `агент не зарегистрировался на … — возвращён прежний buildAgent.properties` | новый агент не смог подключиться к серверу (обычно УЦ/сеть): смотрите строки журнала в выводе, исправьте и запустите снова; старый агент не тронут |
| `записи старого агента … на сервере нет — пул выберите вручную` | новый агент в пуле Default: поставьте его в нужный пул (Agents → Pools) |
| `REST HTTP 401` / `REST недоступен` | `vault_teamcity_admin_token` — не того сервера или истёк; новый токен: Profile → Access Tokens |
