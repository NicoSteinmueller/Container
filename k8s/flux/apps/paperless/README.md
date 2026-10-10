# Paperless-ngx

Dokumente unter `https://paperless.k8s.nico-steinmueller.de`

| Datei                                          | Was                                                         |
|------------------------------------------------|-------------------------------------------------------------|
| [`Deployment.yaml`](Deployment.yaml)           | Webserver, Worker, Scheduler, Consumer in einem Container   |
| [`Storage.yaml`](Storage.yaml)                 | Index, Dokumente, Eingangsordner, Export                    |
| [`Database.yaml`](Database.yaml)               | Postgres per CNPG, Dump alle 12 h                           |
| [`Valkey.yaml`](Valkey.yaml)                   | Celery-Broker                                               |
| [`Gotenberg.yaml`](Gotenberg.yaml)             | Office-Dateien und E-Mails nach PDF                         |
| [`Tika.yaml`](Tika.yaml)                       | Text aus Office-Dateien und E-Mails                         |
| [`NetworkPolicies.yaml`](NetworkPolicies.yaml) | Eingang nur von `ingress-internal`, Ausgang nur Keycloak    |

## Aufbau

Offizielles Image ohne root und mit schreibgeschütztem
Dateisystem. Das Image erkennt das selbst (`USER_IS_NON_ROOT`) und lässt
`USERMAP_*` und das Umschreiben der Rechte aus. s6-overlay braucht `/run`,
OCR braucht `/tmp` - beides `emptyDir`.

| Variable                                       | Secret             | Quelle                      |
|------------------------------------------------|--------------------|-----------------------------|
| `PAPERLESS_SECRET_KEY`                         | `paperless`        | SOPS                        |
| Client-Secret in `PAPERLESS_SOCIALACCOUNT_PROVIDERS` | `paperless`  | SOPS                        |
| `PAPERLESS_IGNORE_DATES`                       | `paperless`        | SOPS                        |
| `PAPERLESS_DBHOST`, `PAPERLESS_DBPASS`, …      | `paperless-db-app` | vom CNPG-Operator gewürfelt |

## Speicher

| PVC       | Klasse       | Pfad auf dem Host                 | gesichert                      |
|-----------|--------------|-----------------------------------|--------------------------------|
| `data`    | `local-path` | -                                 | nein - baut Paperless neu      |
| `media`   | `nfs-unraid` | `/mnt/user/k8s/paperless/media`   | ja                             |
| `consume` | `nfs-unraid` | `/mnt/user/k8s/paperless/consume` | ja                             |
| `export`  | `nfs-unraid` | `/mnt/user/k8s/paperless/export`  | ja                             |
| `dumps`   | `nfs-unraid` | `/mnt/user/k8s/paperless/dumps`   | ja                             |

`data` hält Suchindex, Klassifikator und Logs. Fehlt der Index, baut ihn der
Start neu (`document_index reindex --if-needed`), den Klassifikator trainiert
der Scheduler stündlich.

Den Eingangsordner bindet auch Nextcloud ein (statisches PV
`nextcloud-paperless-consume`). Auf NFS kommen keine inotify-Ereignisse für
Dateien anderer Clients an, deshalb fragt der Consumer alle 10 s ab
(`PAPERLESS_CONSUMER_POLLING_INTERVAL`).

## manage.py

```bash
pm() { kubectl -n paperless exec deploy/paperless -- python3 /usr/src/paperless/src/manage.py "$@"; }
pm document_index reindex
pm document_exporter /usr/src/paperless/export
```

## Umzug aus Docker

Die Befehle für `kubectl` laufen vom Wurzelverzeichnis dieses Repos.

1. **Keycloak.** Im Client `paperless` (Realm `mein-realm`) die neue Adresse
   ergänzen, die alte bleibt bis zum Abbau des Docker-Stacks:

   | Feld                            | Wert                                                                         |
   |---------------------------------|------------------------------------------------------------------------------|
   | Valid redirect URIs             | `https://paperless.k8s.nico-steinmueller.de/accounts/oidc/keycloak/login/callback/` |
   | Valid post logout redirect URIs | `https://paperless.k8s.nico-steinmueller.de`                                 |
   | Web origins                     | `https://paperless.k8s.nico-steinmueller.de`                                 |

2. **Secret** `homelab-secrets/cluster/paperless.sops.yaml` mit den Werten
   aus dem Portainer-Stack füllen (`sops edit`), pushen.

3. **Ausrollen** mit `replicas: 0` im [`Deployment.yaml`](Deployment.yaml).
   Danach stehen Datenbank, PVCs, Valkey, Gotenberg und Tika:

   ```bash
   kubectl -n paperless get cluster,pvc,pod
   ```

4. **Version prüfen.** Das Image im Cluster darf nicht älter sein als das im
   Docker-Stack - Paperless migriert nur vorwärts.

5. **Anwendung auf dem Host stoppen**, die Datenbank nicht, dann Dump
   schreiben:

   ```bash
   ssh root@192.168.178.3
   docker stop paperless
   out=/mnt/user/k8s/paperless/dumps/migration-paperless-$(date -u +%Y-%m-%dT%H%MZ).dump
   docker exec paperless_postgres sh -c \
     'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --compress=0 --no-owner --no-privileges' \
     > "$out"
   docker exec -i paperless_postgres pg_restore --list < "$out" > /dev/null && echo lesbar
   ```

6. **Dateien kopieren**, noch auf dem Host. `-a` behält `99:100`, und die
   Pfade unter `media/` müssen gleich bleiben - sie stehen in der Datenbank.
   Was im alten Eingangsordner liegt, kommt in den neuen.

   ```bash
   rsync -a --info=progress2 /mnt/user/data/paperless/media/  /mnt/user/k8s/paperless/media/
   rsync -a --info=progress2 /mnt/user/data/paperless/export/ /mnt/user/k8s/paperless/export/
   rsync -a /mnt/user/data/paperless/consume/ /mnt/user/k8s/paperless/consume/
   ```

7. **Zurückspielen:**

   ```bash
   DUMP=migration-paperless-<zeitstempel>.dump
   sed -e 's/nextcloud/paperless/g' \
       -e "s|/dumps/paperless-JJJJ-MM-TTTHHMMZ.dump|/dumps/${DUMP}|" \
       k8s/templates/CnpgRestore.yaml | kubectl apply -f -
   kubectl -n paperless wait --for=condition=complete --timeout=20m job/paperless-db-restore
   kubectl -n paperless logs job/paperless-db-restore
   kubectl -n paperless delete job paperless-db-restore
   kubectl -n paperless exec paperless-db-1 -c postgres -- psql -d app -c 'ANALYZE;'
   ```

8. **Starten:** `replicas: 1` im [`Deployment.yaml`](Deployment.yaml), die
   Zeile `UMZUG` dazu löschen, pushen. Der erste Start baut den Suchindex
   über alle Dokumente neu, das dauert:

   ```bash
   kubectl -n paperless logs -f deploy/paperless   # [init-index] …
   kubectl -n paperless rollout status deploy/paperless --timeout=60m
   ```

9. **Prüfen:** Anmeldung über Keycloak, Suche, ein Dokument über den
   Eingangsordner in Nextcloud, ein Dump außer der Reihe (unten).

10. **Docker-Stack** in Portainer stoppen, nicht löschen - er ist der
    Rückweg. Erst wenn Paperless hier ein paar Tage steht und ein Dump samt
    Kopia-Snapshot existiert: Stack, `paperless/`, `grafana/alloy/paperless.alloy`,
    `/mnt/user/appdata/paperless`, `/mnt/user/data/paperless`, die alten
    Keycloak-URIs und den Dump `migration-*` entfernen.

## Backup

Der CronJob `paperless-db-dump` schreibt alle 12 h einen `pg_dump` nach
`/mnt/user/k8s/paperless/dumps/`, hält 14 Stück vor und meldet sich bei
Fehlern über [`DbBackupRules.yaml`](../../observability-rules/DbBackupRules.yaml).
Die Dokumente selbst liegen unter `media/`, beides sichert Kopia.

Außer der Reihe, etwa vor einem Major-Update:

```bash
kubectl -n paperless create job --from=cronjob/paperless-db-dump dump-manuell
kubectl -n paperless logs -f job/dump-manuell
kubectl -n paperless delete job dump-manuell
```

## Wiederherstellen

Wie beim Umzug ab Schritt 7, mit einem Dump aus `dumps/` statt `migration-…`.
Vorher anhalten, sonst schreibt Paperless in die halb zurückgespielte
Datenbank:

```bash
kubectl -n flux-system patch kustomization apps --type=merge -p '{"spec":{"suspend":true}}'
kubectl -n paperless scale deploy/paperless --replicas=0
```

Danach wieder anlaufen lassen:

```bash
kubectl -n flux-system patch kustomization apps --type=merge -p '{"spec":{"suspend":false}}'
kubectl -n flux-system annotate --overwrite kustomization apps reconcile.fluxcd.io/requestedAt="$(date +%s)"
kubectl -n paperless rollout status deploy/paperless --timeout=30m
```

Dokumente, die nach dem Dump dazukamen, liegen danach ohne Eintrag unter
`media/` - `pm document_sanity_checker` zeigt sie.
