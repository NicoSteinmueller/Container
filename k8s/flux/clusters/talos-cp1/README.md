# Wurzel-Verzeichnis für Flux

Was hier liegt, rollt Flux automatisch aus - dies ist der `sync.path` der
FluxInstance aus `../../main.tf`.

## `whoami.yaml`

`HelmRelease` auf das lokale Chart `k8s/whoami/chart` (Deployment, Service,
NetworkPolicy, Namespace, Ingress). `sourceRef` zeigt auf die
`GitRepository flux-system` - kein zweites Source-Objekt nötig.

`valuesFiles` wählt die Umgebung; `values-prod.yaml` setzt seit
[ingress-internal.yaml](ingress-internal.yaml) `service.type: ClusterIP` und
einen Ingress auf `ingressClassName: internal`. Der NodePort `30083` ist damit
weg. Werte pro Umgebung: `k8s/whoami/README.md`.

```bash
kubectl -n flux-system get helmrelease whoami
kubectl -n whoami get pods,svc,ingress
curl -k https://whoami.k8s.nico-steinmueller.de
```

## `secrets.yaml`

Die zweite Git-Quelle: `GitRepository` auf `homelab-secrets` im Gitea plus die
`Kustomization`, die sie anwendet. Der `decryption`-Block darin ist die
eigentliche Zeile — ohne ihn landete `ENC[AES256_GCM,...]` wörtlich als Wert im
Cluster, und die Kustomization bliebe dabei grün.

Warum ein zweites Repo statt einer Datei hier: Dieses geht öffentlich nach
GitHub, und auch Ciphertext soll dort nicht liegen. Begründung im Kopf der
Datei, Umgang damit in [../../README.md](../../README.md#secrets).

```bash
kubectl -n flux-system get gitrepository homelab-secrets
kubectl -n flux-system get kustomization homelab-secrets

# Beweisfall - erwartet wird "entschluesselt":
kubectl -n flux-system get secret sops-smoketest \
  -o jsonpath='{.data.probe}' | base64 -d; echo
```

## `reloader.yaml`

Startet neu, was ein geändertes Secret benutzt — sonst arbeitet ein Pod nach
einer Rotation bis zu seinem nächsten Start mit dem alten Wert weiter. Fremder
Chart, deshalb eine eigene `HelmRepository`.

Wen er anfasst, regelt er selbst: `autoReloadAll: true` mit
`ignoreNamespaces` als Ausnahmeliste — alles gilt als annotiert, außer
`kube-system`, `flux-system` und `reloader`. Vorher setzte Kyverno die
Annotation `reloader.stakater.com/auto` cluster-weit; mit dem Plattform-Stack
fiel Kyverno weg, und Reloader lief eine Zeit lang wirkungslos. Dieselbe Regel,
ein Controller weniger — Begründung je Namespace steht in
[reloader.yaml](reloader.yaml).

```bash
kubectl -n reloader get pods
kubectl -n reloader logs deploy/reloader-reloader | tail
```

## `headlamp.yaml`, `metrics-server.yaml`

Beide Charts kommen aus fremden Helm-Repositories - `chart.spec.sourceRef`
braucht deshalb je eine eigene `HelmRepository` statt der `GitRepository`.

`headlamp.yaml` bringt Namespace und RBAC als eigene Manifeste mit (PodSecurity
`restricted`, ServiceAccount `headlamp` nur lesend, `headlamp-admin` mit
`cluster-admin` ohne Pod und Token) - das Chart selbst würde den Namespace
unbeschriftet anlegen und seinen ServiceAccount an `cluster-admin` binden.
Begründungen stehen als Kommentare in der Datei.

`metrics-server.yaml` liefert die Auslastungsanzeigen, läuft in `kube-system`
mit `--kubelet-insecure-tls` (siehe Kommentare dort).

Headlamp hängt seit [ingress-internal.yaml](ingress-internal.yaml) an
`https://dashboard.k8s.nico-steinmueller.de`, nicht mehr am NodePort `30080`.
Das Zertifikat ist das selbstsignierte von Traefik - der Browser warnt, bis
cert-manager und step-ca stehen. Verschlüsselt ist die Verbindung trotzdem, und
darauf kommt es hier an: Das Token, das man beim Aufruf einfügt, ging über den
NodePort im Klartext durchs LAN.

Erreichbar ist das Dashboard nur über den Controller - die NetworkPolicy im
Namespace lässt sonst niemanden an den Pod. Anmeldung per Token:

```bash
kubectl -n headlamp create token headlamp --duration=8h        # Lesen
kubectl -n headlamp create token headlamp-admin --duration=1h  # Ändern
kubectl -n flux-system get helmrelease headlamp metrics-server
```

## `ingress-internal.yaml`

Der erste Ingress-Controller dieses Clusters: Namespace, IngressClass
`internal`, NetworkPolicies und die Traefik-Release. Vorher war jeder Dienst
nur über einen NodePort und per HTTP erreichbar.

Erreichbar ausschließlich aus dem Heimnetz. Die Gegenstelle für das Internet
(`ingress-public` hinter der Edge-VM) fehlt weiterhin — deshalb legt die Datei
auch nur **eine** Klasse an, nicht das Paar `public`/`internal`. Eine Klasse
ohne Controller wäre eine Falle: Ein Ingress mit `ingressClassName: public`
würde angenommen und nie bedient.

### hostPort statt hostNetwork

Der frühere Plattform-Stack fuhr beide Controller mit `hostNetwork` und band
sie über `hostIP` an je eine Node-Adresse. Das kostete den Sysctl
`net.ipv4.ip_unprivileged_port_start=0` auf dem Node, weil Traefik als UID
65532 sonst die Ports 80 und 443 nicht binden darf.

Beides ist hier weg, und die Kette dahin steht ausführlich in der Datei. Kurz:
Der Node hat heute **ein** Bein und dieser Cluster **einen** Controller. Damit
entfällt der Grund für `hostIP` — und ohne `hostIP` der für `hostNetwork`, und
ohne `hostNetwork` der für den Sysctl. Traefik bindet 8000/8443 im eigenen
Pod-Netz, wo es kein Privileg braucht, und Cilium bildet Node:80/443 darauf ab.
Das kann es, weil kube-proxy durch Cilium ersetzt ist.

**Die Stelle, an der das zurückgedreht werden muss,** ist der Bau von
`ingress-public`: Zwei Controller auf einem Node brauchen wieder je eine eigene
Adresse, also `hostIP`, also `hostNetwork`, also den Sysctl.

### Was den Zugang begrenzt

| | wodurch |
|---|---|
| Von außen nur aus dem LAN | NetworkPolicy `allow-from-lan` (`ipBlock` auf das Heimnetz) |
| An die Anwendungen nur über den Controller | `default-deny-ingress` je Namespace plus eine Regel auf `traefik-internal` |
| Nur in gelisteten Namespaces | `rbac.namespaced: true` — Role statt ClusterRole, je Namespace einzeln |

Der letzte Punkt ist die Bremse, die man beim nächsten Dienst spürt: Ein neuer
Namespace muss in `providers.kubernetesIngress.namespaces` **und**
`providers.kubernetesCRD.namespaces` eingetragen werden. Sonst wird sein
Ingress schlicht nicht bedient — was besser ist als still bedient zu werden,
aber beim ersten Mal wie ein Fehler aussieht.

### Kein TLS-Aussteller

Traefik liefert sein eingebautes, selbstsigniertes Zertifikat aus; der Browser
warnt. Das ist ein bewusster Zwischenstand und kein Versehen: cert-manager und
step-ca sind der nächste Schritt, und wenn sie stehen, wechselt hier nur das
Zertifikat. Port 80 leitet dauerhaft auf 443 um.

### Voraussetzung im Heimnetz

Nicht im Repo abgebildet: Die Hostnamen müssen **nur intern** auf die
LAN-Adresse des Nodes zeigen (AdGuard oder Fritzbox), nicht über DynDNS.

```
dashboard.k8s.nico-steinmueller.de  ->  192.168.178.230
whoami.k8s.nico-steinmueller.de     ->  192.168.178.230
```

Die eigene Zone `k8s.` ist dabei der Punkt: Die Dienste auf dem Unraid-Host
liegen unter `*.local.nico-steinmueller.de`, und ein Wildcard-Eintrag dorthin
kann diese Namen nicht mehr einfangen. Am Namen ist damit ablesbar, wo ein
Dienst läuft — und der Umzug eines Dienstes vom Host in den Cluster ist ein
sichtbarer Namenswechsel statt einer stillen Umleitung.

### Gegenproben

```bash
kubectl -n traefik-internal get pods
kubectl get ingressclass
kubectl get ingress -A                 # ADDRESS bleibt leer, siehe unten

# Der Beweisfall - der Weg über den Controller:
curl -k https://whoami.k8s.nico-steinmueller.de

# Und die Gegenrichtung: der alte NodePort ist zu.
curl --max-time 5 http://192.168.178.230:30083 || echo "zu, wie erwartet"
```

`kubectl get ingress` zeigt keine ADDRESS. Das ist kein Fehler: Der Controller
läuft ohne eigenen Service (`service.enabled: false`), und das Chart trägt die
Adresse nur aus einem solchen nach.

Antwortet der Ingress gar nicht, ist die NetworkPolicy die erste Stelle:

```bash
kubectl -n traefik-internal logs deploy/traefik-internal | tail
kubectl -n kube-system exec ds/cilium -- hubble observe --last 200 --type drop
kubectl -n traefik-internal delete networkpolicy allow-from-lan   # Notbremse
```

## `local-path.yaml`, `nfs-storage.yaml`

Der Speicher des Clusters, aufgeteilt nach **Zugriffsmuster**:

| | `local-path` (Default) | `nfs-unraid` |
|---|---|---|
| wofür | fsync und Locking: DBs, Indizes, Queues | Bestände: Medien, Uploads, Backups |
| liegt auf | zweiter Disk der VM, `/var/mnt/local-path` | Unraid-Shares über NFSv4.1 |
| Zugriff | `ReadWriteOnce`, an einen Node gebunden | `ReadWriteMany` |
| beim PVC-Löschen | `Retain` — Verzeichnis bleibt | `onDelete: archive` |

Vor diesen Dateien hatte der Cluster **keine** StorageClass — `kubectl get sc`
kam leer zurück, und jeder Chart, der einen PVC ohne `storageClassName` anlegt,
wäre auf `Pending` stehen geblieben.

Der Grund für die Aufteilung ist nicht Durchsatz. Physisch ist beides dieselbe
SSD: Die qcow2-Dateien der VM liegen auf `/mnt/cache/domains`, also auf dem
Unraid-Cache, auf den ein NFS-Mount ebenfalls zeigen würde. Der Unterschied ist
der Weg dorthin — und was er mit der Semantik macht. Jeder Commit einer
Datenbank ist ein `fsync`, und über NFS geht jeder einzelne davon durch den
Netzwerk-Stack. Dazu bleiben nach einem Neustart des NFS-Servers stale locks
zurück; SQLite rät von NFS ausdrücklich ab. Und `hard` — für Mediendaten
richtig — heißt hier, dass eine Datenbank bei einer Störung *hängt*, statt
abzustürzen.

Deshalb ist `local-path` die Default-Klasse: Ein Chart, der nichts angibt, hat
meistens etwas mit fsync vor. Wer NFS will, schreibt `storageClassName:
nfs-unraid` hin. Die Default-Annotation steht an genau **einer** Stelle — zwei
Default-Klassen wären kein Fehler, den Kubernetes meldet, es wählt dann
willkürlich aus.

### `local-path.yaml`

`local-path-provisioner` von Rancher auf der zweiten Disk der VM. Der Chart
kommt aus einer **`GitRepository`** statt einer `HelmRepository`: Rancher
veröffentlicht ihn nur im Git,  `ref.tag` statt Branch, damit Flux nicht 
jede Änderung nachzieht.

Der Pfad `/var/mnt/local-path` ist nicht frei gewählt: Talos mountet User-Volumes
immer unter `/var/mnt/<name>`. Er muss mit dem Volume-Namen in
[vm/talos/patches/uservolume.yaml.tftpl](../../../../vm/talos/patches/uservolume.yaml.tftpl)
zusammenpassen — beide Stellen tragen einen Kommentar darauf.

`volumeBindingMode: WaitForFirstConsumer` ist bei lokalem Speicher keine
Feinheit: Das Volume ist ein Verzeichnis auf genau einem Node. Auf einem
Ein-Node-Cluster fällt eine falsche Einstellung nicht auf, beim zweiten Node
sofort.

**Kein Backup.** Diese Disk verschwindet mit der VM und mit `tofu destroy`.
Ein Sicherungsweg aus dem Cluster heraus steht noch aus; wenn er kommt, gehört
er nach Kopia auf dem Unraid-Host — bei Datenbanken als Dump und nicht als
Dateikopie.

### `nfs-storage.yaml`

`csi-driver-nfs` plus die StorageClass `nfs-unraid` und die statischen PVs auf
die Shares des Unraid-Hosts.

Zwei Wege, bewusst nebeneinander:

- **dynamisch** über `nfs-unraid` (Default-Klasse). Der Treiber legt je PVC ein
  Unterverzeichnis unter `/mnt/user/k8s` an. Für alles, was der Cluster sich
  selbst anlegt.
- **statisch** über das PV `unraid-data`. Für Bestände, die schon da sind —
  der Cluster soll sie benutzen, nicht anlegen. Deshalb dort `Retain`.

### Voraussetzung auf dem Unraid-Host

Nicht im Repo abgebildet und von Hand zu setzen — NFS ist dort ab Werk aus
(`shareNFSEnabled="no"`, `/etc/exports` leer, Port 2049 zu):

1. **Array stoppen.** *Settings → NFS* ist bei laufendem Array gesperrt.
2. *Settings → NFS* → **Enable NFS = Yes**, Array wieder starten.
3. Share `k8s` anlegen, falls noch nicht vorhanden (Ziel der dynamischen PVCs).
4. Je Share unter *Shares → \<share\> → NFS Security Settings*: **Export = Yes**,
   Rule auf die Node-Adresse:

   ```
   192.168.178.230(sec=sys,rw,no_root_squash)
   ```

   für `k8s` und `data`.

Die Regel steht auf der **Node-Adresse**, nicht auf dem Pod-CIDR: Gemountet
wird nicht vom Pod, sondern vom kubelet auf dem Node — und Cilium maskiert
Pod-Egress ohnehin auf die Node-Adresse.

`no_root_squash`, weil Container regelmäßig als `root` schreiben und ihre
Dateien sonst `nobody` gehören. Es heißt zugleich, dass `root` im Cluster auch
auf dem Share `root` ist; die Regel ist deshalb auf die eine Adresse begrenzt.

Dass der Weg überhaupt offen ist, hängt an Unraids *Host access to custom
networks* — siehe [vm/talos/README.md](../../../../vm/talos/README.md#macvtap-wer-wen-erreicht).

### Voraussetzung in der VM

Der lokale Speicher braucht die zweite Disk. Sie entsteht mit `tofu apply` in
[vm/talos](../../../../vm/talos), wird aber erst beim **nächsten Start der VM**
sichtbar — libvirt hängt sie an eine laufende Maschine nicht von selbst an:

```bash
talosctl -n <node-ip> get disks                  # erwartet: vda und vdb
talosctl -n <node-ip> get volumestatus           # erwartet: u-local-path ready
talosctl -n <node-ip> get volumemountstatus      # erwartet: /var/mnt/local-path
```

Das Partitionslabel `u-local-path` vergibt Talos aus dem Volume-Namen; unter
diesem Namen taucht es in `volumestatus` auf, nicht als `local-path`.

Fehlt `vdb`, bleibt der Provisioner ohne Verzeichnis, und PVCs stehen auf
`Pending` — das Event am Pod nennt dann den Pfad.

### Gegenproben

```bash
kubectl get sc                    # local-path (default), nfs-unraid
kubectl -n local-path-storage get pods
kubectl -n csi-driver-nfs get pods
kubectl get pv

# Der Beweisfall - schreibt über die Default-Klasse und liest zurück:
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: nfs-smoketest }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
EOF
kubectl get pvc nfs-smoketest     # erwartet: Bound
ssh root@192.168.178.3 ls /mnt/user/k8s
kubectl delete pvc nfs-smoketest  # bleibt als archived-* liegen (onDelete)
```

Hängt ein Pod beim Start in `ContainerCreating`, steht der Grund im Event, nicht
im Log:

```bash
kubectl describe pod <name> | tail -20
kubectl -n csi-driver-nfs logs ds/csi-nfs-node -c nfs | tail
```
