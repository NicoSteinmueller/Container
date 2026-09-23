# nfs-storage

`csi-driver-nfs` plus StorageClass `nfs-unraid`. Je PVC ein Verzeichnis
`/mnt/user/k8s/<namespace>/<pvc-name>`. Mit `onDelete: retain` findet ein neues
PVC gleichen Namens seine Daten wieder - ohne statische PVs.

Keine Egress-Policy: Beide Pods laufen auf hostNetwork, keine Policy griffe.

## Auf dem Unraid-Host (von Hand)

1. Array stoppen, *Settings → NFS* → **Enable NFS**, Array starten.
2. Share `k8s` anlegen.
3. *Shares → k8s → NFS Security*: **Export = Yes**, Regel
   `192.168.178.230(sec=sys,rw,no_root_squash)`.

- **Node-Adresse, nicht Pod-CIDR**: Es mountet das kubelet.
- **`no_root_squash`**, weil die übernommenen Dienste als `root` schreiben.
  Damit ist `root` im Cluster auch auf dem Share `root`. Gegen einen
  übernommenen Pod hilft die Adressregel nicht; die setuid-Kette schließen
  `nosuid,nodev,noexec` im Mount. Nächster Schritt ist `root_squash`, sobald
  die Dienste feste IDs führen.
- Der Weg zum Host hängt an Unraids *Host access to custom networks*
  ([vm/talos/README.md](../../../../vm/talos/README.md#macvtap-wer-wen-erreicht)).

```bash
kubectl -n csi-driver-nfs exec ds/csi-nfs-node -c nfs -- timeout 10 showmount -e 192.168.178.3
kubectl -n csi-driver-nfs logs ds/csi-nfs-node -c nfs | tail
```

> Bei einem Update ändern sich drei Zeilen in `HelmRelease.yaml`: `tag:`,
> `chart:`-Pfad und `ignore:`-Pfad. Renovate hebt nur die erste.
