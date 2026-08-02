#!/usr/bin/env bash
#
# Fährt von der Edge-VM aus die Proben, die der Egress-Filter bestehen muss.
#
# Der Regelsatz behauptet: "Die Edge-VM erreicht ausschließlich eine IP und
# einen Port im Cluster - kein LAN, keine Shares, keine Unraid-Oberfläche."
# Dieses Skript belegt es, statt es zu glauben. Es gehört in die Abnahme und
# nach jeder Änderung an egress_open, egress_targets oder dns_servers.
#
# Unterschieden wird über die Zeit: Ein gesperrtes Ziel läuft in den Timeout
# (nftables verwirft still), ein erlaubtes Ziel antwortet sofort - entweder mit
# einer Verbindung oder mit "connection refused". "refused" ist deshalb kein
# Fehler, sondern der Beweis, dass das Paket die VM verlassen durfte.
#
# Aufruf:
#
#   vm/edge/verify/egress-test.sh [user@host]
#
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tf() { terraform -chdir="$MODULE_DIR" output -raw "$1"; }

TARGET="${1:-$(tf ssh_target)}"

ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" bash -s -- \
  "$(tf cluster_ingress_ip)" \
  "$(tf cluster_ingress_port)" \
  "$(tf crowdsec_lapi_port)" \
  "$(tf dns_server)" \
  "$(tf lan_gateway)" \
  "$(tf egress_open)" <<'REMOTE'
set -uo pipefail

ingress_ip="$1"
ingress_port="$2"
lapi_port="$3"
dns_server="$4"
lan_gateway="$5"
egress_open="$6"

fail=0

info() { printf '\n\033[1m%s\033[0m\n' "$*"; }
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
flunk() {
  printf '  \033[31mFAIL\033[0m  %s\n' "$*"
  fail=1
}

#
# open    - Verbindung steht
# refused - Paket durfte raus, dort lauscht nur nichts
# blocked - Timeout, also von nftables verworfen
#
probe() {
  if timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; then
    echo open
  elif [ $? -eq 124 ]; then
    echo blocked
  else
    echo refused
  fi
}

expect_reachable() {
  local host="$1" port="$2" what="$3" r
  r="$(probe "$host" "$port")"
  case "$r" in
    open|refused) pass "$what ($host:$port -> $r)" ;;
    *) flunk "$what ($host:$port -> $r) - der Regelsatz sperrt ein Ziel, das gebraucht wird" ;;
  esac
}

expect_blocked() {
  local host="$1" port="$2" what="$3" r
  r="$(probe "$host" "$port")"
  case "$r" in
    blocked) pass "$what ($host:$port -> blocked)" ;;
    *) flunk "$what ($host:$port -> $r) - hier kommt die Edge-VM hin, obwohl sie es nicht dürfte" ;;
  esac
}

# ---------------------------------------------------------------------
info "1/4  Erlaubt: der Weg in den Cluster"

expect_reachable "$ingress_ip" "$ingress_port" "ingress-public"
expect_reachable "$ingress_ip" "$lapi_port" "CrowdSec-LAPI"
expect_reachable "$dns_server" 53 "interner Resolver (TCP)"

if getent hosts deb.debian.org >/dev/null 2>&1; then
  pass "Namensauflösung funktioniert"
else
  flunk "Namensauflösung schlägt fehl - ohne DNS keine ACME-Erneuerung"
fi

# ---------------------------------------------------------------------
info "2/4  Gesperrt: das Heimnetz"

expect_blocked "$lan_gateway" 443 "Gateway-Weboberfläche"
expect_blocked "$lan_gateway" 80 "Gateway HTTP"
expect_blocked "$lan_gateway" 22 "Gateway SSH"

# Derselbe Host, der als Resolver erlaubt ist, darf auf jedem anderen Port
# gesperrt sein - sonst wäre die Freigabe hostweit statt portweit.
expect_blocked "$dns_server" 22 "Resolver-Host auf einem anderen Port"

if ! command -v ping >/dev/null 2>&1; then
  printf '  \033[33mSKIP\033[0m  ICMP-Probe: ping nicht installiert\n'
elif timeout 3 ping -c 1 -W 2 "$lan_gateway" >/dev/null 2>&1; then
  flunk "ICMP ins Heimnetz kommt durch - die Egress-Regel greift nicht"
else
  pass "ICMP ins Heimnetz gesperrt"
fi

# ---------------------------------------------------------------------
info "3/4  Gesperrt: DNS nach draußen"

# Der Kanal, den der Filter nicht schließen kann, ist DNS zum internen Resolver.
# Ein zweiter Resolver im Internet wäre genau der Umweg daran vorbei.
expect_blocked 8.8.8.8 53 "öffentlicher Resolver"

# ---------------------------------------------------------------------
info "4/4  Internet"

if [ "$egress_open" = "true" ]; then
  expect_reachable 1.1.1.1 443 "HTTPS ins Internet (Bootstrap-Zustand)"
  printf '  \033[33mHINWEIS\033[0m egress_open = true: ausgehend ist noch jedes öffentliche Ziel erlaubt.\n'
  printf '          Counter lesen und dann zuschnüren:  sudo nft list table inet edge\n'
else
  expect_blocked 1.1.1.1 443 "beliebiges Ziel außerhalb von egress_targets"
fi

echo
if [ $fail -eq 0 ]; then
  printf '\033[32mAlle Proben wie erwartet.\033[0m\n'
else
  printf '\033[31mMindestens eine Probe weicht ab - Regelsatz prüfen.\033[0m\n'
fi
exit $fail
REMOTE
