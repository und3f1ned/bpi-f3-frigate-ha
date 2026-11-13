#!/usr/bin/env python3
"""Compares the SpaceMIT Execution Provider with the plain CPU EP on a quantized model (SpacemiT K1).

Prints latency, throughput, core usage and how far the outputs of the two providers differ.
"""
import argparse
import os
import statistics
import time

# The IME AI instructions exist only on cores 0-3, and TCM needs the affinity set before the session is created.
AI_CORES = {0, 1, 2, 3}
os.sched_setaffinity(0, AI_CORES)

import numpy as np  # noqa: E402
import onnxruntime as ort  # noqa: E402  must be imported before spacemit_ort
import spacemit_ort  # noqa: E402,F401  registers SpaceMITExecutionProvider


def make_session(model: str, use_ep: bool, threads: int) -> ort.InferenceSession:
    so = ort.SessionOptions()
    if use_ep:
        so.intra_op_num_threads = 1  # leave parallelism to the EP thread pool
        ep_opts = {
            "SPACEMIT_EP_INTRA_THREAD_NUM": str(threads),
            "SPACEMIT_EP_INTRA_THREAD_AFFINITY": ";".join(str(c) for c in sorted(AI_CORES)[:threads]),
        }
        return ort.InferenceSession(
            model,
            so,
            providers=["SpaceMITExecutionProvider", "CPUExecutionProvider"],
            provider_options=[ep_opts, {}],
        )
    so.intra_op_num_threads = threads
    return ort.InferenceSession(model, so, providers=["CPUExecutionProvider"])


def bench(sess: ort.InferenceSession, feed: dict, n: int, warmup: int):
    for _ in range(warmup):
        sess.run(None, feed)
    lat = []
    cpu0, wall0 = time.process_time(), time.perf_counter()
    out = None
    for _ in range(n):
        t = time.perf_counter()
        out = sess.run(None, feed)
        lat.append((time.perf_counter() - t) * 1000.0)
    wall, cpu = time.perf_counter() - wall0, time.process_time() - cpu0
    lat.sort()
    return out, {
        "median_ms": statistics.median(lat),
        "p90_ms": lat[int(0.9 * (len(lat) - 1))],
        "fps": n / wall,
        "cores_busy": cpu / wall,
    }


def compare(a, b) -> str:
    parts = []
    for i, (x, y) in enumerate(zip(a, b)):
        x, y = np.asarray(x, np.float64).ravel(), np.asarray(y, np.float64).ravel()
        cos = float(np.dot(x, y) / (np.linalg.norm(x) * np.linalg.norm(y) + 1e-12))
        parts.append(f"output {i}: max|Δ|={np.max(np.abs(x - y)):.4g}, cos={cos:.5f}")
    return "; ".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--model", default="/models/yolov8n_320x320.q.onnx")
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("-n", type=int, default=200, help="runs on SpaceMIT EP")
    ap.add_argument("--n-cpu", type=int, default=30, help="runs on CPU EP")
    ap.add_argument("--warmup", type=int, default=10)
    args = ap.parse_args()

    print(f"onnxruntime {ort.__version__}, spacemit_ort {getattr(spacemit_ort, '__version__', '?')}")
    print("available providers:", ", ".join(ort.get_available_providers()))
    print("process CPU affinity:", sorted(os.sched_getaffinity(0)))

    ep = make_session(args.model, True, args.threads)
    print("EP session providers:", ep.get_providers())
    inp = ep.get_inputs()[0]
    shape = [d if isinstance(d, int) else 1 for d in inp.shape]
    print(f"input {inp.name} {inp.shape} {inp.type}; outputs:",
          [(o.name, o.shape) for o in ep.get_outputs()])

    rng = np.random.default_rng(0)
    feed = {inp.name: rng.random(shape, dtype=np.float32)}

    out_ep, r_ep = bench(ep, feed, args.n, args.warmup)
    del ep
    cpu = make_session(args.model, False, args.threads)
    out_cpu, r_cpu = bench(cpu, feed, args.n_cpu, max(2, args.warmup // 5))

    print()
    print(f"{'provider':<22}{'median, ms':>12}{'p90, ms':>10}{'fps':>9}{'cores busy':>13}")
    for name, r in (("SpaceMIT EP", r_ep), ("CPU EP", r_cpu)):
        print(f"{name:<22}{r['median_ms']:>12.2f}{r['p90_ms']:>10.2f}{r['fps']:>9.1f}{r['cores_busy']:>13.2f}")
    print(f"\nEP speedup over CPU: x{r_cpu['median_ms'] / r_ep['median_ms']:.1f}")
    print("EP vs CPU outputs:", compare(out_ep, out_cpu))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
