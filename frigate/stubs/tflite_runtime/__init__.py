"""tflite_runtime stub for linux/riscv64 (bpi-f3-frigate-ha).

There is no TensorFlow Lite for riscv64, but Frigate imports it at the top level of modules that
are always loaded (bird classification, custom classifiers, audio, small face recognition model,
cpu/edgetpu detectors). The stub lets those modules import; the features themselves fail with a
clear error when enabled. Object detection goes through the zmq detector (k1det) and doesn't use TFLite.
"""
