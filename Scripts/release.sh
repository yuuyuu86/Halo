#!/bin/bash
# Builds a distributable Halo.app: universal binary, Developer ID signature,
# notarisation, and a DMG.
#
#   ./Scripts/release.sh
#
# Configuration comes from the environment so no identity ever lands in git:
#
#   HALO_SIGN_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#   HALO_NOTARY_PROFILE  notarytool keychain profile name
#
# Both are optional. Without them the script still produces a working universal
# app and DMG — ad-hoc signed, which runs locally but is blocked by Gatekeeper
# on other Macs. See docs/Distribution.md.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

APP="$ROOT/build/Halo.app"
CONTENTS="$APP/Contents"
DMG="$ROOT/build/Halo-$VERSION.dmg"
STAGING="$ROOT/build/dmg"

SIGN_IDENTITY="${HALO_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${HALO_NOTARY_PROFILE:-}"

echo "▸ Halo $VERSION"

# ---------------------------------------------------------------- build ----
echo "▸ building universal (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Halo"
lipo -info "$BIN"

# -------------------------------------------------------------- assemble ----
echo "▸ assembling bundle"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/Halo"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

for lproj in "$ROOT"/Resources/*.lproj; do
    [ -d "$lproj" ] && cp -R "$lproj" "$CONTENTS/Resources/"
done

ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
if swift "$ROOT/Scripts/make_icon.swift" "$ICONSET" >/dev/null 2>&1; then
    iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
fi

# ----------------------------------------------------------------- sign ----
if [ -n "$SIGN_IDENTITY" ]; then
    echo "▸ signing with Developer ID"
    # The hardened runtime is required for notarisation.
    codesign --force --timestamp --options runtime \
        --entitlements "$ROOT/Resources/Halo.entitlements" \
        --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
else
    echo "▸ no HALO_SIGN_IDENTITY — signing ad-hoc (local use only)"
    codesign --force --deep --sign - \
        --entitlements "$ROOT/Resources/Halo.entitlements" "$APP"
fi

# ------------------------------------------------------------------ dmg ----
echo "▸ building DMG"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Halo $VERSION" -srcfolder "$STAGING" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

# ------------------------------------------------------------- notarise ----
if [ -n "$SIGN_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
    echo "▸ notarising (this takes a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "▸ stapling"
    xcrun stapler staple "$DMG"
    xcrun stapler staple "$APP"
    echo "▸ verifying"
    spctl --assess --type execute --verbose=2 "$APP" || true
elif [ -n "$SIGN_IDENTITY" ]; then
    echo "▸ HALO_NOTARY_PROFILE not set — skipping notarisation"
    echo "  Gatekeeper will still warn on other Macs until the DMG is notarised."
fi

echo
echo "✓ $APP"
echo "✓ $DMG"
