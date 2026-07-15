#!/bin/bash
# SUPERSEDED by tool/render_soundtrack.py: this mastered rip drifts against
# the real tracker modules by ~0.04% (MUSIC1's alignment walked from
# +104.340s at soundtrack t=120s to +104.460s at t=440s), which corrupts the
# music-ROW sync (lib/engine/music_rows.dart) late in long parts. Kept only
# for provenance / history; the old output is backed up at
# reference/music/soundtrack_mastered.ogg.
#
# Builds the demo soundtrack from the mastered Future Crew "Metropolis"
# release of the Second Reality music (three parts), hosted on archive.org:
#   https://archive.org/details/futurecrew-metropolis
#
# These are the authoritative renders of the demo tracks (Purple Motion &
# Skaven). We concatenate the three parts into one continuous track so the
# demo's master clock is a single, drift-free audio position.
#
# Part boundaries in the continuous track (needed for sync tables):
#   Pt1  0.000 s
#   Pt2  104.280 s
#   Pt3  473.730 s
#   end  720.140 s
#
# Requires: curl, ffmpeg
set -euo pipefail
cd "$(dirname "$0")/.."
BASE="https://archive.org/download/futurecrew-metropolis"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for n in 1 2 3; do
  curl -sL "$BASE/0$((n+1))-SecondReality-Pt${n}.ogg" -o "$tmp/pt${n}.ogg"
  # Decode to a common PCM format so concatenation is glitch-free at the
  # boundaries (direct ogg->ogg concat produces non-monotonic timestamps).
  ffmpeg -y -hide_banner -loglevel error -i "$tmp/pt${n}.ogg" \
    -ar 44100 -ac 2 "$tmp/pt${n}.wav"
done

printf "file '%s'\n" "$tmp/pt1.wav" "$tmp/pt2.wav" "$tmp/pt3.wav" > "$tmp/list.txt"
ffmpeg -y -hide_banner -loglevel error -f concat -safe 0 -i "$tmp/list.txt" \
  -c:a pcm_s16le "$tmp/full.wav"
ffmpeg -y -hide_banner -loglevel error -i "$tmp/full.wav" \
  -c:a libvorbis -q:a 5 assets/music/soundtrack.ogg

ffprobe -hide_banner assets/music/soundtrack.ogg 2>&1 | grep Duration
ls -lh assets/music/soundtrack.ogg
