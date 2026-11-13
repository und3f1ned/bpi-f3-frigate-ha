#!/bin/sh
# Bundles a portable copy of ffmpeg/ffprobe from Bianbu (stcodec + MPP, K1 VPU hardware decoding)
# with all its libraries and its own glibc loader.
#   ffmpeg_bundle.sh /rootfs /usr/lib/ffmpeg/6.1
# Files go to <root><dir>, the MPP plugin to <root>/usr/lib (MPP loads it by absolute path).
# Runs inside the harbor.spacemit.com/bianbu/bianbu image with ffmpeg installed.
set -eu
ROOT=$1
DIR=$2
OUT="$ROOT$DIR"
mkdir -p "$OUT/bin" "$OUT/real" "$OUT/lib" "$ROOT/usr/lib"
cp /usr/bin/ffmpeg /usr/bin/ffprobe "$OUT/real/"
for f in /usr/bin/ffmpeg /usr/bin/ffprobe /usr/lib/libv4l2_linlonv5v7_codec.so; do ldd "$f"; done \
  | awk '/=> \// {print $3} /^[[:space:]]*\/lib.*ld-linux/ {print $1}' | sort -u \
  | while read -r l; do cp -L "$l" "$OUT/lib/"; done
cp -L /lib/ld-linux-riscv64-lp64d.so.1 "$OUT/lib/"
cp -L /usr/lib/libv4l2_linlonv5v7_codec.so "$ROOT/usr/lib/"
# Wrappers: bundled libraries and loader. The ffmpeg one also splits output: libspacemit_mpp printf()s
# debug output to stdout, and if ffmpeg's output also goes to stdout (that's how Frigate reads frames:
# last argument pipe:/pipe:1/-), the text lands in the rawvideo stream and shifts every frame. So the
# output is sent to fd 3 (the original stdout), and the process's stdout goes to stderr.
for t in ffmpeg ffprobe; do
  {
    echo '#!/bin/sh'
    echo "# $t from Bianbu (stcodec/MPP for the SpacemiT K1 VPU) with bundled libraries and glibc loader."
    if [ "$t" = ffmpeg ]; then cat <<'SPLIT'
# Output to stdout -> fd 3; process stdout (libspacemit_mpp debug) -> stderr.
last=; [ $# -gt 0 ] && eval "last=\${$#}"
case "$last" in
  pipe:|pipe:1|-)
    n=$#; i=0
    for a in "$@"; do i=$((i + 1)); [ "$i" -eq "$n" ] && a=pipe:3; set -- "$@" "$a"; done
    shift "$n"
    exec 3>&1 1>&2 ;;
esac
SPLIT
    fi
    echo "exec \"$DIR/lib/ld-linux-riscv64-lp64d.so.1\" --library-path \"$DIR/lib\" \"$DIR/real/$t\" \"\$@\""
  } > "$OUT/bin/$t"
  chmod 755 "$OUT/bin/$t"
done
echo "ffmpeg bundle: $(ls "$OUT/lib" | wc -l) libraries, $(du -sh "$OUT" | cut -f1)"
