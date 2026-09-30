# Navidrome

Musik-Streaming unter `https://music.k8s.nico-steinmueller.de`

## Speicher

| PVC                | Klasse       | Inhalt                                      | gesichert               |
|--------------------|--------------|---------------------------------------------|-------------------------|
| `navidrome-data`   | `local-path` | `navidrome.db`, Bild- und Transcoding-Cache | nein - dafür das Backup |
| `navidrome-backup` | `nfs-unraid` | tägliche Kopie der DB, 7 Stück              | ja                      |
| `navidrome-music`  | `nfs-unraid` | die Sammlung, nur lesbar                    | ja                      |

## Backup wiederherstellen

Jedes Backup ist eine vollständige Kopie der SQLite-Datenbank, die Navidrome
benutzt. Die Wiederherstellung legt sie an die Stelle von `navidrome.db`.

Voraussetzung: dasselbe `ND_PASSWORDENCRYPTIONKEY` wie beim Anlegen des
Backups, sonst sind die gespeicherten Passwörter unlesbar.

1. Navidrome anhalten. Ohne `suspend` setzt Flux die Replikas beim nächsten
   Abgleich zurück:

   ```bash
   flux suspend kustomization apps
   kubectl -n navidrome scale deploy/navidrome --replicas=0
   ```

2. Backup einspielen. `-wal` und `-shm` müssen mit weg, sonst spielt SQLite
   sie über die zurückgeholte Datei:

   ```bash
   BACKUP=navidrome_backup_<zeitstempel>.db
   kubectl -n navidrome apply -f - <<EOF
   apiVersion: v1
   kind: Pod
   metadata:
     name: navidrome-restore
     namespace: navidrome
   spec:
     restartPolicy: Never
     automountServiceAccountToken: false
     securityContext:
       runAsNonRoot: true
       runAsUser: 99
       runAsGroup: 100
       fsGroup: 100
       fsGroupChangePolicy: OnRootMismatch
       seccompProfile: { type: RuntimeDefault }
     containers:
       - name: restore
         image: deluan/navidrome:0.63.2
         command:
           - sh
           - -c
           - rm -f /data/navidrome.db /data/navidrome.db-wal /data/navidrome.db-shm
             && cp /backup/$BACKUP /data/navidrome.db && ls -l /data
         securityContext:
           allowPrivilegeEscalation: false
           readOnlyRootFilesystem: true
           capabilities: { drop: [ALL] }
         volumeMounts:
           - { name: data, mountPath: /data }
           - { name: backup, mountPath: /backup, readOnly: true }
     volumes:
       - name: data
         persistentVolumeClaim: { claimName: navidrome-data }
       - name: backup
         persistentVolumeClaim: { claimName: navidrome-backup }
   EOF
   kubectl -n navidrome logs -f navidrome-restore
   kubectl -n navidrome delete pod navidrome-restore
   ```

3. Wieder anlaufen lassen. `resume` setzt auch die Replikas zurück:

   ```bash
   flux resume kustomization apps
   ```
