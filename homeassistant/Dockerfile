# syntax=docker/dockerfile:1
# Home Assistant Container for linux/riscv64 (SpacemiT K1 / BPI-F3).
# The official HA image is only built for amd64/arm64, so we install homeassistant from PyPI
# on python:3.x-slim-trixie. Prebuilt riscv64 wheels come from PyPI and the SpacemiT index,
# everything else is compiled right here. All versions are passed in by build.sh.

ARG PYTHON_VERSION=3.14
ARG GO_VERSION=1.26
ARG DEBIAN=trixie

# --- go2rtc for the go2rtc integration (the official HA image has it at /bin/go2rtc) ---
FROM golang:${GO_VERSION}-${DEBIAN} AS go2rtc
ARG GO2RTC_VERSION
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    git clone --depth 1 --branch "v${GO2RTC_VERSION}" https://github.com/AlexxIT/go2rtc /src \
 && cd /src && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /go2rtc . \
 && /go2rtc -version

# --- FFmpeg from source: PyAV (stream integration) needs a newer FFmpeg than Debian has ---
FROM python:${PYTHON_VERSION}-slim-${DEBIAN} AS ffmpeg
ARG FFMPEG_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential pkg-config curl xz-utils ca-certificates libssl-dev zlib1g-dev ccache \
 && rm -rf /var/lib/apt/lists/*
RUN --mount=type=cache,target=/root/.ccache \
    curl -fsSL "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" | tar -xJ -C /tmp \
 && cd "/tmp/ffmpeg-${FFMPEG_VERSION}" \
 && ./configure --prefix=/usr/local --cc="ccache gcc" --enable-shared --disable-static --disable-doc \
      --enable-gpl --enable-version3 --enable-openssl --disable-debug \
 && make -j"$(nproc)" && make install DESTDIR=/out \
 && rm -rf "/tmp/ffmpeg-${FFMPEG_VERSION}"

# --- Home Assistant ---
FROM python:${PYTHON_VERSION}-slim-${DEBIAN}
ARG HA_VERSION
ARG HA_INTEGRATIONS="default_config"
ARG EXTRA_INDEX_URL=https://git.spacemit.com/api/v4/projects/33/packages/pypi/simple

# Compilers and headers stay in the image: HA installs integration requirements when the
# integration is enabled, and on riscv64 some of them have to be built from source.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential pkg-config git curl ca-certificates tzdata iputils-ping \
      libturbojpeg0 libjpeg-dev zlib1g-dev libffi-dev libssl-dev \
      libatomic1 libgomp1 libpcap0.8 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=ffmpeg /out/usr/local/ /usr/local/
RUN ldconfig && ffmpeg -hide_banner -version | head -1

# UV_SYSTEM_PYTHON: HA installs integration packages with uv; without it they go to ~/.local,
# which is not on sys.path, and the integration fails to load (set as in the official image).
ENV PIP_EXTRA_INDEX_URL=${EXTRA_INDEX_URL} \
    UV_EXTRA_INDEX_URL=${EXTRA_INDEX_URL} \
    UV_SYSTEM_PYTHON=true \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONUNBUFFERED=1 \
    MAKEFLAGS=-j6

COPY collect_requirements.py /usr/src/
RUN --mount=type=cache,target=/root/.cache/pip \
    set -eux; \
    base="https://raw.githubusercontent.com/home-assistant/core/${HA_VERSION}"; \
    curl -4 -fsSL "$base/homeassistant/package_constraints.txt" -o /usr/src/constraints.txt; \
    python3 /usr/src/collect_requirements.py "${HA_VERSION}" ${HA_INTEGRATIONS} > /usr/src/integrations.txt; \
    head -1 /usr/src/integrations.txt; \
    pip install --upgrade pip wheel setuptools; \
    pip install "homeassistant==${HA_VERSION}" \
        -r /usr/src/integrations.txt -c /usr/src/constraints.txt; \
    python3 -c "import homeassistant.const as c, av; print('Home Assistant', c.__version__, 'PyAV', av.__version__, av.ffmpeg_version_info)"

COPY --from=go2rtc /go2rtc /bin/go2rtc

WORKDIR /config
VOLUME /config
EXPOSE 8123
CMD ["python3", "-m", "homeassistant", "--config", "/config"]
