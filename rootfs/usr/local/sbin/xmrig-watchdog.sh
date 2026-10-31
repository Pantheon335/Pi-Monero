#!/usr/bin/env bash
# XMRig pool watchdog, run every 10 min by xmrig-watchdog.timer.
#
# Check 1, STALL: no new accepted shares for STALL_SECS. Covers "can't reach
#   the pool at all" (DNS block, firewall, pool down). Logs a warning with a
#   DNS hint; does not restart, because a restart can't fix the network.
# Check 2, MISMATCH: shares accepted locally, but the pool has not credited
#   this worker for STALE_SECS. Restarts xmrig to force a fresh connection,
#   at most once per COOLDOWN.
#
# Always exits 0: a watchdog must never break boot or spam failed units.
set -uo pipefail

CONFIG="${CONFIG:-/opt/xmrig/config.json}"
STATE_DIR="${STATE_DIR:-/var/lib/xmrig-watchdog}"
LOCAL_API="${LOCAL_API:-http://127.0.0.1:8080/2/summary}"
POOL_API="${POOL_API:-https://supportxmr.com/api/miner}"
STALL_SECS="${STALL_SECS:-1800}"      # no new local shares for 30 min -> warn
STALE_SECS="${STALE_SECS:-1800}"      # pool silent for 30 min -> suspicious
MIN_UPTIME="${MIN_UPTIME:-1800}"      # give a fresh connection 30 min first
COOLDOWN="${COOLDOWN:-3600}"          # at most one restart per hour
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
NOW="${NOW:-$(date +%s)}"

log() { echo "xmrig-watchdog: $*"; }
mkdir -p "$STATE_DIR"
progress_file="$STATE_DIR/last_progress"
prev_file="$STATE_DIR/prev_shares"

# Only judge a miner that is supposed to be running. While the thermal guard
# has it paused, reset the stall clock so resuming doesn't raise a false alarm.
if ! $SYSTEMCTL is-active --quiet xmrig.service; then
  echo "$NOW" > "$progress_file"
  log "xmrig not active (paused or stopped), skipping"
  exit 0
fi

WALLET="$(jq -r '.pools[0].user // empty' "$CONFIG" 2>/dev/null)"
WORKER="$(jq -r '.pools[0].pass // "x"' "$CONFIG" 2>/dev/null)"
POOL_HOST="$(jq -r '.pools[0].url // empty' "$CONFIG" 2>/dev/null | cut -d: -f1)"
if [[ -z "$WALLET" || "$WALLET" == "__WALLET_PLACEHOLDER__" ]]; then
  log "no wallet configured, skipping"; exit 0
fi

# --- local side ---
summary="$(curl -fsS --max-time 5 "$LOCAL_API" 2>/dev/null)" || { log "local API unreachable, skipping"; exit 0; }
local_good="$(jq -r '.results.shares_good // 0' <<<"$summary")"
uptime="$(jq -r '.connection.uptime // 0' <<<"$summary")"

prev_good="$(cat "$prev_file" 2>/dev/null || echo "$local_good")"
echo "$local_good" > "$prev_file"
# The counter resets when xmrig restarts; a drop counts as no new shares.
new_shares=$(( local_good > prev_good ? local_good - prev_good : 0 ))

[[ -f "$progress_file" ]] || echo "$NOW" > "$progress_file"
(( new_shares > 0 )) && echo "$NOW" > "$progress_file"
last_progress="$(cat "$progress_file")"
idle=$(( NOW - last_progress ))

# --- check 1: stall ---
if (( idle > STALL_SECS )); then
  hint=""
  ip="$(getent ahosts "$POOL_HOST" 2>/dev/null | awk 'NR==1{print $1}')"
  case "$ip" in
    "")               hint=" ($POOL_HOST does not resolve)" ;;
    0.0.0.0|::|127.*) hint=" ($POOL_HOST resolves to $ip: DNS is blocking the pool)" ;;
  esac
  log "STALL: no new accepted shares for ${idle}s, pool connection uptime ${uptime}s${hint}"
  exit 0
fi

if (( uptime < MIN_UPTIME )); then
  log "pool connection only ${uptime}s old, waiting (local accepted: $local_good)"
  exit 0
fi

# --- check 2: pool credit mismatch ---
pool="$(curl -fsS --max-time 15 "$POOL_API/$WALLET/stats/allWorkers" 2>/dev/null)" \
  || { log "pool API unreachable, skipping (no action on missing data)"; exit 0; }
lts="$(jq -r --arg w "$WORKER" '.[$w].lts // 0' <<<"$pool" 2>/dev/null || echo 0)"

if (( lts == 0 )); then
  pool_age="never"
  stale=1
else
  pool_age=$(( NOW - lts ))
  stale=$(( pool_age > STALE_SECS ? 1 : 0 ))
fi

log "worker=$WORKER local_accepted=$local_good (+$new_shares) pool_last_share_age=${pool_age}s"

if (( stale == 1 && new_shares > 0 )); then
  last_restart="$(cat "$STATE_DIR/last_restart" 2>/dev/null || echo 0)"
  if (( NOW - last_restart < COOLDOWN )); then
    log "MISMATCH but restarted $(( NOW - last_restart ))s ago, in cooldown"
    exit 0
  fi
  log "MISMATCH: miner accepted $new_shares new shares, pool silent ${pool_age}s -> restarting xmrig"
  echo "$NOW" > "$STATE_DIR/last_restart"
  count="$(cat "$STATE_DIR/restart_count" 2>/dev/null || echo 0)"
  echo $(( count + 1 )) > "$STATE_DIR/restart_count"
  echo 0 > "$prev_file"
  $SYSTEMCTL restart xmrig.service
else
  log "ok"
fi
exit 0
