# Keycloak

Single Sign-On.

| Adresse                                     | Controller         | Was                                                  |
|---------------------------------------------|--------------------|------------------------------------------------------|
| `https://keycloak.nico-steinmueller.de`     | `ingress-public`   | nur `/realms/`, `/resources/`, `/.well-known/` - ohne master-Realm |
| `https://keycloak.k8s.nico-steinmueller.de` | `ingress-internal` | alles, darunter die Admin-Konsole                    |

## Datenbank

Postgres per CNPG in [`Database.yaml`](Database.yaml), Passwort vom Operator
im Secret `keycloak-db-app`. Dumps alle 12 h, Ablauf und Alarme wie in
[`cloudnative-pg`](../../platform/cloudnative-pg/README.md).

## Erster Admin

Nur auf leerer Datenbank: Benutzer und Passwort aus dem Secret
`keycloak-admin` (`homelab-secrets`). 

## Backup

Der CronJob `keycloak-db-dump` schreibt alle 12 h einen `pg_dump` nach
`/mnt/user/k8s/keycloak/dumps/keycloak-<Ortszeit>.dump`, etwa
`keycloak-2026.10.01_12.00.00.dump`. Er hält 14 Stück
vor, die Tiefe liegt bei Kopia. Scheitert ein Lauf oder ist der letzte
gelungene älter als 13 h, meldet Alertmanager das über ntfy
([`DbBackupRules.yaml`](../../observability-rules/DbBackupRules.yaml)).

Außer der Reihe, etwa vor einem Update:

```bash
kubectl -n keycloak create job --from=cronjob/keycloak-db-dump dump-manuell
kubectl -n keycloak logs -f job/dump-manuell
kubectl -n keycloak delete job dump-manuell
```

## Restore

**Vorher die Version prüfen.** Keycloak kann kein Downgrade. Die Version steht im Dump selbst:

```bash
DUMP=keycloak-<zeitstempel>.dump
ssh root@192.168.178.3 cat /mnt/user/k8s/keycloak/dumps/$DUMP |
  docker run --rm -i postgres:18-alpine pg_restore --data-only --table=migration_model --file=- |
  awk -F'\t' 'NF == 3 { print $3, $2 }' | sort -n | tail -1   # Zeitstempel, Version
```

Die Befehle laufen vom Wurzelverzeichnis dieses Repos aus.

1. Keycloak anhalten. Flux pausieren, sonst setzt es die Replikas zurück:

   ```bash
   kubectl -n flux-system patch kustomization apps --type=merge -p '{"spec":{"suspend":true}}'
   kubectl -n keycloak scale deploy/keycloak --replicas=0
   ```

2. Schema leeren und zurückspielen. Leeren, weil `--clean` nur entfernt, was
   auch im Dump steht, und eine andere Keycloak-Version andere Tabellen hat:

   ```bash
   kubectl -n keycloak exec keycloak-db-1 -c postgres -- psql -d app -c \
     'DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION pg_database_owner;'

   sed -e 's/nextcloud/keycloak/g' \
       -e "s|/dumps/keycloak-JJJJ-MM-TTTHHMMZ.dump|/dumps/${DUMP}|" \
       k8s/templates/CnpgRestore.yaml | kubectl apply -f -
   kubectl -n keycloak wait --for=condition=complete --timeout=10m job/keycloak-db-restore
   kubectl -n keycloak logs job/keycloak-db-restore
   kubectl -n keycloak delete job keycloak-db-restore
   ```

3. Wieder anlaufen lassen:

   ```bash
   kubectl -n flux-system patch kustomization apps --type=merge -p '{"spec":{"suspend":false}}'
   kubectl -n flux-system annotate --overwrite kustomization apps reconcile.fluxcd.io/requestedAt="$(date +%s)"
   ```

4. Prüfen, ob der master-Realm den internen Host als Frontend URL trägt
   (Abschnitt unten), und dann an der Admin-Konsole anmelden.

### Hinweis: master-Realm braucht die Frontend URL

`KC_HOSTNAME_ADMIN` verlegt nur die Konsole. Login, Token und Session-Iframe
des master-Realms laufen sonst über `keycloak.nico-steinmueller.de`, und
dort sperrt `ingress-public` `/realms/master`. Das Login-Formular der Konsole
endet dann in 404. Deshalb trägt der master-Realm
`https://keycloak.k8s.nico-steinmueller.de` als Frontend URL; die anderen
Realms behalten den öffentlichen Host.

Die Einstellung steht in der Datenbank, nicht im Manifest. Ein eigener Dump
bringt sie mit; neu setzen nach dem ersten Start auf leerer Datenbank und
nach jedem Dump, der sie nicht hat (der aus Docker nicht). Prüfen:

```bash
curl -s https://keycloak.k8s.nico-steinmueller.de/realms/master/.well-known/openid-configuration | jq -r .issuer
```

Steht dort der öffentliche Host, setzen. Über die Konsole geht das nicht, die
hängt ja im Login, also mit `kcadm.sh` im Pod. Es fragt nach dem Passwort:

```bash
kubectl -n keycloak exec -it deploy/keycloak -- bash -c '
  kc() { /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config; }
  kc config credentials --server http://localhost:8080 --realm master --user <admin> &&
  kc update realms/master -s attributes.frontendUrl=https://keycloak.k8s.nico-steinmueller.de'
```
