#!/usr/bin/env bash
# Thermal guard for XMRig on a Raspberry Pi.
#   >= STOP_AT      -> stop the miner
#   <= RESUME_AT    -> start it again
#   >= SHUTDOWN_AT  -> power the Pi off (last-resort protection)
set -euo pipefail

STOP_AT="${STOP_AT:-77}"
RESUME_AT="${RESUME_AT:-65}"
SHUTDOWN_AT="${SHUTDOWN_AT:-82}"
INTERVAL="${INTERVAL:-5}"
SERVICE="xmrig.service"

paused=0
echo "thermal-guard: stop>=${STOP_AT} resume<=${RESUME_AT} shutdown>=${SHUTDOWN_AT} every ${INTERVAL}s"

while true; do
  # vcgencmd prints e.g. temp=54.7'C
  temp="$(vcgencmd measure_temp | grep -oE '[0-9]+\.[0-9]+' || echo 0)"
  t="${temp%.*}"   # integer part

  if (( t >= SHUTDOWN_AT )); then
    echo "CRITICAL ${temp}C >= ${SHUTDOWN_AT}C: stopping miner and powering off"
    systemctl stop "$SERVICE" || true
    sleep 2
    systemctl poweroff
    exit 0
  fi

  if (( paused == 0 )) && (( t >= STOP_AT )); then
    echo "${temp}C >= ${STOP_AT}C: pausing miner"
    systemctl stop "$SERVICE" || true
    paused=1
  elif (( paused == 1 )) && (( t <= RESUME_AT )); then
    echo "${temp}C <= ${RESUME_AT}C: resuming miner"
    systemctl start "$SERVICE" || true
    paused=0
  fi

  sleep "$INTERVAL"
done
