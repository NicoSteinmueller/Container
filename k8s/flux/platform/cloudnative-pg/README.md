# cloudnative-pg

Postgres per Operator: Man deklariert einen `Cluster`, kein Passwort. Der
Operator würfelt es und legt es als Secret `<name>-app` ab.

## Backup: `pg_dump` 

 CronJob alle 12 h auf ein PVC der Klasse `nfs-unraid`.

## Ein neuer Dienst

Vorlage: [`../../../templates/CnpgDatabase.yaml`](../../../templates/CnpgDatabase.yaml). Dazu:

- **`cnpg-egress`** in [`NetworkPolicies.yaml`](NetworkPolicies.yaml)
- **Wer an die Datenbank darf**, trägt das Label `homelab.io/db-client: <name>-db`
- **Image:** `imageName` und das Image des Dump-Jobs sind gleich.
- **Datenbankname:** ohne `bootstrap`-Block heißen Datenbank und Rolle `app`.

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
   Cluster starten. 

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

Mit dem Job aus [`../../../templates/CnpgRestore.yaml`](../../../templates/CnpgRestore.yaml).
Nach einem Totalverlust: Cluster-CR anwenden (leere Instanz, neues Passwort,
die Anwendung liest es per `secretKeyRef`), Anwendung auf `replicas: 0`, Job
anwenden, Anwendung wieder hoch.
