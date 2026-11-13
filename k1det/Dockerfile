# syntax=docker/dockerfile:1
# k1det: detection server for Frigate on the SpacemiT K1 AI accelerator, plus test tools.
#  - SpacemiT's onnxruntime + SpaceMIT Execution Provider (IME on cores 0-3), libspine_tcm;
#  - ffmpeg from Bianbu with the stcodec hardware decoders (for decode_test.sh);
#  - server.py (ZMQ for Frigate ≥0.17 and a Unix socket for 0.13), bench_ort.py, decode_test.sh.
# The host needs a kernel with the tcm and amvx drivers and firmware /lib/firmware/linlon-v52_v76-80-2.
ARG BIANBU_IMAGE=harbor.spacemit.com/bianbu/bianbu:2.3.5
FROM ${BIANBU_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ARG EXTRA_INDEX_URL=https://git.spacemit.com/api/v4/projects/33/packages/pypi/simple
ARG ORT_VERSION=1.24.2+spacemit.a2
# EP 2.0.6 is the last one without the external libspert.so.1 (no package index has it)
ARG SPACEMIT_ORT_VERSION=2.0.6
# 3.0.0-bpo1+2 is built for K1; 3.0.1 is for K3 and doesn't work on K1
ARG SPACEMIT_TCM_DEB=https://archive.spacemit.com/bianbu/pool/main/s/spacemit-tcm/spacemit-tcm_3.0.0-bpo1+2_riscv64.deb
ARG SPACEMIT_TCM_SHA256=68ed23112cbc2b3a14d61c9eeec9cd1215da66a8bd81c5f0db07c6522ff1133d
ARG MODEL_URL=https://archive.spacemit.com/spacemit-ai/BRDK/Model_Zoo/CV/YOLOv8/yolov8n_320x320.q.onnx
ARG LABELS_URL=https://archive.spacemit.com/spacemit-ai/BRDK/Model_Zoo/Datasets/Coco/label.txt

# The image already has the Bianbu repos at priority 1100, so ffmpeg comes with stcodec and mpp.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl ffmpeg python3-venv python3-pip v4l-utils procps libatomic1 \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/tcm.deb "${SPACEMIT_TCM_DEB}" \
 && echo "${SPACEMIT_TCM_SHA256}  /tmp/tcm.deb" | sha256sum -c - \
 && dpkg -i /tmp/tcm.deb && rm /tmp/tcm.deb

# onnxruntime has to be the "+spacemit" build, otherwise spacemit_ort refuses to load.
RUN --mount=type=cache,target=/root/.cache/pip \
    python3 -m venv /opt/k1 \
 && /opt/k1/bin/pip install --only-binary=:all: \
      --index-url "${EXTRA_INDEX_URL}" --extra-index-url https://pypi.org/simple \
      "onnxruntime==${ORT_VERSION}" "spacemit-ort==${SPACEMIT_ORT_VERSION}" "numpy>=2.2,<2.6" "pyzmq>=26"

RUN mkdir -p /models /opt/k1/default-models \
 && curl -fsSL -o /opt/k1/default-models/yolov8n_320x320.q.onnx "${MODEL_URL}" \
 && curl -fsSL -o /opt/k1/default-models/coco80.txt "${LABELS_URL}" \
 && cp /opt/k1/default-models/* /models/

COPY server.py bench_ort.py decode_test.sh /opt/k1/
RUN chmod +x /opt/k1/*.py /opt/k1/*.sh \
 && ffmpeg -hide_banner -decoders | grep -q h264_stcodec \
 && /opt/k1/bin/python -c "import onnxruntime, spacemit_ort, zmq; print('onnxruntime', onnxruntime.__version__, 'pyzmq', zmq.__version__)"

ENV PATH=/opt/k1/bin:/opt/k1:$PATH
WORKDIR /work
# If /models is empty (fresh volume), the default model is copied there.
CMD ["sh", "-c", "cp -n /opt/k1/default-models/* /models/ 2>/dev/null; exec python /opt/k1/server.py"]
