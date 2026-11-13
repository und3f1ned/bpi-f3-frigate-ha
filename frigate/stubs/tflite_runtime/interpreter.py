"""tflite_runtime.interpreter stub (see __init__.py)."""

_MSG = ("TensorFlow Lite is not available on linux/riscv64 (bpi-f3-frigate-ha build): this Frigate feature "
        "(bird/custom object classification, audio detection, small face recognition model, "
        "cpu/edgetpu detectors) is not supported")


class Interpreter:
    def __init__(self, *args, **kwargs):
        raise RuntimeError(_MSG)


def load_delegate(*args, **kwargs):
    # Frigate catches ValueError when there is no EdgeTPU
    raise ValueError(_MSG)
