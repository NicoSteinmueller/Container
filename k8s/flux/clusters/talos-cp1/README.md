# Wurzel-Verzeichnis für Flux

Was hier liegt, rollt Flux automatisch aus - dies ist der `sync.path` der
FluxInstance aus `../../main.tf`.

## `whoami.yaml`

`HelmRelease` auf das lokale Chart `k8s/whoami/chart` (Deployment, Service,
NetworkPolicy, Namespace, Ingress). `sourceRef` zeigt auf die
`GitRepository flux-system` - kein zweites Source-Objekt nötig.

`valuesFiles` wählt die Umgebung; `values-prod.yaml` setzt `service.type:
NodePort` auf `30083`. Eine Ingress-Variante liegt dort auskommentiert bereit
(`ingressClassName: internal`) - sie ist vorerst wirkungslos, denn dieser
Cluster hat derzeit keinen Ingress-Controller und damit keine IngressClass.
Werte pro Umgebung: `k8s/whoami/README.md`.

```bash
kubectl -n flux-system get helmrelease whoami
kubectl -n whoami get pods,svc
curl http://<node-ip>:30083
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

Headlamp per NodePort `30080`, HTTP - vertretbar im LAN, dieser Cluster hat
weder Ingress-Controller noch cert-manager. Anmeldung per Token:

```bash
kubectl -n headlamp create token headlamp --duration=8h        # Lesen
kubectl -n headlamp create token headlamp-admin --duration=1h  # Ändern
kubectl -n flux-system get helmrelease headlamp metrics-server
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
Sicherungen gehen nach `unraid-kopia-backup`, bei Datenbanken als Dump und
nicht als Dateikopie.

### `nfs-storage.yaml`

`csi-driver-nfs` plus die StorageClass `nfs-unraid` und die statischen PVs auf
die Shares des Unraid-Hosts.

Zwei Wege, bewusst nebeneinander:

- **dynamisch** über `nfs-unraid` (Default-Klasse). Der Treiber legt je PVC ein
  Unterverzeichnis unter `/mnt/user/k8s` an. Für alles, was der Cluster sich
  selbst anlegt.
- **statisch** über die PVs `unraid-data`, `unraid-bilder` und
  `unraid-kopia-backup`. Für Bestände, die schon da sind — der Cluster soll sie
  benutzen, nicht anlegen. Deshalb dort `Retain`. `unraid-bilder` ist lesend,
  und zwar doppelt: `accessModes: ReadOnlyMany` für den Scheduler, `ro` in den
  `mountOptions` für den Kernel — die erste Zeile allein sperrt nichts.

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

   für `k8s`, `data` und `kopia-nas-backup`. Für `Bilder` stattdessen `ro`
   statt `rw` — der Cluster liest dort nur.

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
