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

**Migration aus Docker:** `bootstrap.initdb.import` (`type: microservice`). Das
alte Passwort braucht es ein letztes Mal als temporäres Secret, dazu eine
**befristete** Egress-Ausnahme auf `192.168.178.3:5432` - beides danach wieder
entfernen.

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
