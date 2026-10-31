#!/usr/bin/env bash
# Remove the miner, its services and its data. Build packages stay installed.
# Usage: sudo ./scripts/uninstall.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "ERROR: run with sudo" >&2; exit 1; }

systemctl disable --now xmrig-watchdog.timer xmrig.service thermal-guard.service 2>/dev/null || true
rm -f /etc/systemd/system/xmrig.service \
      /etc/systemd/system/thermal-guard.service \
      /etc/systemd/system/xmrig-watchdog.service \
      /etc/systemd/system/xmrig-watchdog.timer \
      /etc/systemd/system/xmrig-config.service
rm -f /usr/local/sbin/thermal-guard.sh /usr/local/sbin/xmrig-watchdog.sh \
      /usr/local/sbin/xmrig-apply-wallet.sh
systemctl daemon-reload

rm -rf /opt/xmrig /var/lib/xmrig /var/lib/xmrig-watchdog /usr/local/src/xmrig
id xmrig &>/dev/null && userdel xmrig

echo "Miner removed."
