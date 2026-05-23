# Unraid Docker Sicherheitsmodell

Dieses Dokument beschreibt ein praxisnahes Sicherheitsmodell fuer Container auf Unraid.
Es ist als Vorlage fuer Produktiv-Setups gedacht und kann auf einzelne Dienste wie Uptime Kuma
oder andere Container uebertragen werden.

## Zielbild

Das Modell soll die folgenden Ziele gleichzeitig erfuellen:

- Angriffsoberflaeche reduzieren
- Container voneinander und vom Host trennen
- Schreibzugriffe auf das Notwendige begrenzen
- Netzwerkzugriff nur ueber definierte Pfade erlauben
- Betrieb, Updates und Backups nachvollziehbar halten

## Sicherheitsprinzipien

1. **Least Privilege**: jeder Container bekommt nur die Rechte, die er wirklich braucht.
2. **Explizite Freigaben**: Ports, Verzeichnisse und Ziele werden immer bewusst freigegeben.
3. **Netzwerksegmentierung**: Container sprechen nur ueber definierte Netze.
4. **Reproduzierbarkeit**: Images werden moeglichst per `tag@sha256` gepinnt.
5. **Beobachtbarkeit**: Healthchecks, Logging und Backups sind Teil des Designs.

## Schichtenmodell

### 1. Host-Haertung

Unraid selbst ist die erste Sicherheitsgrenze.

- Unraid regelmaessig aktualisieren
- Web-UI nur aus vertrauenswuerdigen Netzen erreichbar machen
- SSH nur aktivieren, wenn es wirklich gebraucht wird
- starke Passwoerter oder MFA verwenden, falls verfuegbar
- Backups von `appdata`, Konfigurationen und kritischen Shares einplanen

### 2. Container-Laufzeit

Die Standard-Haertung fuer normale Container sollte enthalten:

- `cap_drop: ALL`
- `security_opt: no-new-privileges:true`
- `security_opt: seccomp=default`
- kein `privileged: true`
- kein Mount des Docker-Sockets
- `read_only: true`, wenn die App damit klarkommt
- `tmpfs` fuer temporaere Pfade wie `/tmp` und `/run`
- `init: true`
- `pids_limit` setzen
- `ulimits` setzen, wo sinnvoll
- nicht als `root` laufen, wenn moeglich

### 3. Netzwerkmodell

Empfohlen ist ein klares Netzkonzept:

- **proxy-Netz**: Reverse Proxy wie Traefik oder Nginx Proxy Manager
- **app-Netze**: interne Dienste ohne direkte Host-Ports
- **admin-Netz**: nur fuer Verwaltungs- oder Support-Zugriffe

Regeln:

- von aussen nur den Reverse Proxy freigeben
- App-Container nicht direkt mit Host-Ports exponieren
- Container nur in den Netzen platzieren, die sie wirklich brauchen
- interne Dienste moeglichst nur im internen Netz erreichen

### 4. DNS und Egress-Kontrolle

Ein separater DNS fuer Docker kann sinnvoll sein, ersetzt aber keine Firewall.

Er ist hilfreich fuer:

- kontrollierte Namensaufloesung
- Logging
- interne Hostnamen
- Allow-/Blocklisten

Wichtig:

- DNS-Restriktion verhindert keine IP-basierten Verbindungen
- fuer echte Egress-Kontrolle zusaetzlich Firewall- oder Router-Regeln nutzen

### 5. Rechte und Speicher

Schreibrechte sollen nur dort existieren, wo sie zwingend benoetigt werden.

- eigenes `appdata`-Verzeichnis pro Container
- keine gemeinsamen Schreibvolumes zwischen Diensten
- nur Daten-, Konfigurations- und Uploadpfade einhaengen
- Logs begrenzen und rotieren
- Ownership sauber setzen, statt mit pauschalem `chmod 777` zu arbeiten

## Konkrete Kontrollen fuer Unraid

### Standard-Container-Policy

```yaml
security_opt:
  - no-new-privileges:true
  - seccomp=default
cap_drop:
  - ALL
init: true
read_only: true
tmpfs:
  - /tmp:rw,noexec,nosuid,size=64m
  - /run:rw,noexec,nosuid,size=16m
```

Optional, je nach App:

- weitere `tmpfs`-Pfade wie `/var/tmp`, `/var/log`, `/var/cache`
- `user: "99:100"` fuer Unraid-Standardrechte
- `user: "1000:1000"`, wenn ein Dienst damit besser kompatibel ist
- `pids_limit: 256` oder aehnlich
- `ulimits.nofile: 4096` oder passend zum Dienst

### Netzwerkzugriff

- externe Erreichbarkeit nur ueber den Reverse Proxy
- `traefik.http.routers.<name>.entrypoints=websecure`
- `traefik.http.routers.<name>.middlewares=local-only@file`
- HTTPS immer bewusst aktivieren

### Logging und Monitoring

- Healthcheck aktivieren, wenn die App es unterstuetzt
- Log-Rotation setzen, z. B. `max-size` und `max-file`
- Neustarts und Crash-Loops beobachten
- Speicherverbrauch in `appdata` regelmaessig pruefen

## Betriebsmodell

### Updates

- Images mit Digest pinnen
- Updates nicht blind automatisch einspielen
- vor groesseren Upgrades Changelog lesen
- kritische Container zuerst in einer Testumgebung pruefen

### Backups

- `appdata` regelmaessig sichern
- bei Datenbanken zusaetzlich Dumps erzeugen
- Restore nicht nur planen, sondern auch testen

### Wiederherstellung

Wichtige Reihenfolge bei einem Problem:

1. Container stoppen
2. Daten sichern
3. Backup zurueckspielen oder Konfiguration pruefen
4. Berechtigungen kontrollieren
5. Container erneut starten und Healthcheck pruefen

## Empfehlung fuer ein sicheres Default-Setup

Wenn du ein gutes Sicherheitsniveau ohne unnötige Komplexitaet willst, nutze als Standard:

- Reverse Proxy als einzigen externen Eintrittspunkt
- `cap_drop: ALL`
- `no-new-privileges:true`
- `seccomp=default`
- `read_only: true` plus passende `tmpfs`
- non-root User, wenn der Container es vertraegt
- keine Docker-Socket-Mounts
- separate Netzwerke fuer unterschiedliche Aufgaben
- Backups mit Restore-Test

## Beispielhafte Zuordnung fuer Uptime Kuma

Uptime Kuma ist ein typischer Kandidat fuer diese Policy:

- nur ueber Traefik erreichbar
- kein direkter Host-Port
- Schreibzugriff nur auf `/app/data`
- harte Runtime-Parameter wie `cap_drop`, `no-new-privileges`, `read_only` und `tmpfs`
- DNS- und Egress-Kontrolle nur als Zusatzmassnahme

## Rueckbau bei zu strenger Haertung

Wenn ein Container durch die Haertung nicht mehr laeuft, dann nacheinander pruefen:

1. fehlende Schreibpfade
2. falscher `user`
3. zu strenges `read_only`
4. fehlende `tmpfs`-Pfade
5. nicht kompatibles `seccomp`-Profil

Erst danach einzelne Schutzmassnahmen wieder lockern.

## Kurzfazit

Ein gutes Unraid-Docker-Sicherheitsmodell basiert nicht auf einer einzelnen Massnahme,
sondern auf mehreren Schichten: Host-Haertung, Container-Haertung, Netzwerksegmentierung,
kontrollierte Rechte und saubere Betriebsprozesse.

Das Ziel ist nicht maximale Restriktion um jeden Preis, sondern ein kontrolliertes,
wartbares und produktionsfaehiges Setup.
