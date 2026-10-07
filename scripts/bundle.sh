#!/bin/sh
# Assembles build/MacStats.app from a built MacStats binary: the bundle's Info.plist
# (with the version from VERSION), the app icon the binary draws itself, and an ad-hoc
# signature. `make app` builds the binary and runs this.
#
#   sh scripts/bundle.sh [path/to/MacStats binary]   # default .build/release/MacStats
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$ROOT/.build/release/MacStats}"
APP="$ROOT/build/MacStats.app"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

[ -x "$BIN" ] || { echo "bundle.sh: no binary at $BIN (run \`swift build -c release\` first)" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacStats"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>sh.csarko.MacStats</string>
  <key>CFBundleName</key><string>MacStats</string>
  <key>CFBundleExecutable</key><string>MacStats</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHumanReadableCopyright</key><string>MIT licence. Parts adapted from Stats (MIT, Serhiy Mytrovtsiy).</string>
</dict>
</plist>
EOF

# The icon: MacStats draws it (AppIcon.swift) at the sizes iconutil packs.
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$APP/Contents/MacOS/MacStats" --write-icon "$ICONSET"
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"
rm -rf "$(dirname "$ICONSET")"

# Ad-hoc signed: built on this Mac, so macOS runs it without a Developer ID.
codesign --force --sign - "$APP"
echo "Built $APP ($VERSION)"
