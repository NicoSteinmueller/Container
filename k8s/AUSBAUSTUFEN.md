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
  die Reloader offenlässt (siehe `flux/README.md`, Abschnitt Rotation).
- **Migration aus dem laufenden Docker-Container.** `bootstrap.initdb.import`
  mit `type: microservice` fährt `pg_dump`/`pg_restore` gegen die alte
  Instanz — inklusive Versionssprung. Das alte `POSTGRES_PASSWORD` braucht man
  dabei ein letztes Mal als temporäres Secret, danach nie wieder.

Dazu WAL-Archivierung und `ScheduledBackup` als CR — was im
Sicherheitskonzept unter „Postgres auf die SSD-vDisk" und „append-only
Backup-Repository" steht, deklarativ.

**Kosten:** Operator-Deployment, grob 100–200 MiB. Die Postgres-Instanzen selbst
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

## 3. OpenBao — nur, wenn dynamische Credentials der Grund sind

**Auslöser:** der Wunsch nach Zugangsdaten mit Ablaufdatum statt langlebiger
Passwörter, oder nach einem Audit-Log darüber, wer welches Geheimnis gelesen
hat.

Die Database Secrets Engine erzeugt pro Anwendung ein Passwort mit TTL und
rotiert beide Seiten — statisch abgelegte DB-Passwörter verschwinden ganz. Das
ist der eine Gewinn, den SOPS strukturell nicht liefern kann. Alles andere, was
OpenBao mitbringt, ist schon da: Versionierung durch Git, PKI durch step-ca,
Zugriffskontrolle durch Gitea.

**Wenn, dann außerhalb des Clusters, neben Gitea.** Ein Vault *im* Cluster, der
die Secrets *des* Clusters hält, ist zirkulär: Node startet neu → Vault ist
versiegelt → nichts bekommt Zugangsdaten → jemand entsiegelt von Hand. Genau
dieselbe Überlegung, aus der Gitea außerhalb läuft.

Anmerkung zur Reihenfolge: Nach Stufe 1 und 2 ist der Bedarf kleiner, als er
heute aussieht. Deshalb steht das hier unten und nicht oben.
