#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/bin/sed -n 's/.*"version": "\(.*\)".*/\1/p' "$ROOT/package.json" | /usr/bin/head -n 1)"
APP="$ROOT/OCKey.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
BIN="$RESOURCES/bin"
OPENCODE_SOURCE="${OPENCODE_SOURCE:-/Users/wf/.opencode/bin/opencode}"

if [[ ! -x "$OPENCODE_SOURCE" ]]; then
  echo "OpenCode CLI not found or not executable at $OPENCODE_SOURCE" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$BIN"

swiftc "$ROOT/app/OCKeyApp.swift" \
  -o "$MACOS/OCKey" \
  -framework AppKit \
  -framework Foundation \
  -framework Network

/usr/bin/ditto "$OPENCODE_SOURCE" "$BIN/opencode"
chmod +x "$BIN/opencode"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>OCKey</string>
  <key>CFBundleIdentifier</key>
  <string>local.ockey.app</string>
  <key>CFBundleName</key>
  <string>OCKey</string>
  <key>CFBundleDisplayName</key>
  <string>OCKey</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

/usr/bin/ditto "$ROOT/README.md" "$RESOURCES/README.md"
/bin/date '+%Y%m%d%H%M%S' > "$RESOURCES/runtime-version.txt"

printf 'APPL????' > "$CONTENTS/PkgInfo"
chmod +x "$MACOS/OCKey"
codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null
echo "Built $APP"
