# Immich

Fotos und Videos unter `https://immich.nico-steinmueller.de`, Anmeldung nur über Keycloak.

| Datei                                          | Was                                                          |
|------------------------------------------------|--------------------------------------------------------------|
| [`Deployment.yaml`](Deployment.yaml)           | Server: API und Hintergrundjobs                              |
| [`Config.yaml`](Config.yaml)                   | Systemeinstellungen (`immich.yaml`)                          |
| [`MachineLearning.yaml`](MachineLearning.yaml) | Suche und Gesichtserkennung, Modell-Cache                    |
| [`Storage.yaml`](Storage.yaml)                 | Medien                                                       |
| [`Database.yaml`](Database.yaml)               | Postgres mit VectorChord per CNPG, Dump alle 12 h            |
| [`Valkey.yaml`](Valkey.yaml)                   | Job-Warteschlangen                                           |
| [`NetworkPolicies.yaml`](NetworkPolicies.yaml) | Eingang nur von `ingress-public`, Ausgang nur Hugging Face   |

## Konfiguration aus Git

`IMMICH_CONFIG_FILE` zeigt auf die Datei aus [`Config.yaml`](Config.yaml).
Damit sind die Einstellungen in der Weboberfläche gesperrt.

| Variable / Schlüssel   | Secret          | Quelle                      |
|------------------------|-----------------|-----------------------------|
| `oauth.clientSecret`   | `immich`        | SOPS                        |
| `DB_URL`               | `immich-db-app` | vom CNPG-Operator gewürfelt |

## Verwaltung nur aus dem Heimnetz

Der Router `immich-admin` in
[`ingress-public/DynamicConfig.yaml`](../../network/ingress-public/DynamicConfig.yaml)
lässt `/admin` und die Admin-API nur von `192.168.178.0/24` durch, sonst `403`.
`/admin` allein ist nur eine Route im Browser - gesperrt sind die API-Pfade
dahinter. Die Liste stammt aus dem Code von v3.2.4 (`admin: true`); bei einem
Major-Update prüfen, ob neue dazugekommen sind.

## Datenbank

Anders als bei den übrigen Diensten:

- **VectorChord** kommt als eigenes Image (`vchord-scratch`) per Image-Volume
  zum gewöhnlichen `standard`-Image, wie im
  [Beispiel von Immich](https://github.com/immich-app/immich-charts/tree/main/local).
  `pgvector` bringt das Standard-Image mit.
- **Extensions** führt das `Database`-Objekt. Der Operator legt sie als
  Superuser an und hebt `vchord` auf die dort eingetragene `version`. `app`
  ist kein Superuser und dürfte beides nicht.
- **Vektor-Indizes** (`clip_index`, `face_index`) spielt der Restore nicht
  zurück. Immich baut sie beim Start selbst, wenn sie fehlen. Der Start dauert
  dann ein paar Minuten, im Log steht `Reindexing … do not restart`.

## Backup

Zwei Wege, beide im Share `k8s` und damit bei Kopia, wie die Medien:

|             | CronJob `immich-db-dump`                 | Immichs eigenes Backup               |
|-------------|------------------------------------------|--------------------------------------|
| wann        | alle 12 h                                | täglich 02:00                        |
| wohin       | `/mnt/user/k8s/immich/dumps/`            | `/mnt/user/k8s/immich/data/backups/` |
| vorgehalten | 14                                       | 7 ([`Config.yaml`](Config.yaml))     |
| Format      | `pg_dump` custom, unkomprimiert          | SQL, gzip                            |
| Alarm       | `DbDumpFehlgeschlagen`, `DbDumpVeraltet` | keiner                               |
| zurück      | [Wiederherstellen](#wiederherstellen)    | Notweg unten                         |

Der CronJob ist das Haupt-Backup. Den Restore-Knopf in Immichs
Weboberfläche gibt es, er scheitert hier aber: Er löscht als `app` das Schema
samt Extensions, und die gehören dem Superuser.

Außer der Reihe, etwa vor einem Update:

```bash
kubectl -n immich create job --from=cronjob/immich-db-dump dump-manuell
kubectl -n immich logs -f job/dump-manuell
kubectl -n immich delete job dump-manuell
```

## Wiederherstellen

**Vorher die Version prüfen.** Immich migriert nur vorwärts: Der Dump darf
nicht von einer neueren Version stammen als das Image. Was nach dem Dump
hochgeladen wurde, liegt danach ohne Eintrag auf der Platte.

1. Anhalten:

   ```bash
   kubectl -n flux-system patch kustomization apps --type=merge -p '{"spec":{"suspend":true}}'
   kubectl -n immich scale deploy/immich-server --replicas=0
   ```

2. Schema leeren und die Extensions neu anlegen, als Superuser. Der Operator
   legte sie nach dem `DROP` auch selbst wieder an, aber erst beim nächsten
   Abgleich. Die Liste ist die aus dem `Database`-Objekt in
   [`Database.yaml`](Database.yaml):

   ```bash
   kubectl -n immich exec -i immich-db-1 -c postgres -- psql -d app -v ON_ERROR_STOP=1 <<'SQL'
   DROP SCHEMA public CASCADE;
   CREATE SCHEMA public AUTHORIZATION pg_database_owner;
   CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
   CREATE EXTENSION IF NOT EXISTS cube;
   CREATE EXTENSION IF NOT EXISTS earthdistance;
   CREATE EXTENSION IF NOT EXISTS pg_trgm;
   CREATE EXTENSION IF NOT EXISTS unaccent;
   CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
   SQL
   ```

3. Zurückspielen, ohne Vektor-Indizes. Die Befehle laufen vom
   Wurzelverzeichnis dieses Repos aus:

   ```bash
   DUMP=immich-<zeitstempel>.dump
   sed -e 's/nextcloud/immich/g' \
       -e "s|/dumps/immich-JJJJ-MM-TTTHHMMZ.dump|/dumps/${DUMP}|" \
       -e 's#{ name: EXCLUDE, value: "" }#{ name: EXCLUDE, value: "INDEX public (clip_index|face_index) " }#' \
       k8s/templates/CnpgRestore.yaml | kubectl apply -f -
   kubectl -n immich wait --for=condition=complete --timeout=30m job/immich-db-restore
   kubectl -n immich logs job/immich-db-restore
   kubectl -n immich delete job immich-db-restore
   kubectl -n immich exec immich-db-1 -c postgres -- psql -d app -c 'ANALYZE;'
   ```

4. Wieder anlaufen lassen:

   ```bash
   kubectl -n flux-system patch kustomization apps --type=merge -p '{"spec":{"suspend":false}}'
   kubectl -n flux-system annotate --overwrite kustomization apps reconcile.fluxcd.io/requestedAt="$(date +%s)"
   kubectl -n immich logs -f deploy/immich-server -c immich-server   # Reindexing clip_index …
   kubectl -n immich rollout status deploy/immich-server --timeout=30m
   ```

### Notweg: aus Immichs eigenem Backup

Ungetestet. Statt der Schritte 2 und 3 oben, als Superuser: Schema leeren,
ohne die Extensions neu anzulegen. Das macht der Dump selbst, und als
Superuser darf er das. Die Tabellen bekommt `app` über die `OWNER TO`-Zeilen
im Dump.

```bash
BACKUP=immich-db-backup-<zeitstempel>.sql.gz
kubectl -n immich exec immich-db-1 -c postgres -- psql -d app -c \
  'DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION pg_database_owner;'
ssh root@192.168.178.3 cat /mnt/user/k8s/immich/data/backups/$BACKUP | gunzip |
  kubectl -n immich exec -i immich-db-1 -c postgres -- \
    psql -d app -v ON_ERROR_STOP=1 --single-transaction > /dev/null
```

## Updates

| Was | Renovate-Gruppe | automatisch |
|---|---|---|
| Server und Machine Learning | `immich` | außer Majors |
| Postgres (Instanz und Dump-Job) | `cnpg-postgres`, wie die anderen Dienste | außer Majors |
| VectorChord (Image und `version`) | `immich-vchord` | nie |

**VectorChord** hebt der Operator nach dem Merge selbst (`ALTER EXTENSION
vchord UPDATE TO …`). Die Vektor-Indizes baut dabei niemand neu - Immich täte
es bei einem eigenen Update. Deshalb danach:

```bash
kubectl -n immich exec immich-db-1 -c postgres -- psql -d app -Atc \
  "select extversion from pg_extension where extname = 'vchord'"   # neue Version
kubectl -n immich exec immich-db-1 -c postgres -- psql -d app -c \
  'DROP INDEX IF EXISTS clip_index, face_index;'
kubectl -n immich rollout restart deploy/immich-server   # baut sie neu
```

