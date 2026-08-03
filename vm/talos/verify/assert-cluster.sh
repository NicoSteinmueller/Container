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

#
# Genau eine Default-Route, und die zeigt ins LAN. Eine zweite über das
# DMZ-Bein wäre ein Weg nach außen an der Edge-VM vorbei.
#
# Gezählt werden nur Zeilen mit leerem Ziel (= Default-Route) und gesetztem
# Gateway. Ein bloßes `grep -c 'gateway: '` zählt zu viel: Cilium legt für das
# Pod-Netz eine Route über cilium_host an, die ebenfalls ein Gateway trägt -
# das meldete sich als Fund, obwohl der Node nur ein Default-Gateway hat.
#
default_routes="$(
  talosctl -n "$NODE_IP" get routes -o yaml 2>/dev/null |
    awk '/^ *dst: ""/ { dst = 1; next }
         /^ *gateway: / { if (dst && $2 != "\"\"") n++; dst = 0 }
         END { print n + 0 }'
)"
if [ "${default_routes:-0}" -le 1 ]; then
  pass "Genau ein Default-Gateway (DMZ-Bein ohne Route)"
else
  bad "$default_routes Default-Gateways - das DMZ-Bein darf keins haben: talosctl -n $NODE_IP get routes"
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
# Beide Ingress-Controller laufen im Netz-Namespace des Nodes (hostNetwork,
# begründet in k8s/platform/values/traefik-*.yaml.tftpl). Ihre Bindung ist
# damit ein echter lauschender Socket und direkt nachweisbar - anders als
# früher mit hostPort, wo sie nur im eBPF-Datapath von Cilium stand und man
# der Service-Liste des Agents glauben musste.
#
# Das ist die Abnahme aus dem Konzept in ihrer strengsten Form: nicht "ist so
# konfiguriert", sondern "der Kernel hat genau diese Adresse gebunden".
#
sockets="$(talosctl -n "$NODE_IP" netstat -l -t -p 2>/dev/null || true)"

if [ -z "$sockets" ]; then
  warn "netstat über talosctl nicht abrufbar - Schritt übersprungen"
else
  for entry in "$DMZ_IP:443" "$DMZ_IP:8443" "$DMZ_IP:9000" "$NODE_IP:443"; do
    if grep -qE "[[:space:]]${entry//./\\.}[[:space:]]" <<<"$sockets"; then
      pass "$entry gebunden"
    else
      warn "$entry lauscht nicht - k8s/platform schon angewendet?"
    fi
  done

  #
  # Der eigentliche Fund, auf den es hier ankommt: Läge einer der drei
  # DMZ-Ports auf 0.0.0.0, wäre ingress-public aus dem Heimnetz erreichbar -
  # und die Trennung zwischen öffentlichem und internem Ingress aufgehoben,
  # ohne dass irgendetwas kaputt aussähe.
  #
  if grep -qE '[[:space:]]0\.0\.0\.0:(443|8443|9000)[[:space:]]' <<<"$sockets"; then
    bad "Ein exponierter Port hängt an 0.0.0.0 statt an einer festen Node-Adresse - ingress-public wäre aus dem LAN erreichbar"
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
