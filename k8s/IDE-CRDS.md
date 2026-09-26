# CRDs für IntelliJ

Ohne die CRDs meldet IntelliJ bei Flux-, Cilium-, cert-manager-, Prometheus- und
CNPG-Ressourcen "Unknown resource".

1. CRDs laden (nach `.idea/crds/`, gitignored):

   ```bash
   tools/ide-crds
   ```

2. **Settings → Build, Execution, Deployment → Kubernetes → Schemas**:
   **+** → **Add files**, alle Dateien aus `.idea/crds/` wählen, Scope **Project**.

3. **Apply**, dann **Clear Schemas Cache**.

Neue CRD-Art im Repo? URL in [tools/ide-crds](../tools/ide-crds) ergänzen und
die neue Datei in Schritt 2 hinzufügen. Zum Aktualisieren das Skript erneut
ausführen.
