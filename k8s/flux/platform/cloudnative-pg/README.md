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
(Cluster, Dump-PVC, CronJob). Dazu:

- **`cnpg-egress`** in [`NetworkPolicies.yaml`](NetworkPolicies.yaml): der
  Dienst-Namespace auf `5432`/`8000` (Block steht auskommentiert). Sonst bleibt
  der Cluster auf *Setting up primary*.
- **Im Dienst-Namespace** Egress zur eigenen Instanz auf `5432`; Ingress an die
  Instanz vom Operator (`5432`, `8000`) und von der Anwendung (`5432`).
- **Reloader** nur für Secrets aus `homelab-secrets`, nicht für `-app`: Das
  rotiert der Operator auf beiden Seiten selbst.

**Migration aus Docker:** `bootstrap.initdb.import` (`type: microservice`). Das
alte Passwort braucht es ein letztes Mal als temporäres Secret, dazu eine
**befristete** Egress-Ausnahme auf `192.168.178.3:5432` - beides danach wieder
entfernen.

```bash
# Restore: Cluster-CR anwenden (leere Instanz), dann
kubectl -n nextcloud exec -it nextcloud-db-1 -- pg_restore --clean --if-exists \
  --no-owner --no-privileges -d nextcloud /dumps/nextcloud-<zeitstempel>.dump

# Dump sofort statt in 12 h, und nachsehen, wo es zählt
kubectl -n nextcloud create job --from=cronjob/nextcloud-db-dump dump-test
ssh root@192.168.178.3 ls -lh /mnt/user/k8s/nextcloud/dumps/

# Hängt "Setting up primary": erste Stelle ist cnpg-egress
kubectl -n kube-system exec ds/cilium -- hubble observe --namespace cnpg-system --type drop --last 100
```
