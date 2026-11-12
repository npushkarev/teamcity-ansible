# Корневой сертификат УЦ

Сюда кладётся `ca.crt` — корневой сертификат нашего УЦ (тот же, что `resources/ca.crt` в Dockerfile-ах), в формате PEM (`-----BEGIN CERTIFICATE-----`).

| Кто | Зачем |
|---|---|
| `00` | ставит его на новую ВМ первым: без него ВМ не доверяет https ProGet и не скачает GPG-ключ и пакет `ca-certificates-elara` |
| `60` (`61`, `62`) | без него перенос агентов не начнётся: кладёт его агентам в `conf/trustedCertificates/elara-ca.pem` и в системное хранилище (`update-ca-certificates`, `update-ca-trust`, `LocalMachine\Root`); по нему control node проверяет https и REST нового сервера |

Проверка: `openssl x509 -in files/ca/ca.crt -noout -subject -enddate`.

Это публичный сертификат (не секрет) — его можно хранить в git. Не путать с сертификатом сервиса в `files/tls/` (сертификат и ключ для https на nginx).
