#!/bin/bash
# Builds Halo.app from the SwiftPM executable.
#
#   ./Scripts/build.sh            release build → build/Halo.app
#   ./Scripts/build.sh debug      debug build
#   ./Scripts/build.sh release run   build, then relaunch the app
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG="${1:-release}"
RUN="${2:-}"

APP="$ROOT/build/Halo.app"
CONTENTS="$APP/Contents"

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Halo"

echo "▸ assembling bundle"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/Halo"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# Localisations live beside the binary rather than in a SwiftPM resource
# bundle, so Bundle.main lookups — which is what SwiftUI and String(localized:)
# use — resolve without any extra plumbing.
for lproj in "$ROOT"/Resources/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$CONTENTS/Resources/"
done

# App icon — non-fatal, the app runs fine without it.
if command -v iconutil >/dev/null 2>&1; then
    ICONSET="$ROOT/build/AppIcon.iconset"
    rm -rf "$ICONSET"
    if swift "$ROOT/Scripts/make_icon.swift" "$ICONSET" >/dev/null 2>&1; then
        iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns" 2>/dev/null \
            && echo "▸ icon built" || echo "▸ icon skipped"
        rm -rf "$ICONSET"
    else
        echo "▸ icon skipped"
    fi
fi

# Ad-hoc signature. Without a stable signature macOS re-asks for Accessibility
# permission on every rebuild, so this matters more than it looks.
echo "▸ codesign (ad-hoc)"
codesign --force --deep --sign - \
    --entitlements "$ROOT/Resources/Halo.entitlements" \
    "$APP" 2>/dev/null || codesign --force --deep --sign - "$APP"

echo "✓ built $APP"

if [ "$RUN" = "run" ]; then
    echo "▸ relaunching"
    pkill -x Halo 2>/dev/null || true
    sleep 0.4
    open "$APP"
fi
