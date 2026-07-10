#!/usr/bin/env bash
# create_dmg.sh — create a distributable DMG from the built app bundle.
#
# Produces: ClusageMenubar-<VERSION>.dmg
# Optional env vars:
#   CODESIGN_IDENTITY  — sign the DMG (no effect if unset)
#   NOTARY_PROFILE     — notarytool credential profile; DMG is notarized+stapled
#                        only when BOTH CODESIGN_IDENTITY and NOTARY_PROFILE are set.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="ClusageMenubar"
VERSION="$(cat VERSION)"
APP_BUNDLE="build/${APP_NAME}.app"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
TEMP_DIR="dmg_temp"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "ERROR: App bundle not found at $APP_BUNDLE — run ./build.sh first" >&2
    exit 1
fi

echo "==> Creating DMG: ${DMG_NAME}"

rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"
cp -r "$APP_BUNDLE" "$TEMP_DIR/"
ln -s /Applications "$TEMP_DIR/Applications"

# Remove extended attributes (can corrupt the DMG)
xattr -cr "$TEMP_DIR" 2>/dev/null || true

# Create a writable UDRW image first (needed for icon layout)
hdiutil create \
    -srcfolder "$TEMP_DIR" \
    -format UDRW \
    -volname "${APP_NAME}" \
    -o "${DMG_NAME%.dmg}_rw.dmg" \
    -quiet

# Mount for icon layout via AppleScript
MOUNT_POINT="$(hdiutil attach "${DMG_NAME%.dmg}_rw.dmg" -readwrite -noverify -noautoopen | grep '/Volumes/' | awk '{print $NF}')"

# AppleScript layout: set icon size + window bounds (tolerate failure — cosmetic only)
osascript <<APPLESCRIPT || echo "  (AppleScript icon layout skipped)"
tell application "Finder"
    tell disk "${APP_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 100, 900, 400}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 80
        set position of item "${APP_NAME}.app" of container window to {130, 150}
        set position of item "Applications" of container window to {370, 150}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

# Sync and detach
sync
hdiutil detach "$MOUNT_POINT" -quiet

# Convert to compressed read-only UDZO
hdiutil convert "${DMG_NAME%.dmg}_rw.dmg" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_NAME" \
    -quiet

rm -f "${DMG_NAME%.dmg}_rw.dmg"
rm -rf "$TEMP_DIR"

# -- Notarization (optional) --
if [[ -n "${CODESIGN_IDENTITY:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
    echo "--> Signing DMG …"
    codesign --sign "$CODESIGN_IDENTITY" "$DMG_NAME"

    echo "--> Submitting for notarization (this may take a few minutes) …"
    xcrun notarytool submit "$DMG_NAME" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    echo "--> Stapling notarization ticket …"
    xcrun stapler staple "$DMG_NAME"

    echo "==> DMG notarized and stapled: $DMG_NAME"
else
    echo ""
    echo "==> Created: $DMG_NAME (unsigned / un-notarized)"
    echo "    NOTE: Gatekeeper will block opening on other machines until the user"
    echo "    right-clicks the app and selects Open, or you notarize the DMG."
    echo "    To notarize: set CODESIGN_IDENTITY and NOTARY_PROFILE env vars."
fi
