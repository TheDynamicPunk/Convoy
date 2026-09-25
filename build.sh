#!/bin/bash
#
# Assembles Convoy.app from the Swift package.
#
# Defaults to a fast, native-architecture development build. release.sh
# drives this same script for a real release by setting CONVOY_ARCHS to both
# architectures and passing a version through.
#
#   CONVOY_ARCHS          space-separated arch list (default: this machine's)
#   CONVOY_VERSION        CFBundleShortVersionString (default: nearest git tag, else 0.0.0)
#   CONVOY_BUILD_NUMBER   CFBundleVersion (default: git commit count, else 0)
#
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# .swift-version is resolved from the current directory, not from
# --package-path, so run from here or the toolchain pin is ignored.
cd "$PROJECT_DIR"

"$PROJECT_DIR/verify-toolchain.sh"

BUILD_DIR="${PROJECT_DIR}/.build"
APP_NAME="Convoy"
HOST_NAME="NativeMessagingHost"

# ---------------------------------------------------------------------------
# Version
#
# Single source of truth is git, injected into the bundle's Info.plist below.
# The source Info.plist carries fallback values only -- there is deliberately
# no "keep these two files in sync" step to forget, which is what the previous
# hardcoded VERSION here and the matching RELEASE CHECKLIST comments were.
#
# CFBundleVersion specifically matters beyond cosmetics: Sparkle decides
# whether an update exists by comparing it, so a value that fails to advance
# means updates silently never appear -- a failure you cannot see in testing.
# ---------------------------------------------------------------------------
if [ -z "${CONVOY_VERSION:-}" ]; then
    if git -C "$PROJECT_DIR" describe --tags --abbrev=0 >/dev/null 2>&1; then
        CONVOY_VERSION="$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 | sed 's/^v//')"
    else
        CONVOY_VERSION="0.0.0"
    fi
fi
if [ -z "${CONVOY_BUILD_NUMBER:-}" ]; then
    CONVOY_BUILD_NUMBER="$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || echo 0)"
fi

# Minimum OS is read back out of Info.plist rather than repeated here, so the
# build triple and the bundle's own claim cannot disagree.
MACOS_MIN="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "${PROJECT_DIR}/Resources/Info.plist")"

ARCHS="${CONVOY_ARCHS:-$(uname -m)}"

echo "Building $APP_NAME $CONVOY_VERSION (build $CONVOY_BUILD_NUMBER) for: $ARCHS"

# ---------------------------------------------------------------------------
# Compile
#
# A single-architecture native build goes through plain `swift build` so it
# shares the incremental cache with an ordinary development build. Anything
# else is compiled once per architecture into its own scratch directory and
# lipo'd together.
#
# Note this does NOT use `swift build --arch a --arch b`, which is the
# documented way to get a universal binary but requires the full Xcode
# toolchain (it shells out to xcbuild). This project builds fine on Command
# Line Tools alone, and cross-compiling per-arch with --triple keeps it that
# way -- worth preserving, since it is also what lets CI and a
# contributor-built-from-source install work without a 10GB dependency.
# ---------------------------------------------------------------------------
ARCH_COUNT=$(echo "$ARCHS" | wc -w | tr -d ' ')

# ---------------------------------------------------------------------------
# Record the SDK in LC_BUILD_VERSION. SwiftPM writes the deployment target
# into both minos and sdk, and macOS reads sdk to pick the control appearance
# — see README.
# ---------------------------------------------------------------------------
SDK_VERSION="$(xcrun --show-sdk-version)"
PLATFORM_VERSION_FLAGS=(-Xlinker -platform_version -Xlinker macos \
                        -Xlinker "$MACOS_MIN" -Xlinker "$SDK_VERSION")
echo "  SDK ${SDK_VERSION}, minimum macOS ${MACOS_MIN}"

# Output locations come from --show-bin-path: they differ between SwiftPM's
# build backends, and hard-coded ones go stale silently.
if [ "$ARCH_COUNT" = "1" ] && [ "$ARCHS" = "$(uname -m)" ]; then
    swift build -c release --package-path "$PROJECT_DIR" "${PLATFORM_VERSION_FLAGS[@]}"
    bin="$(swift build -c release --package-path "$PROJECT_DIR" --show-bin-path)"
    APP_BIN_SOURCES=("${bin}/${APP_NAME}")
    HOST_BIN_SOURCES=("${bin}/${HOST_NAME}")
    SPARKLE_SOURCE="${bin}/Sparkle.framework"
else
    APP_BIN_SOURCES=()
    HOST_BIN_SOURCES=()
    for arch in $ARCHS; do
        scratch="${BUILD_DIR}/arch-${arch}"
        echo "  -> ${arch}"
        arch_flags=(-c release --package-path "$PROJECT_DIR"
                    --triple "${arch}-apple-macosx${MACOS_MIN}"
                    --scratch-path "$scratch")
        swift build "${arch_flags[@]}" "${PLATFORM_VERSION_FLAGS[@]}"
        bin="$(swift build "${arch_flags[@]}" --show-bin-path)"
        APP_BIN_SOURCES+=("${bin}/${APP_NAME}")
        HOST_BIN_SOURCES+=("${bin}/${HOST_NAME}")
        # Sparkle ships universal, so any one arch's copy will do.
        SPARKLE_SOURCE="${bin}/Sparkle.framework"
    done
fi

# ---------------------------------------------------------------------------
# Assemble the bundle
# ---------------------------------------------------------------------------
APP_DIR="${BUILD_DIR}/release/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
SPARKLE_DIR="${FRAMEWORKS_DIR}/Sparkle.framework"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

if [ "${#APP_BIN_SOURCES[@]}" = "1" ]; then
    cp "${APP_BIN_SOURCES[0]}" "${MACOS_DIR}/${APP_NAME}"
    cp "${HOST_BIN_SOURCES[0]}" "${MACOS_DIR}/${HOST_NAME}"
else
    lipo -create -output "${MACOS_DIR}/${APP_NAME}" "${APP_BIN_SOURCES[@]}"
    lipo -create -output "${MACOS_DIR}/${HOST_NAME}" "${HOST_BIN_SOURCES[@]}"
fi

# Sparkle. ditto keeps the framework's Versions/Current symlinks, which a
# plain copy would flatten into duplicates and break its signature. The XPC
# services are only used by sandboxed apps; this one isn't, so they go
# (the top-level XPCServices symlink too, or it dangles).
if [ ! -d "$SPARKLE_SOURCE" ]; then
    echo "ERROR: Sparkle.framework not found at ${SPARKLE_SOURCE}"
    exit 1
fi
ditto "$SPARKLE_SOURCE" "$SPARKLE_DIR"
rm -rf "${SPARKLE_DIR}/Versions/B/XPCServices" "${SPARKLE_DIR}/XPCServices"

cp "${PROJECT_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${CONVOY_VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${CONVOY_BUILD_NUMBER}" "${CONTENTS_DIR}/Info.plist"

# The unpacked browser extension. The app copies it to Application Support,
# which is the folder users load it from, and writes each browser's native
# messaging file itself -- see BrowserIntegration.
rsync -a --delete --exclude '.*' "${PROJECT_DIR}/Extensions/Chromium/" "${RESOURCES_DIR}/Extension/"

# The helper list. Not signed: it lives inside the bundle, which macOS seals,
# so the app's own signature is what protects it. Required, not optional -- a
# build without it can install no helpers at all, and would fail at run time
# with nothing pointing at the cause.
if [ ! -f "${PROJECT_DIR}/Resources/HelperManifest/helpers.json" ]; then
    echo "ERROR: Resources/HelperManifest/helpers.json missing."
    echo "       Regenerate with: ./.build/release/helper-manifest build --sources Resources/HelperManifest/helper-sources.json --sequence <n> --out Resources/HelperManifest"
    exit 1
fi
cp "${PROJECT_DIR}/Resources/HelperManifest/helpers.json" "${RESOURCES_DIR}/helpers.json"

# App icon & menu bar icon. These are required assets, not optional -- fail
# loudly rather than silently shipping a bundle with no icon (or a stale one
# from a previous build) and no indication anything went wrong.
if [ ! -f "${PROJECT_DIR}/Resources/AppIcon.icns" ]; then
    echo "ERROR: Resources/AppIcon.icns not found. Run the icon generation step first."
    exit 1
fi
cp "${PROJECT_DIR}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"

if [ ! -f "${PROJECT_DIR}/Resources/MenuBarIcon.png" ] || [ ! -f "${PROJECT_DIR}/Resources/MenuBarIcon@2x.png" ]; then
    echo "ERROR: Resources/MenuBarIcon.png and/or MenuBarIcon@2x.png not found."
    exit 1
fi
cp "${PROJECT_DIR}/Resources/MenuBarIcon.png" "${RESOURCES_DIR}/MenuBarIcon.png"
cp "${PROJECT_DIR}/Resources/MenuBarIcon@2x.png" "${RESOURCES_DIR}/MenuBarIcon@2x.png"

# ---------------------------------------------------------------------------
# Sign
#
# Ad-hoc, inside-out, one binary at a time. Three things this is deliberately
# NOT doing:
#
# 1. No `--deep`. Apple deprecated it for signing, and it is what caused this
#    project's worst signing bug: it applied one set of options to every
#    binary in the bundle, attaching the app's entitlements to
#    NativeMessagingHost too. macOS SIGKILLs a sandboxed binary the instant
#    Chrome exec()s it, which surfaces in the browser as "Native host has
#    exited" with zero diagnostics. Signing each binary explicitly, nested
#    first so the outer signature seals it, is both the supported way and the
#    one that cannot silently do that.
#
# 2. No entitlements, and no --entitlements flag. This app does not sandbox:
#    sandboxing breaks the browser-launched native messaging host (point 1)
#    and the yt-dlp/ffmpeg/qjs subprocesses, and it relocates
#    ~/Library/Application Support/Convoy/ into a container, which is
#    the "all my old downloads vanished after a rebuild" symptom. Every key
#    that used to be in Convoy.entitlements was either App-Sandbox-
#    scoped (a no-op without app-sandbox=true) or governed dynamic code
#    loading this app does not do. An empty entitlements dict is equivalent
#    to passing none, so the flag is omitted entirely rather than embedding
#    an empty blob for the next person to puzzle over. The file is kept in
#    the repo as a record of that decision.
#
# 3. No `--options runtime`. Hardened Runtime exists to satisfy notarization.
#    Without a Developer ID certificate there is nothing to notarize, so it
#    would buy nothing and can only cause problems.
#
# Signing correctly matters more here than it looks: IPCPeerVerification
# derives its trust requirement from the designated requirement of the
# sibling binary, so an unsigned or mis-signed helper does not merely look
# untrusted to Gatekeeper -- it breaks browser integration outright.
#
# Sparkle's helpers are signed before its framework, and the framework before
# the app, so each outer signature seals the inner ones. Sparkle accepts an
# update on its EdDSA signature plus the new bundle's signature being valid;
# an ad-hoc app never matches its previous version's signature, so validity is
# all that is checked here.
#
# To move to Developer ID later: replace `-` with the identity and add
# `--options runtime --timestamp` to every codesign call. Nothing else in
# this script changes.
# ---------------------------------------------------------------------------
codesign --force --sign - "${SPARKLE_DIR}/Versions/B/Autoupdate"
codesign --force --sign - "${SPARKLE_DIR}/Versions/B/Updater.app"
codesign --force --sign - "${SPARKLE_DIR}"
codesign --force --sign - "${MACOS_DIR}/${HOST_NAME}"
codesign --force --sign - "${APP_DIR}"

echo ""
echo "Build complete: ${APP_DIR}"
echo "  version ${CONVOY_VERSION} (${CONVOY_BUILD_NUMBER}), arch: $(lipo -archs "${MACOS_DIR}/${APP_NAME}")"
echo ""
echo "Verify it with:  ./verify-bundle.sh \"${APP_DIR}\""
