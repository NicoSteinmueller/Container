# Paperless lokal mit KI

Dev-Stack zum Ausprobieren der KI: die eingebaute von Paperless und
[paperless-gpt](https://github.com/icereed/paperless-gpt). Das Sprachmodell
ist llama-swap im Cluster ([`k8s/flux/apps/llm`](../k8s/flux/apps/llm)).

| Datei                                                        | Was                                                |
|--------------------------------------------------------------|----------------------------------------------------|
| [`compose.yml`](compose.yml)                                 | Paperless mit Postgres, Valkey, Gotenberg, Tika    |
| [`compose.override.yml`](compose.override.yml)               | Dev-Einstellungen, eingebaute KI                   |
| [`docker-compose.gpt.local.yml`](docker-compose.gpt.local.yml) | paperless-gpt                                    |
| `.env`                                                       | `PAPERLESS_GPT_API_TOKEN`, gitignored              |
| `gpt/`                                                       | Prompts und Workflows von paperless-gpt, gitignored |
| `data/gpt/`                                                  | Einstellungen und Verlauf von paperless-gpt        |

## Starten

```bash
# llama-swap aus dem Cluster - nur localhost und Docker-Bridge, nicht das LAN
KUBECONFIG=../vm/talos/kubeconfig \
  kubectl -n llm port-forward svc/llama-swap --address 127.0.0.1,172.17.0.1 11435:8080

docker compose -f compose.yml -f compose.override.yml -f docker-compose.gpt.local.yml up -d
```

Paperless unter `http://127.0.0.1:8080` (`admin`/`admin`), paperless-gpt
unter `http://127.0.0.1:8081`. Die NetworkPolicy von llama-swap lässt sonst
nur Open WebUI zu; der Port-Forward landet direkt im Pod.

## Ablauf

```
Upload ─▶ Paperless (Tesseract) ─▶ Workflow „an paperless-gpt“: Tag gpt
       ─▶ paperless-gpt, Workflow „test1“: OCR mit Qwen, dann Titel, Tags,
          Korrespondent, Typ, Datum, Custom Fields ─▶ Tag gpt-auto-complete
```

Rund 5 Minuten je Dokument, davon knapp 2 für die OCR. Qwen denkt vor jeder
Antwort, abschalten lässt sich das in paperless-gpt nicht.

Der Paperless-Workflow „ki“ (Aktion „KI-Vorschläge übernehmen“) ist
abgeschaltet. Er würde parallel auf dem Tesseract-Text zuordnen und sich
mit paperless-gpt gegenseitig überschreiben.

## Eingebaut oder paperless-gpt

|                         | Paperless 3.3          | paperless-gpt                        |
|-------------------------|------------------------|--------------------------------------|
| OCR per Sprachmodell    | nein (nur Azure)       | ja, Seiten als Bilder                |
| Custom Fields           | nein                   | ja, nur vorhandene und ausgewählte   |
| Speicherpfad            | ja                     | nein                                 |
| Automatisch             | Workflow-Aktion        | Trigger-Tag                          |
| Chat mit Dokumenten     | ja (Embeddings lokal)  | nein                                 |
| Prompts anpassbar       | nein                   | ja, `gpt/*.tmpl`                     |

### Was paperless-gpt anlegt

| Attribut       | legt neu an                       | sonst                                                        |
|----------------|-----------------------------------|--------------------------------------------------------------|
| Titel, Datum   | -                                 | setzt den Wert                                               |
| Korrespondent  | ja, immer                         | bevorzugt vorhandene; `CORRESPONDENT_BLACK_LIST` schließt Namen aus |
| Tag            | nur mit `CREATE_NEW_TAGS=true` (lokal aus) | Standard `false`: nur aus der vorhandenen Liste      |
| Dokumenttyp    | nein                              | nur vorhandene; unbekannte Vorschläge verwirft es            |
| Custom Field   | nein                              | nur vorhandene und unter Settings ausgewählte; andere verwirft es |
| Speicherpfad   | -                                 | kennt es nicht                                               |
| eigene Tags    | ja, beim Start bzw. Speichern     | `paperless-gpt-auto-complete`, `paperless-gpt-failed`, `paperless-gpt-ocr-complete`; Trigger- und Abschluss-Tag eines Workflows |

Dokumenttypen und Custom Fields also vorher in Paperless anlegen. Lokal:
Betrag, Rechnungsnummer, Fälligkeitsdatum, Kunden-/Vertragsnummer.
`PRESERVE_EXISTING_METADATA=true` lässt einen schon gesetzten
Korrespondenten oder Dokumenttyp stehen (Standard: überschreiben). Neu
angelegte Korrespondenten und Tags gehören dem Benutzer von paperless-gpt
(siehe [Freigaben](#freigaben)).

## Benutzer und Rechte

Lokal arbeitet paperless-gpt noch mit dem Token von `admin`. Im Cluster
bekommt es einen eigenen Benutzer.

### Wer was sieht

Ein Benutzer ohne Superuser-Status sieht ein Objekt nur, wenn es

1. ihm gehört,
2. keinen Besitzer hat oder
3. ihm oder einer seiner Gruppen freigegeben ist.

Die globalen Rechte („Dokument anzeigen“) öffnen nur die API, nicht fremde
Objekte. Ein Recht „alles sehen“ gibt es außer Superuser nicht. Das gilt für
Dokumente, Tags, Korrespondenten und Dokumenttypen; Custom Fields haben
keinen Besitzer.

### Gruppe `ki` und Benutzer `paperless-gpt`

Lokal angelegt und geprüft. Globale Rechte der Gruppe:

| Objekt                          | Rechte                        |
|---------------------------------|-------------------------------|
| Dokument                        | Anzeigen, Ändern              |
| Tag, Korrespondent, Dokumenttyp | Anzeigen, Hinzufügen, Ändern  |
| Custom Field                    | Anzeigen                      |

Damit setzt paperless-gpt Tags und alle Custom-Field-Typen, legt Tags an
und gibt seine eigenen Objekte frei. Hinzufügen bei Dokumenten braucht es
nur mit `PDF_UPLOAD`. Benutzer `paperless-gpt` ohne Admin und Superuser in
die Gruppe; seinen Token in `PAPERLESS_API_TOKEN`.

### Freigaben

| Was                                 | Wie                                                                 |
|-------------------------------------|---------------------------------------------------------------------|
| neue Dokumente                      | Workflow „an paperless-gpt“: in der Zuweisung zusätzlich Gruppe `ki` bei Anzeigen und Bearbeiten |
| vorhandene Dokumente                | alle markieren → Berechtigungen → Gruppe `ki`, „Zusammenführen“     |
| vorhandene Tags, Korrespondenten, Typen | Verwaltung → markieren → Berechtigungen → Gruppe `ki`. Sonst kennt paperless-gpt sie nicht und legt Duplikate an |
| was paperless-gpt neu anlegt        | gehört `paperless-gpt`, andere Nicht-Superuser sehen es nicht → Skript unten |

### Neue Objekte für alle freigeben

Macht alles besitzerlos, was `paperless-gpt` gehört - als CronJob, etwa alle
5 Minuten. Läuft mit dessen eigenem Token: Die Rechte eigener Objekte darf
ein Benutzer ändern. Die ID steht fest drin, weil der Benutzer weder seine
Einstellungen noch die Benutzerliste lesen darf.

```sh
#!/bin/sh
# Macht Tags, Korrespondenten und Dokumenttypen, die paperless-gpt angelegt
# hat, besitzerlos - damit für alle Benutzer sichtbar.
set -eu
API="$PAPERLESS_URL/api"
AUTH="Authorization: Token $PAPERLESS_TOKEN"

for type in tags correspondents document_types; do
  ids=$(curl -sf -H "$AUTH" "$API/$type/?page_size=100000&fields=id,owner" \
    | jq -c --argjson me "$GPT_USER_ID" '[.results[] | select(.owner == $me) | .id]')
  [ "$ids" = "[]" ] && continue
  curl -sf -o /dev/null -H "$AUTH" -H "Content-Type: application/json" \
    -X POST "$API/bulk_edit_objects/" \
    -d "{\"objects\":$ids,\"object_type\":\"$type\",\"operation\":\"set_permissions\",\"owner\":null}"
  echo "$type: $ids freigegeben"
done
```

Besitzerlos heißt auch: Jeder mit dem globalen Recht „Tag ändern“ darf sie
umbenennen oder löschen. Soll das nicht sein, statt `"owner":null` eine
Gruppe aller Benutzer freigeben: `"permissions":{"view":{"users":[],"groups":[…]}},"merge":true`.

## Absicherung

paperless-gpt hat keine Anmeldung. Wer die Oberfläche erreicht, arbeitet mit
dessen Paperless-Token. Lokal hängt sie nur an `127.0.0.1`. Im Cluster
ohne Ingress betreiben - die Kette braucht die Oberfläche nicht, für
Workflows reicht `kubectl port-forward`.

## Stolpersteine

- **Endlosschleife**: paperless-gpt schickt Temperatur 0 und kein
  `max_tokens`; Qwen denkt dann ohne Ende, die GPU läuft mit 300 W und
  102 °C Junction. `LLM_TEMPERATURE`/`LLM_MAX_TOKENS` wirken nur mit Ollama.
  Deshalb nutzen beide den Alias `qwen3.8-27b:docs`, für den llama-swap 0.6
  und 8192 erzwingt ([`LlamaSwap.yaml`](../k8s/flux/apps/llm/LlamaSwap.yaml)).
  Eine hängende Anfrage läuft auch ohne Client weiter - abbrechen mit
  `kubectl -n llm exec deploy/llama-swap -c llama-swap -- curl -s localhost:8080/unload`.
- **OCR-Prompt** (`gpt/ocr_prompt.tmpl`, gitignored - fürs Cluster
  mitnehmen): Der Standard hängt den Tesseract-Text an mit „korrigiere
  ihn“. Ohne Denkphase übernimmt Qwen dann dessen Format und lässt
  Markdown weg. Und Formularlinien bildet es als `\_\_\_…` nach, bis
  `max_tokens` greift - der Rest der Seite fehlt. Angepasst: Markdown-Regeln
  ausdrücklich, Referenztext nur für schwer lesbare Wörter, leere Felder als
  `[ ]`, nie mehr als drei Unterstriche. Ändern über die Oberfläche (Prompts)
  oder `POST /api/prompts`, das wirkt ohne Neustart.
- **`PAPERLESS_AI_LLM_EXTRA_PARAMS`**: eigene Felder unter `extra_body`, sonst
  lehnt das OpenAI-SDK sie ab (500 bei den Vorschlägen).
- **`/api/generate-suggestions`** von paperless-gpt will das ganze Dokument
  wie aus `/api/documents`, nicht nur die ID - sonst ist der Prompt leer.
- **Korrespondenten**: Der Prompt streicht Rechtsformen („Bosch Power Tools“
  statt „… GmbH“) und legt sonst Duplikate an. Korrespondenten so benennen
  oder `gpt/correspondent_prompt.tmpl` anpassen.
- **Doppelte OCR**: Tesseract läuft trotzdem. Qwens Text ersetzt nur den
  Inhalt, die Textebene im Archiv-PDF bleibt von Tesseract.
- **„Privat“ an Tags** in der Oberfläche: Die Seite kennt neu angelegte Tags
  noch nicht. Neu laden.
- **Testlauf** eines Workflows in paperless-gpt überspringt die OCR.
