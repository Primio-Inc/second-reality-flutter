#!/bin/bash
# Extract labelled reference frames from the Second Reality demo capture for
# visual comparison against our render (see the porting notes "VISUAL TEST").
# Video: https://www.youtube.com/watch?v=iw17c70uJes  ->  /tmp/sr_demo.mp4
#   yt-dlp -f "best[height<=720][ext=mp4]/best" -o /tmp/sr_demo.mp4 <url>
set -euo pipefail
cd "$(dirname "$0")/.."
V=/tmp/sr_demo.mp4
mkdir -p reference/frames
# name=timestamp(seconds)
frames=(
  "credits-fc=16" "credits-assembly=24" "credits-dolby=31"
  "horizon=40" "gfx-marvel=48" "music-pm=57" "code-psi=64" "adddesign=72"
  "ship=96" "ship-point=100" "explosion=104" "whiteflash=106"
  "title=108" "title-hold=112"
  "glenz-floor=118" "glenz-drop=123" "glenz-land=127" "glenz-sit=132"
  "glenz-inner-outer=138" "glenz-red-grow=145" "glenz-red-fill=150"
)
for fr in "${frames[@]}"; do
  name="${fr%%=*}"; t="${fr##*=}"
  ffmpeg -hide_banner -loglevel error -ss "$t" -i "$V" -frames:v 1 \
    "reference/frames/${t}s-${name}.png" -y
done
ls reference/frames/
