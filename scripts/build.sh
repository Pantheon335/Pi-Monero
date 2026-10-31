#!/usr/bin/env bash
# Builds a custom Raspberry Pi OS Lite arm64 image with XMRig pre-installed.
# Runs on the GitHub arm64 runner as root. Downloads the official image,
# chroots into it, builds + installs the miner, re-compresses the result.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
OUT="$HERE/output"
mkdir -p "$OUT"

XMRIG_VERSION="${XMRIG_VERSION:-v6.26.0}"
DISABLE_DONATION="${DISABLE_DONATION:-true}"
LOOP=""
RESOLV_MOVED=0

cleanup() {
  set +e
  mountpoint -q "$WORK/mnt/boot/firmware" && umount "$WORK/mnt/boot/firmware"
  for m in dev/pts dev sys proc; do
    mountpoint -q "$WORK/mnt/$m" && umount "$WORK/mnt/$m"
  done
  mountpoint -q "$WORK/mnt" && umount "$WORK/mnt"
  [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

echo "==> Resolving latest Raspberry Pi OS Lite arm64"
DL="https://downloads.raspberrypi.org/raspios_lite_arm64_latest"
URL="$(curl -ILs -o /dev/null -w '%{url_effective}' "$DL")"
echo "    $URL"

echo "==> Downloading"
curl -fSL -o "$WORK/raspios.img.xz" "$URL"

echo "==> Verifying SHA-256"
EXPECT="$(curl -fsSL "$URL.sha256" | awk '{print $1}')"
ACTUAL="$(sha256sum "$WORK/raspios.img.xz" | awk '{print $1}')"
if [[ "$EXPECT" != "$ACTUAL" ]]; then
  echo "    checksum mismatch: expected $EXPECT got $ACTUAL" >&2
  exit 1
fi
echo "    ok ($ACTUAL)"

echo "==> Decompressing"
xz -dk "$WORK/raspios.img.xz"
IMG="$WORK/raspios.img"

echo "==> Expanding root partition by 2 GiB (build needs headroom)"
truncate -s +2G "$IMG"
LOOP="$(losetup -Pf --show "$IMG")"
growpart "$LOOP" 2 || true
e2fsck -fy "${LOOP}p2" || true
resize2fs "${LOOP}p2"

echo "==> Mounting image"
mkdir -p "$WORK/mnt"
mount "${LOOP}p2" "$WORK/mnt"
mkdir -p "$WORK/mnt/boot/firmware"
mount "${LOOP}p1" "$WORK/mnt/boot/firmware"
for m in proc sys dev dev/pts; do mount --bind "/$m" "$WORK/mnt/$m"; done

# Give the chroot working DNS, then restore the image's own resolv.conf after.
if [[ -e "$WORK/mnt/etc/resolv.conf" || -L "$WORK/mnt/etc/resolv.conf" ]]; then
  mv "$WORK/mnt/etc/resolv.conf" "$WORK/mnt/etc/resolv.conf.orig"
  RESOLV_MOVED=1
fi
cp /etc/resolv.conf "$WORK/mnt/etc/resolv.conf"

echo "==> Overlaying rootfs (configs, services, scripts)"
cp -a "$HERE/rootfs/." "$WORK/mnt/"
install -m 755 "$HERE/scripts/chroot-install.sh" "$WORK/mnt/tmp/chroot-install.sh"

echo "==> Overlaying boot-partition template (wallet example)"
cp -a "$HERE/boot-template/." "$WORK/mnt/boot/firmware/"

echo "==> Running install inside chroot (building XMRig $XMRIG_VERSION)"
chroot "$WORK/mnt" env \
  XMRIG_VERSION="$XMRIG_VERSION" \
  DISABLE_DONATION="$DISABLE_DONATION" \
  /tmp/chroot-install.sh

echo "==> Restoring image resolv.conf and cleaning up"
rm -f "$WORK/mnt/tmp/chroot-install.sh"
rm -f "$WORK/mnt/etc/resolv.conf"
[[ "$RESOLV_MOVED" -eq 1 ]] && mv "$WORK/mnt/etc/resolv.conf.orig" "$WORK/mnt/etc/resolv.conf"

echo "==> Unmounting"
sync
umount "$WORK/mnt/boot/firmware"
for m in dev/pts dev sys proc; do umount "$WORK/mnt/$m"; done
umount "$WORK/mnt"

echo "==> Zeroing free space for better compression"
zerofree "${LOOP}p2" || true
losetup -d "$LOOP"; LOOP=""

STAMP="$(date +%Y%m%d)"
FINAL="pi-monero-${STAMP}.img"
mv "$IMG" "$WORK/$FINAL"

echo "==> Compressing with xz"
xz -T0 -6 "$WORK/$FINAL"
mv "$WORK/$FINAL.xz" "$OUT/"

echo "==> Done:"
ls -lh "$OUT"
