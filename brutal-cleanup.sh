#!/usr/bin/env bash
# brutal-cleanup: quarterly zombie reaper. Deletes kernel brutal rules that
# are older than 90 days AND have never carried traffic (MEMBERS=0, SENT=0).
# Protected: KNOWN_CLIENTS are never deleted. Deletions are also removed
# from known.list so autolearn will not restore them.
set -u
PROTECTED=""  # e.g. PROTECTED="1.2.3.4"
KNOWN_FILE="/var/lib/brutal-autolearn/known.list"
LOG="/var/log/brutal-cleanup.log"
RETENTION_DAYS=90
RETENTION_SEC=$((RETENTION_DAYS*86400))
NOW="$(date +%s)"

log() { echo "$(date "+%F %T") $*" >> "$LOG"; }

[ -f "$KNOWN_FILE" ] || exit 0

brutalctl list 2>/dev/null | awk "NR>1 {print \$1, \$7, \$8}" | while read -r dest members sent; do
  [ -z "$dest" ] && continue
  ip="${dest%%/*}"
  len="${dest##*/}"
  # protected never expires
  for p in $PROTECTED; do [ "$ip" = "$p" ] && continue 2; done
  # only pure zombies: no members and zero traffic
  [ "$members" = "0" ] || continue
  case "$sent" in 0|0.0|0.00) ;; *) continue;; esac
  first="$(awk -v ip="$ip" "\$1==ip {print \$2; exit}" "$KNOWN_FILE" 2>/dev/null || true)"
  [ -z "$first" ] && continue
  age=$((NOW - first))
  if [ "$age" -ge "$RETENTION_SEC" ]; then
    if brutalctl del "$dest" >>"$LOG" 2>&1; then
      log "DEL ${dest} age_days=$((age/86400)) members=${members} sent=${sent}"
      sed -i "/^${ip} /d" "$KNOWN_FILE"
    else
      log "FAIL-DEL ${dest}"
    fi
  fi
done
