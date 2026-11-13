#!/usr/bin/env bash
# Moves Docker data (images, build cache) and stack data (camera recordings, HA config and database)
# from the microSD card to an external disk (USB or NVMe in the M.2 slot).
#
#   sudo ./host/use-disk.sh /dev/sda1                 # existing partition (ext4/xfs/btrfs)
#   sudo ./host/use-disk.sh /dev/sda --format         # WIPE the whole disk: GPT + one ext4 partition
#   (--yes: don't ask for confirmation before formatting)
#
# The disk is mounted at /srv/k1 (by UUID, in /etc/fstab with nofail), Docker gets data-root
# /srv/k1/docker, and the deploy/data and deploy/homeassistant directories are moved to /srv/k1
# and left in place as symlinks. The old /var/lib/docker is kept as
# /var/lib/docker.old; delete it by hand once you're sure everything works.
set -euo pipefail
die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
DEV=${1:-}; shift || true
FORMAT=0 YES=0
for a in "$@"; do case "$a" in --format) FORMAT=1 ;; --yes) YES=1 ;; *) die "unknown argument $a" ;; esac; done
MNT=/srv/k1
STACK=$(dirname "$(dirname "$(readlink -f "$0")")")

[ -b "$DEV" ] || die "no block device '$DEV' (see lsblk)"
ROOT_DISK=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)")
[ "$(lsblk -no PKNAME "$DEV" 2>/dev/null || true)" != "$ROOT_DISK" ] && [ "$(basename "$DEV")" != "$ROOT_DISK" ] \
  || die "$DEV is the system disk"

if [[ "$(basename "$DEV")" == nvme* ]]; then
  log "NVMe: disabling power saving (APST, ASPM L1) now and on every boot"
  install -m 755 "$STACK/host/k1-nvme-tune" /usr/local/sbin/k1-nvme-tune
  install -m 644 "$STACK/host/k1-nvme-tune.service" /etc/systemd/system/k1-nvme-tune.service
  systemctl daemon-reload && systemctl enable k1-nvme-tune.service >/dev/null
  /usr/local/sbin/k1-nvme-tune
  # the weekly fstrim would issue a bulk TRIM, which hangs the controller
  systemctl disable --now fstrim.timer >/dev/null 2>&1 || true
fi

if [ "$FORMAT" = 1 ]; then
  log "Formatting $DEV: ALL data on it will be erased"
  lsblk -o NAME,SIZE,MODEL,FSTYPE,LABEL,MOUNTPOINTS "$DEV"
  if [ "$YES" != 1 ]; then read -r -p "Type 'yes' to continue: " ans; [ "$ans" = "yes" ] || die "cancelled"; fi
  for p in $(lsblk -lnpo NAME "$DEV" | tail -n +2); do umount "$p" 2>/dev/null || true; done
  wipefs -a "$DEV"
  printf 'label: gpt\n,,L\n' | sfdisk -q "$DEV"
  partprobe "$DEV" 2>/dev/null || true; udevadm settle; sleep 1
  DEV=$(lsblk -lnpo NAME "$DEV" | sed -n 2p)
  # no whole-disk TRIM: some NVMe drives on the K1 hang during a long discard
  mkfs.ext4 -q -F -E nodiscard -L k1data "$DEV"
fi

UUID=$(blkid -s UUID -o value "$DEV"); FSTYPE=$(blkid -s TYPE -o value "$DEV")
[ -n "$UUID" ] || die "no filesystem on $DEV (use --format)"
log "Mounting $DEV ($FSTYPE) at $MNT"
mkdir -p "$MNT"
if ! grep -q "UUID=$UUID" /etc/fstab; then
  sed -i "\\| $MNT |d" /etc/fstab   # remove old entries for this mount point
  echo "UUID=$UUID $MNT $FSTYPE defaults,noatime,nofail 0 2" >> /etc/fstab
fi
systemctl daemon-reload
findmnt "$MNT" >/dev/null || mount "$MNT"
df -h "$MNT" | tail -1

if [ "$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)" != "$MNT/docker" ]; then
  log "Moving Docker data to $MNT/docker"
  RUNNING=$(cd "$STACK/deploy" 2>/dev/null && docker compose ps --services --status running || true)
  (cd "$STACK/deploy" 2>/dev/null && docker compose stop) || true
  systemctl stop docker.socket docker
  mkdir -p "$MNT/docker"
  rsync -aHAX --info=progress2 /var/lib/docker/ "$MNT/docker/"
  python3 - "$MNT/docker" <<'PY'
import json, os, sys
p = "/etc/docker/daemon.json"
cfg = json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else {}
cfg["data-root"] = sys.argv[1]
os.makedirs("/etc/docker", exist_ok=True)
json.dump(cfg, open(p, "w"), indent=2)
PY
  mv /var/lib/docker /var/lib/docker.old
  systemctl start docker
  docker info -f 'Docker Root Dir: {{.DockerRootDir}}'
fi

log "Moving stack data (recordings, HA database) to the disk"
for d in data homeassistant; do
  src="$STACK/deploy/$d"
  [ -L "$src" ] && continue
  mkdir -p "$MNT/$d"
  [ -d "$src" ] && rsync -aHAX "$src/" "$MNT/$d/" && rm -rf "$src"
  ln -s "$MNT/$d" "$src"
  [ -n "${SUDO_USER:-}" ] && chown -h "$SUDO_USER:" "$src"
done
ls -l "$STACK/deploy"
# start what was running before the move (other images may not be built yet)
[ -n "${RUNNING:-}" ] && (cd "$STACK/deploy" && docker compose up -d $RUNNING) || true

log "Done. Once you're sure everything works: sudo rm -rf /var/lib/docker.old"
