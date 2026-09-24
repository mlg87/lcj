#!/usr/bin/env bash
# build.sh — assemble ClusageMenubar.app from SPM release builds.
#
# WHY two single-arch builds + lipo instead of one multi-arch build:
# `swift build --arch arm64 --arch x86_64` requires xcbuild / full Xcode;
# it fails under Command Line Tools only (CLT). The two-invocation+lipo
# approach works with CLT alone and produces an identical universal binary.
#
# Optional env vars:
#   CODESIGN_IDENTITY  — code signing identity (default: ad-hoc "-")
#   ARCHS              — space-separated arch list (default: "arm64 x86_64")
#                        Set to "arm64" on CLT machines where x86_64 build fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

VERSION="$(cat version.txt)"
APP_NAME="ClusageMenubar"
APP_DIR="build/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
ARCHS="${ARCHS:-arm64 x86_64}"

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

echo "==> Building Clusage v${VERSION}"

# -- Icon --
if [[ ! -f "${APP_NAME}.icns" ]]; then
    echo "--> Generating icon …"
    ./make_icon.sh
fi

# -- Compile each arch --
# WHY --show-bin-path plus a copy per arch: the output directory depends on
# the toolchain. Older SwiftPM wrote .build/<arch>-apple-macosx/release; the
# newer build system writes .build/out/Products/Release for every arch, so the
# old hardcoded path silently packaged whatever stale binary an earlier
# toolchain had left there. A shared directory also means each arch build
# overwrites the previous one, so every binary is copied out before the next.
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
BINARY_PATHS=()
for ARCH in $ARCHS; do
    echo "--> swift build -c release --arch ${ARCH}"
    swift build -c release --arch "$ARCH" 2>&1
    BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"
    cp "${BIN_DIR}/${APP_NAME}" "${STAGE_DIR}/${APP_NAME}-${ARCH}"
    # No pipe into grep -q here: under pipefail, grep exiting early can fail
    # the check with SIGPIPE even when the arch matches.
    SLICE_ARCHS="$(lipo -archs "${STAGE_DIR}/${APP_NAME}-${ARCH}")"
    if [[ " ${SLICE_ARCHS} " != *" ${ARCH} "* ]]; then
        echo "ERROR: ${BIN_DIR}/${APP_NAME} is ${SLICE_ARCHS}, not ${ARCH}" >&2
        exit 1
    fi
    BINARY_PATHS+=("${STAGE_DIR}/${APP_NAME}-${ARCH}")
done

# -- Assemble app bundle --
echo "--> Assembling ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

# Produce universal binary (or copy single-arch if only one arch built)
if [[ ${#BINARY_PATHS[@]} -eq 1 ]]; then
    cp "${BINARY_PATHS[0]}" "${MACOS}/${APP_NAME}"
else
    lipo -create "${BINARY_PATHS[@]}" -output "${MACOS}/${APP_NAME}"
fi

# Info.plist with version stamped in
cp Info.plist "${CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString ${VERSION}" \
    -c "Set :CFBundleVersion ${VERSION}" \
    "${CONTENTS}/Info.plist"

# App type signature
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# Icon
if [[ -f "${APP_NAME}.icns" ]]; then
    cp "${APP_NAME}.icns" "${RESOURCES}/${APP_NAME}.icns"
fi

chmod 755 "${MACOS}/${APP_NAME}"

# -- Remove signing detritus (reference's hard-won lesson) --
# Extended attributes and dot-files cause codesign to fail or produce an invalid
# bundle on subsequent re-runs, so we always clean before signing.
xattr -cr "$APP_DIR" 2>/dev/null || true
find "$APP_DIR" -name "._*" -delete 2>/dev/null || true
find "$APP_DIR" -name ".DS_Store" -delete 2>/dev/null || true

# -- Code sign --
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    # Hardened runtime only makes sense with a real identity (required for notarization).
    codesign --force --deep --sign "$CODESIGN_IDENTITY" --options runtime --timestamp "$APP_DIR"
else
    codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_DIR"
fi

codesign --verify --verbose=2 "$APP_DIR" || {
    echo "ERROR: codesign verification failed" >&2
    exit 1
}

echo ""
echo "==> Built: ${APP_DIR}"
echo "    Version: ${VERSION}"
if [[ ${#BINARY_PATHS[@]} -gt 1 ]]; then
    echo "    Architectures: $(lipo -archs "${MACOS}/${APP_NAME}")"
fi
