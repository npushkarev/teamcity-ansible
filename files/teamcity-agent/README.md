# Агенты TeamCity: скрипты и Java для 60-teamcity-agents (61 Linux, 62 Windows)

- `linux/teamcity-agent-linux-*.sh` — перенос Linux-агента (без изменений из GitLab `root/teamcity`;
  описание: `docs/teamcity-agent-linux-migrate.md`).
- `windows/teamcity-agent-windows-{disable-old,remove-new}.ps1` — без изменений из GitLab.
- `windows/teamcity-agent-windows-migrate.ps1` — из GitLab с тремя правками, помеченными `ansible:`
  (пароль службы из окружения вместо окна, TLS 1.2 для проверки https, без индикатора прогресса).
  Файлы копируются на агент байт в байт: в них UTF-8 с BOM, иначе PowerShell 5.1 исказит русский текст.
- `windows/teamcity-agent-windows-ansible.ps1` — помощник плейбука 62 (состояние, проверка https,
  ожидание без сборки, перенаправление, ожидание регистрации, проверка выключения старого агента).
- `jdk/` — Java 21 (в git не попадает, положите сами):

  ```text
  files/teamcity-agent/jdk/teamcity-agent-jdk21_21.0.12.12.1-1_amd64.deb        ← Debian 12+, Ubuntu 22.04+
  files/teamcity-agent/jdk/teamcity-agent-jdk21_21.0.12.12.1-1~deb9_amd64.deb   ← Debian 9–11, Astra; из него — архив для ROSA
  files/teamcity-agent/jdk/amazon-corretto-21.0.12.12.1-windows-x64-jdk.zip     ← Windows
  ```

  Скачайте из GitLab `root/teamcity` (`files/teamcity-agent-jdk21/…`) кнопкой **Download**
  (не указатель LFS) и сверьте `SHA256SUMS`. Плейбук выбирает пакет по версии libc6 агента;
  указатели LFS (около 134 байт) он не примет.
- `build/` — создаёт плейбук: `buildAgentFull.zip` с нового сервера, `buildAgentFull-https.zip`
  с корпоративным УЦ в `conf/trustedCertificates`, `trusted/*.pem`, архив JDK для RPM-систем
  (в git не попадает).
