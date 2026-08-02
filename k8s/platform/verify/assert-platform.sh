#!/usr/bin/env bash
#
# Prüft die Zusagen der Cluster-Ausstattung - Verhalten statt Konfiguration,
# wo es geht.
#
# Die wichtigste Probe ist die letzte: Ein Ingress mit
# ingressClassName: public in einem internen Namespace muss abgelehnt
# werden. Das ist die Regel, die laut Konzept überhaupt erst aus der
# Topologie eine Durchsetzung macht - und sie wird hier tatsächlich
# ausprobiert, nicht nur gelesen (--dry-run=server geht durch die
# Admission-Kette, legt aber nichts an).
#
# Aufruf:
#
#   k8s/platform/verify/assert-platform.sh
#
set -uo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$MODULE_DIR/../../vm/talos/kubeconfig}"

fail=0
info() { printf '\n\033[1m%s\033[0m\n' "$*"; }
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
bad() {
  printf '  \033[31mFAIL\033[0m  %s\n' "$*"
  fail=1
}

command -v kubectl >/dev/null || {
  echo "kubectl nicht gefunden." >&2
  exit 127
}

# ---------------------------------------------------------------------
info "1. Komponenten"
# ---------------------------------------------------------------------

check_ready() {
  local ns="$1" sel="$2" name="$3"
  local ready
  ready="$(kubectl -n "$ns" get pods -l "$sel" \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  if grep -q "True" <<<"$ready"; then
    pass "$name läuft"
  else
    bad "$name läuft nicht (kubectl -n $ns get pods)"
  fi
}

check_ready kube-system k8s-app=cilium "Cilium"
check_ready cert-manager app.kubernetes.io/name=cert-manager "cert-manager"
check_ready step-ca app.kubernetes.io/name=step-certificates "step-ca"
check_ready traefik-public app.kubernetes.io/name=traefik "ingress-public"
check_ready traefik-internal app.kubernetes.io/name=traefik "ingress-internal"
check_ready crowdsec type=lapi "CrowdSec-LAPI"
check_ready kyverno app.kubernetes.io/component=admission-controller "Kyverno"

# ---------------------------------------------------------------------
info "2. Serverzertifikat von ingress-public"
# ---------------------------------------------------------------------

#
# Es muss von der internen CA kommen, den erwarteten Namen tragen und die
# DMZ-Adresse als SAN führen - sonst schlägt entweder die Namensprüfung der
# Edge fehl (serverName in servers-transport.yml) oder die Verbindung der
# CrowdSec-Agenten, die die LAPI über die IP ansprechen.
#
cert="$(kubectl -n traefik-public exec deploy/traefik-public -c pki-renew -- \
  step certificate inspect /pki/tls.crt --format text 2>/dev/null || true)"

if [ -z "$cert" ]; then
  warn "Zertifikat nicht lesbar - kubectl -n traefik-public logs deploy/traefik-public -c pki-bootstrap"
else
  for san in "ingress-public.internal" "10.10.20.3"; do
    if grep -q "$san" <<<"$cert"; then
      pass "SAN $san vorhanden"
    else
      bad "SAN $san fehlt - die Edge bzw. die LAPI-Verbindung schlägt damit fehl"
    fi
  done

  if grep -q "Homelab Internal CA" <<<"$cert"; then
    pass "Aussteller ist die interne CA"
  else
    warn "Aussteller unerwartet - step certificate inspect von Hand ansehen"
  fi
fi

# ---------------------------------------------------------------------
info "3. mTLS-Pflicht auf ingress-public"
# ---------------------------------------------------------------------

#
# Ohne Client-Zertifikat muss der Handshake scheitern. Geprüft wird aus dem
# Cluster heraus gegen den Pod - vom Arbeitsplatz aus ist die DMZ-Adresse
# bewusst nicht erreichbar.
#
if kubectl -n traefik-public get configmap traefik-public-dynamic -o yaml 2>/dev/null |
  grep -q "RequireAndVerifyClientCert"; then
  pass "TLS-Option verlangt ein Client-Zertifikat"
else
  bad "Keine clientAuth-Pflicht in der dynamischen Konfiguration - das Client-Zertifikat der Edge wäre Dekoration"
fi

if kubectl -n traefik-public get configmap traefik-public-dynamic -o yaml 2>/dev/null |
  grep -q "internal-ca.crt"; then
  pass "Vertrauensanker ist die interne CA"
else
  bad "Kein Vertrauensanker konfiguriert"
fi

# ---------------------------------------------------------------------
info "4. Kyverno: ingressClassName public"
# ---------------------------------------------------------------------

internal_ns="$(kubectl get ns -l homelab.io/zone=internal -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
public_ns="$(kubectl get ns -l homelab.io/zone=public -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"

probe_ingress() {
  local ns="$1" class="$2"
  cat <<EOF | kubectl apply --dry-run=server -f - >/dev/null 2>&1
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kyverno-probe
  namespace: $ns
spec:
  ingressClassName: $class
  rules:
    - host: probe.invalid
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: probe
                port:
                  number: 80
EOF
}

if [ -z "$internal_ns" ] || [ -z "$public_ns" ]; then
  warn "Keine Namespaces mit homelab.io/zone gefunden - Probe übersprungen"
else
  if probe_ingress "$internal_ns" public; then
    bad "Ein public-Ingress in $internal_ns wurde angenommen - genau das soll die Regel verhindern"
  else
    pass "public-Ingress in $internal_ns wird abgelehnt"
  fi

  if probe_ingress "$public_ns" public; then
    pass "public-Ingress in $public_ns ist zulässig"
  else
    bad "public-Ingress in $public_ns wird abgelehnt - die Regel ist zu streng"
  fi

  if probe_ingress "$internal_ns" internal; then
    pass "internal-Ingress in $internal_ns ist zulässig"
  else
    bad "internal-Ingress in $internal_ns wird abgelehnt - die Regel ist zu streng"
  fi
fi

# ---------------------------------------------------------------------
info "5. Default-Deny in den Anwendungs-Namespaces"
# ---------------------------------------------------------------------

for ns in $(kubectl get ns -l homelab.io/zone -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  zone="$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.homelab\.io/zone}')"
  case "$zone" in
    public | internal) ;;
    *) continue ;;
  esac

  if kubectl -n "$ns" get networkpolicy default-deny >/dev/null 2>&1; then
    pass "$ns hat eine Default-Deny-Policy"
  else
    warn "$ns ohne Default-Deny - Infrastruktur-Namespace?"
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mAlle harten Prüfungen bestanden.\033[0m\n'
else
  printf '\033[31mMindestens eine Prüfung ist durchgefallen.\033[0m\n'
fi
exit "$fail"
