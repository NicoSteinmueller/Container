#!/usr/bin/env bash
#
# Erzeugt ein Bootstrap-Token für das Client-Zertifikat der Edge-VM.
#
# Das Token ist der einzige Weg, auf dem die Edge zum ersten Mal an ein
# Zertifikat kommt - danach erneuert sie über mTLS mit dem noch gültigen
# Zertifikat. Auf der Edge liegt deshalb nie ein Provisioner-Passwort, mit
# dem sich Zertifikate für andere Namen ausstellen ließen.
#
# Das Token läuft nach wenigen Minuten ab. Es gehört über einen Kanal auf die
# VM, den man auch für ein Passwort verwenden würde - nicht in die
# Shell-History eines geteilten Rechners.
#
# Aufruf:
#
#   k8s/platform/scripts/edge-token.sh [common-name]
#
#   # danach auf der Edge-VM:
#   sudo edge-mtls-bootstrap <token>
#
set -euo pipefail

CN="${1:-edge1.dmz}"
NS="${STEP_CA_NAMESPACE:-step-ca}"
PROVISIONER="${STEP_CA_PROVISIONER:-homelab}"

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$MODULE_DIR/../../vm/talos/kubeconfig}"

pod="$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=step-certificates \
  -o jsonpath='{.items[0].metadata.name}')"

if [ -z "$pod" ]; then
  echo "Kein step-ca-Pod im Namespace $NS gefunden." >&2
  exit 1
fi

#
# Das Provisioner-Passwort steht in einem Secret und wird über die Standard-
# eingabe in den Pod gereicht. Bewusst nicht als Datei im Container: Das
# Wurzeldateisystem ist read-only, und eine Datei, die dort doch anlegbar
# wäre, bliebe liegen.
#
password="$(kubectl -n "$NS" get secret step-ca-provisioner-password \
  -o jsonpath='{.data.password}' | base64 -d)"

printf '%s' "$password" | kubectl -n "$NS" exec -i "$pod" -- \
  step ca token "$CN" \
  --provisioner "$PROVISIONER" \
  --password-file /dev/stdin \
  --ca-url https://127.0.0.1:9000 \
  --root /home/step/certs/root_ca.crt
