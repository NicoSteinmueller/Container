# Lokale LLMs mit API und WebUI

Dieser Stack stellt lokale LLM-Inferenz mit **Ollama** bereit und nutzt **Open WebUI** als Browser-Oberflaeche.

## Enthaltene Services

- `ollama`:
  - lokale LLM-API auf Port `11434`
  - fuer andere Services direkt nutzbar (z. B. `http://ollama:11434` im Docker-Netz)
- `open-webui`:
  - WebUI auf Port `3000`
  - verbunden mit Ollama (`OLLAMA_BASE_URL=http://ollama:11434`)
- `model-init` (optional, Profil `init`):
  - zieht ein Startmodell (`llama3.2:3b`)

## Start

```bash
docker compose up -d
```

Optional inkl. initialem Modell-Download:

```bash
docker compose --profile init up model-init
```

## Nutzung

- WebUI direkt: `http://<dein-host>:3000`
- WebUI via Traefik: `https://llm.local.nico-steinmueller.de`
- Ollama API direkt: `http://<dein-host>:11434`
- Ollama API via Traefik: `https://ollama-api.local.nico-steinmueller.de`

Beispiel-Test gegen die API:

```bash
curl http://localhost:11434/api/tags
```

## Hinweise fuer andere Container

Wenn ein anderer Service im externen Netzwerk `proxy` haengt, kann er Ollama ueber erreichen:

- `http://ollama:11434`

Wenn der Service nicht im `proxy`-Netz haengt, nutze den Host-Port:

- `http://<docker-host-ip>:11434`

## Persistenz

- Ollama-Modelle: Volume `ollama`
- Open-WebUI-Daten: Volume `open-webui`

## GPU (optional)

Der Compose laeuft standardmaessig auf CPU. Falls du GPU nutzen willst, kann ich dir als naechsten Schritt eine NVIDIA- oder AMD-Variante einbauen.

