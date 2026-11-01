#!/bin/sh
# Renders the opening clip for MacStats' page on apps.csarko.sh: docs/previews/hero.mp4
# (2880 by 1600, 30 fps) with its last frame as docs/previews/hero.jpg, the page's poster and
# share card. scripts/hero-video/main.swift draws every frame with MacStats' own menu bar items
# and CPU panel, fed a scripted minute of readings, over an original backdrop: no screen is
# recorded and no process of this Mac is shown.
#
#   sh scripts/hero-video.sh              into docs/previews/
#   sh scripts/hero-video.sh <out dir>    somewhere else, to look before replacing
#   sh scripts/hero-video.sh --preview    a quarter of the size at 15 fps into /tmp, in seconds
#
# Needs the Xcode command line tools (swiftc) and ffmpeg. Every frame is drawn for its own time,
# so the clip is the same on every run.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v ffmpeg >/dev/null || { echo "hero-video.sh: ffmpeg is required" >&2; exit 1; }
mkdir -p "$ROOT/build"
BIN="$ROOT/build/hero-scene"
# The harness with every source of the app but its main.swift, whose command line it replaces.
set --  "$@"
SOURCES=$(ls "$ROOT"/Sources/MacStats/*.swift | grep -v '/main\.swift$')
# shellcheck disable=SC2086
swiftc -O -o "$BIN" $SOURCES "$ROOT/scripts/hero-video/main.swift"
if [ "${1:-}" = --preview ]; then
  OUT="${TMPDIR:-/tmp}/macstats-hero"
  mkdir -p "$OUT"
  "$BIN" "$OUT/hero.mp4" --poster "$OUT/hero.jpg" --preview
  exit 0
fi
OUT="${1:-$ROOT/docs/previews}"
mkdir -p "$OUT"
"$BIN" "$OUT/hero.mp4" --poster "$OUT/hero.jpg"
