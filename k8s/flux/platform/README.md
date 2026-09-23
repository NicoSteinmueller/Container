# platform

Die Controller, auf denen die Dienste aufsetzen: Zertifikate, Datenbanken,
Neustarts nach einer Rotation.

| Komponente | Was |
|---|---|
| [`cert-manager/`](cert-manager) | cert-manager, ohne DNS-Provider — nur die interne CA |
| [`cloudnative-pg/`](cloudnative-pg) | Postgres-Operator |
| [`reloader/`](reloader) | startet neu, was ein geändertes Secret benutzt |
| [`Sources.yaml`](Sources.yaml) | HelmRepositories `jetstack`, `cloudnative-pg`, `stakater` |

`wait: true` an dieser Gruppe ([`../sync/Platform.yaml`](../sync/Platform.yaml)):
[`cert-manager-issuers`](../cert-manager-issuers) wartet darauf, und dahinter
`network`. Hängt eine der drei Releases, steht die Kette — sie ist echt und
nicht vorsichtshalber.

## `cert-manager/`

**Nicht** für die öffentlichen Zertifikate: Die holen sich die beiden
Traefik-Controller weiter selbst per ACME/DNS-01 bei Let's Encrypt. cert-manager
bekommt deshalb auch keinen DNS-Provider-Token, und diese CA ist clusterintern —
kein Browser kennt sie, und das ist richtig so.

Der Anlass ist CrowdSec. Der Agent registriert sich beim Start mit seinem
Pod-Namen bei der LAPI; startet der Container neu, ohne dass der Pod neu
entsteht, sind die lokalen Zugangsdaten weg, der Name in der LAPI aber noch da:

```
403 Forbidden: user 'crowdsec-agent-xxxxx': user already exist
```

Der Init-Container hängt dann für immer im CrashLoopBackOff. Am 2026-09-11 waren
es 65 Versuche. Der Chart hat dafür genau einen Ausweg, und der hängt an TLS:
Mit `tls.enabled` weist sich der Agent per Client-Zertifikat aus statt per
registriertem Passwort, der Init-Container fällt in den Zweig ohne `register` —
und das Problem ist weg statt diesmal gelöst.

Die Issuer und Zertifikate liegen in [`../cert-manager-issuers`](../cert-manager-issuers),
weil ihre CRDs erst mit dem Helm-Release entstehen.

## `cloudnative-pg/`

Der Operator, dem die Postgres-Instanzen der migrierten Dienste gehören. Was er
löst, steht in [../../AUSBAUSTUFEN.md](../../AUSBAUSTUFEN.md), Stufe 1 — kurz:
Man deklariert einen `Cluster`, kein Passwort. Der Operator würfelt es selbst,
legt es als Secret `<name>-app` ab, die Anwendung greift es per `secretKeyRef`.
Der Wert existiert nie in Git, auch nicht verschlüsselt.

Er läuft `clusterWide` in `cnpg-system`; die Instanzen liegen **nicht** dort,
sondern im Namespace des jeweiligen Dienstes. Der Operator spricht sie über zwei
Ports an: Instance Manager auf `8000` für den Zustand, Postgres auf `5432` für
Rollen und Datenbanken. Beides muss in `cnpg-egress` je Namespace freigegeben
werden — sonst bleibt der `Cluster` auf *Setting up primary* stehen.

### Warum hier keine `ScheduledBackup` steht

CNPG kennt drei Backup-Methoden, und keine schreibt in ein PVC:
`barmanObjectStore` und `plugin` wollen einen Objektspeicher, `volumeSnapshot`
einen snapshot-fähigen CSI-Treiber plus snapshot-controller. `local-path` kann
das nicht — und dort liegt PGDATA, aus den Gründen in
[../storage/README.md](../storage/README.md).

Deshalb: **`pg_dump` per CronJob, alle 12 h, auf ein PVC der Klasse
`nfs-unraid`** — also nach `/mnt/user/k8s`, wo Kopia es abholt. Der Preis ist
entschieden und ausdrücklich: kein PITR. Man kommt auf den letzten Dump zurück,
nicht auf einen Zeitpunkt dazwischen.

Zu sichern ist damit wenig: nur der Dump. Nicht PGDATA, nicht der Operator,
nicht die `Cluster`-CRs — die stehen in Git. Der Weg zurück ist: CR anwenden,
leere Instanz, Dump einspielen.

### Vorlage je Dienst

Der CronJob braucht das Secret `<cluster>-app` und ist damit namespace-gebunden;
er gehört in die Datei des Dienstes, nicht hierher. Am Beispiel `nextcloud`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: nextcloud-db
  namespace: nextcloud
spec:
  instances: 1                    # ein Node, keine Hochverfügbarkeit
  storage:
    size: 20Gi                    # ohne storageClass -> local-path (Default)
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { memory: 1Gi }
---
# Das Ziel der Dumps. Der PVC-Name landet im Pfad: die StorageClass setzt
# subDir auf <namespace>/<pvc-name>, das ergibt /mnt/user/k8s/nextcloud/dumps.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dumps
  namespace: nextcloud
spec:
  accessModes: [ReadWriteMany]
  storageClassName: nfs-unraid
  resources:
    requests:
      storage: 20Gi            # NFS erzwingt kein Kontingent, nur Buchhaltung
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nextcloud-db-dump
  namespace: nextcloud
spec:
  schedule: "0 */12 * * *"
  timeZone: Europe/Berlin         # sonst UTC, und die Zeitstempel lügen
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure
          securityContext:
            runAsNonRoot: true
            runAsUser: 26         # postgres im CNPG-Image
            runAsGroup: 26
            fsGroup: 26
            seccompProfile: { type: RuntimeDefault }
          containers:
            - name: dump
              # Dasselbe Image wie die Instanz: pg_dump muss zur Server-
              # Version passen. Ein fremdes Image ist der Fehler, der erst
              # beim Versionssprung auffällt.
              image: ghcr.io/cloudnative-pg/postgresql:17.6
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities: { drop: [ALL] }
              env:
                - { name: PGHOST,     valueFrom: { secretKeyRef: { name: nextcloud-db-app, key: host } } }
                - { name: PGPORT,     valueFrom: { secretKeyRef: { name: nextcloud-db-app, key: port } } }
                - { name: PGUSER,     valueFrom: { secretKeyRef: { name: nextcloud-db-app, key: username } } }
                - { name: PGPASSWORD, valueFrom: { secretKeyRef: { name: nextcloud-db-app, key: password } } }
                - { name: PGDATABASE, valueFrom: { secretKeyRef: { name: nextcloud-db-app, key: dbname } } }
              command: [/bin/bash, -c]
              args:
                - |
                  set -euo pipefail
                  out="/dumps/nextcloud-$(date +%Y-%m-%dT%H%M).dump"

                  # --compress=0 mit Absicht: Kopia dedupliziert und
                  # komprimiert selbst. Ein komprimierter Dump unterscheidet
                  # sich ab der ersten geänderten Zeile auf ganzer Länge vom
                  # vorigen - jeder Snapshot legte dann eine volle Kopie ab.
                  pg_dump --format=custom --compress=0 \
                          --no-owner --no-privileges --file="${out}.part"

                  # Erst fertig schreiben, dann umbenennen: mv innerhalb eines
                  # Dateisystems ist atomar, Kopia sieht nie einen halben Dump.
                  mv "${out}.part" "${out}"

                  # Lokale Vorhaltung; die Tiefe hat Kopia.
                  ls -1t /dumps/nextcloud-*.dump | tail -n +15 | xargs -r rm --
              volumeMounts:
                - { name: dumps, mountPath: /dumps }
                - { name: tmp,   mountPath: /tmp }
          volumes:
            - name: dumps
              persistentVolumeClaim:
                claimName: dumps
            - name: tmp
              emptyDir: {}
```

Dazu je Dienst:

- **`cnpg-egress` erweitern** — der Namespace mit `cnpg.io/podRole: instance` auf
  `5432` und `8000`, sonst kommt die Datenbank nicht hoch. Der Block steht
  auskommentiert in [`cloudnative-pg/NetworkPolicies.yaml`](cloudnative-pg/NetworkPolicies.yaml).
- **Egress im Dienst-Namespace** — CoreDNS und die eigene Instanz auf `5432`.
  Der CronJob-Pod fällt unter dieselbe Regel wie die Anwendung.
- **Reloader** — der Namespace gehört in die Liste in [`reloader/HelmRelease.yaml`](reloader/HelmRelease.yaml),
  sobald ein Secret aus `homelab-secrets` dort in `env` hängt. Für das
  `-app`-Secret ist er *nicht* nötig: Rotiert der Operator es über
  `spec.managed.roles`, ändert er beide Seiten selbst — genau die Lücke, die
  Reloader offenlässt.

### Der Weg zurück

Kein Restore *in* eine laufende Instanz: `Cluster`-CR anwenden, der Operator
legt eine leere Instanz an, Dump einspielen.

```bash
kubectl -n nextcloud exec -it nextcloud-db-1 -- \
  pg_restore --clean --if-exists --no-owner --no-privileges \
             -d nextcloud /dumps/nextcloud-<zeitstempel>.dump
```

Das Passwort entsteht dabei neu und fehlt niemandem, solange die Anwendung es
per `secretKeyRef` liest.

### Migration aus dem Docker-Container

`bootstrap.initdb.import` mit `type: microservice` fährt pg_dump/pg_restore gegen
die alte Instanz, inklusive Versionssprung. Zwei Dinge fallen dabei an, die es
sonst nicht gibt:

- Das alte `POSTGRES_PASSWORD` braucht man **ein letztes Mal** als temporäres
  Secret im Namespace. Danach gehört es aus `homelab-secrets` heraus.
- Der Import spricht den Unraid-Host an, und ins Heimnetz darf sonst keiner
  (siehe [../sync/README.md](../sync/README.md#egress-wer-aus-dem-cluster-heraus-darf)).
  Die Regel dafür ist eine **befristete** Ausnahme auf `192.168.178.3:5432`, die
  mit dem temporären Secret zusammen wieder verschwindet. Sie stehen zu lassen
  wäre der stille Weg zurück in ein flaches Netz.

### Gegenproben

```bash
kubectl -n cnpg-system get deploy,pods
kubectl -n nextcloud get cluster,pods,cronjob

# Einen Lauf erzwingen, statt zwölf Stunden zu warten
kubectl -n nextcloud create job --from=cronjob/nextcloud-db-dump dump-test
kubectl -n nextcloud logs job/dump-test

# Die Gegenprobe, auf die es ankommt - auf dem Host, nicht im Cluster
ssh root@192.168.178.3 ls -lh /mnt/user/k8s/nextcloud/dumps/

# Bleibt der Cluster auf "Setting up primary": erste Stelle ist cnpg-egress
kubectl -n kube-system exec ds/cilium -- \
  hubble observe --namespace cnpg-system --type drop --last 100
```

## `reloader/`

Startet neu, was ein geändertes Secret benutzt — sonst arbeitet ein Pod nach
einer Rotation bis zu seinem nächsten Start mit dem alten Wert weiter.

Wen er anfasst, regelt er selbst: `autoReloadAll: true`, innerhalb seines
Blickfelds gilt jeder Workload als annotiert. Vorher setzte Kyverno die
Annotation `reloader.stakater.com/auto` cluster-weit; mit dem Plattform-Stack
fiel Kyverno weg, und Reloader lief eine Zeit lang wirkungslos — er beobachtete
alles und startete nichts. Dieselbe Regel, ein Controller weniger.

Das Blickfeld ist eine Namespace-Liste und nicht der ganze Cluster
(`watchGlobally: false` plus `namespaces`): `crowdsec`, `traefik-internal`,
`traefik-public` — dort und nur dort hält ein laufender Prozess ein Secret aus
`homelab-secrets`. Das Chart legt daraufhin Role und RoleBinding je Namespace an
und **keine ClusterRole**. Der Unterschied ist nicht kosmetisch: Cluster-weit
bekäme Reloader `update`/`patch` auf Deployments, DaemonSets und StatefulSets in
jedem Namespace, `kube-system` eingeschlossen.

> **Ein neuer Dienst mit Secret gehört in diese Liste.** Sonst läuft er nach
> einer Rotation still mit dem alten Wert weiter — er läuft ja.

Was dabei **nicht** passiert: die Gegenseite ändern. Ein rotiertes
Postgres-Passwort startet Nextcloud neu, und Nextcloud kommt dann nicht mehr an
die Datenbank, weil dort noch das alte gilt. Diese Hälfte gehört einem Operator,
der beide Seiten besitzt.

```bash
# Gegenprobe, dass nichts cluster-weit übrig ist
kubectl get clusterrole,clusterrolebinding | grep reloader   # erwartet: leer
kubectl get role,rolebinding -A | grep reloader

kubectl -n reloader logs deploy/reloader-reloader | tail
```
