# Frigate + Home Assistant on the Banana Pi BPI-F3

I bought a BPI-F3 to be a quiet little NAS and smart-home box. Its SpacemiT K1 chip has 8 RISC-V
cores, a hardware video decoder and an NPU that SpacemiT sells as "2 TOPS". Neither Frigate nor
Home Assistant publishes riscv64 images, and nothing I could find used the decoder or the NPU, so
I put this together.

What you get:

- **Frigate 0.18** with camera streams decoded by the VPU and object detection (YOLOv8n, INT8)
  running on the K1's AI cores, about 10 ms per inference.
- **Home Assistant** in a container, built from PyPI.
- **Mosquitto**, so the Frigate integration in HA has an MQTT broker.
- **One update script** that checks for new HA and Frigate releases, rebuilds only what changed and
  restarts the stack. Run it by hand or let a weekly systemd timer do it.

Everything is built on the board itself. No cross-compiling, no QEMU.

## Does it actually work?

Yes, on my board, as of November 2026:

| | |
|---|---|
| Board | BPI-F3, 4 GB RAM |
| Storage | two SATA SSDs in a RAID1 mirror behind a JMB582 M.2-to-SATA adapter (an NVMe SSD before that, see [NVMe](#nvme-is-not-reliable-on-this-board)) |
| OS | Armbian (Debian trixie), `current` kernel 6.18 for spacemit |
| Frigate | 0.18.2 |
| Home Assistant | 2026.11.1 (Python 3.14) |

With one 1080p H.264 camera at 12 fps, detecting at 640×360 / 5 fps:

- The VPU decodes the stream. The ffmpeg process still uses about 0.7 of a core: scaling and
  pixel format conversion happen on the CPU.
- Inference takes about 10 ms on the NPU, or 22–24 ms as Frigate measures it, ZMQ round trip
  included. Thirty detections a second is no problem.
- Frigate uses about 1.4 of the 8 cores and the detector about 0.3. The board sits ~80% idle.
- Memory: Frigate ~700 MB, Home Assistant ~200 MB, detector 50 MB.

Other K1 boards (Milk-V Jupiter, Muse Pi and friends) should behave the same on an Armbian vendor
kernel. I haven't tried them.

## What you need

- **A BPI-F3.** The 4 GB version is enough.
- **Armbian with the `current` (or `legacy`) kernel for spacemit.** Those kernels carry SpacemiT's
  vendor drivers for the VPU and for the NPU's memory (TCM). The `edge` kernel is mainline, has
  neither, and won't work.
- **An external disk.** Use a SATA drive behind an M.2-to-SATA adapter (JMB582 or similar) in the
  M.2 slot, or a USB SSD. **Avoid NVMe** on this board, see
  [NVMe is not reliable on this board](#nvme-is-not-reliable-on-this-board).
  - The images take about 5 GB, and building Frigate needs another 7–8 GB of scratch space.
  - Recordings need room too.
  - A 16 GB microSD is too small, and recording to it will wear it out quickly.
- **Patience for the first build.** It takes a few hours because everything compiles on the board.
  Later updates only rebuild what changed.

## Setup

1. Flash Armbian `current` for the BPI-F3, boot it, get it on the network and ssh in.

2. Clone this repo:

   ```bash
   git clone https://github.com/und3f1ned/bpi-f3-frigate-ha ~/bpi-f3-frigate-ha
   ```

   ```bash
   cd ~/bpi-f3-frigate-ha
   ```

3. Prepare the host:

   ```bash
   sudo ./host/setup-host.sh --hold-kernel
   ```

   This script:
   - installs the VPU firmware;
   - makes the VPU driver load at boot (it doesn't on its own);
   - gives the `video` group access to the NPU and VPU devices;
   - installs Docker with buildx and compose;
   - adds you to the `docker` and `video` groups. Log out and back in afterwards.

   `--hold-kernel` pins the kernel packages, so an `apt upgrade` can't move you to a kernel without
   the VPU and NPU drivers. I recommend it.

4. Move Docker and the stack's data to the external disk. Find the disk with `lsblk`, then:

   ```bash
   sudo ./host/use-disk.sh /dev/sda --format
   ```

   `--format` **erases the whole disk.** To use an existing partition, leave it off and pass the
   partition instead, e.g. `/dev/sda1`.

   With two disks (a JMB582 has two SATA ports), make a mirror. If one disk dies, nothing is lost:

   ```bash
   sudo ./host/use-disk.sh /dev/sda --mirror /dev/sdb --format
   ```

   That **erases both disks**, builds a RAID1 array with `mdadm` and puts ext4 on it. Leftover RAID
   members from an old NAS (Synology and the like) are stopped and cleaned up. The first sync runs in
   the background, about 20 minutes for 240 GB SSDs. The array is usable during that time.

   The script:
   - mounts the disk at `/srv/k1`;
   - moves Docker's data root there;
   - moves `deploy/data` and `deploy/homeassistant` there, leaving symlinks behind.

   It also makes Docker depend on that mount. If the disk is missing at boot, Docker stays down
   instead of quietly starting with an empty data root on the microSD.

   If you use an NVMe drive anyway, the script prints a warning and applies the workarounds
   described in [Known problems](#nvme-is-not-reliable-on-this-board).

5. Build the images:

   ```bash
   ./build.sh all
   ```

   The first run takes hours. Logs go to `logs/`. `./build.sh versions` shows which versions it
   would build.

6. Set up your cameras in `deploy/frigate/config.yml`.

   The file comes with a test camera that loops a video file. Drop any H.264 clip at
   `deploy/data/media/test/test_1080p.mp4` to check that decoding and detection work, then replace
   the test camera with your own.

   Keep camera passwords out of the config. Put them in `deploy/.env`:

   ```
   FRIGATE_RTSP_PASSWORD=your-password
   ```

   Then refer to the password as `{FRIGATE_RTSP_PASSWORD}` in stream URLs.

   For H.265 cameras, set `hwaccel_args: -c:v hevc_stcodec` on that camera. The global default is
   `h264_stcodec`.

7. Start everything:

   ```bash
   cd deploy && docker compose up -d
   ```

   - Home Assistant: `http://<board>:8123`
   - Frigate: `https://<board>:8971`. The `admin` password is printed in `docker logs frigate` on
     first start.
   - To connect Frigate to Home Assistant:
     - install the Frigate integration through HACS;
     - use `http://127.0.0.1:5000` as the Frigate URL and `127.0.0.1:1883` as the MQTT broker.

     Port 5000 has no authentication, so don't expose it outside your LAN.

8. Turn on automatic updates:

   ```bash
   sudo ./host/enable-auto-update.sh
   ```

   This runs `update.sh` every Sunday at 03:00. Pass your own schedule if you like:
   `sudo ./host/enable-auto-update.sh "Sat 04:30"`. You can also just run `./update.sh` by hand.

   If nothing new came out, a run takes a few seconds and leaves the containers alone. If building a
   new version fails, the stack keeps running on the old images. The reason is in
   `journalctl -u k1-update.service` and in `logs/`.

## How it works

Four images are built, all tagged `k1/<name>:<version>` and `k1/<name>:latest`:

| Image | What's inside |
|---|---|
| `k1/frigate` | Frigate, with the native parts rebuilt for riscv64 and SpacemiT's ffmpeg |
| `k1/k1det` | The detector Frigate talks to: YOLOv8n INT8 on the NPU, plus test tools |
| `k1/homeassistant` | Home Assistant from PyPI, FFmpeg 8 built from source (for PyAV), go2rtc |
| `k1/mosquitto` | Mosquitto from Debian |

`build.sh` labels every image with a hash of its recipe: the files in its directory plus the
versions it was built for. If an image with the same hash already exists, it's skipped. That's why
re-running is cheap.

**Frigate.** The Python code and the web UI don't depend on the CPU architecture. So they're
copied from the official arm64 image of the same version. Only the layer that contains them is
downloaded, and nothing goes through Node.

Everything native is rebuilt for riscv64:
- nginx and sqlite-vec, using Frigate's own build scripts;
- go2rtc, from source;
- the Python wheels;
- s6-overlay, tempio and yq, which have riscv64 releases.

ffmpeg comes from SpacemiT's Bianbu 2.3. Its `h264_stcodec`/`hevc_stcodec` decoders use the VPU.

Frigate's `requirements-wheels.txt` doesn't install as-is on riscv64. `frigate/adapt_requirements.py`
applies a small set of rules: drop what doesn't exist for riscv64, relax pins that can't be met on
Python 3.13, install a couple of packages without their dependency checks. When a new Frigate
release breaks the build, a new rule in that file or in `frigate/source-fixups.sed` is usually the
fix.

At the end of the build, the image imports `frigate.app` and lists any missing shared libraries
(`missing lib:` in the log). So most breakage shows up at build time rather than at 3 a.m. on your
NVR.

**Detection.** Frigate has a built-in `zmq` detector type. It sends each 320×320 frame over a Unix
socket to the `k1det` container. `k1det` runs YOLOv8n through onnxruntime with SpaceMIT's
execution provider, pinned to cores 0–3 (the only cores with the AI instructions), and sends the
boxes back.

You can use your own model. It has to be a YOLOv8 export with the 9 raw outputs, quantized with
SpacemiT's XSlim. Put the `.q.onnx` file in `deploy/data/models` and point `model.path` at it.

**Home Assistant.** `homeassistant==<version>` is installed with that release's
`package_constraints.txt`. The requirements of `default_config`, MQTT and everything HA loads at
startup are installed into the image ahead of time. Wheels come from PyPI and SpacemiT's package
index, and whatever has no riscv64 wheel gets compiled.

The compilers stay in the image. When you enable an integration later, HA installs its
requirements itself. The first time can be slow.

### Things that took a while to figure out

In case you're doing something similar on this chip:

- SpacemiT's MPP library prints debug output with `printf` to **stdout**. Frigate reads raw frames
  from ffmpeg's stdout, so the text got mixed into the video and every frame came out shifted and
  striped. That looked like a decoder bug and wasn't. The bundled `ffmpeg` wrapper sends the
  frames to a separate file descriptor and moves stdout to stderr.
- `sherpa-onnx` exists for riscv64 in two package indexes under the same file name, built against
  different onnxruntime versions. Only SpacemiT's build works with SpacemiT's onnxruntime. The
  build now always takes it from their index.
- `norfair` declares `numpy<2` in its metadata but works with numpy 2. It's installed with
  `--no-deps`.
- Frigate imports TensorFlow Lite unconditionally, and there's no TFLite for riscv64. A tiny stub
  (`frigate/stubs`) lets the imports succeed. The features that really need TFLite fail with a
  clear error if you turn them on.
- The `kaltura/nginx-vod-module` and `nginx-secure-token-module` repos that Frigate's nginx build
  uses are gone from GitHub. The build uses forks with the same commits.
- Frigate 0.18 ships with detection **off** by default (`detect: enabled: true` turns it on). It
  also strips `exec:` sources from the go2rtc config unless you set
  `GO2RTC_ALLOW_ARBITRARY_EXEC`.

## Known problems

### NVMe is not reliable on this board

I ran the stack from a Patriot P300 (MAXIO MAP1202 controller) in the M.2 slot for a while and gave
up on it. Don't use NVMe here unless you're fine with the disk possibly not showing up after the
next reboot.

What I saw:

- **Hangs under load.** The kernel logs `nvme nvme0: I/O tag … QID 0 timeout, disable controller`.
  It happened during `mkfs`, which TRIMs the whole disk by default.
- **The drive didn't come back after a reboot.** The controller never became ready
  (`nvme nvme0: Device not ready; aborting initialisation, CSTS=0x0`), and pulling the power for
  30 seconds didn't help either. The same drive worked fine in a USB enclosure on another machine,
  so the drive itself was OK. The K1's PCIe driver doesn't control the M.2 slot's power
  (`has no power on gpio` in the log). My guess is that the drive needs a power and reset sequence
  the board doesn't give it.

`use-disk.sh` still has workarounds for NVMe, and it prints a warning when you point it at one:
- it turns off the drive's power saving (APST) and the PCIe link's (ASPM L1) from a udev rule
  every time the drive appears (`journalctl -b -t k1-nvme-tune` shows it ran);
- it formats without TRIM and disables the weekly `fstrim.timer`.

They made the hangs under load go away for me, but they didn't stop the drive from getting stuck
after a reboot.

My board now runs from a JMB582 M.2-to-SATA adapter with two SATA SSDs in a mirror. The kernel's
built-in AHCI driver handles the adapter (it shows up as a JMB585, `197b:0585`, on a PCIe Gen2 x1
link). None of the NVMe workarounds apply there: TRIM and power management stay at their defaults.

To move off NVMe without rebuilding anything:
1. Set up the new disks with `use-disk.sh`.
2. Put the old NVMe drive in a USB enclosure and plug it into the board.
3. Stop Docker, mount the old drive read-only and copy it over:

   ```bash
   rsync -aHAX --numeric-ids --exclude /lost+found /mnt/old/ /srv/k1/
   ```

> [!WARNING]
> Do not add `pcie_aspm=off` or `nvme_core.default_ps_max_latency_us=0` to
> `/boot/extlinux/extlinux.conf`. With these parameters, this kernel doesn't boot. If you already
> did, put the microSD in another computer and remove them.

### Other known problems

**Booting can take about 5 minutes.** About two of those are a pause in the initramfs before the
root filesystem on the microSD is mounted. It isn't related to the external disk, and I haven't
found the cause. It doesn't affect anything once the board is up.

**The VPU decoder hangs at end of stream.** Cameras never end, so in practice this only matters
for files. Loop them through go2rtc, as the test camera does.

**`stcodec`'s `-scale` option doesn't work** with this kernel and corrupts the picture. Scaling
stays on the CPU.

**No TensorFlow Lite, OpenVINO or TensorFlow on riscv64.** In Frigate that means none of these
work:
- the Coral, OpenVINO and CPU detectors;
- audio detection;
- bird classification and custom classification models;
- the `small` face recognition model (`large` runs on ONNX and works);
- speech transcription.

**Home Assistant add-ons and ESPHome firmware builds aren't available.** There's no Supervisor here,
and ESPHome needs toolchains that don't exist for RISC-V. Zigbee2MQTT publishes an official riscv64
image if you need it.

**The `current` kernel is a vendor branch maintained by one person.** That's another reason to use
`--hold-kernel`.

## Troubleshooting

Check that the devices are there:

```bash
ls -l /dev/video0 /dev/tcm /dev/dma_heap/linux,cma
```

```bash
sudo dmesg | grep -i -E 'amvx|tcm'
```

Benchmark the NPU (SpaceMIT EP against plain CPU on the same model):

```bash
docker exec k1det python /opt/k1/bench_ort.py
```

Benchmark the VPU (software against hardware decoding, H.264 and HEVC, on generated test clips):

```bash
docker run --rm --device /dev/video0 --device /dev/dma_heap/linux,cma --device /dev/dma_heap/system k1/k1det decode_test.sh
```

See what Frigate thinks of the detector:

```bash
curl -s http://127.0.0.1:5000/api/stats | python3 -m json.tool | grep -E 'inference_speed|detection_fps|detection_enabled'
```

If `detection_enabled` is `false`, enable detection in the config. If the picture in Frigate looks
cut in half with colored stripes at the top, your ffmpeg isn't the bundled wrapper. See
[Things that took a while to figure out](#things-that-took-a-while-to-figure-out).

A failed build leaves its log in `logs/<image>-<version>.log`. Start from the end.

## Credits

None of this would work without:
- **SpacemiT:** Bianbu, MPP, ffmpeg with stcodec, onnxruntime with their execution provider, and
  the model zoo;
- **the Frigate, Home Assistant, go2rtc and Armbian projects.**

The YOLOv8 model is by Ultralytics and licensed AGPL-3.0. It's downloaded from SpacemiT's model zoo
at build time and isn't part of this repo.

## License

MIT, see [LICENSE](LICENSE). That covers the scripts and files in this repository. The images you
build contain third-party software under its own licenses.
