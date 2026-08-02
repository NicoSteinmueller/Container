#!/usr/bin/env bash
#
# Registriert den Agenten und die beiden Bouncer der Edge-VM an der
# CrowdSec-LAPI im Cluster und gibt den fertigen Aufruf für die VM aus.
#
# Warum von Hand und nicht aus Terraform: Sonst lägen LAPI-Zugangsdaten im
# Terraform-State und in der Seed-ISO im Storage-Pool der Edge-VM. Dieselbe
# Begründung steht in vm/edge/README.md.
#
# Die Zugangsdaten sind bewusst getrennt von denen der Cluster-Agents und
# einzeln widerrufbar:
#
#   cscli machines delete edge1
#   cscli bouncers delete edge1-firewall
#
# Aufruf:
#
#   k8s/platform/scripts/edge-register.sh [machine-id]
#
set -euo pipefail

MACHINE="${1:-edge1}"
NS="${CROWDSEC_NAMESPACE:-crowdsec}"

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$MODULE_DIR/../../vm/talos/kubeconfig}"

pod="$(kubectl -n "$NS" get pod -l type=lapi -o jsonpath='{.items[0].metadata.name}')"
if [ -z "$pod" ]; then
  echo "Kein LAPI-Pod im Namespace $NS gefunden." >&2
  exit 1
fi

cs() { kubectl -n "$NS" exec "$pod" -- cscli "$@"; }

agent_password="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"

echo "[edge-register] Maschine $MACHINE anlegen"
cs machines add "$MACHINE" --password "$agent_password" --force >/dev/null

echo "[edge-register] Bouncer anlegen"
firewall_key="$(cs bouncers add "${MACHINE}-firewall" --output raw 2>/dev/null | tail -1)"
traefik_key="$(cs bouncers add "${MACHINE}-traefik" --output raw 2>/dev/null | tail -1)"

if [ -z "$firewall_key" ] || [ -z "$traefik_key" ]; then
  echo "Bouncer-Key leer - existieren die Bouncer schon?" >&2
  echo "Dann erst löschen: cscli bouncers delete ${MACHINE}-firewall ${MACHINE}-traefik" >&2
  exit 1
fi

cat <<EOF

Auf der Edge-VM ausführen (der Weg zur LAPI läuft über die mTLS-Strecke -
edge-mtls-bootstrap muss also schon durch sein):

  sudo edge-crowdsec-connect \\
    --agent-password '${agent_password}' \\
    --firewall-key '${firewall_key}' \\
    --traefik-key '${traefik_key}'

Danach in vm/edge/terraform.tfvars:

  crowdsec_bouncer_armed = true

und dort erneut anwenden. Der Firewall-Bouncer bleibt zunächst aus - das
Konzept sieht ein bis zwei Wochen Beobachtungsmodus vor:

  kubectl -n ${NS} exec ${pod} -- cscli alerts list
  # danach auf der Edge-VM:
  sudo edge-crowdsec-connect --arm-firewall-bouncer

EOF
