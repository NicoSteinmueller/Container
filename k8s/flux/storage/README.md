# storage

Der Speicher des Clusters, aufgeteilt nach **Zugriffsmuster**.

| | `local-path` (Default) | `nfs-unraid` |
|---|---|---|
| wofür | fsync und Locking: DBs, Indizes, Queues | Bestände: Medien, Uploads, Backups |
| liegt auf | zweiter Disk der VM, `/var/mnt/local-path` | Unraid-Shares über NFSv4.1 |
| Zugriff | `ReadWriteOnce`, an einen Node gebunden | `ReadWriteMany` |
| beim PVC-Löschen | `Retain` — Verzeichnis bleibt | `onDelete: retain` — Verzeichnis bleibt |

Der Grund für die Aufteilung ist nicht Durchsatz. Physisch ist beides dieselbe
SSD: Die qcow2-Dateien der VM liegen auf `/mnt/cache/domains`, also auf dem
Unraid-Cache, auf den ein NFS-Mount ebenfalls zeigen würde. Der Unterschied ist
der Weg dorthin — und was er mit der Semantik macht. Jeder Commit einer
Datenbank ist ein `fsync`, und über NFS geht jeder einzelne durch den
Netzwerk-Stack. Dazu bleiben nach einem Neustart des NFS-Servers stale locks
zurück, SQLite rät von NFS ausdrücklich ab, und `hard` — für Mediendaten
richtig — heißt hier, dass eine Datenbank bei einer Störung *hängt*, statt
abzustürzen.

Deshalb ist `local-path` die Default-Klasse: Ein Chart, der nichts angibt, hat
meistens etwas mit fsync vor. Wer NFS will, schreibt `storageClassName:
nfs-unraid` hin. Die Default-Annotation steht an genau **einer** Stelle — zwei
Default-Klassen sind kein Fehler, den Kubernetes meldet, er wählt dann
willkürlich.

## [`local-path.yaml`](local-path.yaml)

`local-path-provisioner` von Rancher auf der zweiten Disk der VM. Der Chart
kommt aus einer **`GitRepository`** statt einer `HelmRepository` — Rancher
veröffentlicht ihn nur im Git; `ref.tag` statt Branch, damit Flux nicht jede
Änderung nachzieht.

Der Pfad `/var/mnt/local-path` ist nicht frei gewählt: Talos mountet
User-Volumes immer unter `/var/mnt/<name>`. Er muss mit dem Volume-Namen in
[vm/talos/patches/uservolume.yaml.tftpl](../../../vm/talos/patches/uservolume.yaml.tftpl)
zusammenpassen — beide Stellen tragen einen Kommentar darauf.

`volumeBindingMode: WaitForFirstConsumer` ist bei lokalem Speicher keine
Feinheit: Das Volume ist ein Verzeichnis auf genau einem Node. Auf einem
Ein-Node-Cluster fällt eine falsche Einstellung nicht auf, beim zweiten Node
sofort.

**Kein Backup.** Diese Disk verschwindet mit der VM und mit `tofu destroy`. Ein
Sicherungsweg aus dem Cluster heraus steht noch aus; wenn er kommt, gehört er
nach Kopia auf dem Unraid-Host — bei Datenbanken als Dump, nicht als Dateikopie.

## [`nfs-storage.yaml`](nfs-storage.yaml)

`csi-driver-nfs` plus die StorageClass `nfs-unraid` auf den Share `k8s`. Der
Treiber legt je PVC ein Verzeichnis `<namespace>/<pvc-name>` unter
`/mnt/user/k8s` an — für alles, was dauerhaft auf dem Array liegen soll.

Dass das auch für Bestände trägt, deren Verlust wehtut, hängt an
`onDelete: retain`: Beim Löschen eines PVC passiert mit dem Verzeichnis nichts.
Und weil der Pfad ausschließlich aus Namespace und PVC-Namen entsteht, findet
ein später neu angelegtes PVC gleichen Namens seine Daten wieder. Statisch
gebundene PVs braucht es dafür nicht.

### Voraussetzung auf dem Unraid-Host

Nicht im Repo abgebildet und von Hand zu setzen — NFS ist dort ab Werk aus:

1. **Array stoppen** (*Settings → NFS* ist bei laufendem Array gesperrt).
2. *Settings → NFS* → **Enable NFS = Yes**, Array wieder starten.
3. Share `k8s` anlegen, falls noch nicht vorhanden.
4. *Shares → k8s → NFS Security Settings*: **Export = Yes**, Rule auf die
   Node-Adresse:

   ```
   192.168.178.230(sec=sys,rw,no_root_squash)
   ```

Die Regel steht auf der **Node-Adresse**, nicht auf dem Pod-CIDR: Gemountet
wird vom kubelet, nicht vom Pod — und Cilium maskiert Pod-Egress ohnehin auf die
Node-Adresse.

`no_root_squash`, weil Container regelmäßig als `root` schreiben und ihre
Dateien sonst `nobody` gehören. Es heißt zugleich, dass `root` im Cluster auch
auf dem Share `root` ist; deshalb die Begrenzung auf die eine Adresse.

**Sie deckt aber nur die halbe Bedrohung.** Gegen andere Geräte im Heimnetz
hilft sie, gegen einen übernommenen Pod nicht — der erreicht den Share ja
bestimmungsgemäß. Die Kette wäre: Pod als `root` legt eine setuid-root-Binary
auf dem Share ab, irgendein Pod führt sie vom Mount aus aus, Root auf dem Node.
Schritt zwei ist im Mount geschlossen: StorageClass und statisches PV tragen
`nosuid`, `nodev` und `noexec`. `sec=sys` steht ausdrücklich dort, damit beim
Lesen sichtbar ist, dass diese Strecke keine Authentisierung hat.

Der saubere Weg wäre `root_squash`. Er scheitert heute daran, dass die Dienste,
die vom Host herüberziehen, als `root` schreiben. Sobald sie über `runAsUser`
und `fsGroup` feste IDs führen, ist das der nächste Schritt.

Dass der Weg überhaupt offen ist, hängt an Unraids *Host access to custom
networks* — siehe [vm/talos/README.md](../../../vm/talos/README.md#macvtap-wer-wen-erreicht).
Nachprüfen ohne Testdienst aus dem `csi-nfs-node`-Pod heraus; er läuft mit
`hostNetwork`, steht also dort, wo auch das kubelet mountet:

```bash
kubectl -n csi-driver-nfs exec ds/csi-nfs-node -c nfs -- \
  timeout 10 showmount -e 192.168.178.3
```

Kommt eine Export-Liste zurück, ist der Weg offen und jede weitere Fehlersuche
gehört auf Share-Namen und Export-Regeln, nicht auf das Netz.

### Voraussetzung in der VM

Der lokale Speicher braucht die zweite Disk. Sie entsteht mit `tofu apply` in
[vm/talos](../../../vm/talos), wird aber erst beim **nächsten Start der VM**
sichtbar — libvirt hängt sie an eine laufende Maschine nicht von selbst an:

```bash
talosctl -n <node-ip> get disks                  # erwartet: vda und vdb
talosctl -n <node-ip> get volumestatus           # erwartet: u-local-path ready
talosctl -n <node-ip> get volumemountstatus      # erwartet: /var/mnt/local-path
```

Das Partitionslabel `u-local-path` vergibt Talos aus dem Volume-Namen; unter
diesem Namen taucht es in `volumestatus` auf, nicht als `local-path`.

**`vdb` da und trotzdem `Pending`?** Dann liegt es am Volume, und der Fehler
steht nur in der Talos-Ressource — nicht im Apply, nicht im Provisioner-Log:

```bash
talosctl -n <node-ip> get volumestatus u-local-path -o yaml
```

Steht dort `phase: failed`, sagt `errorMessage` warum. Nach außen sieht es
harmlos aus: `/var/mnt` bleibt read-only, und der Helper-Pod scheitert an
`mkdir /var/mnt/local-path/: read-only file system`. Genau so ist `!system_disk`
im Disk-Selektor aufgefallen — der Ausdruck übersetzt sich, die Variable wird
bei User-Volumes aber nicht gebunden.

### Gegenproben

```bash
kubectl get sc                    # local-path (default), nfs-unraid
kubectl -n local-path-storage get pods
kubectl -n csi-driver-nfs get pods

# Beweisfall - schreibt über die Default-Klasse und liest zurück
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
kubectl delete pvc nfs-smoketest  # Verzeichnis bleibt liegen (onDelete: retain)
```

Hängt ein Pod in `ContainerCreating`, steht der Grund im Event, nicht im Log:

```bash
kubectl describe pod <name> | tail -20
kubectl -n csi-driver-nfs logs ds/csi-nfs-node -c nfs | tail
```
