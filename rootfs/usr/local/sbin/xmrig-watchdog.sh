#!/usr/bin/env bash
# XMRig pool watchdog: catches the "miner says accepted, pool credits nothing" failure.
#
# Every run (systemd timer, every 10 min):
#   1. Reads local accepted shares from the XMRig API (127.0.0.1:8080).
#   2. Reads this worker's last-share timestamp ("lts") from the SupportXMR API.
#   3. If the miner kept getting shares accepted locally but the pool has not
#      credited this worker for STALE_SECS, restart xmrig to force a fresh
#      pool connection. A cooldown stops restart loops.
#
# Exit is always 0: a watchdog must never break boot or spam failed units.
set -uo pipefail

CONFIG="${CONFIG:-/opt/xmrig/config.json}"
STATE_DIR="${STATE_DIR:-/var/lib/xmrig-watchdog}"
LOCAL_API="${LOCAL_API:-http://127.0.0.1:8080/2/summary}"
POOL_API="${POOL_API:-https://supportxmr.com/api/miner}"
STALE_SECS="${STALE_SECS:-1800}"      # pool silent for 30 min -> suspicious
MIN_UPTIME="${MIN_UPTIME:-1800}"      # give a fresh connection 30 min first
COOLDOWN="${COOLDOWN:-3600}"          # at most one restart per hour
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
NOW="${NOW:-$(date +%s)}"

log() { echo "xmrig-watchdog: $*"; }
mkdir -p "$STATE_DIR"

# Only judge a miner that is supposed to be running (thermal guard may pause it).
if ! $SYSTEMCTL is-active --quiet xmrig.service; then
  log "xmrig not active (paused or unconfigured), skipping"
  exit 0
fi

WALLET="$(jq -r '.pools[0].user // empty' "$CONFIG" 2>/dev/null)"
WORKER="$(jq -r '.pools[0].pass // "x"' "$CONFIG" 2>/dev/null)"
if [[ -z "$WALLET" || "$WALLET" == "__WALLET_PLACEHOLDER__" ]]; then
  log "no wallet configured, skipping"; exit 0
fi

# --- local side ---
summary="$(curl -fsS --max-time 5 "$LOCAL_API" 2>/dev/null)" || { log "local API unreachable, skipping"; exit 0; }
local_good="$(jq -r '.results.shares_good // 0' <<<"$summary")"
uptime="$(jq -r '.connection.uptime // 0' <<<"$summary")"

prev_file="$STATE_DIR/prev_shares"
prev_good="$(cat "$prev_file" 2>/dev/null || echo "$local_good")"
echo "$local_good" > "$prev_file"

# Counter resets when xmrig restarts; treat a drop as "no new shares this round".
new_shares=$(( local_good > prev_good ? local_good - prev_good : 0 ))

if (( uptime < MIN_UPTIME )); then
  log "pool connection only ${uptime}s old, waiting (local accepted: $local_good)"
  exit 0
fi

# --- pool side ---
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
