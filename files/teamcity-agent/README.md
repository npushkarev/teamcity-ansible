# Агенты TeamCity: скрипты и Java для 60-teamcity-agents-linux

- `linux/teamcity-agent-linux-migrate.sh` — перенос Linux-агента на новый сервер
  (описание: `docs/teamcity-agent-linux-migrate.md`). Рядом `disable-old` и `remove-new`
  для ручных случаев.
- `jdk/` — пакеты Java 21 для агента (в git не попадают, положите сами):

  ```text
  files/teamcity-agent/jdk/teamcity-agent-jdk21_21.0.12.12.1-1_amd64.deb        ← Debian 12+, Ubuntu 22.04+
  files/teamcity-agent/jdk/teamcity-agent-jdk21_21.0.12.12.1-1~deb9_amd64.deb   ← Debian 9–11, Astra
  ```

  Скачайте из GitLab `root/teamcity`, каталоги `files/teamcity-agent-jdk21/debian12-amd64`
  и `debian9-amd64`, кнопкой **Download** (не указатель LFS), и сверьте `SHA256SUMS`.
  Плейбук сам выбирает пакет по версии libc6 агента. Нужен только тот, что подходит вашим агентам.
- `build/` — создаёт плейбук: `buildAgentFull.zip` с нового сервера и `buildAgentFull-https.zip`
  с корпоративным УЦ в `conf/trustedCertificates` (в git не попадает).
