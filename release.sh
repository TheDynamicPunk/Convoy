#!/bin/bash
#
# Cuts a release: universal build -> gates -> DMG and pkg, each re-verified,
# with checksums -> Sparkle update archive and appcast entry.
#
#   ./release.sh                 release the current tag
#   CONVOY_ALLOW_DIRTY=1 ./release.sh   ... from a dirty tree (don't)
#   CONVOY_PAGES_DIR=<path>      local clone of thedynamicpunk.github.io; its
#                                convoy/appcast.xml is updated in place.
#                                Without it the appcast is written to dist.
#   CONVOY_DOWNLOAD_URL_PREFIX   where the update zip will be hosted (default:
#                                this tag's GitHub release)
#
# Refuses to produce installers unless verify-bundle.sh passes every gate. That
# refusal is the point of this script: assembling a bundle is the easy part,
# and a bundle that is subtly mis-signed looks completely fine right up until
# a stranger's browser cannot start its native messaging host.
#
# There is no notarization step because there is no Apple Developer Program
# membership. Adding one later means: swap the ad-hoc identity in build.sh,
# then insert `notarytool submit --wait` and `stapler staple` between the
# gates and the DMG below. Nothing else here changes.
#
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Same reason as build.sh: .swift-version is resolved from the current
# directory.
cd "$PROJECT_DIR"

"$PROJECT_DIR/verify-toolchain.sh"

BUILD_DIR="${PROJECT_DIR}/.build"
APP_NAME="Convoy"
DIST_DIR="${BUILD_DIR}/dist"

# ---------------------------------------------------------------------------
# Preconditions
#
# Both of these exist so that what shipped can be rebuilt later. A release
# from an untagged or dirty tree is a build nobody -- including you -- can
# reproduce from the repository, which makes every bug report against it
# guesswork.
# ---------------------------------------------------------------------------
if ! TAG="$(git -C "$PROJECT_DIR" describe --tags --exact-match 2>/dev/null)"; then
    echo "ERROR: HEAD is not tagged."
    echo "  Releases are identified by their tag. Tag the commit first:"
    echo "      git tag -a v1.0.0 -m 'Convoy 1.0.0'"
    exit 1
fi

if [ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]; then
    if [ "${CONVOY_ALLOW_DIRTY:-0}" != "1" ]; then
        echo "ERROR: working tree is dirty; tag ${TAG} does not describe what would be built."
        git -C "$PROJECT_DIR" status --short | sed 's/^/    /'
        echo "  Commit or stash, or set CONVOY_ALLOW_DIRTY=1 if you accept an unreproducible build."
        exit 1
    fi
    echo "WARNING: building ${TAG} from a dirty tree (CONVOY_ALLOW_DIRTY=1)."
fi

# No manifest-signing gate here: the helper list is not signed. It ships inside
# the bundle, sealed by the app's own code signature. The one key this release
# path depends on is Sparkle's, checked next.

# ---------------------------------------------------------------------------
# Sparkle key gate
#
# Updates are trusted on their EdDSA signature alone, so the public key in
# Info.plist and the private key in this Mac's Keychain must be a pair.
# Checked before the universal build rather than discovered after it.
#
# Resolve first: Sparkle's tools arrive as a binary artifact, so on a fresh
# clone they do not exist until dependencies are fetched.
# ---------------------------------------------------------------------------
swift package resolve --package-path "$PROJECT_DIR" >/dev/null
SPARKLE_BIN="${BUILD_DIR}/artifacts/sparkle/Sparkle/bin"
if [ ! -x "${SPARKLE_BIN}/generate_keys" ]; then
    echo "ERROR: Sparkle's tools are missing at ${SPARKLE_BIN}."
    exit 1
fi
PLIST_ED_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "${PROJECT_DIR}/Resources/Info.plist" 2>/dev/null || true)"
KEYCHAIN_ED_KEY="$("${SPARKLE_BIN}/generate_keys" -p 2>/dev/null || true)"
if [ -z "$PLIST_ED_KEY" ]; then
    echo "ERROR: Resources/Info.plist has no SUPublicEDKey. Run"
    echo "       ${SPARKLE_BIN}/generate_keys"
    echo "       and add the public key it prints."
    exit 1
fi
if [ "$PLIST_ED_KEY" != "$KEYCHAIN_ED_KEY" ]; then
    echo "ERROR: SUPublicEDKey in Info.plist does not match the private key in this Mac's Keychain."
    echo "       Updates signed here would be rejected by every installed copy."
    exit 1
fi

VERSION="${TAG#v}"
BUILD_NUMBER="$(git -C "$PROJECT_DIR" rev-list --count HEAD)"
ARCHS="arm64 x86_64"

echo "Releasing ${APP_NAME} ${VERSION} (build ${BUILD_NUMBER}) from ${TAG}"
echo ""

# ---------------------------------------------------------------------------
# Build universal
# ---------------------------------------------------------------------------
CONVOY_ARCHS="$ARCHS" \
CONVOY_VERSION="$VERSION" \
CONVOY_BUILD_NUMBER="$BUILD_NUMBER" \
    "${PROJECT_DIR}/build.sh"

APP_DIR="${BUILD_DIR}/release/${APP_NAME}.app"

# ---------------------------------------------------------------------------
# Gate
# ---------------------------------------------------------------------------
echo ""
echo "=============================================================="
CONVOY_VERIFY_RELEASE=1 "${PROJECT_DIR}/verify-bundle.sh" "$APP_DIR" $ARCHS
echo "=============================================================="

# ---------------------------------------------------------------------------
# Package
#
# Two installers, for users to pick from: the drag-to-Applications DMG built
# by make-dmg.sh, and the pkg built by make-pkg.sh further down. Each writes
# a checksum beside it; put them in the release notes too.
# ---------------------------------------------------------------------------
echo ""
echo "packaging"
rm -rf "$DIST_DIR"
"${PROJECT_DIR}/make-dmg.sh"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"

# ---------------------------------------------------------------------------
# Re-verify what actually shipped
#
# The gates above ran against the bundle on disk. This runs them again
# against the copy extracted from the DMG, because packaging is itself a step
# that can break a signature -- and the DMG is the artifact a user gets, not
# the directory it was built from.
# ---------------------------------------------------------------------------
echo ""
echo "re-verifying the app as it exists inside the DMG"
MOUNT_POINT="$(mktemp -d)"
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_POINT" >/dev/null
VERIFY_STATUS=0
CONVOY_VERIFY_RELEASE=1 "${PROJECT_DIR}/verify-bundle.sh" "${MOUNT_POINT}/${APP_NAME}.app" $ARCHS || VERIFY_STATUS=$?
hdiutil detach "$MOUNT_POINT" >/dev/null
rmdir "$MOUNT_POINT" 2>/dev/null || true

if [ "$VERIFY_STATUS" != "0" ]; then
    echo ""
    echo "ERROR: the app inside the DMG fails verification. Removing it."
    rm -f "$DMG_PATH" "${DMG_PATH}.sha256"
    exit 1
fi

# ---------------------------------------------------------------------------
# Installer package
#
# Checked like the DMG: the gates run again on the app expanded from the
# payload, and a package Installer could relocate is refused.
# ---------------------------------------------------------------------------
echo ""
echo "installer package"
"${PROJECT_DIR}/make-pkg.sh"
PKG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.pkg"

echo ""
echo "re-verifying the app as it exists inside the package"
EXPAND_PARENT="$(mktemp -d)"
EXPANDED="${EXPAND_PARENT}/pkg"
pkgutil --expand-full "$PKG_PATH" "$EXPANDED" >/dev/null
VERIFY_STATUS=0
CONVOY_VERIFY_RELEASE=1 "${PROJECT_DIR}/verify-bundle.sh" "${EXPANDED}/${APP_NAME}.pkg/Payload/${APP_NAME}.app" $ARCHS || VERIFY_STATUS=$?
RELOCATABLE="$(xmllint --xpath 'count(//relocate/bundle)' "${EXPANDED}/${APP_NAME}.pkg/PackageInfo")"
rm -rf "$EXPAND_PARENT"

if [ "$VERIFY_STATUS" != "0" ] || [ "$RELOCATABLE" != "0" ]; then
    echo ""
    [ "$VERIFY_STATUS" != "0" ] && echo "ERROR: the app inside the package fails verification."
    [ "$RELOCATABLE" != "0" ] && echo "ERROR: the package is relocatable, so it could install over a copy outside /Applications."
    echo "Removing it."
    rm -f "$PKG_PATH" "${PKG_PATH}.sha256"
    exit 1
fi

# ---------------------------------------------------------------------------
# Sparkle update
#
# Sparkle installs from a zip of the app, not from the DMG or pkg. ditto with
# --keepParent is Sparkle's recommended way to make one: it keeps symlinks
# and extended attributes that the framework's signature depends on.
#
# generate_appcast signs the zip with the Keychain key and adds an item to an
# existing appcast.xml, keeping earlier items (--maximum-versions 0). No
# deltas: they need every previous archive on hand.
# ---------------------------------------------------------------------------
echo ""
echo "sparkle update"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"
APPCAST_STAGING="${DIST_DIR}/appcast"
mkdir -p "$APPCAST_STAGING"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "${APPCAST_STAGING}/${ZIP_NAME}"

PAGES_APPCAST=""
if [ -n "${CONVOY_PAGES_DIR:-}" ]; then
    PAGES_APPCAST="${CONVOY_PAGES_DIR}/convoy/appcast.xml"
    [ -f "$PAGES_APPCAST" ] && cp "$PAGES_APPCAST" "${APPCAST_STAGING}/appcast.xml"
fi

DOWNLOAD_URL_PREFIX="${CONVOY_DOWNLOAD_URL_PREFIX:-https://github.com/TheDynamicPunk/Convoy/releases/download/${TAG}/}"
"${SPARKLE_BIN}/generate_appcast" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --maximum-versions 0 \
    --maximum-deltas 0 \
    "$APPCAST_STAGING"

mv "${APPCAST_STAGING}/${ZIP_NAME}" "${DIST_DIR}/${ZIP_NAME}"
if [ -n "$PAGES_APPCAST" ]; then
    mkdir -p "$(dirname "$PAGES_APPCAST")"
    cp "${APPCAST_STAGING}/appcast.xml" "$PAGES_APPCAST"
    APPCAST_OUT="$PAGES_APPCAST (commit and push it)"
else
    mv "${APPCAST_STAGING}/appcast.xml" "${DIST_DIR}/appcast.xml"
    APPCAST_OUT="${DIST_DIR}/appcast.xml (copy to convoy/ in the Pages repo)"
fi
rm -rf "$APPCAST_STAGING"

echo ""
echo "Release artifacts:"
echo "  ${DMG_PATH}"
echo "  ${DMG_PATH}.sha256  ->  $(cat "${DMG_PATH}.sha256")"
echo "  ${PKG_PATH}"
echo "  ${PKG_PATH}.sha256  ->  $(cat "${PKG_PATH}.sha256")"
echo "  ${DIST_DIR}/${ZIP_NAME}  ->  upload to ${DOWNLOAD_URL_PREFIX}"
echo "  appcast: ${APPCAST_OUT}"
echo ""
echo "Upload all of them to the release before pushing the appcast: an appcast"
echo "that points at a missing file makes every copy fail its update check."
echo ""
echo "Not notarized. Opening the DMG's app or the pkg shows 'Apple could not"
echo "verify', and users must use System Settings > Privacy & Security > Open"
echo "Anyway. Say so in the release notes and link the install instructions."
