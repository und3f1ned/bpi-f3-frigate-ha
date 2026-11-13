#!/usr/bin/env bash
# Prepares an Armbian host (current/legacy kernel with SpacemiT vendor drivers) on the BPI-F3:
# VPU firmware, amvx driver autoload, device permissions, Docker with buildx and compose.
# Idempotent: safe to run again.   sudo ./host/setup-host.sh [--hold-kernel]
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

FW_DEB_URL=https://archive.spacemit.com/bianbu/pool/main/k/k1x-vpu-firmware/k1x-vpu-firmware_0.1.0_riscv64.deb
FW_DEB_SHA256=19db65f6e52a702f828f2ad910c0bd1d30e4ea72e933fd3d6af800c25937681d
HOLD_KERNEL=0
for a in "$@"; do [ "$a" = "--hold-kernel" ] && HOLD_KERNEL=1; done
log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

log "Kernel $(uname -r)"
CFG=/boot/config-$(uname -r)
for opt in CONFIG_VIDEO_LINLON_K1X CONFIG_SPACEMIT_TCM CONFIG_DMABUF_HEAPS_CMA; do
  if grep -qE "^$opt=(y|m)" "$CFG" 2>/dev/null; then echo "  $opt: present"
  else echo "  $opt: MISSING, a vendor kernel is required (Armbian current/legacy for spacemit)" >&2; exit 1; fi
done

log "VPU firmware (k1x-vpu-firmware)"
if dpkg -s k1x-vpu-firmware >/dev/null 2>&1; then echo "  already installed"
else
  t=$(mktemp -d); curl -4 -fsSL -o "$t/fw.deb" "$FW_DEB_URL"
  echo "$FW_DEB_SHA256  $t/fw.deb" | sha256sum -c -
  dpkg -i "$t/fw.deb"; rm -rf "$t"
fi

log "VPU driver amvx (not loaded automatically: the DT compatible string contains a space)"
echo amvx > /etc/modules-load.d/spacemit-vpu.conf
modprobe amvx
ls -l /dev/video0

log "K1 device permissions (video group)"
cat > /etc/udev/rules.d/99-spacemit-k1.rules <<'RULES'
# SpacemiT K1: give group video the AI accelerator TCM, user DMA and the CMA heap for MPP
KERNEL=="tcm", GROUP="video", MODE="0660"
KERNEL=="udma", GROUP="video", MODE="0660"
SUBSYSTEM=="dma_heap", KERNEL=="linux,cma", GROUP="video", MODE="0660"
RULES
udevadm control --reload
udevadm trigger --action=change /dev/tcm /dev/udma /dev/dma_heap/linux,cma 2>/dev/null || udevadm trigger
ls -l /dev/tcm /dev/udma /dev/dma_heap/linux,cma

log "Docker, buildx, compose"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  docker.io docker-cli docker-buildx docker-compose v4l-utils git python3 curl >/dev/null
systemctl enable --now docker >/dev/null
if [ -n "${SUDO_USER:-}" ]; then usermod -aG docker,video "$SUDO_USER"; fi
docker --version; docker buildx version; docker compose version

# WARNING: do not add pcie_aspm=off and nvme_core.default_ps_max_latency_us=0 to
# /boot/extlinux/extlinux.conf: with them the BPI-F3 does not boot on the 6.18 current-spacemit
# kernel. To recover, put the microSD in another computer and remove them again.

if [ "$HOLD_KERNEL" = 1 ]; then
  log "Holding kernel packages (Armbian may move current to mainline, which has no VPU/TCM)"
  apt-mark hold $(dpkg-query -W -f='${Package}\n' 'linux-image-*-spacemit' 'linux-dtb-*-spacemit' 2>/dev/null)
fi
log "Done"
