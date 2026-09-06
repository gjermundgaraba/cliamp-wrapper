#!/usr/bin/env bash
# Builds the Swift executable and assembles build/Cliamp.app with an ad-hoc
# signature. VERSION and BUILD_NUMBER may be set in the environment.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

GHOSTTY="$ROOT/vendor/ghostty"
SHARE="$GHOSTTY/zig-out/share"
APP="$ROOT/build/Cliamp.app"
CONTENTS="$APP/Contents"

if [ ! -d "$GHOSTTY/macos/GhosttyKit.xcframework" ]; then
    echo "error: GhosttyKit.xcframework missing; run scripts/build-ghosttykit.sh first" >&2
    exit 1
fi

echo "==> swift build"
(cd "$ROOT" && swift build -c release --product CliampWrapper)
BIN_DIR="$(cd "$ROOT" && swift build -c release --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_DIR/CliampWrapper" "$CONTENTS/MacOS/Cliamp"

sed -e "s|__VERSION__|$VERSION|g" \
    -e "s|__BUILD__|$BUILD_NUMBER|g" \
    -e "s|__GHOSTTY_COMMIT__|$(git -C "$GHOSTTY" rev-parse HEAD)|g" \
    "$ROOT/Resources/Info.plist" > "$CONTENTS/Info.plist"

cp "$ROOT/Resources/ghostty.conf" "$CONTENTS/Resources/ghostty.conf"

# libghostty locates its resources by walking up from the executable and
# looking for Contents/Resources/terminfo/78/xterm-ghostty, then uses
# Contents/Resources/ghostty for themes and shell integration.
cp -R "$SHARE/terminfo" "$CONTENTS/Resources/terminfo"
cp -R "$SHARE/ghostty" "$CONTENTS/Resources/ghostty"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$ROOT/Resources/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$double" "$double" "$ROOT/Resources/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

echo "==> codesign (ad-hoc)"
codesign --force --sign - "$APP"

echo "==> done: $APP"
