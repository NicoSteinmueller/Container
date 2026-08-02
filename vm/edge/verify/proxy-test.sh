#!/usr/bin/env bash
#
# Abnahme der Stufen 3 bis 6 auf der laufenden Edge-VM.
#
# Prüft nicht die Konfiguration, sondern das Verhalten: was die Maschine
# tatsächlich antwortet und was im Log steht. Die beiden wichtigsten Proben
# sind die aus dem Sicherheitskonzept:
#
#   - Ein Request mit gefälschtem X-Forwarded-For muss im Access-Log mit der
#     echten Peer-IP auftauchen. Sonst bestimmt der Angreifer per Kopfzeile,
#     als welche IP er bewertet wird - und die zentrale Abwehrschicht ist mit
#     einer Zeile abgeschaltet.
#   - Ein direkter Zugriff auf die IP oder ein fremder Hostname darf keine
#     Antwort bekommen, sondern muss im TLS-Handshake enden.
#
# Aufruf:
#
#   vm/edge/verify/proxy-test.sh <öffentlicher-name> [user@host]
#   vm/edge/verify/proxy-test.sh cloud.domain.de --rate     # inkl. Rate Limit
#
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tf() { terraform -chdir="$MODULE_DIR" output -raw "$1"; }

HOSTNAME_PUBLIC="${1:-}"
shift || true

with_rate=false
TARGET=""
for arg in "$@"; do
  case "$arg" in
    --rate) with_rate=true ;;
    *) TARGET="$arg" ;;
  esac
done

if [[ -z "$HOSTNAME_PUBLIC" ]]; then
  echo "Aufruf: $0 <öffentlicher-name> [user@host] [--rate]" >&2
  exit 64
fi

EDGE_IP="$(tf lan_ip)"
PORT="$(terraform -chdir="$MODULE_DIR" output -raw public_https_port 2>/dev/null || echo 443)"
TARGET="${TARGET:-$(tf ssh_target)}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET")
RESOLVE=(--resolve "$HOSTNAME_PUBLIC:$PORT:$EDGE_IP")

fail=0
info() { printf '\n\033[1m%s\033[0m\n' "$*"; }
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
flunk() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=1; }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$*"; }

# ---------------------------------------------------------------------
info "1/6  Host-Whitelist (Stufe 4)"

# sniStrict ohne defaultCertificate: Für einen Namen ohne Zertifikat gibt es
# keinen Handshake - Scanner bekommen keine Fehlerseite, aus der sich ableiten
# ließe, was hier läuft.
handshake() {
  local sni="$1" out
  if [[ "$sni" == "-" ]]; then
    out="$(echo | timeout 10 openssl s_client -connect "$EDGE_IP:$PORT" -noservername 2>&1 || true)"
  else
    out="$(echo | timeout 10 openssl s_client -connect "$EDGE_IP:$PORT" -servername "$sni" 2>&1 || true)"
  fi
  grep -q 'subject=' <<<"$out" && echo served || echo refused
}

[[ "$(handshake "$HOSTNAME_PUBLIC")" == "served" ]] \
  && pass "$HOSTNAME_PUBLIC bekommt ein Zertifikat" \
  || flunk "$HOSTNAME_PUBLIC bekommt kein Zertifikat - ACME abgeschlossen?"

[[ "$(handshake "scanner.invalid")" == "refused" ]] \
  && pass "fremder Hostname wird im Handshake abgewiesen" \
  || flunk "fremder Hostname bekommt ein Zertifikat - sniStrict prüfen"

[[ "$(handshake "-")" == "refused" ]] \
  && pass "direkter IP-Zugriff ohne SNI wird abgewiesen" \
  || flunk "direkter IP-Zugriff bekommt eine Antwort"

# ---------------------------------------------------------------------
info "2/6  TLS-Parameter (Stufe 3)"

tlsver="$(echo | timeout 10 openssl s_client -connect "$EDGE_IP:$PORT" -servername "$HOSTNAME_PUBLIC" 2>/dev/null | sed -n 's/^ *Protocol *: *//p' | head -1)"
case "$tlsver" in
  TLSv1.3|TLSv1.2) pass "ausgehandelt: $tlsver" ;;
  *) flunk "unerwartete TLS-Version: ${tlsver:-keine}" ;;
esac

if echo | timeout 10 openssl s_client -connect "$EDGE_IP:$PORT" -servername "$HOSTNAME_PUBLIC" -tls1_1 2>&1 | grep -q 'subject='; then
  flunk "TLS 1.1 wird angenommen"
else
  pass "TLS 1.1 wird abgelehnt"
fi

issuer="$(echo | timeout 10 openssl s_client -connect "$EDGE_IP:$PORT" -servername "$HOSTNAME_PUBLIC" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)"
[[ -n "$issuer" ]] && printf '        %s\n' "$issuer"

# ---------------------------------------------------------------------
info "3/6  Kopfzeilen-Hygiene (Stufe 6) - der wichtigste Test"

probe_path="/edge-proxy-test-$RANDOM$RANDOM"
forged="192.168.178.254"

curl -sk "${RESOLVE[@]}" -m 15 -o /dev/null \
  -H "X-Forwarded-For: $forged" \
  -H "X-Real-IP: $forged" \
  -H "Forwarded: for=$forged" \
  -H "CF-Connecting-IP: $forged" \
  "https://$HOSTNAME_PUBLIC:$PORT$probe_path" || true

sleep 2
logline="$("${SSH[@]}" "sudo grep -F '$probe_path' /var/log/traefik/access.log | tail -1" 2>/dev/null || true)"

if [[ -z "$logline" ]]; then
  flunk "kein Access-Log-Eintrag für $probe_path gefunden"
else
  client="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("ClientHost",""))' <<<"$logline" 2>/dev/null || true)"
  if [[ "$client" == "$forged" ]]; then
    flunk "im Log steht die gefälschte IP $forged - der Angreifer bestimmt seine eigene Bewertung"
  elif [[ -z "$client" ]]; then
    skip "ClientHost nicht aus dem Log lesbar - Zeile: ${logline:0:120}"
  else
    pass "im Log steht die echte Peer-IP ($client), nicht die gefälschte"
  fi

  # Gegenprobe: Der weitergereichte Wert darf die gefälschte IP nicht enthalten.
  if grep -q "$forged" <<<"$logline"; then
    flunk "die gefälschte IP taucht in der Logzeile auf - X-Forwarded-For wird angehängt statt überschrieben"
  else
    pass "die gefälschte IP kommt in der Logzeile nicht vor"
  fi
fi

# ---------------------------------------------------------------------
info "4/6  Antwort-Header"

headers="$(curl -sk "${RESOLVE[@]}" -m 15 -D- -o /dev/null "https://$HOSTNAME_PUBLIC:$PORT/" || true)"

hsts_count="$(grep -ci '^strict-transport-security' <<<"$headers" || true)"
case "$hsts_count" in
  1) pass "HSTS genau einmal gesetzt" ;;
  0) flunk "kein HSTS-Header" ;;
  *) flunk "HSTS $hsts_count-mal gesetzt - doppelte Header brechen Teile der Nextcloud-Oberfläche" ;;
esac

for h in x-frame-options content-security-policy x-content-type-options; do
  n="$(grep -ci "^$h" <<<"$headers" || true)"
  [[ "$n" -le 1 ]] || flunk "$h ist $n-mal gesetzt (Proxy und Anwendung liefern beide)"
done
pass "keine doppelten Sicherheits-Header"

# ---------------------------------------------------------------------
info "5/6  mTLS-Zertifikat und Erneuerung (Stufe 6)"

if "${SSH[@]}" test -f /etc/traefik/pki/edge-client.crt; then
  not_after="$("${SSH[@]}" "sudo openssl x509 -in /etc/traefik/pki/edge-client.crt -noout -enddate" | cut -d= -f2)"
  end_ts="$(date -d "$not_after" +%s 2>/dev/null || echo 0)"
  now_ts="$(date +%s)"
  hours=$(( (end_ts - now_ts) / 3600 ))

  if [[ "$end_ts" -eq 0 ]]; then
    skip "Ablaufdatum nicht lesbar: $not_after"
  elif [[ "$hours" -lt 0 ]]; then
    flunk "Client-Zertifikat ist abgelaufen - edge-mtls-bootstrap erneut ausführen"
  elif [[ "$hours" -gt 72 ]]; then
    flunk "Restlaufzeit $hours h - deutlich mehr als vorgesehen; kurze Laufzeit ersetzt hier den fehlenden Rückruf"
  else
    pass "Client-Zertifikat gültig, Restlaufzeit ${hours} h"
  fi

  if "${SSH[@]}" systemctl is-active --quiet edge-cert-renew.timer; then
    pass "edge-cert-renew.timer läuft"
    "${SSH[@]}" "systemctl list-timers edge-cert-renew.timer --no-pager --no-legend" | sed 's/^/        /'
  else
    flunk "edge-cert-renew.timer läuft nicht - das Zertifikat läuft in Stunden ab"
  fi
else
  skip "kein Client-Zertifikat - edge-mtls-bootstrap noch nicht gelaufen"
fi

# ---------------------------------------------------------------------
info "6/6  CrowdSec (Stufe 2 und 5)"

if "${SSH[@]}" systemctl is-active --quiet crowdsec.service; then
  pass "Agent läuft"
  "${SSH[@]}" "sudo cscli lapi status 2>&1 | tail -3" | sed 's/^/        /'
  "${SSH[@]}" "sudo cscli metrics show acquisition 2>/dev/null | head -12" | sed 's/^/        /' || true

  if "${SSH[@]}" systemctl is-active --quiet crowdsec-firewall-bouncer.service; then
    pass "Firewall-Bouncer ist scharf"
    printf '        \033[33mNotzugang prüfen:\033[0m virsh console %s auf dem Hypervisor\n' "$(tf vm_name)"
  else
    skip "Firewall-Bouncer aus (Beobachtungsmodus) - cscli alerts list auswerten, dann scharfschalten"
  fi
else
  skip "CrowdSec-Agent läuft nicht - edge-crowdsec-connect noch nicht gelaufen"
fi

# ---------------------------------------------------------------------
if [[ "$with_rate" == true ]]; then
  info "Zusatz  Rate Limiting (Stufe 6)"
  printf '        \033[33mAchtung:\033[0m erzeugt Last und ggf. CrowdSec-Alarme auf die eigene IP\n'

  codes=""
  for _ in $(seq 1 40); do
    codes+="$(curl -sk "${RESOLVE[@]}" -m 10 -o /dev/null -w '%{http_code} ' "https://$HOSTNAME_PUBLIC:$PORT/login" || true)"
  done

  if grep -q 429 <<<"$codes"; then
    pass "Login-Pfad greift ins Rate Limit (429)"
  else
    flunk "40 Anfragen auf /login ohne 429 - rate_limit_strict prüfen"
  fi
fi

echo
if [[ $fail -eq 0 ]]; then
  printf '\033[32mAlle Proben wie erwartet.\033[0m\n'
else
  printf '\033[31mMindestens eine Probe weicht ab.\033[0m\n'
fi
exit $fail
