#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/bin/sed -n 's/.*"version": "\(.*\)".*/\1/p' "$ROOT/package.json" | /usr/bin/head -n 1)"
OUT="$ROOT/../OCKey-${VERSION}.dmg"
STAGING="$(/usr/bin/mktemp -d /tmp/ockey-dmg.XXXXXX)"

/bin/rm -f "$OUT"
/usr/bin/ditto "$ROOT/OCKey.app" "$STAGING/OCKey.app"
/bin/ln -s /Applications "$STAGING/Applications"

/bin/cat > "$STAGING/README.txt" <<'TEXT'
Drag OCKey.app into Applications.
After launch, an OCKey icon appears in the upper-right macOS menu bar.
Open the console, log in to OpenCode if needed, then copy Key + URL.
TEXT

/usr/bin/hdiutil create \
  -volname "OCKey" \
  -srcfolder "$STAGING" \
  -format UDZO \
  "$OUT"

/bin/echo "$OUT"
