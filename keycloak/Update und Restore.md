# Keycloak Update und Restore

## Backup

### Windows (PowerShell)
```powershell
docker exec -t keycloak_postgres pg_dumpall -U keycloak > keycloak-backup.sql
```

### Linux/Mac (Bash)
```bash
docker exec -t keycloak_postgres pg_dumpall -U keycloak > /mnt/user/tmp/keycloak-backup.sql
```

## Update/Restore DB

### Vorgehensweise
1. Stack stoppen und (db) volumes löschen
2. Stack pull und Redeploy Button -> Update klicken
3. Alle Container außer DB stoppen

### Windows (PowerShell)
```powershell
# Alte Daten löschen
docker exec -i keycloak_postgres psql -U keycloak -d keycloak -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"

# Backup einspielen
Get-Content keycloak-backup.sql | docker exec -i keycloak_postgres psql -U keycloak
```

### Linux/Mac (Bash)
```bash
# Alte Daten löschen
docker exec -i keycloak_postgres psql -U keycloak -d keycloak -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"

# Backup einspielen
cat /mnt/user/tmp/keycloak-backup.sql | docker exec -i keycloak_postgres psql -U keycloak
```

4. Alle Container restarten

