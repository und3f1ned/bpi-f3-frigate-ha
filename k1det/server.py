#!/usr/bin/env python3
"""k1det: detection server for Frigate on the SpacemiT K1 AI accelerator (SpaceMIT EP 2.x).

Serves two protocols at once:
  * ZMQ REP (Frigate's built-in `zmq` detector, Frigate ≥ 0.17):
      model_request  -> {"model_available", "model_loaded"}
      model_data     -> the model file is saved to --models and loaded
      [JSON header {"shape","dtype"}, tensor] -> 20x6 float32
  * Unix socket (spacemit_remote plugin for Frigate 0.13):
      b"K1D1", uint32 H, uint32 W, uint32 C, then H*W*C bytes of uint8 (NHWC, RGB) -> 20x6 float32
Reply: rows [class_id, score, y_min, x_min, y_max, x_max] as fractions 0..1, sorted by score descending.

Model: YOLOv8 INT8 (QDQ) with 9 raw outputs, like yolov8n_320x320.q.onnx from the SpacemiT demos;
box decoding (DFL) and NMS are done here.
"""
import argparse
import json
import logging
import os
import socket
import struct
import threading
import time

AI_CORES = {0, 1, 2, 3}  # only cluster 0 has IME; TCM needs the affinity set before the session is created
os.sched_setaffinity(0, AI_CORES)

import numpy as np  # noqa: E402
import onnxruntime as ort  # noqa: E402  must be imported before spacemit_ort
import spacemit_ort  # noqa: E402,F401  registers SpaceMITExecutionProvider
import zmq  # noqa: E402

MAGIC = b"K1D1"
HEADER = struct.Struct("<4sIII")
MAX_DETECTIONS = 20
ZERO = np.zeros((MAX_DETECTIONS, 6), np.float32)
log = logging.getLogger("k1det")


class Yolov8K1:
    def __init__(self, path: str, threads: int, min_score: float, iou: float):
        so = ort.SessionOptions()
        so.intra_op_num_threads = 1  # leave parallelism to the EP thread pool
        cores = ";".join(str(c) for c in sorted(AI_CORES)[:threads])
        self.session = ort.InferenceSession(
            path, so,
            providers=["SpaceMITExecutionProvider", "CPUExecutionProvider"],
            provider_options=[{"SPACEMIT_EP_INTRA_THREAD_NUM": str(threads),
                               "SPACEMIT_EP_INTRA_THREAD_AFFINITY": cores}, {}],
        )
        inp = self.session.get_inputs()[0]
        self.path, self.input_name = path, inp.name
        self.height, self.width = int(inp.shape[2]), int(inp.shape[3])
        if len(self.session.get_outputs()) != 9:
            raise ValueError("expected YOLOv8 with 9 outputs (DFL outside the graph)")
        self.min_score, self.iou = min_score, iou
        self.bins = np.arange(16, dtype=np.float32).reshape(1, 16, 1)
        for _ in range(3):  # warm-up
            self.detect(np.zeros((1, self.height, self.width, 3), np.uint8))
        log.info("model %s %dx%d, providers %s", path, self.width, self.height,
                 self.session.get_providers())

    def detect(self, x: np.ndarray) -> np.ndarray:
        """x: (1,H,W,3) or (1,3,H,W); uint8 0..255 or float 0..1 / 0..255."""
        if x.ndim == 4 and x.shape[-1] == 3:
            x = x.transpose(0, 3, 1, 2)
        x = np.ascontiguousarray(x, dtype=np.float32)
        if x.size and float(x.max()) > 1.5:
            x *= np.float32(1.0 / 255.0)
        return self._post(self.session.run(None, {self.input_name: x}))

    def _post(self, outs) -> np.ndarray:
        boxes, scores, classes = [], [], []
        for b in range(3):
            pos, cls = outs[3 * b][0], outs[3 * b + 1][0]  # (64,H,W), (80,H,W)
            nc, gh, gw = cls.shape
            stride = self.height / gh
            cls = cls.reshape(nc, -1)
            best = cls.max(axis=0)
            idx = np.nonzero(best >= self.min_score)[0]
            if idx.size == 0:
                continue
            classes.append(cls[:, idx].argmax(axis=0))
            scores.append(best[idx])
            p = pos.reshape(4, 16, -1)[:, :, idx]  # DFL: 4 sides x 16 bins
            p = np.exp(p - p.max(axis=1, keepdims=True))
            dist = (p * self.bins).sum(axis=1) / p.sum(axis=1)  # l, t, r, b in grid cells
            cx, cy = (idx % gw) + 0.5, (idx // gw) + 0.5
            boxes.append(np.stack([(cx - dist[0]) * stride, (cy - dist[1]) * stride,
                                   (cx + dist[2]) * stride, (cy + dist[3]) * stride], axis=1))
        det = ZERO.copy()
        if not boxes:
            return det
        boxes, scores, classes = np.concatenate(boxes), np.concatenate(scores), np.concatenate(classes)
        for i, k in enumerate(self._nms(boxes, scores, classes)[:MAX_DETECTIONS]):
            x1, y1, x2, y2 = boxes[k]
            det[i] = [classes[k], scores[k], max(0.0, y1 / self.height), max(0.0, x1 / self.width),
                      min(1.0, y2 / self.height), min(1.0, x2 / self.width)]
        return det

    def _nms(self, boxes, scores, classes):
        off = boxes + (classes.astype(np.float32) * 4096.0)[:, None]  # NMS per class
        x1, y1, x2, y2 = off.T
        areas = (x2 - x1) * (y2 - y1)
        order = scores.argsort()[::-1]
        keep = []
        while order.size:
            i = order[0]
            keep.append(i)
            rest = order[1:]
            inter = (np.clip(np.minimum(x2[i], x2[rest]) - np.maximum(x1[i], x1[rest]), 0, None)
                     * np.clip(np.minimum(y2[i], y2[rest]) - np.maximum(y1[i], y1[rest]), 0, None))
            order = rest[inter / (areas[i] + areas[rest] - inter + 1e-9) <= self.iou]
        return keep


class Detector:
    """Current model plus swapping it on Frigate's request; inference runs under a shared lock."""

    def __init__(self, args):
        self.args, self.lock = args, threading.Lock()
        self.model = self._load(args.model)
        self.n, self.t_sum = 0, 0.0

    def _load(self, path):
        return Yolov8K1(path, self.args.threads, self.args.min_score, self.args.iou)

    def run(self, x: np.ndarray) -> np.ndarray:
        with self.lock:
            t = time.perf_counter()
            det = self.model.detect(x)
            self.t_sum += time.perf_counter() - t
            self.n += 1
            if self.n % 1000 == 0:
                log.info("processed %d frames, %.1f ms on average", self.n, self.t_sum / self.n * 1000)
        return det

    def ensure(self, name: str) -> bool:
        """The named model is already loaded or gets loaded from the models directory."""
        name = os.path.basename(name)
        if os.path.basename(self.model.path) == name:
            return True
        path = os.path.join(self.args.models, name)
        if not os.path.exists(path):
            return False
        try:
            with self.lock:
                self.model = self._load(path)
            return True
        except Exception as e:  # noqa: BLE001
            log.error("failed to load %s: %s", path, e)
            return False

    def store(self, name: str, data: bytes) -> bool:
        path = os.path.join(self.args.models, os.path.basename(name))
        with open(path + ".tmp", "wb") as f:
            f.write(data)
        os.replace(path + ".tmp", path)
        return self.ensure(name)


def serve_zmq(det: Detector, endpoint: str) -> None:
    sock = zmq.Context.instance().socket(zmq.REP)
    if endpoint.startswith("ipc://"):
        p = endpoint[len("ipc://"):]
        os.makedirs(os.path.dirname(p), exist_ok=True)
        if os.path.exists(p):
            os.unlink(p)
    sock.bind(endpoint)
    if endpoint.startswith("ipc://"):
        os.chmod(endpoint[len("ipc://"):], 0o666)
    log.info("ZMQ: %s", endpoint)
    while True:
        frames = sock.recv_multipart()
        try:
            hdr = json.loads(frames[0].decode())
            if hdr.get("model_request"):
                ok = det.ensure(hdr.get("model_name", ""))
                sock.send_multipart([json.dumps({"model_available": ok, "model_loaded": ok}).encode()])
            elif hdr.get("model_data"):
                ok = len(frames) > 1 and det.store(hdr.get("model_name", "model.onnx"), frames[1])
                log.info("received model %s: %s", hdr.get("model_name"), "loaded" if ok else "failed")
                sock.send_multipart([json.dumps({"model_saved": bool(ok), "model_loaded": bool(ok)}).encode()])
            else:
                x = np.frombuffer(frames[1], dtype=np.dtype(hdr.get("dtype", "uint8"))).reshape(hdr["shape"])
                sock.send(det.run(x).tobytes())
        except Exception as e:  # noqa: BLE001
            log.error("ZMQ: request error: %s", e)
            sock.send(ZERO.tobytes())


def recv_exact(conn: socket.socket, n: int) -> bytearray:
    buf = bytearray(n)
    view, got = memoryview(buf), 0
    while got < n:
        r = conn.recv_into(view[got:])
        if r == 0:
            raise ConnectionError("client closed the connection")
        got += r
    return buf


def serve_unix_client(conn: socket.socket, det: Detector) -> None:
    with conn:
        while True:
            try:
                magic, h, w, c = HEADER.unpack(recv_exact(conn, HEADER.size))
            except ConnectionError:
                return
            if magic != MAGIC or c != 3 or h > 4096 or w > 4096:
                log.error("bad request: %r %dx%dx%d", magic, h, w, c)
                return
            frame = np.frombuffer(recv_exact(conn, h * w * c), np.uint8).reshape(1, h, w, c)
            conn.sendall(det.run(frame).tobytes())


def serve_unix(det: Detector, path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        os.unlink(path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    os.chmod(path, 0o666)
    srv.listen(8)
    log.info("Unix socket: %s", path)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=serve_unix_client, args=(conn, det), daemon=True).start()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", default="/models/yolov8n_320x320.q.onnx")
    ap.add_argument("--models", default="/models", help="directory for models sent by Frigate")
    ap.add_argument("--zmq", default="ipc:///run/k1det/zmq", help="'' to disable")
    ap.add_argument("--socket", default="/run/k1det/k1det.sock", help="'' to disable")
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--min-score", type=float, default=0.25)
    ap.add_argument("--iou", type=float, default=0.45)
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s: %(message)s")

    det = Detector(args)
    workers = []
    if args.socket:
        workers.append(threading.Thread(target=serve_unix, args=(det, args.socket), daemon=True))
    if args.zmq:
        workers.append(threading.Thread(target=serve_zmq, args=(det, args.zmq), daemon=True))
    for w in workers:
        w.start()
    for w in workers:
        w.join()


if __name__ == "__main__":
    main()
