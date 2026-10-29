#!/usr/bin/env bash
# NAS-Info: Belegung aller Netzwerk-Speicher des Supervisors an Core melden.
set -uo pipefail

SUP="http://supervisor"
CORE="http://supervisor/core/api"
AUTH="Authorization: Bearer ${SUPERVISOR_TOKEN}"
UNITS=(B KB MB GB TB PB)

humanize() {   # $1 = Bytes -> "wert|einheit", nächstkleinere Einheit unter 0.5
  awk -v b="$1" 'BEGIN{
    n=split("B KB MB GB TB PB",u," "); v=b+0; i=1;
    while (i<n && (v/1024)>=0.5) { v=v/1024; i++ }
    s = (i==1) ? sprintf("%d",v) : sprintf("%.1f",v);
    sub(/\.0$/,"",s);
    printf "%s|%s\n", s, u[i];
  }'
}

slugify() {
  printf '%s' "$1" | tr 'A-Z ' 'a-z_' | tr -cs 'a-z0-9_' ''
}

post() {   # $1 entity_id, $2 state, $3 attributes-JSON
  local body
  body=$(jq -cn --arg s "$2" --argjson a "$3" '{state:$s, attributes:$a}')
  if ! curl -s -m 20 -X POST -H "$AUTH" -H 'content-type: application/json' \
        -d "$body" "$CORE/states/$1" | grep -q '"entity_id"'; then
    echo "Fehler beim Schreiben von $1" >&2
  fi
}

INTERVAL=$(jq -r '.interval // 300' /data/options.json)
FILTER=$(jq -rc '.mounts // []' /data/options.json)

while :; do
  START=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  MOUNTS=$(curl -s -m 20 -H "$AUTH" "$SUP/mounts" \
    | jq -r '.data.mounts[]? | select(.type=="cifs" or .type=="nfs") | [.name,.type,(.server//""),(.share//""),.state,(.read_only|tostring)] | join("\u001f")')

  FOUND=0
  while IFS=$'\037' read -r NAME TYPE SERVER SHARE STATE RO; do
    [ -z "$NAME" ] && continue
    if [ "$FILTER" != "[]" ] && ! printf '%s' "$FILTER" | jq -e --arg n "$NAME" 'index($n) != null' >/dev/null; then
      echo "$NAME gefiltert, übersprungen"; continue
    fi
    FOUND=$((FOUND+1))
    S=$(slugify "$NAME")
    ENC=$(jq -rn --arg n "$NAME" '$n|@uri')

    U=$(curl -s -m 120 -H "$AUTH" "$SUP/host/disks/$ENC/usage")
    TOTAL=$(printf '%s' "$U" | jq -r '.data.total_bytes // empty')
    USED=$(printf '%s' "$U" | jq -r '.data.used_bytes // empty')

    A_BASE=$(jq -cn --arg n "$NAME" --arg t "$TYPE" --arg s "$SERVER" --arg sh "$SHARE" \
      '{mount:$n, mount_type:$t, server:$s, share:$sh}')

    post "sensor.nas_info_${S}_status" "$STATE" \
      "$(jq -cn --argjson b "$A_BASE" --arg ro "$RO" --arg ts "$START" \
         '$b + {read_only:$ro, last_check:$ts}')"

    if [ -z "$TOTAL" ] || [ "$TOTAL" = "0" ]; then
      echo "keine Kapazitätsdaten für $NAME: $(printf '%s' "$U" | head -c 200)" >&2
      for x in gesamt belegt frei auslastung; do
        post "sensor.nas_info_${S}_${x}" "unavailable" "$A_BASE"
      done
      continue
    fi
    FREE=$((TOTAL-USED))

    declare -A H
    for k in t:TOTAL u:USED f:FREE; do :; done
    H[gesamt]=$(humanize "$TOTAL"); H[belegt]=$(humanize "$USED"); H[frei]=$(humanize "$FREE")

    GB_T=$(awk -v b="$TOTAL" 'BEGIN{printf "%.2f", b/1073741824}')
    GB_U=$(awk -v b="$USED"  'BEGIN{printf "%.2f", b/1073741824}')
    GB_F=$(awk -v b="$FREE"  'BEGIN{printf "%.2f", b/1073741824}')
    PCT=$(awk -v u="$USED" -v t="$TOTAL" 'BEGIN{printf "%.1f", 100*u/t}')

    for x in gesamt belegt frei; do
      val=${H[$x]%%|*}; unit=${H[$x]##*|}
      attrs=$(jq -cn --argjson b "$A_BASE" --argjson bt "$TOTAL" --argjson bu "$USED" \
        --argjson bf "$FREE" --arg gt "$GB_T" --arg gu "$GB_U" --arg gf "$GB_F" \
        --arg u "$unit" --arg ts "$START" \
        '$b + {bytes_total:$bt, bytes_used:$bu, bytes_free:$bf,
               gb_total:($gt|tonumber), gb_used:($gu|tonumber), gb_free:($gf|tonumber),
               unit_of_measurement:$u, last_check:$ts}')
      post "sensor.nas_info_${S}_${x}" "$val" "$attrs"
    done

    post "sensor.nas_info_${S}_auslastung" "$PCT" \
      "$(jq -cn --argjson b "$A_BASE" --arg ts "$START" \
         '$b + {unit_of_measurement:"%", state_class:"measurement", last_check:$ts}')"
  done <<< "$MOUNTS"

  post "sensor.nas_info_speicher" "$FOUND" \
    "$(jq -cn --argjson f "$FILTER" --arg ts "$START" --arg i "$INTERVAL" \
       '{unit_of_measurement:"Stueck", interval:($i|tonumber), last_check:$ts, selected:$f}')"

  echo "lauf $FOUND(e) Speicher, nächster Durchlauf in ${INTERVAL}s"
  sleep "$INTERVAL"
done
