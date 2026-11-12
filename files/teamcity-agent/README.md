# Агенты TeamCity: скрипты и Java для 60 (61 Linux, 62 Windows)

| Файл | Что это |
|---|---|
| `linux/teamcity-agent-linux-{migrate,disable-old,remove-new}.sh` | перенос Linux-агента, без изменений из GitLab `root/teamcity` ([описание](../../docs/teamcity-agent-linux-migrate.md)); `remove-new.sh` плейбук на агенты не копирует |
| `windows/teamcity-agent-windows-{disable-old,remove-new}.ps1` | без изменений из GitLab |
| `windows/teamcity-agent-windows-migrate.ps1` | из GitLab, правки в двух местах, помеченных `ansible:`: TLS 1.2 для проверки https и без индикатора прогресса; пароль службы из окружения вместо окна `Get-Credential` |
| `windows/teamcity-agent-windows-ansible.ps1` | помощник `62` и `63`: состояние, проверка https, ожидание без сборки, перенаправление, откат, ожидание регистрации, проверка выключения старого агента |
| `jdk/` | Java 21 — положить самим (не в git) |
| `build/` | создаёт плейбук (не в git) |

Windows-скрипты копируются на агент байт в байт: в них UTF-8 с BOM, иначе PowerShell 5.1 исказит русский текст.

## Java 21

```text
jdk/teamcity-agent-jdk21_21.0.12.12.1-1_amd64.deb        ← Debian 12+, Ubuntu 24.04+ (libc6 от 2.36)
jdk/teamcity-agent-jdk21_21.0.12.12.1-1~deb9_amd64.deb   ← Debian 9–11, Ubuntu 22.04 и другие с libc6 старше 2.36
jdk/amazon-corretto-21.0.12.12.1-windows-x64-jdk.zip     ← Windows
```

- Скачать из GitLab `root/teamcity` (`files/teamcity-agent-jdk21/debian12-amd64/`, `debian9-amd64/`, `windows-x64/`) кнопкой **Download** (не указатель LFS). Указатели LFS (около 134 байт) плейбук и скрипт не примут.
- Проверка — `sha256sum files/teamcity-agent/jdk/*`:

```text
780755533757d89f4f7e55742c490aad3bf812ccb79685fa1a9df0452cd1c274  teamcity-agent-jdk21_21.0.12.12.1-1_amd64.deb
5842de222b1ab48e2d73bb4938c96af63a684b03d8fc3fa90535867563c9b135  teamcity-agent-jdk21_21.0.12.12.1-1~deb9_amd64.deb
8945e414866b498f0587ee78411e0abff5071770d56eab8fe6d13eb3766a8631  amazon-corretto-21.0.12.12.1-windows-x64-jdk.zip
```

- Из старой папки со скриптами GitLab брать только эти три файла: скрипты уже в проекте (`windows-migrate.ps1` здесь доработан), `buildAgentFull.zip` плейбук скачивает с нового сервера сам (версия должна совпадать), `agentInstaller.exe` не нужен.
- Нужны оба `.deb`: плейбук выбирает пакет по версии libc6 агента. Архив Java для ROSA собирается из первого по имени `.deb` — подойдёт любой.
- Java нужна только при установке нового агента: для пилота (агенты уже с Java 21) `jdk/` не нужен.

## build/

- `buildAgentFull.zip` — с сервера (`teamcity_agents_server_url`), скачивается один раз и дальше берётся отсюда. Новая версия сервера — `-e teamcity_agents_redownload=true`.
- `buildAgentFull-https.zip` — тот же архив с `conf/trustedCertificates/elara-ca.pem` (`files/ca/ca.crt`) и `teamcity-server.pem` (сертификат из `files/tls/`).
- `trusted/*.pem` — эти сертификаты отдельно, для агентов, перенесённых раньше.
- `teamcity-agent-jdk21-linux-x64.tar.gz` — Java 21 для RPM-систем, из `.deb`.
