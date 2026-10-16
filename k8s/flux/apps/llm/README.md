# llm

Sprachmodelle auf der GPU von `gpu1`, Oberfläche unter
`https://open-webui.k8s.nico-steinmueller.de`.

| Datei                                          | Was                                                      |
|------------------------------------------------|----------------------------------------------------------|
| [`LlamaSwap.yaml`](LlamaSwap.yaml)             | llama-swap mit llama-server (Vulkan), Modell-Liste, Cache |
| [`ModelSync.yaml`](ModelSync.yaml)             | Sidecar: Modelle aus Backup oder Hugging Face, Kopie auf NFS |
| [`OpenWebUI.yaml`](OpenWebUI.yaml)             | Oberfläche, Anmeldung über Keycloak                      |
| [`NetworkPolicies.yaml`](NetworkPolicies.yaml) | Eingang von `ingress-internal`, Ausgang Hugging Face     |

## Aufbau

```
Browser ─▶ ingress-internal ─▶ Open WebUI (cp1) ─▶ llama-swap (gpu1) ─▶ llama-server ─▶ GPU
```

- **llama-swap** startet je Modell einen `llama-server` und wechselt beim
  ersten Request auf ein anderes. Es lädt immer nur ein Modell. Nach 30 min 
  ohne Anfrage entlädt es (`ttl`).
- **Vulkan statt ROCm:** Mindestens gleich schnell und robuster; braucht nur
  `/dev/dri/renderD128`. Die GPU kommt über [`generic-device-plugin`](../../platform/generic-device-plugin).
- **Open WebUI** spricht llama-swap als OpenAI-API an. Ohne Internet: Die
  Modelle für RAG und Sprache bringt das Image mit.

Beide ohne root und mit schreibgeschütztem Dateisystem.

## Modelle

| ID                   | Datei                                                 | Kontext | VRAM   |
|----------------------|-------------------------------------------------------|---------|--------|
| `qwen3.8-27b`        | `unsloth/Qwen3.8-27B-GGUF:UD-Q6_K_XL` + Vision        | 64k     | ~28 GB |
| `qwen3.8-27b-q4-mtp` | `unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL` + Vision + MTP  | 64k     | ~23 GB |
| `gemma-4-31b`        | `unsloth/gemma-4-31B-it-GGUF:Q5_K_M` + Vision         | 32k     | ~26 GB |

`qwen3.8-27b-q4-mtp` ist dasselbe Modell in 4 Bit mit MTP-Kopf
(Multi-Token-Prediction): Der Kopf schlägt bis zu 3 Tokens vor, Qwen prüft sie
in einem Durchlauf. Das Ergebnis ist dasselbe wie ohne MTP, nur schneller.
Unsloth legt den Kopf unter `MTP/` ab, llama.cpp sucht ihn aber nur neben
dem Modell - deshalb steht er als `-hfd <repo> -md <datei>` in der Config,
und `model-sync` holt ihn von dort mit. Ob er greift, zeigt das Log von
llama-server (`draft acceptance`).

`qwen3.8-27b:docs` ist ein Alias auf denselben llama-server (kein Wechsel)
für Paperless und paperless-gpt: llama-swap erzwingt dort Temperatur 0.6 und
`max_tokens` 8192 (`filters.setParamsByID`). paperless-gpt schickt sonst
Temperatur 0 ohne Grenze, und Qwen denkt in einer Schleife bis zum vollen
Kontext.

Ein neues Modell ist ein Eintrag in der ConfigMap in
[`LlamaSwap.yaml`](LlamaSwap.yaml); Reloader startet den Pod danach neu, und
der Sidecar `model-sync` holt die Datei. Bis sie vollständig ist, scheitert
eine Anfrage an das Modell sofort — `llama-server` läuft `--offline` und lädt
nie selbst herunter.

Faustregel für die Größe: Gewichte + KV-Cache × Kontext + ~1,5 GB müssen
unter 32 GB bleiben.


## Download und Backup

`model-sync` liest die `-hf`-Argumente (und Drafts als `-hfd`/`-md`) aus der
Config und arbeitet sie in deren Reihenfolge ab:

1. lokal vollständig → weiter mit 4
2. auf `models-backup` (NFS) → von dort kopieren
3. sonst → `llama download -hf …` von Hugging Face, mit Wiederholung
4. Backup unvollständig → lokal nach NFS kopieren

Danach schläft er bis zum nächsten Neustart. llama-swap ist währenddessen
schon da: Was im Cache liegt, ist sofort nutzbar.

Nach einem Neuaufbau von `gpu1` kommen die Modelle so aus dem LAN statt über
die Internetleitung. Ob ein Modell vollständig ist, entscheidet llama.cpp
selbst (`llama download --offline`); kopiert wird unter `.partial` und erst
dann umbenannt — ein abgebrochener Lauf hinterlässt nichts, das als fertig gilt.

```bash
kubectl -n llm logs deploy/llama-swap -c model-sync
```

Entfernt man ein Modell aus der Config, bleibt es lokal und auf NFS liegen.
Aufräumen von Hand.

## Speicher

| PVC          | Klasse       | Node   | gesichert                         |
|--------------|--------------|--------|-----------------------------------|
| `models`        | `local-path` | `gpu1` | Arbeitskopie, Quelle des VRAM                    |
| `models-backup` | `nfs-unraid` | –      | `/mnt/user/k8s/llm/models-backup` — in Kopia ausschließen |
| `open-webui`    | `local-path` | `cp1`  | nein — Chats, Benutzer, Uploads                  |

`open-webui` hält die SQLite-Datenbank mit allen Chats. Ein Sicherungsweg
für `local-path` steht noch aus (siehe [vm/talos](../../../../vm/talos)).

## Prüfen

```bash
kubectl get node talos-gpu1 -o jsonpath='{.status.allocatable.homelab\.io/gpu}'   # 4
kubectl -n llm logs deploy/llama-swap -c model-sync # Download, Backup
kubectl -n llm exec deploy/llama-swap -- curl -s localhost:8080/running
```

Im Log von llama-server muss die Karte als Vulkan-Gerät auftauchen
(`ggml_vulkan: … AMD Radeon AI PRO R9700 (RADV GFX1201)`) und alle Layer auf
ihr landen (`offloaded 65/65 layers to GPU`). Steht dort `CPU`, fehlt dem Pod
die Ressource `homelab.io/gpu`.
