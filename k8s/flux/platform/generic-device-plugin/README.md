# generic-device-plugin

Macht die GPU auf `gpu1` als Ressource `homelab.io/gpu` anforderbar.

|           |                                                                                       |
|-----------|---------------------------------------------------------------------------------------|
| Läuft auf | Nodes mit Label `homelab/gpu=amd` (siehe `nodes` in [vm/talos](../../../../vm/talos)) |
| Ressource | `homelab.io/gpu`, 4 Stück je Node — geteilt, nicht exklusiv                           |
| Geräte    | `/dev/kfd` (ROCm), `/dev/dri/renderD128` (Vulkan, VA-API)                             |

## Ein GPU-Pod

```yaml
spec:
  nodeSelector:
    homelab/gpu: amd
  tolerations:
    - key: homelab/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - resources:
        limits:
          homelab.io/gpu: 1
```

Den `nodeSelector` erzwingt schon die Ressource, er steht trotzdem da: Ein
Pod `Pending` mit "Insufficient homelab.io/gpu" sagt weniger als einer, dem
der passende Node fehlt.

## Prüfen

```bash
kubectl get node talos-gpu1 -o jsonpath='{.status.allocatable.homelab\.io/gpu}'   # 4
kubectl -n generic-device-plugin logs ds/generic-device-plugin
```

`count: 4` ist keine Aufteilung des VRAM: Lädt Ollama 30 GB Modell, bleibt
für Immich-ML nichts. Begrenzen müssen das die Dienste selbst
(`OLLAMA_MAX_LOADED_MODELS`, `OLLAMA_KEEP_ALIVE`).
