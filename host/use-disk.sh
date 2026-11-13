#!/usr/bin/env bash
# Moves Docker data (images, build cache) and stack data (camera recordings, HA config and database)
# from the microSD card to an external disk: a SATA drive behind an M.2-to-SATA adapter (JMB582
# and the like) or a USB SSD. NVMe works but is not recommended on the K1, see the README.
#
#   sudo ./host/use-disk.sh /dev/sda1                 # existing partition (ext4/xfs/btrfs)
#   sudo ./host/use-disk.sh /dev/sda --format         # WIPE the whole disk: GPT + one ext4 partition
#   sudo ./host/use-disk.sh /dev/sda --mirror /dev/sdb --format
#                                                     # WIPE both disks: RAID1 mirror (mdadm) + ext4
#   sudo ./host/use-disk.sh /dev/md/k1data            # an existing mirror
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
FORMAT=0 YES=0 MIRROR=
while [ $# -gt 0 ]; do
  case "$1" in
    --format) FORMAT=1 ;;
    --yes) YES=1 ;;
    --mirror) [ -n "${2:-}" ] || die "--mirror needs a second disk"; MIRROR=$2; shift ;;
    *) die "unknown argument $1" ;;
  esac
  shift
done
MNT=/srv/k1
STACK=$(dirname "$(dirname "$(readlink -f "$0")")")

ROOT_DISK=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)")
for d in "$DEV" ${MIRROR:+"$MIRROR"}; do
  [ -b "$d" ] || die "no block device '$d' (see lsblk)"
  ! lsblk -no PKNAME "$d" 2>/dev/null | grep -qx "$ROOT_DISK" && [ "$(basename "$d")" != "$ROOT_DISK" ] \
    || die "$d is the system disk"
done
[ -z "$MIRROR" ] || [ "$FORMAT" = 1 ] || die "--mirror builds a new mirror and needs --format; pass an existing one as /dev/md/..."

NVME=0; [[ "$(basename "$DEV")" == nvme* ]] && NVME=1
if [ "$NVME" = 1 ]; then
  echo "WARNING: NVMe on the SpacemiT K1 is unreliable: drives hang under load and may not come back" >&2
  echo "         after a reboot, even after a power cycle. A SATA drive behind a JMB582 is safer." >&2
  log "NVMe: disabling power saving (APST, ASPM L1) now and on every boot"
  install -m 755 "$STACK/host/k1-nvme-tune" /usr/local/sbin/k1-nvme-tune
  install -m 644 "$STACK/host/60-k1-nvme-tune.rules" /etc/udev/rules.d/60-k1-nvme-tune.rules
  udevadm control --reload
  # older versions used a systemd service, which at cold boot could run before the disk showed up
  if [ -e /etc/systemd/system/k1-nvme-tune.service ]; then
    systemctl disable k1-nvme-tune.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/k1-nvme-tune.service
    systemctl daemon-reload
  fi
  /usr/local/sbin/k1-nvme-tune
  # the weekly fstrim would issue a bulk TRIM, which hangs the controller
  systemctl disable --now fstrim.timer >/dev/null 2>&1 || true
fi

# first partition of a disk that has just been partitioned
first_part() { partprobe "$1" 2>/dev/null || true; udevadm settle; sleep 1; lsblk -lnpo NAME "$1" | sed -n 2p; }

if [ "$FORMAT" = 1 ]; then
  DISKS=("$DEV"); [ -n "$MIRROR" ] && DISKS+=("$MIRROR")
  log "Formatting ${DISKS[*]}: ALL data on them will be erased"
  lsblk -o NAME,SIZE,MODEL,FSTYPE,LABEL,MOUNTPOINTS "${DISKS[@]}"
  if [ "$YES" != 1 ]; then read -r -p "Type 'yes' to continue: " ans; [ "$ans" = "yes" ] || die "cancelled"; fi
  [ -z "$MIRROR" ] || command -v mdadm >/dev/null \
    || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends mdadm >/dev/null
  OLD_MD=()   # UUIDs of old RAID arrays on these disks (installing mdadm adds them to mdadm.conf)
  for d in "${DISKS[@]}"; do
    for p in $(lsblk -lnpo NAME "$d"); do
      [ "$(blkid -s TYPE -o value "$p" 2>/dev/null)" = linux_raid_member ] || continue
      OLD_MD+=("$(blkid -s UUID -o value "$p" | tr -d - | sed 's/.\{8\}/&:/g; s/:$//')")
    done
    # old RAID members (e.g. from a Synology) get assembled automatically and keep the disk busy
    for s in /sys/block/md*/slaves/"$(basename "$d")"*; do
      if [ -e "$s" ]; then mdadm --stop "/dev/$(basename "$(dirname "$(dirname "$s")")")"; fi
    done
    for p in $(lsblk -lnpo NAME "$d" | tail -n +2); do umount "$p" 2>/dev/null || true; wipefs -qa "$p" || true; done
    wipefs -a "$d"
  done
  if [ -n "$MIRROR" ]; then
    PARTS=()
    for d in "${DISKS[@]}"; do printf 'label: gpt\n,,R\n' | sfdisk -q "$d"; PARTS+=("$(first_part "$d")"); done
    wipefs -qa "${PARTS[@]}"   # leftovers of old data where the new partitions start
    mdadm --create /dev/md/k1data --name=k1data --level=1 --raid-devices=2 --metadata=1.2 --run "${PARTS[@]}" </dev/null
    for u in "${OLD_MD[@]}"; do sed -i "/^ARRAY .*UUID=$u/d" /etc/mdadm/mdadm.conf; done
    grep -q "^ARRAY /dev/md/k1data " /etc/mdadm/mdadm.conf || mdadm --detail --brief /dev/md/k1data >> /etc/mdadm/mdadm.conf
    command -v update-initramfs >/dev/null && update-initramfs -u   # the initramfs carries a copy of mdadm.conf
    DEV=/dev/md/k1data
  else
    printf 'label: gpt\n,,L\n' | sfdisk -q "$DEV"
    DEV=$(first_part "$DEV")
  fi
  if [ "$NVME" = 1 ]; then
    # no whole-disk TRIM: NVMe drives on the K1 can hang during a long discard
    mkfs.ext4 -q -F -E nodiscard -L k1data "$DEV"
  else
    mkfs.ext4 -q -F -L k1data "$DEV"
  fi
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

# read data-root from the config, not from `docker info`: that would wake Docker up via its socket
DOCKER_ROOT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("data-root", ""))' \
  /etc/docker/daemon.json 2>/dev/null || true)
if [ "$DOCKER_ROOT" != "$MNT/docker" ]; then
  log "Moving Docker data to $MNT/docker"
  RUNNING=$(cd "$STACK/deploy" 2>/dev/null && docker compose ps --services --status running || true)
  (cd "$STACK/deploy" 2>/dev/null && docker compose stop) || true
  systemctl stop docker.socket docker
  mkdir -p "$MNT/docker"
  [ -d /var/lib/docker ] && rsync -aHAX --info=progress2 /var/lib/docker/ "$MNT/docker/"
  python3 - "$MNT/docker" <<'PY'
import json, os, sys
p = "/etc/docker/daemon.json"
cfg = json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else {}
cfg["data-root"] = sys.argv[1]
os.makedirs("/etc/docker", exist_ok=True)
json.dump(cfg, open(p, "w"), indent=2)
PY
  [ -d /var/lib/docker ] && mv /var/lib/docker /var/lib/docker.old
  systemctl start docker
  docker info -f 'Docker Root Dir: {{.DockerRootDir}}'
fi

# If the disk doesn't show up at boot (nofail lets the board boot anyway), Docker must not start:
# it would quietly create an empty data root on the microSD and none of the containers would run.
mkdir -p /etc/systemd/system/docker.service.d
printf '[Unit]\nRequiresMountsFor=%s/docker\n' "$MNT" > /etc/systemd/system/docker.service.d/k1-data-disk.conf
systemctl daemon-reload

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

# TRIM is fine on SATA and USB SSDs; turn the weekly fstrim back on if an earlier NVMe setup disabled it
[ "$NVME" = 1 ] || systemctl enable --now fstrim.timer >/dev/null 2>&1 || true

if [ -d /var/lib/docker.old ]; then
  log "Done. Once you're sure everything works: sudo rm -rf /var/lib/docker.old"
else
  log "Done"
fi
