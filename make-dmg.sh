#!/bin/bash
#
# Builds the disk image, .build/dist/Convoy-<version>.dmg, from
# .build/release/Convoy.app: the app, an Applications shortcut, and a
# background that says to drag one onto the other, and how to get past
# Gatekeeper on first open. release.sh runs it; after a plain ./build.sh it
# packages the dev build.
#
# Finder keeps the window layout in the image's .DS_Store. dmgbuild writes
# that file directly, where tools that script Finder need a logged-in GUI
# session. It runs from a virtualenv under .build, installed from the
# hash-pinned list in Resources/DMG/requirements.txt.
#
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Same reason as build.sh: .swift-version is resolved from the current
# directory, and the background is drawn by a Swift script.
cd "$PROJECT_DIR"

BUILD_DIR="${PROJECT_DIR}/.build"
APP_NAME="Convoy"
APP_DIR="${BUILD_DIR}/release/${APP_NAME}.app"
DIST_DIR="${BUILD_DIR}/dist"
DMG_DIR="${PROJECT_DIR}/Resources/DMG"

if [ ! -d "$APP_DIR" ]; then
    echo "ERROR: ${APP_DIR} not found. Run ./build.sh first."
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_DIR}/Contents/Info.plist")"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"

# dmgbuild needs Python 3.10 or later; the one macOS ships is 3.9.
VENV="${BUILD_DIR}/dmgbuild-venv"
if ! cmp -s "${DMG_DIR}/requirements.txt" "${VENV}/requirements.txt"; then
    PYTHON=""
    for candidate in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
        if command -v "$candidate" >/dev/null \
            && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
            PYTHON="$candidate"
            break
        fi
    done
    if [ -z "$PYTHON" ]; then
        echo "ERROR: building the disk image needs Python 3.10 or later, and none was found."
        echo "  Install one with 'brew install python' or from python.org, then run this again."
        exit 1
    fi
    rm -rf "$VENV"
    "$PYTHON" -m venv "$VENV"
    "${VENV}/bin/pip" install --quiet --disable-pip-version-check \
        --require-hashes --only-binary :all: -r "${DMG_DIR}/requirements.txt"
    cp "${DMG_DIR}/requirements.txt" "${VENV}/requirements.txt"
fi

WORK="${BUILD_DIR}/dmgwork"
rm -rf "$WORK"
mkdir -p "$WORK" "$DIST_DIR"

swift "${DMG_DIR}/background.swift" "$WORK"
# One TIFF holding both, so Finder picks the sharp one on Retina screens. It
# warns that the resolutions aren't exactly 72 and 144 dpi: they are a hair
# over, on purpose (see background.swift).
tiffutil -cathidpicheck "${WORK}/background.png" "${WORK}/background@2x.png" \
    -out "${WORK}/background.tiff" >/dev/null 2>&1

rm -f "$DMG_PATH"
"${VENV}/bin/dmgbuild" -s "${DMG_DIR}/settings.py" \
    -D app="$APP_DIR" \
    -D icon="${PROJECT_DIR}/Resources/AppIcon.icns" \
    -D background="${WORK}/background.tiff" \
    "$APP_NAME" "$DMG_PATH" >/dev/null

rm -rf "$WORK"

# With no notarization ticket to vouch for this download, a published
# checksum is the only integrity signal a cautious user has.
(cd "$DIST_DIR" && shasum -a 256 "$DMG_NAME" > "${DMG_NAME}.sha256")

echo "Built: ${DMG_PATH}"
echo "  $(cat "${DMG_PATH}.sha256")"
