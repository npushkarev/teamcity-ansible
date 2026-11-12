# Сюда кладётся backup старого TeamCity

Содержимое этой папки (кроме этого файла) в git не попадает: в backup есть пароли и токены.

```text
migration/
├── TeamCity_Backup.zip   ← backup старого TeamCity (переименуйте файл в это имя)
└── artifacts/            ← содержимое /data/teamcity-data/system/artifacts старого сервера
```

- Backup — **Administration → Backup** на старом сервере, файл — в `/data/teamcity-data/backup/`; как забрать — [MIGRATION.md](../MIGRATION.md), шаги 2.2 и 4.3.
- Другого сюда не класть: `40` (и `50`) копирует на ВМ в `/srv/teamcity-migration` всё содержимое папки, кроме этого файла, и на ВМ ничего не удаляет.
- В день переезда — свежий архив под тем же именем: `40` заменит его на ВМ.
- После переезда — удалить ([MIGRATION.md](../MIGRATION.md), раздел 5).
