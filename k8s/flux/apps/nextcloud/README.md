# Nextcloud

Dateien, Kalender, Kontakte unter `https://cloud.nico-steinmueller.de` über
`ingress-public`.

| Datei                                          | Was                                                                    |
|------------------------------------------------|------------------------------------------------------------------------|
| [`Deployment.yaml`](Deployment.yaml)           | Pod aus php-fpm, nginx und Cron                                        |
| [`Config.yaml`](Config.yaml)                   | `kubernetes.config.php`, fpm-Pool, nginx                               |
| [`Storage.yaml`](Storage.yaml)                 | Code, Config, Apps, Daten, Paperless-Eingang                           |
| [`Database.yaml`](Database.yaml)               | Postgres per CNPG, Dump alle 12 h                                      |
| [`Valkey.yaml`](Valkey.yaml)                   | Cache und Datei-Sperren                                                |
| [`NetworkPolicies.yaml`](NetworkPolicies.yaml) | Eingang nur von `ingress-public`, Ausgang nur App-Store, Updates, Push |

## Aufbau

Offizielles Image in der `fpm`-Variante, als `99:100` ohne root. Der
Entrypoint kopiert den Code aus dem Image nach `/var/www/html` und führt
nach einem Image-Update `occ upgrade` aus. Cron läuft als Schleife im
Sidecar, weil `/cron.sh` aus dem Image root braucht.


| Variable                                        | Secret             | Quelle                      |
|-------------------------------------------------|--------------------|-----------------------------|
| `NC_instanceid`, `NC_secret`, `NC_passwordsalt` | `nextcloud`        | SOPS                        |
| `NC_dbhost`, `NC_dbpassword`, …                 | `nextcloud-db-app` | vom CNPG-Operator gewürfelt |

## Speicher

| PVC                 | Klasse        | Pfad auf dem Host                     | gesichert                  |
|---------------------|---------------|---------------------------------------|----------------------------|
| `code`              | `local-path`  | -                                     | nein - kommt aus dem Image |
| `config`            | `nfs-unraid`  | `/mnt/user/k8s/nextcloud/config`      | ja                         |
| `custom-apps`       | `nfs-unraid`  | `/mnt/user/k8s/nextcloud/custom-apps` | ja                         |
| `data`              | `nfs-unraid`  | `/mnt/user/k8s/nextcloud/data`        | ja                         |
| `dumps`             | `nfs-unraid`  | `/mnt/user/k8s/nextcloud/dumps`       | ja                         |
| `paperless-consume` | statisches PV | `/mnt/user/k8s/paperless/consume`     | ja                         |


## occ

Die `occ`-Befehle laufen im Container `nextcloud` (nicht `nginx` oder `cron`).
```bash
occ() { kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ "$@"; }
occ status
```

## Backup

Außer der Reihe, etwa vor einem Major-Update:

```bash
kubectl -n nextcloud create job --from=cronjob/nextcloud-db-dump dump-manuell
kubectl -n nextcloud logs -f job/dump-manuell
kubectl -n nextcloud delete job dump-manuell
```

## Wiederherstellen

Die Befehle für `kubectl` laufen vom Wurzelverzeichnis dieses Repos, 

### Bausteine

**Anhalten.** Vorher Wartungsmodus 

```bash
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ maintenance:mode --on
kubectl -n flux-system patch kustomization apps --type=merge -p '{"spec":{"suspend":true}}'
kubectl -n nextcloud scale deploy/nextcloud --replicas=0
```

**Anlaufen lassen**, noch im Wartungsmodus:

```bash
kubectl -n flux-system patch kustomization apps --type=merge -p '{"spec":{"suspend":false}}'
kubectl -n flux-system annotate --overwrite kustomization apps reconcile.fluxcd.io/requestedAt="$(date +%s)"
kubectl -n nextcloud rollout status deploy/nextcloud --timeout=10m
```

**Freigeben.** Fingerprint, Wartungsmodus aus, dann die Dateien gegen die
Datenbank abgleichen.

```bash
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ maintenance:data-fingerprint
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ maintenance:mode --off
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ files:scan --all
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ files:scan-app-data
```

### Datenbank aus einem Dump

1. **Dump wählen und seine Version prüfen.** Der Code kann nicht zurück:
   Der Dump braucht dieselbe Major-Version wie das Image.

   ```bash
   # Host
   ls -lt /mnt/user/k8s/nextcloud/dumps/
   ```

   ```bash
   DUMP=nextcloud-<zeitstempel>.dump
   ssh root@192.168.178.3 cat /mnt/user/k8s/nextcloud/dumps/$DUMP |
     docker run --rm -i postgres:18-alpine pg_restore --data-only --table=oc_migrations --file=- |
     awk -F'\t' '$1 == "core" { print $2 }' | sort | tail -1   # Version35000… -> 35
   occ status | grep versionstring                             # 35.x.y
   ```

2. **Anhalten** (oben).

3. **Schema leeren und zurückspielen.** Leeren

   ```bash
   kubectl -n nextcloud exec nextcloud-db-1 -c postgres -- psql -d app -c \
     'DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION pg_database_owner;'

   sed "s|/dumps/nextcloud-JJJJ-MM-TTTHHMMZ.dump|/dumps/${DUMP}|" \
       k8s/templates/CnpgRestore.yaml | kubectl apply -f -
   kubectl -n nextcloud wait --for=condition=complete --timeout=20m job/nextcloud-db-restore
   kubectl -n nextcloud logs job/nextcloud-db-restore
   kubectl -n nextcloud delete job nextcloud-db-restore

   # pg_restore legt keine Statistiken an
   kubectl -n nextcloud exec nextcloud-db-1 -c postgres -- psql -d app -c 'ANALYZE;'
   ```

4. **Anlaufen lassen** (oben).

5. **Schema nachziehen.** Stammt der Dump von einer älteren Minor-Version,
   fehlen ihm Migrationen, die `config.php` schon für gelaufen hält:

   ```bash
   occ migrations:status core | grep -i 'new migrations'   # 0
   occ migrations:migrate core                             # nur wenn nicht 0
   ```

6. **Freigeben** (oben).
