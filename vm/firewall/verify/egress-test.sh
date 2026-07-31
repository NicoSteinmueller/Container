#!/usr/bin/env bash
#
# Egress-Test aus DMZ bzw. Cluster-Segment.
#
# Die zweite Pflichtprüfung aus k8s/Edge-Architektur.md, Abschnitt 5: belegen,
# dass aus der DMZ nichts ins Heimnetz kommt. "Die Regel steht im Repo" ist
# dafür kein Beleg - nur ein Paket, das nicht ankommt, ist einer.
#
# Zwei Betriebsarten:
#
#   --netns   (Vorgabe) Legt auf dem Hypervisor eine wegwerfbare
#             Network-Namespace an, hängt sie an die DMZ- bzw. Cluster-Bridge
#             und testet von dort. Braucht root, aber keine fertige Edge-VM -
#             der Test läuft also, bevor die erste Last darüber geht.
#
#   --ssh U@H Führt dieselben Proben auf einem echten Gast im Segment aus.
#
# Aufruf:
#
#   sudo vm/firewall/verify/egress-test.sh                 # DMZ
#   sudo vm/firewall/verify/egress-test.sh --segment cluster
#   sudo vm/firewall/verify/egress-test.sh --as-edge       # mit der Edge-IP als Quelle
#   vm/firewall/verify/egress-test.sh --ssh root@10.10.20.10
#
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SEGMENT=dmz
MODE=netns
SSH_TARGET=""
AS_EDGE=0
TIMEOUT=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --segment) SEGMENT="$2"; shift 2 ;;
    --ssh) MODE=ssh; SSH_TARGET="$2"; shift 2 ;;
    --netns) MODE=netns; shift ;;
    --as-edge) AS_EDGE=1; shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
  esac
done

tf() { terraform -chdir="$MODULE_DIR" output -raw "$1"; }
tfj() { terraform -chdir="$MODULE_DIR" output -json "$1"; }

WAN_IP="$(tf wan_ip)"
LAN_GW="$(tf wan_gateway)"
MGMT_IP="$(tf ssh_target | cut -d@ -f2)"
DMZ_JSON="$(tfj dmz)"
CLU_JSON="$(tfj cluster)"

jq_get() { printf '%s' "$1" | python3 -c "import json,sys;print(json.load(sys.stdin)['$2'])"; }

DMZ_BRIDGE="$(jq_get "$DMZ_JSON" bridge)"
DMZ_CIDR="$(jq_get "$DMZ_JSON" cidr)"
DMZ_GW="$(jq_get "$DMZ_JSON" gateway)"
EDGE_IP="$(jq_get "$DMZ_JSON" edge_ip)"

CLU_BRIDGE="$(jq_get "$CLU_JSON" bridge)"
CLU_CIDR="$(jq_get "$CLU_JSON" cidr)"
CLU_GW="$(jq_get "$CLU_JSON" gateway)"
INGRESS_IP="$(jq_get "$CLU_JSON" ingress_ip)"

case "$SEGMENT" in
  dmz)
    BRIDGE="$DMZ_BRIDGE"; CIDR="$DMZ_CIDR"; GW="$DMZ_GW"
    if [[ $AS_EDGE -eq 1 ]]; then SRC_IP="$EDGE_IP"; else SRC_IP="${DMZ_CIDR%.*}.250"; fi
    ;;
  cluster)
    BRIDGE="$CLU_BRIDGE"; CIDR="$CLU_CIDR"; GW="$CLU_GW"
    SRC_IP="${CLU_CIDR%.*}.250"
    ;;
  *) echo "--segment muss dmz oder cluster sein" >&2; exit 2 ;;
esac
PREFIX="${CIDR#*/}"

# ---------------------------------------------------------------------
# Probe: Rückgabe "open", "refused" oder "blocked".
#
# Die Unterscheidung zählt: "refused" heißt geroutet, aber niemand lauscht -
# das ist etwas völlig anderes als ein stiller Drop durch die Firewall.
# ---------------------------------------------------------------------
PROBE_PY='
import socket, sys, time
host, port, timeout = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
s = socket.socket(); s.settimeout(timeout)
t0 = time.time()
try:
    s.connect((host, port)); print("open")
except socket.timeout:
    print("blocked")
except OSError as e:
    print("blocked" if time.time() - t0 > timeout * 0.8 else "refused")
finally:
    s.close()
'

NS=""
cleanup() {
  if [[ -n "$NS" ]]; then
    ip netns del "$NS" >/dev/null 2>&1 || true
    ip link del veth-fwt >/dev/null 2>&1 || true
  fi
  return 0
}
trap cleanup EXIT

run_probe() {
  local host="$1" port="$2"
  case "$MODE" in
    netns) ip netns exec "$NS" python3 -c "$PROBE_PY" "$host" "$port" "$TIMEOUT" ;;
    ssh)   ssh -o BatchMode=yes "$SSH_TARGET" "python3 -c '$PROBE_PY' $host $port $TIMEOUT 2>/dev/null || echo blocked" ;;
  esac
}

run_ping() {
  local host="$1"
  case "$MODE" in
    netns) ip netns exec "$NS" ping -c1 -W1 "$host" >/dev/null 2>&1 && echo open || echo blocked ;;
    ssh)   ssh -o BatchMode=yes "$SSH_TARGET" "ping -c1 -W1 $host >/dev/null 2>&1" && echo open || echo blocked ;;
  esac
}

fail=0
check() {
  local expect="$1" what="$2" host="$3" port="${4:-}"
  local result
  if [[ -z "$port" ]]; then
    result="$(run_ping "$host")"
  else
    result="$(run_probe "$host" "$port")"
  fi

  local good=0
  case "$expect" in
    blocked) [[ "$result" == "blocked" ]] && good=1 ;;
    open)    [[ "$result" == "open" ]] && good=1 ;;
  esac

  if [[ $good -eq 1 ]]; then
    printf '  \033[32mOK\033[0m    %-46s %s\n' "$what" "$result"
  else
    printf '  \033[31mFEHLER\033[0m %-46s %s (erwartet: %s)\n' "$what" "$result" "$expect"
    fail=1
  fi
}

# ---------------------------------------------------------------------
if [[ "$MODE" == "netns" ]]; then
  [[ $EUID -eq 0 ]] || { echo "--netns braucht root (Bridge und Namespace)." >&2; exit 2; }

  NS="fw-egress-test"
  ip netns del "$NS" >/dev/null 2>&1 || true
  ip link del veth-fwt >/dev/null 2>&1 || true

  ip netns add "$NS"
  ip link add veth-fwt type veth peer name veth-fwt-ns
  ip link set veth-fwt master "$BRIDGE" up
  ip link set veth-fwt-ns netns "$NS"
  ip -n "$NS" link set lo up
  ip -n "$NS" addr add "$SRC_IP/$PREFIX" dev veth-fwt-ns
  ip -n "$NS" link set veth-fwt-ns up
  ip -n "$NS" route add default via "$GW"
fi

printf '\n\033[1mEgress-Test  Segment=%s  Quelle=%s  Modus=%s\033[0m\n' "$SEGMENT" "${SRC_IP:-$SSH_TARGET}" "$MODE"

printf '\n\033[1mMuss geblockt sein - Heimnetz und Management\033[0m\n'
check blocked "Fritzbox HTTP            ${LAN_GW}:80" "$LAN_GW" 80
check blocked "Fritzbox HTTPS           ${LAN_GW}:443" "$LAN_GW" 443
check blocked "Firewall WAN-Bein SSH    ${WAN_IP}:22" "$WAN_IP" 22
check blocked "Firewall WAN-Bein HTTPS  ${WAN_IP}:443" "$WAN_IP" 443
check blocked "Ping ins Heimnetz        ${LAN_GW}" "$LAN_GW"
check blocked "Management-Netz SSH      ${MGMT_IP}:22" "$MGMT_IP" 22

if [[ "$SEGMENT" == "dmz" ]]; then
  printf '\n\033[1mCluster-Segment\033[0m\n'
  if [[ $AS_EDGE -eq 1 ]]; then
    # Quelle ist die Edge-IP: 443 auf den Ingress muss erlaubt sein. Steht der
    # Cluster noch nicht, ist "refused" der erwartete Zwischenstand - "blocked"
    # dagegen heißt, die Firewall lässt den Edge nicht durch.
    check open    "Ingress HTTPS (als Edge)  ${INGRESS_IP}:443" "$INGRESS_IP" 443
  else
    check blocked "Ingress HTTPS (fremde IP) ${INGRESS_IP}:443" "$INGRESS_IP" 443
  fi
  check blocked "kube-apiserver           ${INGRESS_IP}:6443" "$INGRESS_IP" 6443
else
  printf '\n\033[1mDMZ-Segment\033[0m\n'
  check blocked "Edge HTTPS               ${EDGE_IP}:443" "$EDGE_IP" 443
fi

printf '\n\033[1mMuss funktionieren - Internet\033[0m\n'
check open "DNS über TCP             9.9.9.9:53" 9.9.9.9 53
check open "HTTPS                    1.1.1.1:443" 1.1.1.1 443

printf '\n\033[1mGateway\033[0m\n'
check open "Ping auf die Firewall    ${GW}" "$GW"

echo
if [[ $fail -eq 0 ]]; then
  printf '\033[32mSegmentierung verhält sich wie im Regelsatz beschrieben.\033[0m\n'
else
  printf '\033[31mAbweichung gefunden - NICHT in Betrieb nehmen.\033[0m\n'
fi
exit $fail
