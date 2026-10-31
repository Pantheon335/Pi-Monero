#!/usr/bin/env bash
# Runs INSIDE the Pi OS arm64 chroot. Builds XMRig from source so the binary
# links against Pi OS's glibc, installs it, creates the service user, and
# enables the systemd units that the rootfs overlay already placed.
set -euo pipefail

XMRIG_VERSION="${XMRIG_VERSION:-v6.26.0}"
DISABLE_DONATION="${DISABLE_DONATION:-true}"
export DEBIAN_FRONTEND=noninteractive

echo "--> Installing build dependencies"
apt-get update
apt-get install -y --no-install-recommends \
  git build-essential cmake automake libtool autoconf \
  libuv1-dev libssl-dev libhwloc-dev \
  jq curl ca-certificates

echo "--> Cloning XMRig $XMRIG_VERSION"
rm -rf /tmp/xmrig
git clone --depth 1 --branch "$XMRIG_VERSION" https://github.com/xmrig/xmrig.git /tmp/xmrig

if [[ "$DISABLE_DONATION" == "true" ]]; then
  echo "--> Patching donate level to 0%"
  sed -i \
    -e 's/kDefaultDonateLevel = [0-9]\+/kDefaultDonateLevel = 0/' \
    -e 's/kMinimumDonateLevel = [0-9]\+/kMinimumDonateLevel = 0/' \
    /tmp/xmrig/src/donate.h
  grep DonateLevel /tmp/xmrig/src/donate.h
fi

echo "--> Building"
mkdir -p /tmp/xmrig/build
cd /tmp/xmrig/build
cmake .. -DWITH_HWLOC=ON
make -j"$(nproc)"
install -m 755 xmrig /opt/xmrig/xmrig
cd /

echo "--> Creating service user and permissions"
id xmrig &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin xmrig
install -d -o xmrig -g xmrig /var/lib/xmrig
chown -R xmrig:xmrig /opt/xmrig
chmod 755 /usr/local/sbin/xmrig-apply-wallet.sh /usr/local/sbin/thermal-guard.sh \
          /usr/local/sbin/xmrig-watchdog.sh

echo "--> Enabling services"
systemctl enable xmrig-config.service xmrig.service thermal-guard.service \
                 xmrig-watchdog.timer

echo "--> Removing build toolchain to shrink the image"
apt-get purge -y \
  git build-essential cmake automake libtool autoconf \
  libuv1-dev libssl-dev libhwloc-dev
apt-get autoremove -y
apt-get clean
rm -rf /tmp/xmrig /var/lib/apt/lists/*

echo "--> chroot install complete"
