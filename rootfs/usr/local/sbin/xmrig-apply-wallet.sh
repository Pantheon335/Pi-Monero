#!/usr/bin/env bash
# First-boot (and every-boot) step: read the Monero wallet from a file the
# user drops on the boot partition, validate it, write it into config.json,
# and set the marker that unlocks xmrig.service. No wallet -> no mining.
set -euo pipefail

BOOT=/boot/firmware
WALLET_FILE="$BOOT/xmrig-wallet.txt"
WORKER_FILE="$BOOT/xmrig-worker.txt"
CONFIG=/opt/xmrig/config.json
MARKER_DIR=/var/lib/xmrig
MARKER="$MARKER_DIR/configured"

mkdir -p "$MARKER_DIR"

if [[ ! -f "$WALLET_FILE" ]]; then
  echo "No $WALLET_FILE found — mining stays disabled until you add one."
  rm -f "$MARKER"
  exit 0
fi

WALLET="$(tr -d '[:space:]' < "$WALLET_FILE")"

# Sanity check: Monero addresses start with 4 (standard/integrated) or 8
# (subaddress) and are 95-106 base58 characters long.
if [[ ! "$WALLET" =~ ^[48][0-9A-Za-z]{94,105}$ ]]; then
  echo "Wallet in $WALLET_FILE does not look like a Monero address — mining stays disabled."
  rm -f "$MARKER"
  exit 0
fi

WORKER="pi5"
if [[ -f "$WORKER_FILE" ]]; then
  W="$(tr -d '[:space:]' < "$WORKER_FILE")"
  [[ -n "$W" ]] && WORKER="$W"
fi

tmp="$(mktemp)"
jq --arg w "$WALLET" --arg p "$WORKER" \
  '.pools[0].user=$w | .pools[0].pass=$p' "$CONFIG" > "$tmp"
mv "$tmp" "$CONFIG"
chown xmrig:xmrig "$CONFIG"
chmod 640 "$CONFIG"

touch "$MARKER"
echo "Wallet applied (worker: $WORKER). Mining enabled."
