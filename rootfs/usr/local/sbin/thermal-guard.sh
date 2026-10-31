#!/usr/bin/env bash
# Thermal guard for XMRig on a Raspberry Pi.
#   >= STOP_AT      -> stop the miner
#   <= RESUME_AT    -> start it again
#   >= SHUTDOWN_AT  -> power the Pi off (last-resort protection)
# Fail-safe: if the temperature cannot be read 3 times in a row, the miner is
# stopped until readings come back below RESUME_AT.
set -uo pipefail

STOP_AT="${STOP_AT:-77}"
RESUME_AT="${RESUME_AT:-65}"
SHUTDOWN_AT="${SHUTDOWN_AT:-82}"
INTERVAL="${INTERVAL:-5}"
THERMAL_FILE="${THERMAL_FILE:-/sys/class/thermal/thermal_zone0/temp}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
SERVICE="xmrig.service"
MAX_FAILS=3

paused=0
fails=0
echo "thermal-guard: stop>=${STOP_AT} resume<=${RESUME_AT} shutdown>=${SHUTDOWN_AT} every ${INTERVAL}s"

# Prints whole degrees C. The kernel reports millidegrees, e.g. 54750.
read_temp() {
  local raw
  raw="$(cat "$THERMAL_FILE" 2>/dev/null)" || return 1
  [[ "$raw" =~ ^[0-9]+$ ]] || return 1
  echo $(( raw / 1000 ))
}

while true; do
  if ! t="$(read_temp)"; then
    fails=$(( fails + 1 ))
    echo "cannot read temperature from $THERMAL_FILE (${fails}/${MAX_FAILS})"
    if (( fails >= MAX_FAILS && paused == 0 )); then
      echo "no temperature readings: stopping miner for safety"
      $SYSTEMCTL stop "$SERVICE" || true
      paused=1
    fi
    sleep "$INTERVAL"
    continue
  fi
  fails=0

  if (( t >= SHUTDOWN_AT )); then
    echo "CRITICAL ${t}C >= ${SHUTDOWN_AT}C: stopping miner and powering off"
    $SYSTEMCTL stop "$SERVICE" || true
    sleep 2
    $SYSTEMCTL poweroff
    exit 0
  fi

  if (( paused == 0 )) && (( t >= STOP_AT )); then
    echo "${t}C >= ${STOP_AT}C: pausing miner"
    $SYSTEMCTL stop "$SERVICE" || true
    paused=1
  elif (( paused == 1 )) && (( t <= RESUME_AT )); then
    echo "${t}C <= ${RESUME_AT}C: resuming miner"
    $SYSTEMCTL start "$SERVICE" || true
    paused=0
  fi

  sleep "$INTERVAL"
done
