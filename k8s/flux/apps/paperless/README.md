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
| [`NetworkPolicies.yaml`](NetworkPolicies.yaml) | Eingang von `ingress-internal`, Ausgang Keycloak und IMAP   |

## Aufbau

Offizielles Image ohne root und mit schreibgeschütztem
Dateisystem.

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

Den Eingangsordner bindet auch Nextcloud ein (statisches PV `nextcloud-paperless-consume`).

## manage.py

```bash
pm() { kubectl -n paperless exec deploy/paperless -- python3 /usr/src/paperless/src/manage.py "$@"; }
pm document_index reindex
pm document_exporter /usr/src/paperless/export
```

## Backup

Der CronJob `paperless-db-dump` schreibt alle 12 h einen `pg_dump`,
hält 14 Stück vor und meldet sich bei Fehlern über [`DbBackupRules.yaml`](../../observability-rules/DbBackupRules.yaml).
Die Dokumente selbst liegen unter `media/`, beides sichert Kopia.

Außer der Reihe, etwa vor einem Major-Update:

```bash
kubectl -n paperless create job --from=cronjob/paperless-db-dump dump-manuell
kubectl -n paperless logs -f job/dump-manuell
kubectl -n paperless delete job dump-manuell
```

## Wiederherstellen

Die Datenbank aus einem Dump unter `dumps/`. Die Befehle für `kubectl`
laufen vom Wurzelverzeichnis dieses Repos, `pm` ist die Funktion von oben.

1. **Dump wählen und seine Version prüfen.** Paperless migriert nur
   vorwärts: Ein älterer Dump ist in Ordnung, den zieht der Start nach.

2. **Anhalten**, sonst schreibt Paperless in die halb zurückgespielte
   Datenbank:

   ```bash
   kubectl -n flux-system patch kustomization apps --type=merge -p '{"spec":{"suspend":true}}'
   kubectl -n paperless scale deploy/paperless --replicas=0
   ```

3. **Schema leeren und zurückspielen.** `--clean` im Job räumt nur weg, was
   im Dump steht. Tabellen aus neueren Migrationen blieben liegen, hängen per
   Fremdschlüssel an den alten, und der Job bricht ab.

   ```bash
   kubectl -n paperless exec paperless-db-1 -c postgres -- psql -d app -c \
     'DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION pg_database_owner;'

   sed -e 's/nextcloud/paperless/g' \
       -e "s|/dumps/paperless-JJJJ-MM-TTTHHMMZ.dump|/dumps/${DUMP}|" \
       k8s/templates/CnpgRestore.yaml | kubectl apply -f -
   kubectl -n paperless wait --for=condition=complete --timeout=20m job/paperless-db-restore
   kubectl -n paperless logs job/paperless-db-restore
   kubectl -n paperless delete job paperless-db-restore

   # pg_restore legt keine Statistiken an
   kubectl -n paperless exec paperless-db-1 -c postgres -- psql -d app -c 'ANALYZE;'
   ```

4. **Anlaufen lassen.** Der Start spielt fehlende Migrationen ein:

   ```bash
   kubectl -n flux-system patch kustomization apps --type=merge -p '{"spec":{"suspend":false}}'
   kubectl -n flux-system annotate --overwrite kustomization apps reconcile.fluxcd.io/requestedAt="$(date +%s)"
   kubectl -n paperless rollout status deploy/paperless --timeout=30m
   ```

5. **Abgleichen.** Der Suchindex unter `data/` kennt noch den Stand vor dem
   Zurückspielen, `--if-needed` beim Start greift nicht. Dokumente, die nach
   dem Dump dazukamen, liegen ohne Eintrag unter `media/`.

   ```bash
   pm document_index reindex
   pm document_sanity_checker
   ```
