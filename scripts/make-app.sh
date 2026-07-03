#!/usr/bin/env bash
# make-app.sh — wrap the SwiftPM release binary into dist/WhisprBro.app.
#
# SwiftPM alone can't produce an .app bundle, and menu-bar presence
# (LSUIElement) + the mic usage description require an Info.plist, so we
# assemble the bundle by hand and ad-hoc sign it.
#
# NOTE: ad-hoc signatures change on every build, so macOS may ask you to
# re-grant Accessibility/Input Monitoring after rebuilds (spec §8 gotcha —
# the permission watchdog lands in task-008).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/WhisprBro.app"

echo "building release…"
swift build -c release --package-path "$ROOT"

BIN="$ROOT/.build/release/WhisprBro"
[[ -x "$BIN" ]] || { echo "build product missing: $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WhisprBro"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.micaxes.whispr-bro</string>
	<key>CFBundleName</key>
	<string>WhisprBro</string>
	<key>CFBundleDisplayName</key>
	<string>whispr-bro</string>
	<key>CFBundleExecutable</key>
	<string>WhisprBro</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>whispr-bro transcribes your speech entirely on this Mac. Audio never leaves the device.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "done: $APP"
echo "launch with: open '$APP'"
