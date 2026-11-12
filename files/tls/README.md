# Сертификат для https TeamCity (nginx)

Сюда кладутся два файла wildcard-сертификата `*.inc.elara.local` (те же, что для остальных сервисов). Имена любые, важно только расширение:

- один сертификат: `.cer`, `.crt`, `.pem` или `.der` (PEM или DER; лучше с цепочкой — сертификат и промежуточный УЦ в одном файле);
- один закрытый ключ: `.key` (без пароля).

```text
files/tls/inc.elara.local.cer
files/tls/inc.elara.local.key
```

В git эти файлы не попадают (`.gitignore`). Ключ можно зашифровать тем же паролем, что `inventory/vault.yml`: `ansible-vault encrypt files/tls/inc.elara.local.key` — `50` всё равно запускается с `--ask-vault-pass`.

- `50` проверяет, что ключ подходит к сертификату, сертификат не просрочен и подходит к адресу сервера: `teamcity_public_name` (в день переезда — `teamcity.inc.elara.local`), пока он не задан — имя ВМ.
- `60` кладёт этот сертификат агентам в `conf/trustedCertificates/teamcity-server.pem` (вместе с УЦ), поэтому держите `files/tls/` на control node и при переносе агентов.

Не путать с корневым сертификатом УЦ (`files/ca/ca.crt`): он для доверия, а не для https.
