#!/usr/bin/env bash
# NAS-Info 2.x: Netzwerk-Speicher des Supervisors per MQTT-Entdeckung als Geräte.
set -uo pipefail

SUP="http://supervisor"
CORE="http://supervisor/core/api"
AUTH="Authorization: Bearer ${SUPERVISOR_TOKEN}"
OPTIONS_FILE="${OPTIONS_FILE:-/data/options.json}"
PREFIX="nas_info"
ORIGIN_URL="https://github.com/pottkopp/ha-apps"
STATE_DIR="/data/state"
UNITFILE="$STATE_DIR/units"
mkdir -p "$STATE_DIR"

OPTS=$(cat "$OPTIONS_FILE" 2>/dev/null || echo '{}')
INTERVAL=$(printf '%s' "$OPTS" | jq -r '.interval // 300')
FILTER=$(printf '%s' "$OPTS" | jq -rc '.mounts // []')
MQ_HOST=$(printf '%s' "$OPTS" | jq -r '.mqtt_host // "core-mosquitto"')
MQ_PORT=$(printf '%s' "$OPTS" | jq -r '.mqtt_port // 1883')
MQ_USER=$(printf '%s' "$OPTS" | jq -r '.mqtt_user // ""')
MQ_PASS=$(printf '%s' "$OPTS" | jq -r '.mqtt_password // ""')

mq() {  # $1 topic, $2 payload, $3 "retain"
  local args=(-h "$MQ_HOST" -p "$MQ_PORT" -q 1 -t "$1" -m "$2")
  [ "${3:-}" = "retain" ] && args+=(-r)
  [ -n "$MQ_USER" ] && args+=(-u "$MQ_USER" -P "$MQ_PASS")
  if ! mosquitto_pub "${args[@]}" 2>/dev/null; then
    echo "MQTT senden $1" >&2
    return 1
  fi
}

num_of() {
  awk -v b="$1" 'BEGIN{ n=split("B KB MB GB TB PB",u," "); v=b+0; i=1;
    while (i<n && (v/1024)>=0.5){ v=v/1024; i++ }
    s=(i==1)?sprintf("%d",v):sprintf("%.1f",v); sub(/\.0$/,"",s); print s }'
}
unit_of() {
  awk -v b="$1" 'BEGIN{ n=split("B KB MB GB TB PB",u," "); v=b+0; i=1;
    while (i<n && (v/1024)>=0.5){ v=v/1024; i++ } print u[i] }'
}

slugify() { printf '%s' "$1" | tr '[:upper:] ' '[:lower:]_' | tr -cd '[:lower:][:digit:]_'; }

unit_changed() {  # $1 uniq_id $2 unit ; 0 = geaendert
  local cur
  cur=$(awk -F'|' -v k="$1" '$1==k{print $2}' "$UNITFILE" 2>/dev/null)
  if [ "$cur" != "$2" ]; then
    { grep -v "^$1|" "$UNITFILE" 2>/dev/null; printf '%s|%s\n' "$1" "$2"; } > "$UNITFILE.tmp"
    mv "$UNITFILE.tmp" "$UNITFILE"
    return 0
  fi
  return 1
}

cfg() {  # $1 slug $2 geraetename $3 kind $4 anzeigename $5 einheit $6 icon $7 kategorie $8 device_class $9 attr-topic
  jq -cn \
    --arg uniq "nas_info_$1_$3" --arg obj "sensor.nas_info_$1_$3" --arg name "$4" \
    --arg stat "$PREFIX/$1/$3" --arg avail "$PREFIX/availability" --arg dev "nas_info_$1" \
    --arg devname "$2" --arg unit "$5" --arg icon "$6" --arg cat "$7" --arg dcl "$8" \
    --arg jattr "$9" --arg ourl "$ORIGIN_URL" '
    { component:"sensor", name:$name, uniq_id:$uniq, obj_id:$obj, stat_t:$stat, avty_t:$avail,
      dev:{ids:$dev, name:$devname},
      origin:{name:"NAS-Info", url:$ourl, support:"local"} }
    + (if $unit==""  then {} else {unit_of_measurement:$unit} end)
    + (if $icon==""  then {} else {icon:$icon} end)
    + (if $cat==""   then {} else {entity_category:$cat} end)
    + (if $dcl==""   then {} else {device_class:$dcl} end)
    + (if $jattr=="" then {} else {json_attr_t:$jattr} end)'
}

publish() {  # $1 slug $2 geraetename $3 kind $4 anzeigename $5 wert $6 einheit $7 icon $8 kat $9 dcl $10 attrtopic
  local uniq="nas_info_$1_$3"
  if [ -n "$6" ] && unit_changed "$uniq" "$6"; then
    mq "homeassistant/sensor/$uniq/config" "$(cfg "$1" "$2" "$3" "$4" "$6" "$7" "$8" "$9" "${10:-}")" retain
  elif [ ! -f "$STATE_DIR/seen_$uniq" ]; then
    mq "homeassistant/sensor/$uniq/config" "$(cfg "$1" "$2" "$3" "$4" "$6" "$7" "$8" "$9" "${10:-}")" retain
  fi
  : > "$STATE_DIR/seen_$uniq"
  mq "$PREFIX/$1/$3" "$5" retain
}

trap 'mq "$PREFIX/availability" offline retain; echo "beendet"' EXIT INT TERM
mq "$PREFIX/availability" online retain

while :; do
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  MOUNTS=$(curl -s -m 20 -H "$AUTH" "$SUP/mounts" | jq -r \
    '.data.mounts[]? | select(.type=="cifs" or .type=="nfs")
     | [.name, .type, (.server//""), (.share//""), (.state//""), ((.read_only|tostring))] | @tsv')

  FOUND=0
  while IFS=$'\t' read -r NAME TYPE SERVER SHARE STATE RO; do
    [ -z "$NAME" ] && continue
    if [ "$FILTER" != "[]" ] && ! printf '%s' "$FILTER" | jq -e --arg n "$NAME" 'index($n)!=null' >/dev/null; then
      echo "$NAME: per Optionsliste ausgeschlossen"; continue
    fi
    FOUND=$((FOUND+1))
    S=$(slugify "$NAME")
    [ -z "$S" ] && { echo "$NAME: leerer Slug, übersprungen" >&2; continue; }
    ENC=$(jq -rn --arg n "$NAME" '$n|@uri')

    # Altlasten der States-API aufraeumen (States loeschen, Verlauf bleibt am gleichem ID haengen)
    if [ ! -f "$STATE_DIR/legacy_cleaned" ]; then
      for x in gesamt belegt frei auslastung status; do
        curl -s -m 10 -X DELETE -H "$AUTH" "$CORE/states/sensor.nas_info_${S}_${x}" >/dev/null
      done
    fi

    ATTRS=$(jq -cn --arg n "$NAME" --arg t "$TYPE" --arg s "$SERVER" --arg sh "$SHARE" \
      --arg ro "$RO" --arg ts "$TS" \
      '{mount:$n, mount_type:$t, server:$s, share:$sh, read_only:($ro=="true"), last_check:$ts}')
    mq "$PREFIX/$S/attrs" "$ATTRS" retain

    publish "$S" "$NAME" status   "Status"          "${STATE:-unbekannt}" "" "" "mdi:lan-connect" "diagnostic" "" "$PREFIX/$S/attrs"
    publish "$S" "$NAME" zuletzt  "Zuletzt geprüft" "$TS" "" "" "mdi:clock-check" "diagnostic" "timestamp" "$PREFIX/$S/attrs"

    U=$(curl -s -m 120 -H "$AUTH" "$SUP/host/disks/$ENC/usage")
    TOTAL=$(printf '%s' "$U" | jq -r '.data.total_bytes // empty')
    USED=$(printf '%s' "$U"  | jq -r '.data.used_bytes // empty')

    if [ -z "$TOTAL" ] || [ "$TOTAL" = "0" ] || [ -z "$USED" ]; then
      echo "$NAME: keine Kapazitätsdaten: $(printf '%s' "$U" | head -c 200)" >&2
      for x in gesamt belegt frei auslastung; do
        publish "$S" "$NAME" "$x" "$x" "unavailable" "" "" "mdi:harddisk" "" "" "$PREFIX/$S/attrs"
      done
      continue
    fi
    FREE=$((TOTAL-USED))

    for x in gesamt belegt frei; do
      case "$x" in gesamt) B=$TOTAL;; belegt) B=$USED;; frei) B=$FREE;; esac
      publish "$S" "$NAME" "$x" "$x" "$(num_of "$B")" "$(unit_of "$B")" "" "mdi:harddisk" "" "" "$PREFIX/$S/attrs"
    done
    PCT=$(awk -v u="$USED" -v t="$TOTAL" 'BEGIN{printf "%.1f", 100*u/t}')
    publish "$S" "$NAME" auslastung "Auslastung" "$PCT" "%" "" "mdi:percent" "" "measurement" "$PREFIX/$S/attrs"

    echo "$NAME: ${PCT}% belegt, $(num_of "$FREE") $(unit_of "$FREE") frei"
  done <<< "$MOUNTS"

  [ -f "$STATE_DIR/legacy_cleaned" ] || : > "$STATE_DIR/legacy_cleaned"

  mq "$PREFIX/hub/attrs" "$(jq -cn --arg ts "$TS" --argjson i "$INTERVAL" --argjson f "$FILTER" \
      '{last_check:$ts, interval:$i, selected:$f}')" retain
  publish hub "NAS-Info" speicher "Netzwerkspeicher" "$FOUND" "" "Stück" "mdi:server-network" "" "" "$PREFIX/hub/attrs"
  publish hub "NAS-Info" zuletzt "Zuletzt geprüft" "$TS" "" "" "mdi:clock-check" "diagnostic" "timestamp" "$PREFIX/hub/attrs"

  echo "Netzwerkspeicher gefunden: $FOUND | nächstes Update in ${INTERVAL}s"
  sleep "$INTERVAL"
done
