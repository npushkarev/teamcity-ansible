# Сюда кладётся backup старого TeamCity

Содержимое этой папки (кроме этого файла) в git не попадает: в backup есть пароли и токены.

```text
migration/
├── TeamCity_Backup.zip   ← backup старого TeamCity (переименуйте файл в это имя)
└── artifacts/            ← содержимое <Data Directory>/system/artifacts старого сервера
```

UI-backup TeamCity лежит на старом сервере в `<Data Directory>/backup/`.
Затем `playbooks/40-teamcity-backup-upload.yml` перенесёт всё на ВМ в `/srv/teamcity-migration`.
