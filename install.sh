#!/bin/sh
# Installs MacStats into ~/Applications and starts it now and at every login. Builds it
# on this Mac from the source, so it needs the Xcode Command Line Tools (swiftc), and
# nothing else: no Homebrew, no Xcode, no Developer ID.
#
#   curl -fsSL https://raw.githubusercontent.com/csarkosh/app-macstats/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --uninstall      # remove the app and its login agent
#   curl -fsSL .../install.sh | sh -s -- --version v1.2.0 # a particular release
#   curl -fsSL .../install.sh | sh -s -- --ref main       # the tip of main, rebuilt every time
#   sh install.sh                                         # from a checkout: builds that checkout
#
# Safe to run again: it rebuilds only when the version it would install differs from the
# one installed (or with --force). Homebrew is the other way in: `brew install
# csarkosh/tap/macstats`; use one or the other, or two copies run.
set -eu

REPO="csarkosh/app-macstats"
APP="$HOME/Applications/MacStats.app"
AGENT="$HOME/Library/LaunchAgents/sh.csarko.macstats.plist"
LABEL="sh.csarko.macstats"

say() { printf '%s\n' "$*"; }
fail() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# A signal, not AppleScript's quit, so macOS never asks to let the terminal control the app.
stop_app() {
  pkill -x MacStats 2>/dev/null || return 0
  i=0
  while [ $i -lt 20 ] && pgrep -xq MacStats; do sleep 0.5; i=$((i + 1)); done
  pkill -9 -x MacStats 2>/dev/null || true
}

WANT=""; REF=""; FORCE=0; UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) UNINSTALL=1 ;;
    --version) shift; WANT="$1" ;;
    --ref) shift; REF="$1" ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown option $1" ;;
  esac
  shift
done

[ "$(uname -s)" = Darwin ] || fail "MacStats is a macOS menu bar app; this runs only on macOS."

if [ "$UNINSTALL" = 1 ]; then
  launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
  rm -f "$AGENT"
  stop_app
  rm -rf "$APP"
  say "Removed MacStats and its login agent. Its settings (menu bar positions) stay in"
  say "~/Library/Preferences/sh.csarko.MacStats.plist and its folder measurements in"
  say "~/Library/Caches/sh.csarko.MacStats; delete those too if you want nothing left."
  exit 0
fi

if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  fail "the Xcode Command Line Tools (swiftc, to build MacStats) are not installed. Run:
  xcode-select --install
click Install in the dialog, wait for it to finish, and run this again."
fi

# Where the source comes from: this checkout when run from one, else a tarball of the
# requested release (the latest by default) or of a branch.
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
WORK=""
if [ -n "$HERE" ] && [ -f "$HERE/Package.swift" ] && [ -f "$HERE/VERSION" ] && [ -z "$WANT" ] && [ -z "$REF" ]; then
  SRC="$HERE"
  TARGET="$(tr -d '[:space:]' < "$SRC/VERSION")"
  say "Building MacStats $TARGET from $SRC..."
else
  if [ -n "$REF" ]; then
    URL="https://github.com/$REPO/archive/refs/heads/$REF.tar.gz"
    TARGET="$REF"
    FORCE=1
  else
    if [ -z "$WANT" ]; then
      WANT="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
      [ -n "$WANT" ] || fail "could not find the latest release of $REPO (is GitHub reachable?)."
    fi
    URL="https://github.com/$REPO/archive/refs/tags/$WANT.tar.gz"
    TARGET="${WANT#v}"
  fi
  INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$FORCE" = 0 ] && [ -n "$INSTALLED" ] && [ "$INSTALLED" = "$TARGET" ] && pgrep -xq MacStats; then
    say "MacStats $INSTALLED is installed and running; nothing to do (use --force to rebuild)."
    exit 0
  fi
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  say "Downloading MacStats $TARGET..."
  curl -fsSL "$URL" | tar -xz -C "$WORK"
  SRC="$(find "$WORK" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [ -f "$SRC/Package.swift" ] || fail "the download did not contain MacStats' source."
  say "Building MacStats $TARGET (a minute or two the first time)..."
fi

(cd "$SRC" && make -s app) || fail "the build failed."

stop_app
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R "$SRC/build/MacStats.app" "$APP"

# Starts MacStats at login, only if it is not already running.
mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/sh</string><string>-c</string><string>pgrep -xq MacStats || open -a '$APP'</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"

# The agent starts it; if it has not within a few seconds, start it here. (Nothing else
# may run the binary meanwhile: the agent's pgrep would take that for the app running.)
i=0
while [ $i -lt 10 ] && ! pgrep -xq MacStats; do sleep 0.5; i=$((i + 1)); done
pgrep -xq MacStats || open -a "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
say "Installed MacStats $VERSION at $APP; it is in the menu bar now and at every login."
say "A \"Background Items Added\" notice from macOS is information only. To remove: install.sh --uninstall"
