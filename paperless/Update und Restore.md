# Backup

⚠️ **Wichtig**: Ersetze `<INSTANCE_NAME>` durch den Namen deiner Instanz (z.B. `main`, `privat`, `firma`)

## Windows (PowerShell)
```powershell
# Für Instanz "main"
docker exec -t paperless_postgres_main pg_dumpall -U paperless > backup_main.sql

# Für Instanz "privat"
docker exec -t paperless_postgres_privat pg_dumpall -U paperless > backup_privat.sql
```

## Linux/Mac (Bash)
```bash
# Für Instanz "main"
docker exec -t paperless_postgres_main pg_dumpall -U paperless > /mnt/user/tmp/backup_main.sql

# Für Instanz "privat"
docker exec -t paperless_postgres_privat pg_dumpall -U paperless > /mnt/user/tmp/backup_privat.sql
```

# Update/Restore DB

⚠️ **Wichtig**: Diese Schritte gelten für JEDE Instanz separat

- Stack der Instanz stoppen und (db) volumes löschen
- Stack pull und Redeploy Button -> Update klicken
- Alle Container außer DB der Instanz stoppen

## Windows (PowerShell)
```powershell
# Alte Daten löschen (Instanz "main")
docker exec -i paperless_postgres_main psql -U paperless -d paperless -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"

# Backup einspielen (Instanz "main")
Get-Content backup_main.sql | docker exec -i paperless_postgres_main psql -U paperless

# Für andere Instanzen entsprechend anpassen:
# docker exec -i paperless_postgres_privat psql -U paperless -d paperless -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
# Get-Content backup_privat.sql | docker exec -i paperless_postgres_privat psql -U paperless
```

## Linux/Mac (Bash)
```bash
# Alte Daten löschen (Instanz "main")
docker exec -i paperless_postgres_main psql -U paperless -d paperless -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"

# Backup einspielen (Instanz "main")
cat /mnt/user/tmp/backup_main.sql | docker exec -i paperless_postgres_main psql -U paperless

# Für andere Instanzen entsprechend anpassen:
# docker exec -i paperless_postgres_privat psql -U paperless -d paperless -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
# cat /mnt/user/tmp/backup_privat.sql | docker exec -i paperless_postgres_privat psql -U paperless
```

- alle Container der Instanz restarten

# Dokumenten-Backup

Zusätzlich zur Datenbank sollten die Dokumente selbst gesichert werden.

⚠️ **Wichtig**: Jede Instanz hat ihre eigenen Volumes!

## Windows (PowerShell)
```powershell
# Backup der Dokumente und Medien (Instanz "main")
docker run --rm -v paperless_media_main:/source -v ${PWD}:/backup alpine tar czf /backup/paperless_media_main_backup.tar.gz -C /source .
docker run --rm -v paperless_data_main:/source -v ${PWD}:/backup alpine tar czf /backup/paperless_data_main_backup.tar.gz -C /source .

# Für Instanz "privat"
docker run --rm -v paperless_media_privat:/source -v ${PWD}:/backup alpine tar czf /backup/paperless_media_privat_backup.tar.gz -C /source .
docker run --rm -v paperless_data_privat:/source -v ${PWD}:/backup alpine tar czf /backup/paperless_data_privat_backup.tar.gz -C /source .
```

## Linux/Mac (Bash)
```bash
# Backup der Dokumente und Medien (Instanz "main")
docker run --rm -v paperless_media_main:/source -v /mnt/user/tmp:/backup alpine tar czf /backup/paperless_media_main_backup.tar.gz -C /source .
docker run --rm -v paperless_data_main:/source -v /mnt/user/tmp:/backup alpine tar czf /backup/paperless_data_main_backup.tar.gz -C /source .

# Für Instanz "privat"
docker run --rm -v paperless_media_privat:/source -v /mnt/user/tmp:/backup alpine tar czf /backup/paperless_media_privat_backup.tar.gz -C /source .
docker run --rm -v paperless_data_privat:/source -v /mnt/user/tmp:/backup alpine tar czf /backup/paperless_data_privat_backup.tar.gz -C /source .
```

# Restore Dokumenten-Backup

## Windows (PowerShell)
```powershell
# Restore der Dokumente und Medien (Instanz "main")
docker run --rm -v paperless_media_main:/target -v ${PWD}:/backup alpine tar xzf /backup/paperless_media_main_backup.tar.gz -C /target
docker run --rm -v paperless_data_main:/target -v ${PWD}:/backup alpine tar xzf /backup/paperless_data_main_backup.tar.gz -C /target

# Für Instanz "privat"
docker run --rm -v paperless_media_privat:/target -v ${PWD}:/backup alpine tar xzf /backup/paperless_media_privat_backup.tar.gz -C /target
docker run --rm -v paperless_data_privat:/target -v ${PWD}:/backup alpine tar xzf /backup/paperless_data_privat_backup.tar.gz -C /target
```

## Linux/Mac (Bash)
```bash
# Restore der Dokumente und Medien (Instanz "main")
docker run --rm -v paperless_media_main:/target -v /mnt/user/tmp:/backup alpine tar xzf /backup/paperless_media_main_backup.tar.gz -C /target
docker run --rm -v paperless_data_main:/target -v /mnt/user/tmp:/backup alpine tar xzf /backup/paperless_data_main_backup.tar.gz -C /target

# Für Instanz "privat"
docker run --rm -v paperless_media_privat:/target -v /mnt/user/tmp:/backup alpine tar xzf /backup/paperless_media_privat_backup.tar.gz -C /target
docker run --rm -v paperless_data_privat:/target -v /mnt/user/tmp:/backup alpine tar xzf /backup/paperless_data_privat_backup.tar.gz -C /target
```

# Vollständiges Backup aller Instanzen (Skript)

## Windows (PowerShell)
```powershell
# Backup-Skript für alle Instanzen
$instances = @("main", "privat", "firma")
$backupDir = ".\paperless-backups\$(Get-Date -Format 'yyyy-MM-dd')"

New-Item -ItemType Directory -Force -Path $backupDir

foreach ($instance in $instances) {
    Write-Host "Backing up instance: $instance"
    
    # Datenbank-Backup
    docker exec -t "paperless_postgres_$instance" pg_dumpall -U paperless > "$backupDir\backup_$instance.sql"
    
    # Medien-Backup
    docker run --rm -v "paperless_media_$instance:/source" -v "${PWD}:/backup" alpine tar czf "/backup/$backupDir/paperless_media_$instance.tar.gz" -C /source .
    
    # Daten-Backup
    docker run --rm -v "paperless_data_$instance:/source" -v "${PWD}:/backup" alpine tar czf "/backup/$backupDir/paperless_data_$instance.tar.gz" -C /source .
}

Write-Host "Backup completed in: $backupDir"
```

