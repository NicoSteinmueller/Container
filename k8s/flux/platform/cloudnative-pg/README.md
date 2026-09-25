# cloudnative-pg

Postgres per Operator: Man deklariert einen `Cluster`, kein Passwort. Der
Operator würfelt es und legt es als Secret `<name>-app` ab; die Anwendung liest
es per `secretKeyRef`. Der Wert existiert nie in Git
([../../../AUSBAUSTUFEN.md](../../../AUSBAUSTUFEN.md), Stufe 1).

Der Operator läuft `clusterWide` in `cnpg-system`, die Instanzen im Namespace
ihres Dienstes.

## Backup: `pg_dump` statt `ScheduledBackup`

Alle CNPG-Backups wollen Objektspeicher oder CSI-Snapshots, `local-path` kann
keins von beiden. Deshalb ein CronJob alle 12 h auf ein PVC der Klasse
`nfs-unraid`, von dort holt Kopia es ab. **Kein PITR** - zurück geht es nur auf
den letzten Dump.

## Ein neuer Dienst

Vorlage: [`../../../templates/CnpgDatabase.yaml`](../../../templates/CnpgDatabase.yaml)
(Cluster, Dump-PVC, CronJob, Netzwerkregeln). Dazu:

- **`cnpg-egress`** in [`NetworkPolicies.yaml`](NetworkPolicies.yaml): der
  Dienst-Namespace auf `5432`/`8000` (Block steht auskommentiert). Sonst bleibt
  der Cluster auf *Setting up primary*.
- **Wer an die Datenbank darf**, trägt das Label
  `homelab.io/db-client: <name>-db` - die Anwendung, der Dump- und der
  Restore-Job. Die beiden Policies der Vorlage lassen sonst niemanden herein,
  auch nicht aus demselben Namespace.
- **Image:** `imageName` und das Image des Dump-Jobs sind dasselbe, gepinnt mit
  Digest. `pg_dump` bricht gegen eine neuere Server-Hauptversion ab - ohne Pin
  nähme der Operator seinen Default, und der wandert mit jedem Operator-Update.
  Renovate hebt beide in einem PR (Gruppe `cnpg-postgres`, immer mit Review).
- **Datenbankname:** ohne `bootstrap`-Block heißen Datenbank und Rolle `app`.
- **Reloader** nur für Secrets aus `homelab-secrets`, nicht für `-app`: Das
  rotiert der Operator auf beiden Seiten selbst.

## Migration aus Docker

Das alte Passwort braucht es dafür nicht: Das Postgres-Image lässt im
Container über den lokalen Socket ohne Passwort zu (`trust` in `pg_hba.conf`),
und `POSTGRES_USER`/`POSTGRES_DB` stehen in seiner Umgebung. Keine
Egress-Ausnahme, kein temporäres Secret.

1. Cluster, Dump-PVC und CronJob über Flux ausrollen. Das PVC legt
   `/mnt/user/k8s/<dienst>/dumps` an; die Anwendung im Cluster läuft noch
   nicht (oder auf `replicas: 0`).
2. Auf dem Host die **Anwendung** stoppen, den Datenbank-Container nicht -
   sonst fehlt im Cluster, was nach dem Dump geschrieben wird.
3. Dump schreiben und prüfen:

   ```bash
   ssh root@192.168.178.3
   docker stop nextcloud
   out=/mnt/user/k8s/nextcloud/dumps/migration-nextcloud-$(date -u +%Y-%m-%dT%H%MZ).dump
   docker exec nextcloud_postgres sh -c \
     'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --compress=0 --no-owner --no-privileges' \
     > "$out"
   docker exec -i nextcloud_postgres pg_restore --list < "$out" > /dev/null && echo lesbar
   ```

   Das Präfix `migration-` hält die Datei aus der Rotation des CronJobs
   (`<dienst>-*.dump`). Löschen, wenn der Dienst ein paar Tage steht.
4. `CnpgRestore.yaml` mit diesem `DUMP` anwenden, danach die Anwendung im
   Cluster starten. Der gestoppte Docker-Stack bleibt stehen - er ist der
   Rückweg.

Vorher einmal als Probelauf, bei laufender Anwendung: Dump, Restore, in der
Anwendung im Cluster nachsehen, Cluster-CR löschen und neu anlegen. Erst dann
der echte Umzug mit gestoppter Anwendung.

Drei Dinge, die der Dump nicht mitnimmt:

- **Kollation.** Ohne Angabe legt CNPG die Datenbank mit `C` an. Nextcloud und
  SFTPGo laufen heute auch so; Paperless, Keycloak und Immich auf
  `en_US.utf8`. Dort `bootstrap.initdb.localeCollate` und `localeCType` auf
  `en_US.utf8` setzen, sonst ändert sich die Sortierung. Nachsehen:
  `docker exec <c> sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "select datcollate from pg_database where datname = current_database()"'`
- **Extensions.** Zurückgespielt wird als `app` (`--no-owner`), und der darf
  keine Extensions anlegen, die Superuser verlangen. Nur Immich hat welche
  (`vector`, `vchord`, `cube`, `earthdistance`, `pg_trgm`, `unaccent`,
  `uuid-ossp`) - dort ein Image mit VectorChord statt `standard` und die
  Extensions über `bootstrap.initdb.postInitApplicationSQL` vor dem Restore.
  Die anderen haben nur `plpgsql`.

## Zurückspielen

Mit dem Job aus [`../../../templates/CnpgRestore.yaml`](../../../templates/CnpgRestore.yaml),
nicht per `kubectl exec` in die Instanz - die hat die Dumps nicht eingehängt.
Nach einem Totalverlust: Cluster-CR anwenden (leere Instanz, neues Passwort,
die Anwendung liest es per `secretKeyRef`), Anwendung auf `replicas: 0`, Job
anwenden, Anwendung wieder hoch. Am 2026-09-24 so durchgespielt: Cluster
gelöscht, neu angelegt, 100.000 Zeilen zurück, Prüfsumme gleich.

```bash
# Dump sofort statt in 12 h, und nachsehen, wo es zählt (Zeitstempel in UTC)
kubectl -n nextcloud create job --from=cronjob/nextcloud-db-dump dump-test
ssh root@192.168.178.3 ls -lh /mnt/user/k8s/nextcloud/dumps/

# Hängt "Setting up primary": erste Stelle ist cnpg-egress
kubectl -n kube-system exec ds/cilium -- hubble observe --namespace cnpg-system --type drop --last 100
```
