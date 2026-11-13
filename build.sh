#!/usr/bin/env bash
# Builds images for the Banana Pi BPI-F3 (SpacemiT K1, linux/riscv64).
#
#   ./build.sh all                                # everything, latest stable versions
#   ./build.sh ha --ha-version 2026.11.1          # a specific Home Assistant version
#   ./build.sh frigate --frigate-version 0.18.2   # a specific Frigate version
#   ./build.sh k1det                              # detection server for the K1 AI accelerator
#   ./build.sh mosquitto                          # MQTT broker from the Debian package
#   ./build.sh versions                           # show which versions would be built
# Options: --integrations "default_config mqtt ..."  --force (rebuild even if up to date)
#          --no-cache (no layer cache)  --pull (refresh base images)
# An image that is already built (same version, same recipe) is skipped, so `./build.sh all`
# only builds what is new. Images: k1/<name>:<version> and :latest. Logs: logs/.
# Run it on the board itself: images are built natively (under QEMU it is many times slower).
# Intermediate layers are kept after a build (a rebuild takes minutes, not hours), but if the
# Docker disk has less than PRUNE_BELOW_GB (default 30) GB free, they are pruned (pip/ccache/Go
# caches are kept). PRUNE_BELOW_GB=0 never prunes, KEEP_LAYERS=0 always prunes.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

HA_VERSION=${HA_VERSION:-}
FRIGATE_VERSION=${FRIGATE_VERSION:-}
HA_INTEGRATIONS=${HA_INTEGRATIONS:-"default_config mqtt"}
HA_FFMPEG_MAJOR=${HA_FFMPEG_MAJOR:-8}           # PyAV 19 needs FFmpeg 8; the latest release of that branch is used
SPACEMIT_INDEX=https://git.spacemit.com/api/v4/projects/33/packages/pypi/simple
RISE_INDEX=https://pypi.riseproject.dev/simple
TEMPIO_VERSION=${TEMPIO_VERSION:-2026.07.0}     # first tempio version with a riscv64 build
FFMPEG_VERSION=${FFMPEG_VERSION:-6.1}           # ffmpeg 6.1.1 from Bianbu 2.3 (stcodec) for Frigate
BUILD_OPTS=()
FORCE=0
TARGETS=()

usage() { sed -n '2,/^set /{/^#/p;}' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    ha|frigate|k1det|mosquitto|all|versions) TARGETS+=("$1") ;;
    --ha-version) HA_VERSION=$2; shift ;;
    --frigate-version) FRIGATE_VERSION=${2#v}; shift ;;
    --integrations) HA_INTEGRATIONS=$2; shift ;;
    --force) FORCE=1 ;;
    --no-cache) BUILD_OPTS+=(--no-cache); FORCE=1 ;;
    --pull) BUILD_OPTS+=(--pull); FORCE=1 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
  shift
done
[ ${#TARGETS[@]} -gt 0 ] || usage 1

mkdir -p logs .cache
log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
# curl over IPv4 only: the board has IPv6, but the outbound route doesn't work.
fetch() { curl -4 -fsSL --retry 3 "$@"; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

# Recipe hash: directory files + key parameters. If the recipe or a version changes, the image is rebuilt.
recipe() { local dir=$1; shift
  { (cd "$dir" && find . -type f ! -name 'requirements-riscv64*.txt' ! -path '*/__pycache__/*' -print0 \
      | sort -z | xargs -0 sha256sum); echo "$*"; } | sha256sum | cut -c1-12; }
uptodate() { # image hash
  [ "$FORCE" = 0 ] && [ "$(docker image inspect -f '{{index .Config.Labels "k1.recipe"}}' "$1" 2>/dev/null)" = "$2" ]
}

BUILT=()
# docker buildx build with a log; on failure prints its tail.
# STAGES="a b c": first build these stages one at a time (cache only) to lower peak memory.
maybe_prune() { # drop intermediate layers if disk space is low; pip/ccache/Go caches stay
  local root free
  root=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null) || return 0
  free=$(df -BG --output=avail "$root" | tail -1 | tr -dc 0-9)
  if [ "${KEEP_LAYERS:-}" = 0 ] || [ "${free:-0}" -lt "${PRUNE_BELOW_GB:-30}" ]; then
    docker builder prune -f --filter type=regular >/dev/null
  fi
}
dbuild() { # name version hash args... (the last one is the context directory)
  local name=$1 ver=$2 hash=$3; shift 3
  local logf="logs/$name-$ver.log" t0=$SECONDS st
  echo "    log: $logf"
  : >"$logf"
  for st in ${STAGES:-}; do
    echo "    stage $st"
    docker buildx build --progress=plain "${BUILD_OPTS[@]}" --target "$st" --output type=cacheonly \
      "$@" >>"$logf" 2>&1 || { tail -40 "$logf"; die "build $name $ver: stage $st failed (log $logf)"; }
  done
  if ! docker buildx build --load --progress=plain "${BUILD_OPTS[@]}" --label "k1.recipe=$hash" \
        -t "k1/$name:$ver" -t "k1/$name:latest" "$@" >>"$logf" 2>&1; then
    tail -40 "$logf"; die "build $name $ver failed (log $logf)"
  fi
  log "done in $(( (SECONDS - t0) / 60 )) min: k1/$name:$ver"
  BUILT+=("k1/$name:$ver")
  maybe_prune
}

# ---------- versions ----------
resolve_ha() {
  [ -n "$HA_VERSION" ] || HA_VERSION=$(fetch https://pypi.org/pypi/homeassistant/json | json 'd["info"]["version"]')
  HA_PYTHON=$(fetch "https://pypi.org/pypi/homeassistant/$HA_VERSION/json" | json 'd["info"]["requires_python"]' \
              | sed -E 's/^>=([0-9]+\.[0-9]+).*/\1/')
  HA_GO2RTC=$(fetch "https://raw.githubusercontent.com/home-assistant/core/$HA_VERSION/homeassistant/components/go2rtc/const.py" \
              | sed -nE 's/^RECOMMENDED_VERSION = "([^"]+)".*/\1/p')
  HA_FFMPEG=$(fetch https://ffmpeg.org/releases/ | grep -oE "ffmpeg-$HA_FFMPEG_MAJOR\.[0-9]+(\.[0-9]+)?\.tar\.xz" \
              | sed -E 's/ffmpeg-(.*)\.tar\.xz/\1/' | sort -uV | tail -1)
  [ -n "$HA_PYTHON" ] && [ -n "$HA_GO2RTC" ] && [ -n "$HA_FFMPEG" ] \
    || die "could not determine Python/go2rtc/FFmpeg for HA $HA_VERSION"
}

resolve_frigate() {
  [ -n "$FRIGATE_VERSION" ] || FRIGATE_VERSION=$(fetch https://api.github.com/repos/blakeblackshear/frigate/releases/latest \
                                                 | json 'd["tag_name"]' | sed 's/^v//')
  FRIGATE_SRC=.cache/frigate-$FRIGATE_VERSION
  if [ ! -d "$FRIGATE_SRC/.git" ]; then
    rm -rf "$FRIGATE_SRC"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "v$FRIGATE_VERSION" \
      https://github.com/blakeblackshear/frigate "$FRIGATE_SRC"
  fi
  local d=$FRIGATE_SRC/docker/main
  FRIGATE_GO2RTC=$(sed -nE 's|.*go2rtc/releases/download/v([0-9.]+)/.*|\1|p' "$d/Dockerfile" | head -1)
  FRIGATE_S6=$(sed -nE 's/^s6_version="([^"]+)".*/\1/p' "$d/install_s6_overlay.sh")
  FRIGATE_YQ=$(sed -nE 's|.*mikefarah/yq/releases/download/v([0-9.]+)/.*|\1|p' "$d/install_deps.sh" | head -1)
  [ -n "$FRIGATE_GO2RTC" ] && [ -n "$FRIGATE_S6" ] && [ -n "$FRIGATE_YQ" ] \
    || die "could not determine go2rtc/s6/yq versions in $d"
}

show_versions() {
  resolve_ha; resolve_frigate
  cat <<EOF
Home Assistant  $HA_VERSION  (Python $HA_PYTHON, go2rtc $HA_GO2RTC, FFmpeg $HA_FFMPEG, integrations: $HA_INTEGRATIONS)
Frigate         $FRIGATE_VERSION  (go2rtc $FRIGATE_GO2RTC, s6-overlay $FRIGATE_S6, yq $FRIGATE_YQ, tempio $TEMPIO_VERSION, ffmpeg Bianbu $FFMPEG_VERSION)
EOF
}

# ---------- targets ----------
build_ha() {
  resolve_ha
  local h; h=$(recipe homeassistant "$HA_VERSION $HA_PYTHON $HA_GO2RTC $HA_FFMPEG $HA_INTEGRATIONS")
  log "Home Assistant $HA_VERSION (Python $HA_PYTHON, go2rtc $HA_GO2RTC, FFmpeg $HA_FFMPEG, integrations: $HA_INTEGRATIONS)"
  if uptodate "k1/homeassistant:$HA_VERSION" "$h"; then echo "    already built, skipping"; return; fi
  dbuild homeassistant "$HA_VERSION" "$h" \
    --build-arg HA_VERSION="$HA_VERSION" --build-arg PYTHON_VERSION="$HA_PYTHON" \
    --build-arg GO2RTC_VERSION="$HA_GO2RTC" --build-arg FFMPEG_VERSION="$HA_FFMPEG" \
    --build-arg HA_INTEGRATIONS="$HA_INTEGRATIONS" --build-arg EXTRA_INDEX_URL="$SPACEMIT_INDEX" \
    homeassistant
}

build_k1det() {
  local h; h=$(recipe k1det)
  log "k1det ($h)"
  if uptodate "k1/k1det:$h" "$h"; then echo "    already built, skipping"; return; fi
  dbuild k1det "$h" "$h" --build-arg EXTRA_INDEX_URL="$SPACEMIT_INDEX" k1det
}

build_mosquitto() {
  local h; h=$(recipe mosquitto)
  log "Mosquitto ($h, Debian package)"
  if uptodate "k1/mosquitto:$h" "$h"; then echo "    already built, skipping"; return; fi
  dbuild mosquitto "$h" "$h" mosquitto
}

build_frigate() {
  resolve_frigate
  python3 frigate/adapt_requirements.py "$FRIGATE_SRC/docker/main/requirements-wheels.txt" \
    frigate/requirements-riscv64.txt frigate/requirements-riscv64-nodeps.txt
  local h; h=$(recipe frigate "$FRIGATE_VERSION $TEMPIO_VERSION $FFMPEG_VERSION $(cat frigate/requirements-riscv64*.txt | sha256sum)")
  log "Frigate $FRIGATE_VERSION (go2rtc $FRIGATE_GO2RTC, s6-overlay $FRIGATE_S6, tempio $TEMPIO_VERSION)"
  if uptodate "k1/frigate:$FRIGATE_VERSION" "$h"; then echo "    already built, skipping"; return; fi
  grep -h -E '^# DROP|# was|# dependency' frigate/requirements-riscv64.txt | sed 's/^/    /' || true
  grep -v '^#' frigate/requirements-riscv64-nodeps.txt | sed 's/^/    --no-deps: /' || true
  local up=.cache/frigate-upstream-$FRIGATE_VERSION
  frigate/fetch_upstream.sh "$FRIGATE_VERSION" "$up"
  STAGES="go2rtc downloads native ffmpeg wheels" \
  dbuild frigate "$FRIGATE_VERSION" "$h" --build-context src="$FRIGATE_SRC" --build-context upstream="$up" \
    --build-arg GO2RTC_VERSION="$FRIGATE_GO2RTC" \
    --build-arg S6_VERSION="$FRIGATE_S6" --build-arg TEMPIO_VERSION="$TEMPIO_VERSION" --build-arg YQ_VERSION="$FRIGATE_YQ" \
    --build-arg FFMPEG_VERSION="$FFMPEG_VERSION" --build-arg FFMPEG_DIR="/usr/lib/ffmpeg/$FFMPEG_VERSION" \
    --build-arg EXTRA_INDEX_URL="$SPACEMIT_INDEX $RISE_INDEX" --build-arg SPACEMIT_INDEX="$SPACEMIT_INDEX" \
    frigate
}

for t in "${TARGETS[@]}"; do
  case "$t" in
    versions) show_versions ;;
    ha) build_ha ;;
    k1det) build_k1det ;;
    mosquitto) build_mosquitto ;;
    frigate) build_frigate ;;
    all) build_k1det; build_mosquitto; build_ha; build_frigate ;;
  esac
done
docker image prune -f >/dev/null
if [ ${#BUILT[@]} -gt 0 ]; then log "built: ${BUILT[*]}"; else log "nothing new to build"; fi
