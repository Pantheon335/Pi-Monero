# Pi-Monero

XMRig Monero miner for a Raspberry Pi 5 on Raspberry Pi OS (64-bit), with a
thermal guard and a pool watchdog. A learning lab. Mines at roughly 400 H/s.

## What gets installed

| Part | What it does |
|---|---|
| XMRig (built from source) | The miner, donation level patched to 0% |
| `xmrig.service` | Runs the miner as a locked-down `xmrig` user |
| `thermal-guard.service` | Pauses at 77 °C, resumes at 65 °C, powers off at 82 °C; stops the miner if it can't read the temperature |
| `xmrig-watchdog.timer` | Every 10 min: warns if no shares for 30 min, restarts if the pool stops crediting accepted shares |

## Install

```bash
git clone https://github.com/Pantheon335/Pi-Monero.git
cd Pi-Monero
sudo ./scripts/install.sh <YOUR_MONERO_WALLET_ADDRESS> [worker-name]
```

The worker name defaults to `pi5`. The build takes about 10 minutes.

## Check it

```bash
journalctl -u xmrig -f                         # "accepted" lines = working
journalctl -u thermal-guard -n 20              # pause/resume events
journalctl -t xmrig-watchdog -n 20             # watchdog verdicts
curl -s http://127.0.0.1:8080/2/summary | jq '.hashrate.total'
```

Pool stats: open https://supportxmr.com and enter your wallet address.

## Update or change the wallet

Re-run the installer. It rebuilds XMRig and backs up the old config.

```bash
git pull
sudo XMRIG_VERSION=v6.26.0 ./scripts/install.sh <WALLET> [worker-name]
```

Set `DISABLE_DONATION=false` to keep XMRig's default 1% developer donation.

## Tune the thresholds

```bash
sudo systemctl edit thermal-guard     # add: [Service] Environment=STOP_AT=75 RESUME_AT=63
sudo systemctl edit xmrig-watchdog    # add: [Service] Environment=STALL_SECS=3600
```

## Uninstall

```bash
sudo ./scripts/uninstall.sh
```

## Layout

```
scripts/install.sh, uninstall.sh       run these on the Pi
rootfs/opt/xmrig/config.json           miner config template (wallet filled in at install)
rootfs/usr/local/sbin/*.sh             thermal guard, watchdog
rootfs/etc/systemd/system/*            service and timer units
```
