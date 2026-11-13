#!/usr/bin/env bash
# Tests hardware H.264/HEVC decoding on the SpacemiT K1 VPU (Linlon) through ffmpeg stcodec.
#
# Note: Bianbu ffmpeg 6.1.1 (stcodec) + MPP 0.1.6 + the Armbian current kernel hang at
# end of stream (EOS): the last frames never come out and the decoder spins in a loop on
# "After EOS, no data, NOT return". So the measurements never run ffmpeg to the end of the file:
# the script reads -progress, takes the time at the target frame and kills the process.
# RTSP cameras have no end of stream, so this doesn't affect Frigate.
set -u

W=${WORKDIR:-/work/clips}
DUR=${DUR:-10}           # test clip length, seconds
FPS=30
TARGET=$((DUR * FPS - 75))  # frames to count: at EOS up to ~45 frames can still be in flight in the VPU
PAR=${PAR:-4}            # number of streams to decode at once
LIMIT=${LIMIT:-90}       # time limit for one measurement, seconds
NCPU=$(nproc)
HZ=$(getconf CLK_TCK)
mkdir -p "$W"

log() { printf '\n=== %s\n' "$*"; }
cpu_snap() { awk '/^cpu /{busy=$2+$3+$4+$7+$8+$9; total=busy+$5+$6; print busy, total}' /proc/stat; }
proc_ticks() { awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }

# measure <label> <file> <decoder|sw> [filter] [input frames per output frame] [decoder options...]
measure() {
  local label=$1 in=$2 dec=$3 vf=${4:-} mult=${5:-1}
  local args=(-hide_banner -nostats -loglevel quiet)
  [ "$dec" != sw ] && args+=(-c:v "$dec" "${@:6}")
  args+=(-i "$in")
  [ -n "$vf" ] && args+=(-vf "$vf" -pix_fmt yuv420p)
  args+=(-progress pipe:1 -stats_period 0.1 -f null -)
  local want=$((TARGET / mult)) f=0 k v
  local t0=$EPOCHREALTIME deadline=$((${EPOCHREALTIME%.*} + LIMIT))
  coproc FF { exec ffmpeg "${args[@]}" 2>/dev/null; }
  local pid=$FF_PID
  while IFS='=' read -r -t "$LIMIT" k v <&"${FF[0]}"; do
    [ "$k" = frame ] && f=$v
    [ "$f" -ge "$want" ] && break
    [ "${EPOCHREALTIME%.*}" -ge "$deadline" ] && break
  done
  local t1=$EPOCHREALTIME ticks; ticks=$(proc_ticks "$pid")
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  if [ "$f" -lt "$want" ]; then
    printf '%-40s ERROR: in %s s got only %s frames\n' "$label" "$LIMIT" "$f"; return 1
  fi
  awk -v l="$label" -v f="$((f * mult))" -v t0="$t0" -v t1="$t1" -v c="$ticks" -v hz="$HZ" 'BEGIN{
    w=t1-t0; printf "%-40s %7.1f fps  (x%.1f real time)  CPU %.2f cores\n", l, f/w, f/w/30, c/hz/w }'
}

# parallel <label> <file> <decoder> <N>
parallel() {
  local label=$1 in=$2 dec=$3 n=$4 i pids=()
  local dargs=(); [ "$dec" != sw ] && dargs=(-c:v "$dec")
  rm -f "$W"/par_*.txt
  read -r b0 c0 < <(cpu_snap); local t0=$EPOCHREALTIME
  for i in $(seq "$n"); do
    ffmpeg -hide_banner -nostats -loglevel quiet "${dargs[@]}" -i "$in" \
      -progress "$W/par_$i.txt" -stats_period 0.1 -f null - >/dev/null 2>&1 &
    pids+=($!)
  done
  local done_n=0 total=0 deadline=$((${EPOCHREALTIME%.*} + LIMIT))
  while :; do
    sleep 0.1; done_n=0; total=0
    for i in $(seq "$n"); do
      local f; f=$(grep -a '^frame=' "$W/par_$i.txt" 2>/dev/null | tail -1 | cut -d= -f2); f=${f:-0}
      total=$((total + f)); [ "$f" -ge "$TARGET" ] && done_n=$((done_n + 1))
    done
    [ "$done_n" -eq "$n" ] && break
    [ "${EPOCHREALTIME%.*}" -ge "$deadline" ] && break
  done
  local t1=$EPOCHREALTIME; read -r b1 c1 < <(cpu_snap)
  kill -9 "${pids[@]}" 2>/dev/null; wait 2>/dev/null
  awk -v l="$label" -v n="$n" -v d="$done_n" -v f="$total" -v t0="$t0" -v t1="$t1" \
      -v b0="$b0" -v b1="$b1" -v c0="$c0" -v c1="$c1" -v c="$NCPU" 'BEGIN{
    w=t1-t0; printf "%-40s %7.1f fps total (%.1f per stream)  CPU %.2f cores  reached target: %d of %d\n",
      l, f/w, f/w/n, (b1-b0)/(c1-c0)*c, d, n }'
}

# psnr <codec>: compare VPU frames with the software decoder (stats_file is written as it goes)
psnr() {
  local c=$1 n=100 st="$W/psnr_$1.txt"; rm -f "$st"
  ffmpeg -hide_banner -nostats -loglevel quiet -c:v "${c}_stcodec" -i "$W/${c}_1080p.mp4" -i "$W/${c}_1080p.mp4" \
    -lavfi "[0:v]format=yuv420p[a];[1:v]format=yuv420p[b];[a][b]psnr=stats_file=$st" -f null - >/dev/null 2>&1 &
  local pid=$! i
  for i in $(seq $((LIMIT * 10))); do
    sleep 0.1; [ -f "$st" ] && [ "$(wc -l < "$st")" -ge "$n" ] && break
  done
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  awk -v c="$c" '{for(i=1;i<=NF;i++) if($i ~ /^psnr_avg:/){split($i,p,":"); if(p[2]=="inf") inf++; else {s+=p[2]; k++}}}
    END{ if(NR==0){print "  " c ": could not compute"; exit}
         printf "  %s: %d frames, %d identical", c, NR, inf;
         if(k) printf ", mean PSNR of the rest %.1f dB", s/k; print "" }' "$st"
}

log "ffmpeg and hardware decoders"
ffmpeg -hide_banner -version | head -1
ffmpeg -hide_banner -decoders 2>/dev/null | grep -E '(h264|hevc)_(stcodec|v4l2m2m)' | sed 's/^/  /'
v4l2-ctl --list-devices 2>/dev/null | sed 's/^/  /'

if [ ! -s "$W/h264_1080p.mp4" ]; then
  log "Making H.264 1080p${FPS} test clip, ${DUR} s (encoded on the CPU, takes a while)"
  ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc2=size=1920x1080:rate=$FPS" -t "$DUR" \
    -c:v libx264 -preset ultrafast -g 60 -pix_fmt yuv420p "$W/h264_1080p.mp4" || exit 1
fi
if [ ! -s "$W/hevc_1080p.mp4" ]; then
  log "Making HEVC 1080p${FPS} test clip, ${DUR} s"
  ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc2=size=1920x1080:rate=$FPS" -t "$DUR" \
    -c:v libx265 -preset ultrafast -x265-params log-level=error -g 60 -pix_fmt yuv420p \
    -tag:v hvc1 "$W/hevc_1080p.mp4" || exit 1
fi

log "Single 1080p${FPS} stream, max speed (${TARGET} frames)"
measure "H.264 software (libavcodec)"    "$W/h264_1080p.mp4" sw
measure "H.264 VPU (h264_stcodec)"       "$W/h264_1080p.mp4" h264_stcodec
measure "HEVC software (libavcodec)"     "$W/hevc_1080p.mp4" sw
measure "HEVC VPU (hevc_stcodec)"        "$W/hevc_1080p.mp4" hevc_stcodec

log "Like a Frigate detect stream: decode + fps=5 + scale 640x360 + yuv420p"
measure "H.264 software + filters" "$W/h264_1080p.mp4" sw           "fps=5,scale=640:360" 6
measure "H.264 VPU + filters"      "$W/h264_1080p.mp4" h264_stcodec "fps=5,scale=640:360" 6
# The stcodec -scale option (downscaling in the VPU) doesn't work with the Armbian current
# kernel and MPP 0.1.6: frames stay full size. So it isn't measured here.

log "VPU frames vs software decoder (psnr_avg: inf = identical frames)"
psnr h264
psnr hevc

log "${PAR} 1080p streams at once"
parallel "H.264 VPU x${PAR}"         "$W/h264_1080p.mp4" h264_stcodec "$PAR"
parallel "HEVC VPU x${PAR}"          "$W/hevc_1080p.mp4" hevc_stcodec "$PAR"
parallel "H.264 software x${PAR}"    "$W/h264_1080p.mp4" sw           "$PAR"
