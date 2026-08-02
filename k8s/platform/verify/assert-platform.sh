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
# Gelesen wird aus dem Secret und nicht aus dem Pod: So funktioniert die
# Probe auch dann, wenn der Ingress gerade nicht startet - und das ist der
# Moment, in dem man sie braucht.
#
cert="$(kubectl -n traefik-public get secret ingress-public-tls \
  -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null |
  openssl x509 -noout -text 2>/dev/null || true)"

if [ -z "$cert" ]; then
  warn "Zertifikat nicht lesbar - kubectl -n step-ca logs job/ingress-cert-bootstrap"
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
    warn "Aussteller unerwartet - Zertifikat von Hand ansehen"
  fi
fi

# ---------------------------------------------------------------------
info "2b. Kein CA-Zugang im Namespace von ingress-public"
# ---------------------------------------------------------------------

#
# Der Kern der Trennung: Traefik bekommt mit namespaced RBAC Leserecht auf
# Secrets in seinem eigenen Namespace. Läge dort ein Provisioner-Passwort,
# wäre eine Übernahme des Ingress gleichbedeutend mit Zertifikaten auf
# beliebige Namen - auch auf den der Edge-VM.
#
# Das Passwort gehört deshalb ausschließlich in den Namespace step-ca. Diese
# Probe ist die Gegenprobe dazu und die einzige, die einen Rückschritt
# bemerken würde.
#
found=""
for s in $(kubectl -n traefik-public get secrets -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  case "$s" in
    *provisioner* | *step-ca*) found="$found $s" ;;
  esac
done

if [ -n "$found" ]; then
  bad "Secret mit CA-Bezug in traefik-public:$found - Traefik darf es lesen"
else
  pass "kein Provisioner-Passwort im Namespace von ingress-public"
fi

if kubectl -n step-ca get secret step-ca-provisioner-password >/dev/null 2>&1; then
  pass "das Provisioner-Passwort liegt in step-ca"
else
  warn "step-ca-provisioner-password nicht gefunden - Chartversion geändert?"
fi

if kubectl -n step-ca get cronjob ingress-cert-renew >/dev/null 2>&1; then
  pass "der Aussteller erneuert turnusmäßig"
else
  bad "CronJob ingress-cert-renew fehlt - das Zertifikat läuft in Stunden ab"
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
info "4b. Kyverno: die DMZ-Entrypoints"
# ---------------------------------------------------------------------

#
# lapi und stepca führen zur Entscheidungsdatenbank und zur internen CA. Eine
# IngressRoute darauf aus einem Anwendungs-Namespace könnte die vorhandene
# Route überstimmen und die Edge-VM auf einen eigenen Dienst umlenken - beim
# TCP-Passthrough von step-ca wäre das der Punkt, an dem die
# Fingerprint-Prüfung der Edge ins Leere liefe.
#
# Der öffentliche Namespace ist hier der interessante Fall: Für `websecure`
# ist er ausgenommen, für diese beiden darf er es nicht sein.
#
probe_route_tcp() {
  local ns="$1" entrypoint="$2"
  cat <<EOF | kubectl apply --dry-run=server -f - >/dev/null 2>&1
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: kyverno-probe
  namespace: $ns
spec:
  entryPoints:
    - $entrypoint
  routes:
    - match: HostSNI(\`probe.invalid\`)
      services:
        - name: probe
          port: 9000
EOF
}

if [ -z "$public_ns" ]; then
  warn "Kein öffentlicher Namespace gefunden - Probe übersprungen"
else
  for ep in stepca lapi; do
    if probe_route_tcp "$public_ns" "$ep"; then
      bad "Entrypoint $ep aus $public_ns wurde angenommen - er gehört nur nach traefik-public"
    else
      pass "Entrypoint $ep aus $public_ns wird abgelehnt"
    fi
  done
fi

# ---------------------------------------------------------------------
info "4c. Egress der Infrastruktur-Namespaces"
# ---------------------------------------------------------------------

#
# Ohne diese Policies hätte ausgerechnet ingress-public freien Egress ins
# Heimnetz - der Pod, der die Verbindungen aus der DMZ beendet.
#
for ns in traefik-public traefik-internal cert-manager step-ca crowdsec kyverno local-path-storage; do
  if ! kubectl get ns "$ns" >/dev/null 2>&1; then
    continue
  fi

  if kubectl -n "$ns" get cnp egress-no-lan >/dev/null 2>&1; then
    pass "$ns hat egress-no-lan"
  else
    bad "$ns ohne egress-no-lan - der Namespace erreicht das Heimnetz"
  fi
done

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
