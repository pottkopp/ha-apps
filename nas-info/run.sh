#!/usr/bin/env bash
# NAS-Info: Belegung aller Netzwerk-Speicher des Supervisors an Core melden.
set -uo pipefail

SUP="http://supervisor"
CORE="http://supervisor/core/api"
AUTH="Authorization: Bearer ${SUPERVISOR_TOKEN}"
OPTIONS_FILE="${OPTIONS_FILE:-/data/options.json}"

humanize() {   # $1 = Bytes -> "wert|einheit"  (unter 0,5 eine Einheit kleiner)
  awk -v b="$1" 'BEGIN{
    n=split("B KB MB GB TB PB",u," "); v=b+0; i=1;
    while (i<n && (v/1024)>=0.5) { v=v/1024; i++ }
    s = (i==1) ? sprintf("%d",v) : sprintf("%.1f",v);
    sub(/\.0$/,"",s);
    printf "%s %s\n", s, u[i];
  }'
}

slugify() {
  printf '%s' "$1" | tr '[:upper:] ' '[:lower:]_' | tr -cd '[:lower:][:digit:]_'
}

post() {   # $1 entity_id, $2 state, $3 attributes-JSON
  local body resp
  if ! body=$(jq -cn --arg s "$2" --argjson a "$3" '{state:$s, attributes:$a}'); then
    echo "$1: Attribute-JSON ungültig: $3" >&2
    return 1
  fi
  resp=$(curl -s -m 20 -X POST -H "$AUTH" -H 'content-type: application/json' \
             -d "$body" "$CORE/states/$1")
  case "$resp" in
    *'"entity_id"'*) : ;;
    *) echo "$1 -> Core-Antwort: $(printf '%s' "$resp" | head -c 220)" >&2; return 1 ;;
  esac
}

OPTS=$(cat "$OPTIONS_FILE" 2>/dev/null || echo '{}')
INTERVAL=$(printf '%s' "$OPTS" | jq -r '.interval // 300')
FILTER=$(printf '%s' "$OPTS" | jq -rc '.mounts // []')

while :; do
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  MOUNTS=$(curl -s -m 20 -H "$AUTH" "$SUP/mounts" | jq -r \
    '.data.mounts[]? | select(.type=="cifs" or .type=="nfs")
     | [.name, .type, (.server//""), (.share//""), (.state//""), ((.read_only|tostring))]
     | @tsv')

  FOUND=0
  while IFS=$'\t' read -r NAME TYPE SERVER SHARE STATE RO; do
    [ -z "$NAME" ] && continue
    if [ "$FILTER" != "[]" ] && ! printf '%s' "$FILTER" | jq -e --arg n "$NAME" 'index($n)!=null' >/dev/null; then
      echo "$NAME: durch mount-Liste ausgeschlossen"; continue
    fi
    FOUND=$((FOUND+1))
    S=$(slugify "$NAME")
    if [ -z "$S" ]; then echo "$NAME: Slug leer, übersprungen" >&2; continue; fi
    ENC=$(jq -rn --arg n "$NAME" '$n|@uri')

    A_BASE=$(jq -cn --arg n "$NAME" --arg t "$TYPE" --arg s "$SERVER" --arg sh "$SHARE" \
              '{mount:$n, mount_type:$t, server:$s, share:$sh}')
    STATUS=$(jq -cn --argjson b "$A_BASE" --arg ro "$RO" --arg ts "$TS" \
              '$b + {read_only:$ro, last_check:$ts}')
    post "sensor.nas_info_${S}_status" "${STATE:-unbekannt}" "$STATUS"

    U=$(curl -s -m 120 -H "$AUTH" "$SUP/host/disks/$ENC/usage")
    TOTAL=$(printf '%s' "$U" | jq -r '.data.total_bytes // empty')
    USED=$(printf '%s' "$U"  | jq -r '.data.used_bytes // empty')

    if [ -z "$TOTAL" ] || [ "$TOTAL" = "0" ] || [ -z "$USED" ]; then
      echo "$NAME: keine Kapazitaetsdaten, Antwort: $(printf '%s' "$U" | head -c 200)" >&2
      for x in gesamt belegt frei auslastung; do
        post "sensor.nas_info_${S}_${x}" "unavailable" "$STATUS"
      done
      continue
    fi
    FREE=$((TOTAL-USED))

    for x in gesamt belegt frei; do
      case "$x" in gesamt) B=$TOTAL;; belegt) B=$USED;; frei) B=$FREE;; esac
      H=$(humanize "$B"); val=${H%%|*}; unit=${H##*|}
      attrs=$(jq -cn --argjson b "$A_BASE" --argjson bt "$TOTAL" --argjson bu "$USED" \
        --argjson bf "$FREE" --arg u "$unit" --arg ts "$TS" \
        '$b + {bytes_total:$bt, bytes_used:$bu, bytes_free:$bf,
               unit_of_measurement:$u, last_check:$ts}')
      post "sensor.nas_info_${S}_${x}" "$val" "$attrs"
    done

    PCT=$(awk -v u="$USED" -v t="$TOTAL" 'BEGIN{printf "%.1f", 100*u/t}')
    post "sensor.nas_info_${S}_auslastung" "$PCT" \
      "$(jq -cn --argjson b "$A_BASE" --arg ts "$TS" \
         '$b + {unit_of_measurement:"%", state_class:"measurement", last_check:$ts}')"
    echo "$NAME ($S): ${PCT}% belegt, $(humanize "$FREE")"
  done <<< "$MOUNTS"

  post "sensor.nas_info_speicher" "$FOUND" \
    "$(jq -cn --argjson f "$FILTER" --arg ts "$TS" --arg i "$INTERVAL" \
       '{interval:($i|tonumber), last_check:$ts, selected:$f}')"
  echo "Anzahl gefundener Netzwerkspeicher: $FOUND | nächster Durchlauf in ${INTERVAL}s"
  sleep "$INTERVAL"
done
