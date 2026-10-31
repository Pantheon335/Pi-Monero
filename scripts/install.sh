#!/usr/bin/env bash
# Install (or update) XMRig with the thermal guard and pool watchdog on a
# Raspberry Pi running Raspberry Pi OS. Safe to re-run: a re-run rebuilds
# XMRig and reinstalls all files, keeping a backup of the old config.
#
# Usage:  sudo ./scripts/install.sh <MONERO_WALLET_ADDRESS> [WORKER_NAME]
# Env:    XMRIG_VERSION=v6.26.0   DISABLE_DONATION=true
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
XMRIG_VERSION="${XMRIG_VERSION:-v6.26.0}"
DISABLE_DONATION="${DISABLE_DONATION:-true}"
SRC=/usr/local/src/xmrig
WALLET="${1:-}"
WORKER="${2:-pi5}"

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -n "$WALLET" ]] || die "usage: sudo $0 <MONERO_WALLET_ADDRESS> [WORKER_NAME]"
# Monero addresses start with 4 (standard/integrated) or 8 (subaddress)
# and are 95-106 base58 characters long.
[[ "$WALLET" =~ ^[48][1-9A-HJ-NP-Za-km-z]{94,105}$ ]] || die "that does not look like a Monero address"
[[ "$WORKER" =~ ^[A-Za-z0-9._-]{1,32}$ ]] || die "worker name: letters, digits, . _ - only (max 32)"

step "Installing packages"
apt-get update
apt-get install -y --no-install-recommends \
  git build-essential cmake libuv1-dev libssl-dev libhwloc-dev \
  jq curl ca-certificates

step "Checking that the pool resolves (catches DNS blocking early)"
POOL_HOST="$(jq -r '.pools[0].url' "$REPO/rootfs/opt/xmrig/config.json" | cut -d: -f1)"
POOL_IP="$(getent ahosts "$POOL_HOST" 2>/dev/null | awk 'NR==1{print $1}' || true)"
case "$POOL_IP" in
  "")              echo "    WARNING: $POOL_HOST does not resolve. Check DNS before expecting shares." ;;
  0.0.0.0|::|127.*) echo "    WARNING: $POOL_HOST resolves to $POOL_IP: this network's DNS blocks the pool." ;;
  *)               echo "    ok: $POOL_HOST -> $POOL_IP" ;;
esac

step "Fetching XMRig $XMRIG_VERSION"
rm -rf "$SRC"
git clone --depth 1 --branch "$XMRIG_VERSION" https://github.com/xmrig/xmrig.git "$SRC"

if [[ "$DISABLE_DONATION" == "true" ]]; then
  step "Patching donate level to 0%"
  sed -i \
    -e 's/kDefaultDonateLevel = [0-9]\+/kDefaultDonateLevel = 0/' \
    -e 's/kMinimumDonateLevel = [0-9]\+/kMinimumDonateLevel = 0/' \
    "$SRC/src/donate.h"
  grep DonateLevel "$SRC/src/donate.h"
fi

step "Building (about 10 minutes on a Pi 5)"
mkdir -p "$SRC/build"
cmake -S "$SRC" -B "$SRC/build" -DWITH_HWLOC=ON
make -C "$SRC/build" -j"$(nproc)"

step "Creating the xmrig service user"
id xmrig &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin xmrig

step "Installing files"
systemctl stop xmrig.service thermal-guard.service 2>/dev/null || true
install -d -m 755 /opt/xmrig
install -m 755 "$SRC/build/xmrig" /opt/xmrig/xmrig

if [[ -f /opt/xmrig/config.json ]]; then
  BAK="/opt/xmrig/config.json.bak.$(date +%Y%m%d-%H%M%S)"
  cp /opt/xmrig/config.json "$BAK"
  echo "    old config backed up to $BAK"
fi
jq --arg w "$WALLET" --arg p "$WORKER" \
  '.pools[0].user = $w | .pools[0].pass = $p' \
  "$REPO/rootfs/opt/xmrig/config.json" > /opt/xmrig/config.json
chown -R xmrig:xmrig /opt/xmrig
chmod 640 /opt/xmrig/config.json /opt/xmrig/config.json.bak.* 2>/dev/null || true
install -d -o xmrig -g xmrig /var/lib/xmrig

install -m 755 "$REPO/rootfs/usr/local/sbin/thermal-guard.sh"  /usr/local/sbin/
install -m 755 "$REPO/rootfs/usr/local/sbin/xmrig-watchdog.sh" /usr/local/sbin/
for u in xmrig.service thermal-guard.service xmrig-watchdog.service xmrig-watchdog.timer; do
  install -m 644 "$REPO/rootfs/etc/systemd/system/$u" /etc/systemd/system/
done

# Remove leftovers from the boot-partition wallet design, if present.
systemctl disable xmrig-config.service 2>/dev/null || true
rm -f /etc/systemd/system/xmrig-config.service /usr/local/sbin/xmrig-apply-wallet.sh

step "Enabling and starting services"
systemctl daemon-reload
systemctl enable --now xmrig.service thermal-guard.service xmrig-watchdog.timer

step "Done"
echo "    worker:  $WORKER"
echo "    wallet:  ${WALLET:0:8}...${WALLET: -6}"
echo "    logs:    journalctl -u xmrig -f"
echo "    expect 'accepted' lines within a few minutes."
