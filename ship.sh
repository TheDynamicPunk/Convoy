#!/bin/bash
#
# ship.sh -- prepare a Convoy release.
#
# Everything here is local: nothing is pushed, uploaded or published. The one
# exception is signing the Firefox extension on AMO, which cannot be undone, so
# it asks first. Publishing is a separate step, deliberately not in this file.
#
#   ./ship.sh v1.2.0             run every step in order; stop at the first failure
#   ./ship.sh v1.2.0 verify      run one step on its own
#
# Steps: checks  extension  tag  build  verify
#
# Environment:
#   CONVOY_PAGES_DIR   clone of thedynamicpunk.github.io (default: next to this repo)
#   SKIP_TESTS=1       skip `swift test`
#   AMO_JWT_ISSUER, AMO_JWT_SECRET   only when the extension needs signing
#
set -eo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"       # .swift-version is read from the current directory
ROOT="$PWD"

die() {
    echo "" >&2
    echo "STOPPED: $1" >&2
    shift
    for line in "$@"; do echo "         $line" >&2; done
    exit 1
}

TAG="${1:-}"
ONLY="${2:-}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: ./ship.sh vMAJOR.MINOR.PATCH [step]"

VERSION="${TAG#v}"
BUILD="$(git rev-list --count HEAD)"          # same number release.sh puts in the app
PAGES="${CONVOY_PAGES_DIR:-$ROOT/../thedynamicpunk.github.io}"
WORK="$ROOT/.build/ship-pages"                # scratch copy of the Pages files; the real clone is not touched
DIST="$ROOT/.build/dist"
SPARKLE="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
TMP="$(mktemp -d)"
CURRENT="starting"

# Whatever fails, say which step it was in; release.sh and friends print their own reasons.
on_exit() {
    local rc=$?
    rm -rf "$TMP"
    [ "$rc" -eq 0 ] || echo "         (stopped in step: $CURRENT)" >&2
}
trap on_exit EXIT

step() { CURRENT="$1"; echo ""; echo "== $1"; }
ok()   { echo "  ok  $1"; }

confirm() {
    [ -n "${CONVOY_YES:-}" ] && return 0
    local answer=""
    printf '\n%s [y/N] ' "$1"
    { read -r answer </dev/tty; } 2>/dev/null || answer=""
    [ "$answer" = "y" ] || [ "$answer" = "yes" ]
}

# newer A B: is version A (vX.Y.Z) newer than B?
newer() {
    local a1 a2 a3 b1 b2 b3
    IFS=. read -r a1 a2 a3 <<<"${1#v}"
    IFS=. read -r b1 b2 b3 <<<"${2#v}"
    [ "$a1" -ne "$b1" ] && { [ "$a1" -gt "$b1" ]; return; }
    [ "$a2" -ne "$b2" ] && { [ "$a2" -gt "$b2" ]; return; }
    [ "$a3" -gt "$b3" ]
}

# ---------------------------------------------------------------------------
# 1. checks -- read-only. Cheap things that would otherwise fail after the
#    extension has been signed (which cannot be undone) or after a long build.
# ---------------------------------------------------------------------------
step_checks() {
    step "1. Checks"

    [ "$(git symbolic-ref --short -q HEAD)" = "main" ] || die "not on main"
    [ -z "$(git status --porcelain)" ] || die "the working tree is dirty; $TAG would not describe what is built" "$(git status --short)"
    git fetch -q origin --tags || die "cannot reach origin"
    git merge-base --is-ancestor origin/main HEAD || die "origin/main has commits you do not have; pull first"
    ok "on main, clean, not behind origin"

    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        [ "$(git rev-parse "$TAG^{commit}")" = "$(git rev-parse HEAD)" ] || die "tag $TAG already exists, at a different commit"
    fi
    local prev
    prev="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | grep -vx "$TAG" | head -1 || true)"
    [ -z "$prev" ] || newer "$TAG" "$prev" || die "$TAG is not newer than $prev"
    ok "$TAG is free and newer than ${prev:-any earlier tag}"

    # Sparkle offers an update only when the build number goes up.
    [ -f "$PAGES/convoy/appcast.xml" ] || die "no Pages clone at $PAGES" "Clone thedynamicpunk.github.io there, or set CONVOY_PAGES_DIR."
    git -C "$PAGES" fetch -q origin || die "cannot reach the Pages remote"
    git -C "$PAGES" merge-base --is-ancestor "origin/$(git -C "$PAGES" symbolic-ref --short HEAD)" HEAD \
        || die "the Pages clone is behind its origin; pull it first"
    local highest
    highest="$(grep -o '<sparkle:version>[0-9]*' "$PAGES/convoy/appcast.xml" | grep -o '[0-9]*$' | sort -n | tail -1 || true)"
    [ "$BUILD" -gt "${highest:-0}" ] || die "build number $BUILD is not above the appcast's highest ($highest)" "No installed copy would be offered this update."
    ok "build number $BUILD is above the appcast's ${highest:-0}"

    ./verify-toolchain.sh >"$TMP/toolchain.log" 2>&1 || die "the toolchain check failed" "$(cat "$TMP/toolchain.log")"
    ok "toolchain"

    # release.sh checks this too, but only after the extension has been signed.
    swift package resolve --package-path "$ROOT" >/dev/null
    [ "$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Resources/Info.plist)" = "$("$SPARKLE/generate_keys" -p 2>/dev/null)" ] \
        || die "SUPublicEDKey in Info.plist does not match the key in this Mac's Keychain" "Every installed copy would reject an update signed here."
    ok "Sparkle key matches the Keychain"

    if [ -n "${SKIP_TESTS:-}" ]; then
        echo "  --  swift test skipped"
    else
        swift test >"$TMP/tests.log" 2>&1 || die "swift test failed" "$(tail -20 "$TMP/tests.log")"
        ok "swift test"
    fi
}

# ---------------------------------------------------------------------------
# 2. extension -- AMO signs a version number once, and build.sh silently skips
#    a signed package whose version does not match. So: if a signed package
#    exists for this version, it must be exactly what the source builds; if
#    there is none, sign one.
# ---------------------------------------------------------------------------
step_extension() {
    step "2. Firefox extension"
    local ext xpi
    ext="$(plutil -extract version raw -o - Extensions/Chromium/manifest.json)"
    xpi="Extensions/Firefox/dist/convoy-$ext.xpi"

    if [ -f "$xpi" ]; then
        bash ./Extensions/build-firefox.sh "$TMP/source" >/dev/null
        unzip -q "$xpi" -d "$TMP/signed"
        rm -rf "$TMP/signed/META-INF"                      # AMO's signature files
        diff -r -q "$TMP/source" "$TMP/signed" >"$TMP/ext.diff" || die "the signed convoy-$ext.xpi is STALE: the extension changed after it was signed" \
            "$(sed "s#$TMP/##g" "$TMP/ext.diff" | head -8)" \
            "Bump \"version\" in Extensions/Chromium/manifest.json, commit, and run this again."
        ok "signed convoy-$ext.xpi matches the source"
        return
    fi

    echo "  Extension $ext has no signed package yet."
    [ -n "${AMO_JWT_ISSUER:-}" ] && [ -n "${AMO_JWT_SECRET:-}" ] || die "set AMO_JWT_ISSUER and AMO_JWT_SECRET" "addons.mozilla.org > Developer Hub > API keys"
    command -v npx >/dev/null || die "signing needs Node (npx)"
    confirm "Sign extension $ext on AMO? That version number can never be signed again." || die "not signed; nothing was changed"
    # CONVOY_PAGES_DIR is emptied on purpose: with it set, this would also write
    # the update list into the real Pages clone, which is a publish-time job.
    CONVOY_PAGES_DIR='' bash ./Extensions/build-firefox.sh --sign
    ok "signed $xpi"
}

# ---------------------------------------------------------------------------
# 3. tag -- release.sh builds from the tag at HEAD. Local only.
# ---------------------------------------------------------------------------
step_tag() {
    step "3. Tag"
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        [ "$(git rev-parse "$TAG^{commit}")" = "$(git rev-parse HEAD)" ] || die "tag $TAG exists at a different commit"
        ok "$TAG already points at HEAD"
    else
        git tag -a "$TAG" -m "Convoy $VERSION"
        ok "created $TAG (local only)"
    fi
}

# ---------------------------------------------------------------------------
# 4. build -- release.sh does the work: universal build, gates, DMG, pkg, zip,
#    appcast item. It writes the appcast into a scratch copy, so running this
#    twice never leaves a half-edited Pages clone behind.
# ---------------------------------------------------------------------------
step_build() {
    step "4. Build (release.sh)"
    rm -rf "$WORK"
    mkdir -p "$WORK/convoy"
    cp "$PAGES/convoy/appcast.xml" "$WORK/convoy/"
    CONVOY_PAGES_DIR="$WORK" ./release.sh
}

# ---------------------------------------------------------------------------
# 5. verify -- what release.sh does not check, and what decides whether
#    installed copies accept the update.
# ---------------------------------------------------------------------------
step_verify() {
    step "5. Verify what was built"
    local dmg="$DIST/Convoy-$VERSION.dmg" pkg="$DIST/Convoy-$VERSION.pkg" zip="$DIST/Convoy-$VERSION.zip"
    local appcast="$WORK/convoy/appcast.xml"
    local f
    [ -f "$appcast" ] || die "no appcast to check" "Run the build step first."
    for f in "$dmg" "$pkg" "$zip" "$dmg.sha256" "$pkg.sha256"; do
        [ -s "$f" ] || die "missing or empty: $f"
    done
    (cd "$DIST" && shasum -a 256 -c "Convoy-$VERSION.dmg.sha256" && shasum -a 256 -c "Convoy-$VERSION.pkg.sha256") >/dev/null \
        || die "a .sha256 file does not match its installer"
    ok "5 release files present, checksums agree"

    # release.sh gates the app, the copy in the DMG and the copy in the pkg.
    # The zip is the one it skips, and it is what every installed copy updates from.
    mkdir "$TMP/zip"
    ditto -x -k "$zip" "$TMP/zip"
    CONVOY_VERIFY_RELEASE=1 ./verify-bundle.sh "$TMP/zip/Convoy.app" arm64 x86_64 >"$TMP/zip.log" 2>&1 \
        || die "the app inside the update zip fails verification" "$(grep FAIL "$TMP/zip.log")"
    ok "the app inside the update zip passes every gate"

    # The appcast item for this version: what Sparkle will read.
    local item="//item[*[local-name()='shortVersionString']='$VERSION']"
    local url length sig build
    [ "$(xmllint --xpath "count($item)" "$appcast")" = "1" ] || die "the appcast needs exactly one item for $VERSION"
    url="$(xmllint --xpath "string($item/enclosure/@url)" "$appcast")"
    length="$(xmllint --xpath "string($item/enclosure/@length)" "$appcast")"
    sig="$(xmllint --xpath "string($item/enclosure/@*[local-name()='edSignature'])" "$appcast")"
    build="$(xmllint --xpath "string($item/*[local-name()='version'])" "$appcast")"

    [[ "$url" == */releases/download/$TAG/Convoy-$VERSION.zip ]] || die "the appcast points at the wrong file: $url"
    [ "$length" = "$(wc -c <"$zip" | tr -d ' ')" ] || die "the appcast length ($length) does not match the zip"
    [ "$build" = "$BUILD" ] || die "the appcast build is $build, expected $BUILD"
    [ "$(xmllint --xpath "count($item/*[local-name()='hardwareRequirements'])" "$appcast")" = "0" ] \
        || die "the appcast item restricts the update to some hardware"
    "$SPARKLE/sign_update" --verify "$zip" "$sig" >/dev/null || die "the EdDSA signature does not verify" "Every installed copy would reject this update."
    ok "appcast item: right file, length, build $build, signature verifies"
}

# ---------------------------------------------------------------------------
STEPS="checks extension tag build verify"

if [ -n "$ONLY" ]; then
    case " $STEPS " in
        *" $ONLY "*) "step_$ONLY" ;;
        *) die "unknown step '$ONLY'" "Steps: $STEPS" ;;
    esac
    exit 0
fi

for s in $STEPS; do "step_$s"; done

echo ""
echo "Prepared $TAG (build $BUILD). Nothing has been pushed or published."
echo "  $DIST/Convoy-$VERSION.{dmg,pkg,zip} and their checksums"
echo "  appcast item (scratch copy): $WORK/convoy/appcast.xml"
echo "  tag $TAG exists locally; to abandon this release: git tag -d $TAG"
