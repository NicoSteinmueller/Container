# Edge-Architektur: Reverse Proxy und Exposition

Teil des [Kubernetes-Prod-Konzepts](Kubernetes-Prod-Konzept.md), ausgelagert aus
dessen Kapitel 5.

**Stand:** 2026-07-31

> **Verweise:** „Kapitel N" bezieht sich auf das
> [Hauptkonzept](Kubernetes-Prod-Konzept.md), „Abschnitt N" auf dieses Dokument.

Kapitel 4 des Konzepts listet die Einzelmaßnahmen zur Absicherung auf. Dieses
Dokument legt fest, **wo** der Reverse Proxy steht und wie die Kette vom Internet bis
zum Pod aussieht – die Entscheidung, die den größten Teil des Restrisikos bestimmt.

---

## 1. Die Reihenfolge, die zählt

„Sicherster Reverse Proxy" ist selten eine Produktfrage. Nach tatsächlicher
Risikoreduktion sortiert:

| # | Hebel | Wirkung |
|---|---|---|
| 1 | Was gar nicht exponiert wird | Angriffsfläche halbieren schlägt jede Härtung |
| 2 | Wo der Proxy im Netz steht | Segmentierung, nicht Software-Auswahl |
| 3 | Authentifizierung vor der Anwendung | Gate statt vollständiger App-Oberfläche |
| 4 | Bypass zwischen Edge und Cluster verhindern | mTLS + NetworkPolicy |
| 5 | Welche Proxy-Software | zuletzt, und mit deutlichem Abstand |

Punkt 2 ist im aktuellen Setup die eigentliche Schwachstelle.

## 2. Befund: die heutige Netzanbindung

In `traefik/compose.prod.yml` hängt Traefik per macvlan mit `192.168.178.5`
**direkt im flachen LAN** – und gleichzeitig in den Netzen `proxy`, `monitoring`
und `default`.

Damit hat ausgerechnet die Komponente, die dauerhaft vom Internet beschossen wird,
im Fall eines RCE sofort:

- L2-Zugriff auf das gesamte `192.168.178.0/24`, inklusive Unraid-WebUI
- direkten Zugriff auf die internen Docker-Netze `proxy` und `monitoring`

Die Talos-Härtung aus Kapitel 2 greift dann nicht mehr: der Angreifer braucht den
Cluster gar nicht, weil er bereits im LAN steht.

Zwei kleinere Punkte fallen dabei mit auf:

- **`TRAEFIK_API_INSECURE: true`** (im Repo bereits als TODO markiert). Das
  `host_ip: 127.0.0.1`-Port-Mapping greift bei macvlan nicht, weil der Container auf
  seiner eigenen IP lauscht – das Dashboard ist damit vermutlich LAN-weit ohne
  Authentifizierung erreichbar. **Vor dem Prod-Umbau verifizieren.**
- Die `crowdsec`-Middleware **ohne** AppSec ist die naheliegende Default-Wahl,
  obwohl `crowdsec-appsec` samt CRS-Collections bereits fertig konfiguriert ist. Für
  internetexponierte Router sollte die AppSec-Variante der Standard sein.

## 3. Schicht 0: Was überhaupt öffentlich sein muss

Die wirksamste Maßnahme der Liste und die einzige, die nichts kostet: Dienste in
„öffentlich" und „nur über VPN" aufteilen.

Grafana, Prometheus, Uptime-Kuma, AdGuard, Paperless, Linkwarden, Navidrome,
SFTPGo-Admin, Keycloak-Admin, Kopia und das Traefik-Dashboard brauchen keinen
offenen Port – WireGuard oder Tailscale genügt. Übrig bleiben realistisch drei bis
vier Dienste mit echtem Bedarf nach anonymem bzw. Mobile-Client-Zugriff (Immich,
Nextcloud, ntfy).

Alles Weitere in diesem Kapitel gilt nur noch für diesen Rest.

## 4. Zielarchitektur

```
Internet
   │
   ▼
┌─ Fritzbox ──────────────────────────────────┐
│  Portfreigabe 443 tcp+udp → Firewall-VM     │
│  IPv6-Firewall aktiv, keine v6-Freigaben    │
│  Heimnetz 192.168.178.0/24 bleibt unberührt │
└───────────────┬─────────────────────────────┘
                │ 192.168.178.6 (feste IP)
                ▼
┌─ Firewall-VM (Alpine + nftables) ───────────┐
│  WAN→DMZ  443         allow                 │
│  DMZ→CLU  443         allow                 │
│  DMZ→LAN  *           DENY   ← der Kern     │
│  DMZ→WAN  53,80,443   allow (ACME, CrowdSec)│
│  CLU→LAN  *           DENY                  │
└───────────────┬─────────────────────────────┘
                ▼
┌─ DMZ  10.10.20.0/24 ────────────────────────┐
│  Edge-VM                                    │
│   Traefik + CrowdSec AppSec                 │
│   · TLS-Terminierung (LE DNS-01/IONOS)      │
│   · forward-auth → Keycloak                 │
│   · Rate-Limit, secure-headers              │
└───────────────┬─────────────────────────────┘
                │ mTLS, nur Edge → LB-IP:443
                ▼
┌─ Cluster  10.10.30.0/24 ────────────────────┐
│  Talos + Cilium (LB-IPAM / L2)              │
│   Traefik-Ingress (nur Edge-Client-Cert)    │
│   default-deny NetPol, PSA restricted       │
└─────────────────────────────────────────────┘
```

| Schicht | Aufgabe | Umsetzung |
|---|---|---|
| Fritzbox | einziger Eintrittspunkt | Portfreigabe nur 443 tcp+udp auf die Firewall-VM; **kein** „Exposed Host" |
| Firewall-VM | Segmentierung, Blast Radius | Alpine + nftables; eigene Netze für DMZ und Cluster, `DMZ→LAN` explizit verboten |
| DMZ | Edge isolieren | `10.10.20.0/24`; ausgehend nur ACME/CrowdSec und Cluster:443 |
| Edge-VM | TLS, WAF, Auth | Traefik + CrowdSec AppSec, LE via DNS-01 (IONOS), forward-auth → Keycloak |
| Transport | Bypass verhindern | mTLS – der Cluster-Ingress akzeptiert nur das Client-Zertifikat des Edge |
| Cluster-Netz | laterale Bewegung verhindern | `10.10.30.0/24` + Cilium-NetworkPolicy: Ingress nur von der Edge-IP |
| Cluster-Ingress | Routing, Service-Discovery | Traefik als IngressController, LB-IP über Cilium LB-IPAM / L2 Announcements |
| Pod | letzte Instanz | PSA `restricted`, default-deny NetworkPolicy |

**Die Edge-VM** braucht kein zweites Talos. Das bestehende `vm/alpine`-Muster
reicht: gehärtetes Alpine, read-only, ausschließlich Traefik + CrowdSec. Kostet
etwa 768 MB – ein weiteres Argument für das RAM-Upgrade aus Kapitel 3.

**mTLS zwischen Edge und Cluster** ist das Stück, das in solchen Setups meist fehlt.
Ohne es kann jeder, der die LB-IP erreicht, CrowdSec und Authentifizierung schlicht
umgehen. Die Cilium-NetworkPolicy auf die Edge-IP ist die zweite, unabhängige
Durchsetzung derselben Regel.

**forward-auth gegen Keycloak** ist der größte Einzelgewinn, den es fast geschenkt
gibt – Keycloak läuft bereits. Damit schrumpft die exponierte Angriffsfläche von
„gesamte Anwendungs-Codebase" auf „OIDC-Handshake", für alles, was keinen anonymen
Zugriff braucht.

> **Hinweis zur IP-Allowlist:** Sobald der Edge davorsteht, sieht der Cluster-Ingress
> nur noch dessen Quell-IP. Die `whitelist-source-range`-Regel in
> `k8s/whoami/overlays/prod/ingress.yaml` greift dort also entweder immer oder nie.
> Local-Only bleibt am Edge, wo es heute schon korrekt sitzt – ein
> Durchsetzungspunkt, weniger Fehlerquellen.

## 5. Netzsegmentierung mit der Fritzbox

Eine Fritzbox kann keine DMZ bauen – sie **muss es aber auch nicht**. Sie reicht nur
Port 443 an die Firewall-VM weiter, die Segmentierung passiert dahinter. Damit wird
die Limitierung des Routers irrelevant statt zum Blocker.

| Feature | Verfügbar | Für die DMZ brauchbar |
|---|---|---|
| Portfreigabe auf ein Gerät | ja | **ja** – mehr wird nicht gebraucht |
| Gastnetz (WLAN + LAN 4) | ja, eigenes Subnetz, vom Heimnetz isoliert | nein – Portfreigaben ins Gastnetz sind nicht möglich |
| VLAN-Tagging auf LAN-Ports | nein (außer WAN/IPTV) | nein |
| Eigene Firewall-Regeln zwischen Netzen | nein | nein |
| Statische Routing-Tabelle | ja | ja, als Ergänzung für den Admin-Zugriff |
| „Exposed Host" | ja | **auf keinen Fall** |

> **Warnung:** „Exposed Host" wird in Anleitungen regelmäßig als DMZ verkauft. Es
> leitet *alle* Ports an ein Gerät weiter und hebt den Schutz dafür auf – das exakte
> Gegenteil des Ziels.

Das Gastnetz klingt zunächst passend (isoliert, eigenes Subnetz), scheitert aber
daran, dass sich kein eingehendes 443 hineinleiten lässt. Vor der Umsetzung im Menü
gegenprüfen.

### Firewall-VM: Entscheidung für Alpine + nftables

**Gesetzt: Alpine Linux mit nftables**, aufgesetzt nach dem bestehenden
`vm/alpine`-Terraform-Muster, Regeln per Ansible ausgerollt.

Beim reinen Paketfilter nehmen sich die Kandidaten nichts – `nftables`/netfilter und
`pf` sind beide seit Jahrzehnten im Einsatz. Der Unterschied entsteht um den Filter
herum:

| | **Alpine + nftables** | OPNsense |
|---|---|---|
| Angriffsfläche | sehr klein, kein Dienst im Datenpfad | Web-UI (PHP, root-nah), größerer Base |
| Verifizierbarkeit | manuell (`nft list ruleset`) | Live-Ansicht, Logging, State-Table |
| Auditierbarkeit | Ruleset im Git, echter Diff im PR | `config.xml`-Blob, Diffs kaum lesbar |
| Patch-Aufwand | `apk upgrade`, wenig CVEs | FreeBSD + PHP-Stack, Major-Upgrades |
| Reproduzierbarkeit | Terraform + Ansible, Renovate-fähig | manuell, Backup/Restore |
| Zusatzfunktionen | selbst bauen | Suricata, GeoIP, WireGuard-UI |
| RAM | ~256 MB | ~2 GB |

**Ausschlaggebend waren vier Punkte:**

1. **Der Regelsatz ist winzig.** Abschnitt 4 braucht rund zehn Regeln – nicht der
   Umfang, für den man ein GUI benötigt, sondern einer, den man einmal schreibt,
   reviewt und dann in Ruhe lässt.
2. **Der L7-Schutz steht bereits.** OPNsense' größter funktionaler Vorteil ist
   Suricata. Mit CrowdSec AppSec und den CRS-Collections am Edge ist der
   Zusatznutzen von IDS auf L3/L4 hier kleiner als im Allgemeinfall.
3. **Git schlägt GUI bei der Auditierbarkeit.** Eine Regeländerung wird ein PR mit
   lesbarem Diff statt eines Klicks, dessen Backup hoffentlich aktuell ist. Das ist
   der stimmigere Weg für ein Terraform-first-Repo.
4. **RAM.** 256 MB gegen 2 GB, bei 6–8 GB Gesamtbudget (Kapitel 3).

**Bewusst in Kauf genommen:** Die kleinere Angriffsfläche hat Alpine – die bessere
Chance, korrekt konfiguriert zu sein, hätte OPNsense. Firewalls fallen im Homelab
selten durch Exploits; sie fallen durch Regeln, die nicht das tun, was man denkt.
Diese eingebaute Kontrollinstanz entfällt hier und muss ersetzt werden.

### Verifikation als Pflichtbestandteil

Die Kontrolle, die das OPNsense-UI mitliefern würde, wird automatisiert nachgebaut –
reproduzierbar statt visuell:

- **Egress-Test aus der DMZ**, der prüft, dass LAN nicht erreichbar ist. Läuft nach
  jedem Regel-Deploy, idealerweise in der CI.
- **nftables-Logging auf die Deny-Regeln**, ausgeleitet in den bestehenden
  Loki-Stack.
- **`nft list ruleset` als Ansible-Assertion** gegen den erwarteten Stand, damit
  Drift auffällt.

Ohne diese drei Punkte ist die Entscheidung gegen OPNsense nicht tragfähig.

### Management-Zugang und Hypervisor-Grenze

Der SSH-Zugang der Firewall-VM wird **ausschließlich** an ein Management-Interface
gebunden, nie an WAN oder DMZ. Das ist die Maßnahme, die den Sicherheitsunterschied
zwischen den Varianten am stärksten einebnet – und die am häufigsten vergessen wird.

Die Firewall-VM läuft auf demselben Unraid-Host wie das, was sie schützt. Sauber ist
das nicht, die Trennung hängt am Hypervisor. Die Hürde für einen KVM-Escape liegt
aber um Größenordnungen höher als für einen Traefik-RCE, und gegenüber der heutigen
macvlan-Anbindung (Abschnitt 2) ist es ein echter Gewinn. Physisch getrennte
Hardware wäre besser – das ist eine Budget-, keine Architekturfrage.

> **Aufstiegspfad, falls das Netz wächst:** **VyOS** – deklarative Konfiguration mit
> `commit`/`rollback`, echtes Netzwerk-OS, ~512 MB. Vereint Config-as-Code mit
> struktureller Validierung. Für zehn Regeln überdimensioniert; der Haken ist die
> Lizenzlage (freie Rolling-Releases, LTS nur per Subscription oder Selbstbau).

### Konkrete Fritzbox-Einstellungen

1. **Heimnetz → Netzwerk → Netzwerkverbindungen** → Firewall-VM →
   *„Diesem Netzwerkgerät immer die gleiche IPv4-Adresse zuweisen"*
2. **Internet → Freigaben → Portfreigaben** → Gerät hinzufügen → 443 TCP **und** UDP
   (UDP für HTTP/3, in `traefik/compose.yml` bereits aktiviert)
3. **Internet → Freigaben → IPv6** → Firewall aktiv, keine Freigaben eintragen
4. *Optional:* **Heimnetz → Netzwerk → Netzwerkeinstellungen → statische
   Routing-Tabelle** → Routen für `10.10.20.0/24` und `10.10.30.0/24` via
   `192.168.178.6`, für Admin-Zugriff aus dem LAN

### Stolpersteine

- **IPv6 unterläuft den gesamten Aufbau.** Haben die VMs globale IPv6-Adressen, sind
  sie an NAT und Firewall-VM vorbei potenziell direkt erreichbar. Entweder IPv6 auf
  den DMZ-/Cluster-Segmenten gar nicht anbieten oder die IPv6-Freigaben der Fritzbox
  konsequent leer lassen. Der häufigste Fehler bei genau dieser Konstruktion.
- **Doppel-NAT.** Die Firewall-VM NATet ein zweites Mal. Für eingehendes 443
  unkritisch, aber die echte Client-IP muss per `X-Forwarded-For` durchgereicht
  werden – sonst sieht CrowdSec nur noch `192.168.178.1` und bannt im Zweifel die
  Fritzbox.
- **Zugriff aus dem LAN auf die eigenen Dienste.** Öffentliche DNS-Namen laufen aus
  dem Heimnetz in den Hairpin. Split-DNS im ohnehin betriebenen AdGuard löst das:
  interne Auflösung direkt auf die Edge-IP.

## 6. Warum der Edge außerhalb des Clusters bleibt

Der Reverse Proxy ist die meistangegriffene Komponente des gesamten Aufbaus. Sitzt
er *im* Cluster, bedeutet ein RCE einen Pod im Cluster-Netz mit
ServiceAccount-Token. In einer DMZ-VM bedeutet derselbe RCE eine VM, die per
Firewall genau eine ausgehende Verbindung aufbauen darf.

Das bestätigt die Entscheidung aus Kapitel 4, den Edge nicht in den Cluster zu
migrieren – korrigiert aber den Standort: **weg vom Unraid-Host, hin zu einer
eigenen VM im eigenen Segment.**

## 7. Cluster-Ingress: Traefik statt ingress-nginx

Für den zweiten Hop – den IngressController im Cluster – fällt `ingress-nginx` aus:
das Projekt wurde Ende 2025 in den Retirement-Modus überführt, Wartungsende **März
2026**, ohne produktionsreifen Nachfolger. Für eine internetexponierte Komponente
eines neu gebauten Prod-Clusters ist das disqualifizierend. Die Historie passt dazu:
CVE-2025-1974 („IngressNightmare", CVSS 9.8) war ein unauthentifizierter RCE über
den Admission-Controller mit clusterweiter Secret-Exposition.

> **Vor der Umsetzung den aktuellen Status gegenprüfen** – der Stand kann sich
> geändert haben.

**Traefik** ist damit auch im Cluster die Wahl, und zwar dieselbe Software wie am
Edge:

- Go, speichersicher, aktiv gepflegt
- Router-, Middleware- und EntryPoint-Modell ist aus dem Compose-Setup bereits
  vertraut – die CRDs (`IngressRoute`, `Middleware`) sind dasselbe Modell in anderer
  Syntax
- Der CrowdSec-Bouncer ist dieselbe Middleware, falls der Edge später doch in den
  Cluster wandert
- Traefik 3 spricht Ingress **und** Gateway API – Migration später ohne Wechsel der
  Datenebene

RAM ist kein Unterscheidungsmerkmal, beide liegen bei 80–150 MB.

**Alternative:** Cilium Gateway API – kein separater Controller, der Envoy in Cilium
übernimmt das Routing. Elegant, aber Gateway API als zusätzliche Lernkurve, ein
deutlich dünneres Ökosystem für Auth-Forwarding und Rate-Limiting, und die Symmetrie
zum Edge-Setup geht verloren. Als Einstieg für den ersten Prod-Cluster nicht
empfohlen, als späteres Ziel offen.

## 8. Verworfen: Cloudflare Tunnel

Ein Tunnel eliminiert den offenen Port und verbirgt die eigene IP – technisch stark.
Der Preis: **Cloudflare terminiert TLS und sieht den Klartext.** Konkret liefen
Immich-Fotos und Nextcloud-Dokumente entschlüsselt über fremde Infrastruktur.

Für ein Konzept mit dem Leitmotiv „maximale Sicherheit" ist das der falsche Tausch –
Vertraulichkeit gegen geringeres Verfügbarkeitsrisiko. DNS-01 über IONOS und
CrowdSec mit AppSec laufen bereits; der Tunnel wird nicht gebraucht. DDoS-Schutz als
Motiv wiegt im Homelab leichter als der Vertraulichkeitsverlust.

## 9. Umsetzungsreihenfolge

Jeder Schritt wirkt für sich, die Reihenfolge ist nach Aufwand/Nutzen sortiert:

1. Dienste in „öffentlich" / „nur VPN" aufteilen (kostet nichts, wirkt am meisten)
2. `TRAEFIK_API_INSECURE` schließen, AppSec-Middleware als Default für
   internetexponierte Router
3. Alpine-Firewall-VM aufsetzen (Terraform + Ansible), Portfreigabe der Fritzbox
   darauf umbiegen, IPv6-Freigaben prüfen
4. Egress-Test, Deny-Logging und Ruleset-Assertion einrichten – **bevor** die
   erste Last darüber läuft (Abschnitt 5)
5. Edge-VM ins DMZ-Netz ziehen, macvlan-Anbindung an `bond0` auflösen,
   Split-DNS in AdGuard nachziehen
6. mTLS Edge → Cluster-Ingress, flankiert von der Cilium-NetworkPolicy
7. forward-auth gegen Keycloak für alles ohne anonymen Zugriffsbedarf

Schritte 1 und 2 sind unabhängig vom Kubernetes-Umbau und lohnen sich sofort.
Schritt 3 und 5 gehören in ein gemeinsames Wartungsfenster – dazwischen sind die
exponierten Dienste nicht erreichbar.
