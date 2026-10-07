#!/bin/bash
# Takes the README's screenshots into docs/previews/: the menu bar group, and each panel
# in dark and light. Real captures, not renders: it quits the running MacStats, runs the
# one in build/ (make app first) with --appearance and --show-panel, waits three minutes
# for the charts to fill, captures each panel's window with screencapture, then starts
# the installed MacStats again. Needs Screen Recording permission for the terminal.
#
#   make app && sh scripts/previews.sh           # about eight minutes
#   sh scripts/previews.sh --quick               # no wait: empty charts, for a layout check
#
# The Disk panel shows this Mac's folders; the README's own capture used a sample list
# written to ~/Library/Caches/sh.csarko.MacStats/folders.json first.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/MacStats.app/Contents/MacOS/MacStats"
OUT="$ROOT/docs/previews"
WAIT=185
[ "${1:-}" = --quick ] && WAIT=3
[ -x "$APP" ] || { echo "previews.sh: build the app first: make app" >&2; exit 1; }
mkdir -p "$OUT"

# A helper that prints the id of MacStats' tallest window (an open panel), and the menu
# bar span its status items cover, in points: "<left> <width>".
HELPER="$(mktemp -d)/windows"
cat > "$HELPER.swift" <<'EOF'
import Cocoa
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let bounds = { (window: [String: Any]) -> (x: Double, width: Double, height: Double)? in
    guard let b = window["kCGWindowBounds"] as? [String: Double], let x = b["X"], let w = b["Width"], let h = b["Height"] else { return nil }
    return (x, w, h)
}
if CommandLine.arguments.count > 1 {
    // The status items: layer 25, named by their autosave names (MacStatsCPU …) on macOS 26.
    // Printed: where the group starts, the screen's width, and where the hero's bar starts, in points.
    let items = windows.filter { ($0["kCGWindowLayer"] as? Int) == 25 && (($0["kCGWindowName"] as? String) ?? "").hasPrefix("MacStats") }
        .compactMap(bounds)
    guard let left = items.map(\.x).min(), let screen = NSScreen.main else { exit(1) }
    // Where the bar starts for the hero: the notch's right edge, or the screen's left edge.
    let barStart = screen.auxiliaryTopRightArea?.minX ?? 0
    print(Int(left), Int(screen.frame.width), Int(barStart))
} else {
    let panels = windows.filter { ($0["kCGWindowOwnerName"] as? String) == "MacStats" }
        .compactMap { window -> (id: Int, height: Double)? in
            guard let id = window["kCGWindowNumber"] as? Int, let b = bounds(window), b.height > 100 else { return nil }
            return (id, b.height)
        }
    guard let best = panels.max(by: { $0.height < $1.height }) else { exit(1) }
    print(best.id)
}
EOF
xcrun swiftc "$HELPER.swift" -o "$HELPER" 2>/dev/null

pkill -x MacStats || true
sleep 1
for look in dark light; do
  "$APP" --appearance "$look" --show-panel cpu,gpu,ram,temp,disk --after "$WAIT" --each 8 >/dev/null 2>&1 &
  PID=$!
  sleep "$((WAIT + 4))"
  for panel in cpu gpu ram temp disk; do
    if id="$("$HELPER")"; then
      screencapture -x -o -l "$id" "$OUT/$panel-$look.png" && echo "captured $panel-$look"
    else
      echo "previews.sh: no $panel panel on screen" >&2
    fi
    sleep 8
  done
  # The hero: the bar from the notch's edge to the screen's edge (the system's own icons
  # and the clock show it is the menu bar), composed over a gradient with the CPU panel
  # under its item (the dark run; the bar's look is the system's).
  if [ "$look" = dark ] && span="$("$HELPER" items)"; then
    set -- $span
    screencapture -x -R "$3,0,$(($2 - $3)),24" "$OUT/bar.png" \
      && xcrun swift "$ROOT/scripts/compose-hero.swift" "$OUT/bar.png" "$OUT/cpu-dark.png" "$(($1 - $3))" "$OUT/menubar.png" 390 \
      && rm -f "$OUT/bar.png" && echo "composed menubar"
  fi
  kill "$PID" 2>/dev/null || true
  sleep 1
done
rm -rf "$(dirname "$HELPER")"

# screencapture writes metadata chunks (EXIF, XMP text, Apple's iDOT) into each PNG; a
# published image needs none of them. Keep the colour profile and the pixels.
python3 - "$OUT"/*.png <<'EOF'
import struct, sys
for path in sys.argv[1:]:
    data = open(path, "rb").read(); out = bytearray(data[:8]); i = 8
    while i < len(data):
        n = struct.unpack(">I", data[i:i + 4])[0]; kind = data[i + 4:i + 8]
        if kind not in (b"eXIf", b"iTXt", b"tEXt", b"zTXt", b"iDOT", b"tIME"): out += data[i:i + 12 + n]
        i += 12 + n
    open(path, "wb").write(out)
EOF
open -a "$HOME/Applications/MacStats.app" 2>/dev/null || true
echo "Previews in $OUT"
