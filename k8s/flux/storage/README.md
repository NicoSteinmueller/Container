# storage

Aufgeteilt nach **Zugriffsmuster**. Die Aufteilung folgt auch der Hardware:
`local-path` liegt auf der NVMe, `nfs-unraid` auf dem Array.

| | [`local-path/`](local-path) (Default) | [`nfs-storage/`](nfs-storage) → `nfs-unraid` |
|---|---|---|
| wofür | fsync und Locking: DBs, Indizes, Queues | Bestände: Medien, Uploads, Backups |
| liegt auf | zweite Disk der VM, `/var/mnt/local-path` | Unraid-Share `k8s` über NFSv4.1 |
| Zugriff | `ReadWriteOnce` | `ReadWriteMany` |
| PVC gelöscht | `Retain` | `onDelete: retain` |
| Backup | **keins** - verschwindet mit der VM | Kopia auf dem Host |

Über NFS ginge jedes `fsync` durchs Netz, Locks bleiben nach einem Serverneustart
hängen, und `hard` ließe eine Datenbank hängen statt abstürzen. Deshalb ist
`local-path` Default: Ein Chart ohne Angabe hat meist fsync vor. Die
Default-Annotation steht an genau einer Stelle - bei zweien wählt Kubernetes
willkürlich.

```bash
kubectl get sc                      # local-path (default), nfs-unraid
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: nfs-smoketest }
spec:
  storageClassName: nfs-unraid
  accessModes: [ReadWriteMany]
  resources: { requests: { storage: 1Gi } }
EOF
kubectl get pvc nfs-smoketest       # erwartet: Bound
ssh root@192.168.178.3 ls /mnt/user/k8s/default
kubectl delete pvc nfs-smoketest    # Verzeichnis bleibt (onDelete: retain)
```

Hängt ein Pod in `ContainerCreating`, steht der Grund im Event:
`kubectl describe pod <name> | tail -20`.
