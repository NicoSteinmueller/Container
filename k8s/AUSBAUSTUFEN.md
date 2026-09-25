# Ausbaustufen

Was bewusst später kommt, und woran man merkt, dass der Zeitpunkt da ist.
Nichts davon ist eine offene Baustelle — der Cluster läuft ohne alles hier.

Der gemeinsame Faden: **Was gar nicht abgelegt wird, muss auch nicht rotiert
werden.** SOPS verwaltet Geheimnisse gut; die beiden ersten Stufen unten sorgen
dafür, dass es weniger zu verwalten gibt.

## 1. CloudNativePG — Datenbank-Passwörter abschaffen

**Auslöser:** der erste Dienst mit Postgres, der von Docker nach Kubernetes
zieht. Nextcloud, Immich, Paperless, Linkwarden und Keycloak bringen je eines
mit.

**Stand:** vorbereitet. Der Operator läuft
([flux/platform/cloudnative-pg/](flux/platform/cloudnative-pg/README.md)),
Vorlagen für Datenbank, Dump und Restore liegen unter
[templates/](templates/CnpgDatabase.yaml), ein Restore ist durchgespielt.
Eine Datenbank eines echten Dienstes gibt es noch nicht.

Heute steht in jeder `example.env` derselbe String zweimal — einmal für den
`postgres`-Container, einmal für die Anwendung:

```
nextcloud/example.env    POSTGRES_PASSWORD=changeme
paperless/example.env    DB_PASSWORD=changeme
```

CloudNativePG dreht das um: Man deklariert einen `Cluster`, kein Passwort. Der
Operator würfelt es selbst und legt es als Secret `<name>-app` ab (mit
`username`, `password`, `host`, `dbname`, `uri`). Die Anwendung greift es per
`secretKeyRef` ab.

Der Punkt daran ist nicht Bequemlichkeit: **Dieser Wert existiert nie in Git** —
nicht im Klartext, nicht SOPS-verschlüsselt. Er entsteht im Cluster und bleibt
dort. Fünf Einträge fallen damit ersatzlos aus `homelab-secrets` heraus.

Zwei Dinge kommen dazu, die sonst Handarbeit blieben:

- **Rotation auf beiden Seiten.** Über `spec.managed.roles` mit `passwordSecret`
  führt der Operator das `ALTER ROLE` selbst aus. Das schließt genau die Lücke,
  die Reloader offenlässt (siehe `flux/README.md`, Abschnitt Secrets).
- **Migration aus dem laufenden Docker-Container.** `pg_dump` im alten
  Container über den lokalen Socket, `pg_restore` mit dem Restore-Job der
  Vorlage — dasselbe Werkzeug wie im Ernstfall, also zugleich ein Restore-Test.
  Das alte `POSTGRES_PASSWORD` braucht man dabei nicht einmal mehr.
  `bootstrap.initdb.import` scheidet aus: Die Container veröffentlichen 5432
  nicht. Ablauf in `flux/platform/cloudnative-pg/README.md`.

Nicht dazu gekommen sind WAL-Archivierung und `ScheduledBackup`: Beide
wollen Objektspeicher oder CSI-Snapshots, und `local-path` kann keins von
beiden. An ihrer Stelle steht ein `pg_dump`-CronJob alle 12 h auf
`nfs-unraid` - ohne Point-in-Time-Recovery, zurück geht es nur auf den letzten
Dump.

**Was davon gesichert werden muss, ist wenig:** nur dieser Dump. Nicht das PGDATA auf `local-path`, nicht der Operator, nicht die
`Cluster`-CRs — die stehen in Git und kommen über Flux zurück, und ein
Dateiabzug eines laufenden PGDATA wäre ohnehin ein zerrissener Stand. Der Weg
zurück ist: CR anwenden, leere Instanz, Dump einspielen. Das vom Operator
gewürfelte Passwort entsteht dabei neu und fehlt niemandem, solange die
Anwendung es per `secretKeyRef` liest — genau die Eigenschaft, um die es in
diesem Abschnitt geht. Die Dumps liegen unter
`/mnt/user/k8s/<dienst>/dumps`, Kopia sichert sie von dort
([flux/storage/nfs-storage/](flux/storage/nfs-storage/README.md)).

**Kosten:** Operator-Deployment, gemessen unter 40 MiB bei 100 MiB Request. Die Postgres-Instanzen selbst
kosten nichts zusätzlich — es sind dieselben fünf, die heute als Container auf
dem Host laufen. Ein `Cluster` pro Dienst ist die vorgesehene Bauweise, keine
Verschwendung. Bei `instances: 1` gibt es keine Hochverfügbarkeit; ein
Minor-Update heißt kurze Downtime. Auf einem Node ohnehin gesetzt.

## 2. Keycloak-Operator oder Crossplane — OIDC-Client-Secrets abschaffen

**Auslöser:** wenn nach den Datenbank-Passwörtern die Client-Secrets der
größte verbliebene Block in `homelab-secrets` sind.

Dasselbe Muster, andere Kategorie. Heute:

```
paperless/example.env    KEYCLOAK_SECRET=your-keycloak-client-secret
```

Keycloak erzeugt Client-Secrets selbst. Ein Operator kann den Client
deklarativ anlegen und das erzeugte Secret in ein Kubernetes-Secret schreiben —
dann steht in Git der Client, nicht sein Geheimnis.

Zwei Wege:

- **keycloak-operator** (von Keycloak selbst). `KeycloakRealmImport` und
  Client-CRs. Näher am Produkt, aber die CRD-Abdeckung für Clients ist
  historisch dünner als die Realm-Verwaltung — vor der Entscheidung gegen den
  dann aktuellen Stand prüfen.
- **Crossplane mit `provider-keycloak`.** Deckt die Keycloak-API breiter ab
  (der Provider ist aus dem Terraform-Provider erzeugt) und schreibt
  Verbindungsdetails standardmäßig in ein Secret. Kostet dafür Crossplane
  selbst als Unterbau — spürbar mehr als ein einzelner Operator.

Für einen Cluster mit einer Handvoll Clients ist das eher eine Aufräumaktion
als eine Notwendigkeit. Erst sinnvoll, wenn Keycloak ohnehin nach Kubernetes
gezogen ist.
