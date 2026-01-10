# Backup
## Windows (PowerShell)
```powershell
docker exec -t immich_postgres pg_dumpall -U postgres > backup.sql
```

## Linux/Mac (Bash)
```bash
docker exec -t immich_postgres pg_dumpall -U postgres > /mnt/user/tmp/backup.sql
```

# Update/Restore DB
- Stack stoppen und (db) volumes löschen
- Stack pull und Redeploy
- Alle Container außer DB Stoppen

## Windows (PowerShell)
```powershell
# Alte Daten löschen
docker exec -i immich_postgres psql -U postgres -d immich -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"

# Backup einspielen
Get-Content backup.sql | docker exec -i immich_postgres psql -U postgres
```

## Linux/Mac (Bash)
```bash
# Alte Daten löschen
docker exec -i immich_postgres psql -U postgres -d immich -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"

# Backup einspielen
cat /mnt/user/tmp/backup.sql | docker exec -i immich_postgres psql -U postgres
```

- Stack mit DB_SKIP_MIGRATIONS=false neu deployen