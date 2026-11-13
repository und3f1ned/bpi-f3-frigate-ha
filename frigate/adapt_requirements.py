#!/usr/bin/env python3
"""Adapts Frigate's docker/main/requirements-wheels.txt for linux/riscv64 + Python 3.13.

  adapt_requirements.py requirements-wheels.txt requirements-riscv64.txt requirements-riscv64-nodeps.txt

Rules (the same for all Frigate versions; extend them here when new incompatible packages
show up):
  DROP    — packages that don't exist for riscv64 and that Frigate can start without
            (imported lazily or only needed by specific detectors/features);
  RELAX   — pins that can't be met on cp313/riscv64 (old versions with no wheels and no
            Python 3.13 / numpy 2 support): the pin is replaced with a range the indexes have;
  RENAME  — replace a package with an equivalent;
  NODEPS  — packages whose metadata forbids numpy 2 even though the code works with it: installed
            with --no-deps (into the second file), and their other dependencies are added explicitly.
Everything else stays as is; anything without a wheel is built from source.
"""
import re
import sys

ONNXRUNTIME = "onnxruntime==1.24.2+spacemit.a2"   # SpacemiT build (cp312-cp314 riscv64)

DROP = [
    r"tensorflow(-cpu)?",          # not available for riscv64; only needed to train classifiers
    r"openvino",                   # Intel detector/converter
    r"tflite[-_]runtime",          # CPU/EdgeTPU detectors, audio; replaced by frigate/stubs
    r"faster-whisper",             # no ctranslate2 for cp313 riscv64; audio transcription
    r"memray",                     # profiler, lazy import
    r"mypy",                       # dev tool
]
RELAX = {
    "numpy": "numpy>=2.2,<2.6",                 # 1.26 doesn't support Python 3.13
    "onnxruntime": ONNXRUNTIME,
    "pandas": "pandas>=2.2",
    "scipy": "scipy>=1.15",
    "shapely": "shapely>=2.1",
    "pyzmq": "pyzmq>=26",
    "cryptography": "cryptography>=44",
    "rapidfuzz": "rapidfuzz>=3.12",
    "netifaces": "netifaces>=0.10",
    "transformers": "transformers>=4.45,<5",   # old tokenizers have no riscv64 wheels (Rust)
    "psutil": "psutil>=7.1",
}
NODEPS = {
    # norfair 2.3.0 (latest) declares numpy<2; pure Python on top of numpy/scipy
    "norfair": ["filterpy>=1.4.5,<2.0.0", "rich>=9.10.0,<15.0.0"],
}
RENAME = {
    # both packages provide the same cv2 module; contrib only has a headless 4.11 build for riscv64
    "opencv-contrib-python": "opencv-contrib-python-headless",
}


def name_of(line: str) -> str:
    m = re.match(r"\s*([A-Za-z0-9_.\-]+)", line)
    return m.group(1).lower().replace("_", "-") if m else ""


def main() -> None:
    src, out_main, out_nodeps = sys.argv[1:4]
    out = ["# adapted for linux/riscv64 (bpi-f3-frigate-ha/frigate/adapt_requirements.py)"]
    nodeps = ["# installed with --no-deps (see NODEPS in adapt_requirements.py)"]
    for raw in open(src, encoding="utf-8"):
        line = raw.rstrip("\n")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("git+"):
            out.append(stripped)
            continue
        name = name_of(stripped)
        if any(re.fullmatch(p, name) for p in DROP):
            out.append(f"# DROP {stripped}")
            continue
        if name in NODEPS:
            nodeps.append(stripped)
            out.extend(f"{d}  # dependency of {name}" for d in NODEPS[name])
            continue
        if name in RELAX:
            out.append(f"{RELAX[name]}  # was: {stripped}")
            continue
        if name in RENAME:
            stripped = RENAME[name] + stripped[len(name):]
        out.append(stripped)
    open(out_main, "w", encoding="utf-8").write("\n".join(out) + "\n")
    open(out_nodeps, "w", encoding="utf-8").write("\n".join(nodeps) + "\n")


if __name__ == "__main__":
    main()
