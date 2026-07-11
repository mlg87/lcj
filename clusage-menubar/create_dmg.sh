#!/usr/bin/env bash
# create_dmg.sh — create a distributable DMG from the built app bundle.
#
# Produces: ClusageMenubar-<VERSION>.dmg
# Optional env vars:
#   CODESIGN_IDENTITY  — sign the DMG (no effect if unset)
#   NOTARY_PROFILE     — local dev: `xcrun notarytool store-credentials` profile;
#                        DMG is notarized+stapled only when CODESIGN_IDENTITY is also set.
#   NOTARY_KEY_FILE    — CI: path to App Store Connect API key (.p8 file)
#   NOTARY_KEY_ID      — CI: App Store Connect API key ID
#   NOTARY_ISSUER_ID   — CI: App Store Connect Issuer ID
#                        (all three NOTARY_KEY_* are required for the API-key path)
#   SKIP_DMG_LAYOUT    — set to any value to skip the Finder AppleScript icon-layout
#                        step (used on headless CI where no Finder session exists).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="ClusageMenubar"
VERSION="$(cat version.txt)"
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
# WHY guard: on headless CI runners there is no Finder session; osascript hangs or
# errors. Set SKIP_DMG_LAYOUT=1 to skip this cosmetic step entirely.
if [[ -z "${SKIP_DMG_LAYOUT:-}" ]]; then
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
else
    echo "  (SKIP_DMG_LAYOUT set — skipping Finder icon layout)"
fi

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
# Two credential modes for notarytool:
#   NOTARY_PROFILE                       — local dev: `xcrun notarytool store-credentials` profile
#   NOTARY_KEY_FILE + NOTARY_KEY_ID +
#   NOTARY_ISSUER_ID                     — CI: App Store Connect API key (no keychain profile needed)
NOTARY_ARGS=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY_FILE:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
    NOTARY_ARGS=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
fi

if [[ -n "${CODESIGN_IDENTITY:-}" && ${#NOTARY_ARGS[@]} -gt 0 ]]; then
    echo "--> Signing DMG …"
    codesign --sign "$CODESIGN_IDENTITY" --timestamp "$DMG_NAME"

    echo "--> Submitting for notarization (this may take a few minutes) …"
    xcrun notarytool submit "$DMG_NAME" "${NOTARY_ARGS[@]}" --wait

    # WHY staple is the hard gate: some notarytool versions exit 0 even when the
    # submission status is Invalid; stapler fails (exit 65) unless the ticket exists.
    echo "--> Stapling notarization ticket …"
    xcrun stapler staple "$DMG_NAME"
    xcrun stapler validate "$DMG_NAME"

    # Gatekeeper's own verdict — must print "source=Notarized Developer ID".
    spctl -a -t open --context context:primary-signature -v "$DMG_NAME"

    echo "==> DMG notarized and stapled: $DMG_NAME"
else
    echo ""
    echo "==> Created: $DMG_NAME (unsigned / un-notarized)"
    echo "    NOTE: Gatekeeper will block this DMG on other machines."
    echo "    To notarize: set CODESIGN_IDENTITY plus either NOTARY_PROFILE or"
    echo "    NOTARY_KEY_FILE + NOTARY_KEY_ID + NOTARY_ISSUER_ID."
fi
