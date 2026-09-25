#!/bin/bash
#
# Builds the installer package, .build/dist/Convoy-<version>.pkg, from
# .build/release/Convoy.app. release.sh runs it after the DMG, so a release
# offers both; after a plain ./build.sh it packages the dev build.
#
# Unsigned: there is no Developer ID Installer certificate. Measured on a
# clean macOS 26 VM (Sep 15, 2026): it installs after one Privacy & Security
# approval and an administrator password, the installed app carries no
# quarantine attribute, and it then opens with no Gatekeeper dialog. It always
# installs to /Applications, so App Translocation can't apply.
#
# No install scripts. They would run as root, and the one job they could do,
# browser setup, belongs to the user: the app does it at first launch.
#
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build"
APP_NAME="Convoy"
APP_DIR="${BUILD_DIR}/release/${APP_NAME}.app"
DIST_DIR="${BUILD_DIR}/dist"
BUNDLE_ID="io.github.thedynamicpunk.convoy"
COMPONENT_ID="${BUNDLE_ID}.installer"

if [ ! -d "$APP_DIR" ]; then
    echo "ERROR: ${APP_DIR} not found. Run ./build.sh first."
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_DIR}/Contents/Info.plist")"
MIN_OS="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "${APP_DIR}/Contents/Info.plist")"
PKG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.pkg"

WORK="${BUILD_DIR}/pkgwork"
rm -rf "$WORK"
mkdir -p "${WORK}/root" "$DIST_DIR"
cp -R "$APP_DIR" "${WORK}/root/"

# Not relocatable: otherwise Installer upgrades any other copy of the app it
# finds, say one left in Downloads, instead of installing to /Applications.
# Current pkgbuild defaults to this; older versions didn't.
COMPONENT_PLIST="${WORK}/component.plist"
pkgbuild --analyze --root "${WORK}/root" "$COMPONENT_PLIST" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$COMPONENT_PLIST"

pkgbuild \
    --root "${WORK}/root" \
    --component-plist "$COMPONENT_PLIST" \
    --install-location /Applications \
    --identifier "$COMPONENT_ID" \
    --version "$VERSION" \
    "${WORK}/${APP_NAME}.pkg" >/dev/null

# The product archive around it. It refuses a macOS older than the app runs
# on, and asks the user to quit a running Convoy first so a reinstall doesn't
# replace the bundle under it.
cat > "${WORK}/requirements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>os</key>
    <array><string>${MIN_OS}</string></array>
</dict>
</plist>
EOF

DISTRIBUTION="${WORK}/distribution.xml"
productbuild --synthesize \
    --product "${WORK}/requirements.plist" \
    --package "${WORK}/${APP_NAME}.pkg" \
    "$DISTRIBUTION" >/dev/null
sed -i '' '/^<\/installer-gui-script>$/d' "$DISTRIBUTION"
cat >> "$DISTRIBUTION" <<EOF
    <title>${APP_NAME}</title>
    <pkg-ref id="${COMPONENT_ID}">
        <must-close><app id="${BUNDLE_ID}"/></must-close>
    </pkg-ref>
</installer-gui-script>
EOF
xmllint --noout "$DISTRIBUTION"
grep -q "<os-version min=\"${MIN_OS}\"/>" "$DISTRIBUTION" || { echo "ERROR: no minimum macOS in ${DISTRIBUTION}"; exit 1; }

productbuild \
    --distribution "$DISTRIBUTION" \
    --package-path "$WORK" \
    "$PKG_PATH" >/dev/null

rm -rf "$WORK"

(cd "$DIST_DIR" && shasum -a 256 "$(basename "$PKG_PATH")" > "$(basename "$PKG_PATH").sha256")

echo "Built: ${PKG_PATH}"
echo "  $(cat "${PKG_PATH}.sha256")"
