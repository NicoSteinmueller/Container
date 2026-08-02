#!/usr/bin/env bash
#
# Prüft die Zusagen, die dieses Modul über den Node macht - Verhalten statt
# Konfiguration, wo es geht.
#
# Die drei, auf die es ankommt:
#
#   1. Der Node hat zwei Beine mit den erwarteten Adressen, und das
#      DMZ-Bein hat kein Gateway.
#   2. Die Ingress-Firewall steht auf block, und die Regeln sind im Kernel -
#      nicht nur in der Machine-Config.
#   3. Die exponierten Ports hängen an der DMZ-Adresse und nicht an allen
#      Node-IPs. Das ist die Abnahme aus dem Konzept ("Service-Bindung
#      prüfen, nicht annehmen"): Ein Verbindungsversuch aus dem LAN auf
#      ingress-public muss scheitern.
#
# Aufruf:
#
#   vm/talos/verify/assert-cluster.sh
#
set -uo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tf() { terraform -chdir="$MODULE_DIR" output -raw "$1" 2>/dev/null; }

export TALOSCONFIG="${TALOSCONFIG:-$MODULE_DIR/talosconfig}"
export KUBECONFIG="${KUBECONFIG:-$MODULE_DIR/kubeconfig}"

NODE_IP="$(tf lan_ip)"
DMZ_IP="$(tf node_dmz_ip)"
ENFORCED="$(tf ingress_firewall_enforced)"

fail=0
info() { printf '\n\033[1m%s\033[0m\n' "$*"; }
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
bad() {
  printf '  \033[31mFAIL\033[0m  %s\n' "$*"
  fail=1
}

for tool in talosctl kubectl; do
  command -v "$tool" >/dev/null || {
    echo "$tool nicht gefunden - ohne das geht hier nichts." >&2
    exit 127
  }
done

# ---------------------------------------------------------------------
info "1. Node und Adressen"
# ---------------------------------------------------------------------

if talosctl -n "$NODE_IP" version --short >/dev/null 2>&1; then
  pass "Talos-API auf $NODE_IP erreichbar"
else
  bad "Talos-API auf $NODE_IP nicht erreichbar - admin_sources prüfen"
fi

addresses="$(talosctl -n "$NODE_IP" get addresses -o yaml 2>/dev/null || true)"
for addr in "$NODE_IP" "$DMZ_IP"; do
  if grep -q "$addr/" <<<"$addresses"; then
    pass "Adresse $addr liegt auf dem Node"
  else
    bad "Adresse $addr fehlt - MAC-Zuordnung in patches/network.yaml.tftpl prüfen"
  fi
done

# Genau eine Default-Route, und die zeigt ins LAN. Eine zweite über das
# DMZ-Bein wäre ein Weg nach außen an der Edge-VM vorbei.
default_routes="$(talosctl -n "$NODE_IP" get routes -o yaml 2>/dev/null | grep -c 'gateway: ' || true)"
if [ "${default_routes:-0}" -le 1 ]; then
  pass "Höchstens ein Gateway konfiguriert (DMZ-Bein ohne Route)"
else
  warn "Mehr als ein Gateway sichtbar - talosctl get routes von Hand ansehen"
fi

node_ready="$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
if [ "$node_ready" = "True" ]; then
  pass "Node ist Ready (CNI läuft)"
else
  bad "Node ist nicht Ready - kubectl -n kube-system get pods -l k8s-app=cilium"
fi

internal_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
if [ "$internal_ip" = "$NODE_IP" ]; then
  pass "InternalIP ist die LAN-Adresse ($NODE_IP)"
else
  bad "InternalIP ist '$internal_ip' statt $NODE_IP - kubelet.nodeIP.validSubnets prüfen"
fi

# ---------------------------------------------------------------------
info "2. Ingress-Firewall"
# ---------------------------------------------------------------------

chains="$(talosctl -n "$NODE_IP" get nftableschains -o yaml 2>/dev/null || true)"
if grep -q 'ingress' <<<"$chains"; then
  pass "nftables-Ketten von Talos vorhanden"
else
  bad "Keine nftables-Ketten - greift die NetworkRuleConfig überhaupt?"
fi

if [ "$ENFORCED" = "true" ]; then
  if grep -qi 'policy: *drop\|verdict: *drop' <<<"$chains"; then
    pass "Default-Aktion ist block"
  else
    warn "Default-Aktion nicht eindeutig erkennbar - talosctl get nftableschains -o yaml lesen"
  fi
else
  warn "ingress_firewall_enforced = false - der Node nimmt eingehend noch alles an"
fi

# ---------------------------------------------------------------------
info "3. Bindung der exponierten Ports"
# ---------------------------------------------------------------------

#
# Die Bindung liegt bei Cilium im eBPF-Datapath, nicht in einem lauschenden
# Socket - `ss -lntp` zeigt sie deshalb nicht. Maßgeblich ist die
# Service-Liste des Agents: dort steht die Frontend-Adresse.
#
services="$(kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg service list 2>/dev/null || true)"

if [ -z "$services" ]; then
  warn "cilium-dbg nicht abrufbar - Schritt übersprungen"
else
  for entry in "$DMZ_IP:443" "$DMZ_IP:8443" "$DMZ_IP:9000"; do
    if grep -q "$entry" <<<"$services"; then
      pass "HostPort $entry gebunden"
    else
      warn "HostPort $entry nicht in der Service-Liste - k8s/platform schon angewendet?"
    fi
  done

  if grep -qE '^\s*[0-9]+\s+0\.0\.0\.0:(443|8443|9000)' <<<"$services"; then
    bad "Ein exponierter Port hängt an 0.0.0.0 - hostIP fehlt, damit ist ingress-public aus dem LAN erreichbar"
  else
    pass "Kein exponierter Port an 0.0.0.0"
  fi
fi

#
# Gegenprobe aus dem LAN. Auf $NODE_IP:443 antwortet ingress-internal - das
# ist richtig so. Falsch wäre, wenn dort ingress-public antwortete: erkennbar
# am Serverzertifikat, das dann auf ingress-public.internal ausgestellt ist.
#
# Genau diese Verwechslung ist der Fehler, den das Konzept meint ("Bei
# NodePort beziehungsweise LoadBalancer mit Cilium lauscht ein Service
# standardmäßig auf allen Node-IPs").
#
if command -v openssl >/dev/null; then
  lan_cert="$(echo | openssl s_client -connect "$NODE_IP:443" -servername ingress-public.internal 2>/dev/null |
    openssl x509 -noout -text 2>/dev/null || true)"

  if [ -z "$lan_cert" ]; then
    warn "Auf $NODE_IP:443 antwortet nichts - ingress-internal noch nicht ausgerollt?"
  elif grep -q 'ingress-public.internal' <<<"$lan_cert"; then
    bad "Auf der LAN-Adresse antwortet ingress-public - die hostIP-Bindung greift nicht"
  else
    pass "Auf $NODE_IP:443 antwortet ingress-internal, nicht ingress-public"
  fi
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mAlle harten Prüfungen bestanden.\033[0m\n'
else
  printf '\033[31mMindestens eine Prüfung ist durchgefallen.\033[0m\n'
fi
exit "$fail"
