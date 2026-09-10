#!/usr/bin/env bash
# brutal-autolearn: auto-add tcp-brutal v2 rules for TCP proxy clients.
# Covered (auto mode): all local listening TCP ports, e.g. sing-box naive h2
# (3306) + anytls (8443), xray VLESS+xhttp (443 reality, 8964). New proxy
# ports are picked up without editing. Outbound connections are never
# learned: their local side is an ephemeral port, not a listener.
# Hysteria2/TUIC/hysteria are UDP/QUIC (own app-level control) and out of scope.
set -u
# "auto" = follow all local listening TCP ports (recommended). Or pin a list,
# e.g. PORTS="3306 443 8443 8964".
PORTS="auto"
DEFAULT_RATE_MBPS="100"
GAIN="20"
# Known client IPs: rules are ensured on every run, even before they
# connect, so reconnects get brutal from the very first SYN.
KNOWN_CLIENTS=""  # e.g. KNOWN_CLIENTS="1.2.3.4 5.6.7.8"
LOG="/var/log/brutal-autolearn.log"
STATE_DIR="/var/lib/brutal-autolearn"
KNOWN_FILE="${STATE_DIR}/known.list"
LAST_SEEN="${STATE_DIR}/last_candidates"
mkdir -p "$STATE_DIR" 2>/dev/null
touch "$KNOWN_FILE" 2>/dev/null

log() { echo "$(date "+%F %T") $*" >> "$LOG"; }

remember_ip() {
  local ip="$1" now
  [ -z "$ip" ] && return 0
  grep -q "^${ip} " "$KNOWN_FILE" 2>/dev/null && return 0
  now="$(date +%s)"
  echo "${ip} ${now}" >> "$KNOWN_FILE"
}

have_rules="$(brutalctl list 2>/dev/null | awk "NR>1 {print \$1}" | cut -d/ -f1 || true)"

is_private() {
  case "$1" in
    127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|::1|fe80:*|fc00:*|fd00:*|"") return 0;;
    *) return 1;;
  esac
}

# Strip port from a peer endpoint, keeping IPv6 intact (pure bash, no sed):
#   1.2.3.4:5678 -> 1.2.3.4
#   [1.2.3.4]:5678 -> 1.2.3.4
#   [2001:db8::1]:5678 -> 2001:db8::1
endpoint_to_ip() {
  local ep="$1" ip
  case "$ep" in
    \[*\]:*) ip="${ep#[}"; ip="${ip%%]:*}" ;;
    \[*\]) ip="${ep#[}"; ip="${ip%]}" ;;
    *.*:*) ip="${ep%:*}" ;;
    *) ip="$ep" ;;
  esac
  case "$ip" in
    ::ffff:*) ip="${ip#::ffff:}" ;;
  esac
  echo "$ip"
}

ensure_rule() {
  local ip="$1" src="$2" pfx
  [ -z "$ip" ] && return 0
  # dual-stack listener shows IPv4 clients as ::ffff:a.b.c.d;
  # traffic routes via the IPv4 table, so normalize to plain IPv4.
  case "$ip" in
    ::ffff:*) ip="${ip#::ffff:}" ;;
  esac
  # must be an IPv4 or IPv6 address, never a bare port number
  if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && ! [[ "$ip" == *:* ]]; then
    return 0
  fi
  is_private "$ip" && return 0
  if [[ "$ip" == *:* ]]; then pfx="${ip}/128"; else pfx="${ip}/32"; fi
  if ! grep -qxF "$ip" <<< "$have_rules"; then
    if brutalctl add "$pfx" "$DEFAULT_RATE_MBPS" "gain=${GAIN}" >>"$LOG" 2>&1; then
      log "ADD ${pfx} ${DEFAULT_RATE_MBPS}Mbps (${src})"
      have_rules="${have_rules}
${ip}"
      remember_ip "$ip"
    else
      log "FAIL ${pfx}"
    fi
  else
    # already has kernel rule (e.g. after reboot restore gap): make sure it is persisted
    remember_ip "$ip"
  fi
}

for ip in $KNOWN_CLIENTS; do
  ensure_rule "$ip" "known"
done

# Persistence: re-ensure all previously learned IPs so reconnects get brutal
# from the very first SYN, even after a reboot wiped the kernel table.
if [ -s "$KNOWN_FILE" ]; then
  while read -r ip _rest; do
    [ -z "$ip" ] && continue
    case "$ip" in \#*) continue;; esac
    ensure_rule "$ip" "restore"
  done < "$KNOWN_FILE"
fi

# Self-learning (behavior gate): only the SAME SOCKET still connected on the
# NEXT poll (~10s later) earns a rule. Scanners fail auth in milliseconds and
# churn source ports, so the same IP:port is never seen twice. Genuine proxy
# sessions (naive h2, xray VLESS) hold one TCP for minutes and pass.
# KNOWN_CLIENTS / known.list above bypass this gate.
# Port scope: in "auto" mode every local LISTENING port is watched, so new
# proxy inbounds are covered with zero config; outbound connections can never
# match (their local port is ephemeral, never a listener).
if [ "$PORTS" = "auto" ]; then
  EFFECTIVE_PORTS="$(ss -tlnH 2>/dev/null | awk '{print $4}' | sed -e 's/.*://' | grep -E '^[0-9]+$' | sort -u | tr '\n' ' ')"
else
  EFFECTIVE_PORTS="$PORTS"
fi
CUR_SEEN="$(mktemp)"
for port in $EFFECTIVE_PORTS; do
  # $3 = local, $4 = peer ("1.2.3.4:5678", "[2001:db8::1]:5678",
  # "[::ffff:1.2.3.4]:5678"). Keep the FULL endpoint as the key so rapid
  # reconnects from the same IP with different ports do NOT match.
  ss -tn state established 2>/dev/null \
    | awk -v p=":${port}" '$3 ~ p"$" {print $4}' \
    | sed -e "s/::ffff://g" \
    | sort -u \
    | while read -r ep; do
      [ -z "$ep" ] && continue
      ip="$(endpoint_to_ip "$ep")"
      if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$ip" == *:* ]]; then
        is_private "$ip" || echo "$ep"
      fi
    done
done | sort -u > "$CUR_SEEN"

if [ -s "$LAST_SEEN" ]; then
  comm -12 "$LAST_SEEN" "$CUR_SEEN" | while read -r ep; do
    [ -z "$ep" ] && continue
    ip="$(endpoint_to_ip "$ep")"
    ensure_rule "$ip" "learned"
  done
fi
mv "$CUR_SEEN" "$LAST_SEEN"
