# syntax=docker/dockerfile:1
# Frigate for linux/riscv64 (SpacemiT K1 / BPI-F3).
#
# Architecture-independent parts (Frigate code, the built web UI, s6/nginx configs) are used
# as is: /opt/frigate comes from the official arm64 image of the same version (context `upstream`,
# prepared by fetch_upstream.sh, which downloads only the top layer), rootfs and labelmaps come
# from the source at the release tag (context `src`). Native parts (nginx, go2rtc, s6-overlay,
# tempio, sqlite-vec, Python wheels, ffmpeg) are built here for riscv64. build.sh passes all versions.

ARG DEBIAN=trixie
ARG GO_VERSION=1.26
ARG BIANBU_IMAGE=harbor.spacemit.com/bianbu/bianbu:2.3.5

# --- go2rtc (no official riscv64 builds) ---
FROM golang:${GO_VERSION}-${DEBIAN} AS go2rtc
ARG GO2RTC_VERSION
RUN --mount=type=cache,target=/root/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    git clone --depth 1 --branch "v${GO2RTC_VERSION}" https://github.com/AlexxIT/go2rtc /src \
 && cd /src && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" \
      -o /rootfs/usr/local/go2rtc/bin/go2rtc . \
 && /rootfs/usr/local/go2rtc/bin/go2rtc -version

# --- s6-overlay, tempio, yq: prebuilt riscv64 releases ---
FROM debian:${DEBIAN}-slim AS downloads
ARG S6_VERSION
ARG TEMPIO_VERSION
ARG YQ_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && mkdir -p /rootfs/usr/local/tempio/bin \
 && for p in noarch riscv64; do \
      curl -fsSL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_VERSION}/s6-overlay-${p}.tar.xz" \
        | tar -C /rootfs -Jxpf - ; done \
 && curl -fsSL -o /rootfs/usr/local/tempio/bin/tempio \
      "https://github.com/home-assistant/tempio/releases/download/${TEMPIO_VERSION}/tempio_riscv64" \
 && chmod 755 /rootfs/usr/local/tempio/bin/tempio \
 && mkdir -p /rootfs/usr/local/bin \
 && curl -fsSL -o /rootfs/usr/local/bin/yq \
      "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_riscv64" \
 && chmod 755 /rootfs/usr/local/bin/yq

# --- nginx and sqlite-vec: Frigate's scripts patched by source-fixups.sed ---
FROM debian:${DEBIAN} AS native
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates wget unzip
RUN --mount=type=bind,from=src,source=docker/main,target=/upstream \
    --mount=type=bind,source=source-fixups.sed,target=/fixups.sed \
    set -eux; mkdir -p /deps; \
    for s in build_nginx.sh build_sqlite_vec.sh; do \
      sed -f /fixups.sed /upstream/$s > /deps/$s; chmod +x /deps/$s; done; \
    grep -h -E 'wget .*github' /deps/build_nginx.sh
RUN --mount=type=cache,target=/root/.ccache /deps/build_nginx.sh
RUN --mount=type=tmpfs,target=/tmp /deps/build_sqlite_vec.sh

# --- Python wheels for cp313/riscv64 ---
FROM debian:${DEBIAN} AS wheels
ARG EXTRA_INDEX_URL
ENV DEBIAN_FRONTEND=noninteractive PIP_BREAK_SYSTEM_PACKAGES=1 \
    PIP_EXTRA_INDEX_URL=${EXTRA_INDEX_URL} PIP_PREFER_BINARY=1 \
    CARGO_BUILD_JOBS=4 MAKEFLAGS=-j4
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-dev python3-pip python3-venv build-essential cmake git pkg-config wget unzip \
      gfortran libopenblas-dev liblapack-dev libssl-dev libffi-dev libsqlite3-dev tclsh \
      libjpeg-dev zlib1g-dev libsndfile1-dev rustc cargo ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN --mount=type=bind,from=src,source=docker/main/build_pysqlite3.sh,target=/upstream/build_pysqlite3.sh \
    --mount=type=bind,source=source-fixups.sed,target=/fixups.sed \
    --mount=type=cache,target=/root/.cache/pip \
    sed -f /fixups.sed /upstream/build_pysqlite3.sh > /build_pysqlite3.sh \
 && grep -E '^PYSQLITE3_VERSION' /build_pysqlite3.sh \
 && pip3 install "scikit-build==0.18.*" && bash /build_pysqlite3.sh
COPY requirements-riscv64.txt requirements-riscv64-nodeps.txt /
RUN --mount=type=cache,target=/root/.cache/pip \
    pip3 wheel --wheel-dir=/wheels -r /requirements-riscv64.txt \
 && pip3 wheel --no-deps --wheel-dir=/wheels -r /requirements-riscv64-nodeps.txt
# Packages that link against libonnxruntime must be SpacemiT's builds for its ORT 1.24.2.
# The RISE index has files with the same names but built against a different ORT (import fails
# with "version VERS_1.29.0 not found"), and which one pip picks is down to chance. Swap explicitly.
ARG SPACEMIT_INDEX
ARG ORT_LINKED="sherpa_onnx"
RUN --mount=type=cache,target=/root/.cache/pip set -e; \
    for p in ${ORT_LINKED}; do for w in /wheels/$p-*.whl; do \
      [ -e "$w" ] || continue; v=$(basename "$w" | cut -d- -f2); rm "$w"; \
      env -u PIP_EXTRA_INDEX_URL pip3 download --no-deps --only-binary=:all: \
        --index-url "${SPACEMIT_INDEX}" -d /wheels "$p==$v"; \
    done; done

# --- ffmpeg with VPU hardware decoding (stcodec) from Bianbu ---
FROM ${BIANBU_IMAGE} AS ffmpeg
ARG FFMPEG_DIR
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*
COPY ffmpeg_bundle.sh /usr/local/bin/
RUN ffmpeg -hide_banner -decoders | grep -q h264_stcodec && ffmpeg_bundle.sh /rootfs "${FFMPEG_DIR}"

# --- final image ---
FROM debian:${DEBIAN}-slim AS frigate
ARG FFMPEG_VERSION
ENV DEBIAN_FRONTEND=noninteractive PIP_BREAK_SYSTEM_PACKAGES=1
# libxrender1: cv2 in the riscv64 opencv wheel is linked against X11
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates wget curl lbzip2 procps unzip locales tzdata libxml2 xz-utils \
      python3 python3-pip lsof jq libgl1 libglib2.0-0 libusb-1.0-0 python3-h2 \
      libgomp1 libatomic1 libopenblas0 libsndfile1 libjpeg62-turbo libssl3t64 libpcre2-8-0 \
      libxrender1 \
 && rm -rf /var/lib/apt/lists/*
RUN --mount=type=bind,from=wheels,source=/wheels,target=/deps/wheels \
    pip3 install --no-cache-dir --no-index --no-deps --ignore-installed /deps/wheels/*.whl
# (the set is complete, pip wheel resolved it; --ignore-installed: pip can't uninstall Debian
#  packages like python3-packaging, and it installs into /usr/local, which comes first in sys.path)
# tflite_runtime stub: there is no TFLite for riscv64, but Frigate imports it unconditionally.
COPY stubs/ /usr/local/lib/k1-stubs/
RUN cp -r /usr/local/lib/k1-stubs/* "$(python3 -c 'import sysconfig; print(sysconfig.get_path("purelib"))')/"

COPY --from=downloads /rootfs/ /
COPY --from=go2rtc /rootfs/ /
COPY --from=native /usr/local/nginx/ /usr/local/nginx/
COPY --from=native /usr/local/lib/ /usr/local/lib/
COPY --from=ffmpeg /rootfs/ /
COPY --from=src docker/main/rootfs/ /
COPY --from=upstream opt/frigate/ /opt/frigate/
COPY --from=src labelmap.txt audio-labelmap.txt /
# Frigate hardcodes /usr/lib/ffmpeg/8.0 for export thumbnails.
RUN ldconfig && { [ -e /usr/lib/ffmpeg/8.0 ] || ln -s "${FFMPEG_VERSION}" /usr/lib/ffmpeg/8.0; } \
 && /usr/lib/ffmpeg/${FFMPEG_VERSION}/bin/ffmpeg -hide_banner -decoders | grep -q h264_stcodec \
 && { find /usr/local/lib/python3*/dist-packages -name '*.so*' -type f -exec ldd {} + 2>/dev/null \
        | grep 'not found' | grep -v -- '-[0-9a-f]\{8\}\.so' | sort -u | sed 's/^/missing lib: /'; true; } \
 && python3 -c "import cv2, numpy, onnxruntime, sherpa_onnx, scipy, pandas, zmq; print('python deps ok', numpy.__version__, cv2.__version__, onnxruntime.__version__)" \
 && cd /opt/frigate && python3 -c "import frigate.app; print('frigate.app import ok')"

ENV PATH="/usr/local/go2rtc/bin:/usr/local/tempio/bin:/usr/local/nginx/sbin:${PATH}" \
    DEFAULT_FFMPEG_VERSION=${FFMPEG_VERSION} \
    INCLUDED_FFMPEG_VERSIONS=${FFMPEG_VERSION} \
    S6_LOGGING_SCRIPT="T 1 n0 s10000000 T" \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    TOKENIZERS_PARALLELISM=true \
    TRANSFORMERS_NO_ADVISORY_WARNINGS=1 \
    OPENCV_FFMPEG_LOGLEVEL=8 \
    PYTHONWARNINGS="ignore:::numpy.core.getlimits"

EXPOSE 5000 8554 8555/tcp 8555/udp 8971
WORKDIR /opt/frigate/
ENTRYPOINT ["/init"]
CMD []
