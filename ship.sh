#!/bin/bash
#
# ship.sh -- prepare a Convoy release.
#
# The default run is entirely local: nothing is pushed, uploaded or published.
# (The one exception is signing the Firefox extension on AMO, which cannot be
# undone, so it asks first.) Going public is three more commands, run one at a
# time, at the bottom of this file.
#
#   ./ship.sh v1.2.0             prepare: checks, extension, tag, build, verify
#   ./ship.sh v1.2.0 verify      run one step on its own
#   ./ship.sh v1.2.0 push        then: push, (release in the browser), pages, live
#
# Steps: checks  extension  tag  build  verify
#
# Environment:
#   CONVOY_PAGES_DIR   clone of thedynamicpunk.github.io (default: next to this repo)
#   CONVOY_PAGES_EXTRA extra files in that clone to commit with the release, e.g. index.html
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
        local hint='Bump "version" in Extensions/Chromium/manifest.json, commit, and run this again.'
        bash ./Extensions/build-firefox.sh "$TMP/source" >/dev/null
        unzip -q "$xpi" -d "$TMP/signed"
        rm -rf "$TMP/signed/META-INF"                      # AMO's signature files
        # Signing re-lays-out manifest.json (same content, different formatting),
        # so that one file is compared as data and every other file byte for byte.
        python3 - "$TMP/source/manifest.json" "$TMP/signed/manifest.json" <<'PY' \
            || die "the signed convoy-$ext.xpi is STALE: manifest.json changed after it was signed" "$hint"
import json, sys
sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)
PY
        rm "$TMP/source/manifest.json" "$TMP/signed/manifest.json"
        diff -r -q "$TMP/source" "$TMP/signed" >"$TMP/ext.diff" || die "the signed convoy-$ext.xpi is STALE: the extension changed after it was signed" \
            "$(sed "s#$TMP/##g" "$TMP/ext.diff" | head -8)" "$hint"
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

# ===========================================================================
# PUBLISH. Not part of the default run: each is its own command, in this order.
#
#   ./ship.sh v1.2.0 push     push main and the tag
#   (you, in the browser)     create the GitHub release and attach the files
#   ./ship.sh v1.2.0 pages    appcast, latest.json, extension list -> Pages repo
#   ./ship.sh v1.2.0 live     check what users will fetch
#
# The appcast is what makes installed copies update, so it goes out last: an
# appcast that points at a missing file breaks every update check.
# ===========================================================================

repo() { git config --get remote.origin.url | sed -E 's#^.*github\.com[:/]##; s#\.git$##'; }

# The files that belong on the GitHub release. The signed extension is included
# only when this release is the one that introduces it.
release_files() {
    local f ext link
    for f in dmg dmg.sha256 pkg pkg.sha256 zip; do echo "$DIST/Convoy-$VERSION.$f"; done
    ext="$(plutil -extract version raw -o - Extensions/Chromium/manifest.json)"
    link="$(grep -A1 "\"version\": \"$ext\"" "$PAGES/convoy/firefox-updates.json" | grep update_link || true)"
    if [ -z "$link" ] || [[ "$link" == *"/$TAG/"* ]]; then echo "$ROOT/Extensions/Firefox/dist/convoy-$ext.xpi"; fi
}

# ---------------------------------------------------------------------------
# 6. push -- the first thing that goes public.
# ---------------------------------------------------------------------------
step_push() {
    [ "$(git symbolic-ref --short -q HEAD)" = "main" ] || die "not on main"
    [ -z "$(git status --porcelain)" ] || die "the working tree is dirty" "$(git status --short)"
    [ "$(git rev-parse "$TAG^{commit}" 2>/dev/null)" = "$(git rev-parse HEAD)" ] \
        || die "$TAG does not point at HEAD" "Something was committed after the build, so the build is not what HEAD is." "Run: git tag -d $TAG   then ./ship.sh $TAG"
    git fetch -q origin --tags || die "cannot reach origin"
    git merge-base --is-ancestor origin/main HEAD || die "origin/main has commits you do not have; pull first"
    step_verify                                  # the built files, once more, before anything goes out

    step "6. Push main and $TAG"
    confirm "Push main ($(git rev-list --count origin/main..HEAD) commit(s)) and $TAG to origin?" || die "not pushed; nothing was changed"
    git push origin main "refs/tags/$TAG"
    ok "pushed"

    # A starting point for the release notes: edit it, or write your own.
    local prev f
    prev="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | grep -vx "$TAG" | head -1 || true)"
    {
        echo "## What's new"; echo
        git log --no-merges --pretty='- %s' "${prev:+$prev..}HEAD"
        echo; echo "## Checksums (SHA-256)"; echo; echo '```'
        while IFS= read -r f; do
            case "$f" in *.dmg|*.pkg|*.xpi) printf '%s  %s\n' "$(shasum -a 256 <"$f" | cut -d' ' -f1)" "$(basename "$f")" ;; esac
        done < <(release_files)
        echo '```'
    } >"$DIST/release-notes.md"

    echo ""
    echo "Now create the release in the browser:"
    echo "  https://github.com/$(repo)/releases/new?tag=$TAG"
    echo "  Title: Convoy $VERSION"
    echo "  Notes: a draft is in $DIST/release-notes.md"
    echo "  Attach exactly these files (do not rebuild them):"
    release_files | sed 's/^/    /'
    echo "  Publish it as a normal release: not a draft, not a pre-release."
    echo ""
    echo "Then run: ./ship.sh $TAG pages"
}

# ---------------------------------------------------------------------------
# 7. pages -- the appcast goes live here. Refuses unless the release is
#    published and its files are byte for byte the ones that were built.
# ---------------------------------------------------------------------------
step_pages() {
    step "7. Pages repo"
    local r f name branch files others path
    r="$(repo)"

    git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 || die "$TAG is not on origin" "Run: ./ship.sh $TAG push"
    while IFS= read -r f; do
        name="$(basename "$f")"
        curl -fsSL "https://github.com/$r/releases/download/$TAG/$name" -o "$TMP/download" 2>/dev/null \
            || die "$name cannot be downloaded from the release" "Is the release published (not a draft)? Is $name attached?"
        [ "$(shasum -a 256 <"$TMP/download" | cut -d' ' -f1)" = "$(shasum -a 256 <"$f" | cut -d' ' -f1)" ] \
            || die "$name on the release is not the file that was built" "Remove it from the release and attach $f."
        ok "on the release, byte for byte: $name"
    done < <(release_files)

    git -C "$PAGES" fetch -q origin || die "cannot reach the Pages remote"
    branch="$(git -C "$PAGES" symbolic-ref --short HEAD)"
    git -C "$PAGES" merge-base --is-ancestor "origin/$branch" HEAD || die "the Pages clone is behind its origin; pull it first"
    git -C "$PAGES" diff --cached --quiet || die "the Pages clone has staged changes; unstage them first"

    # 1. The appcast, built earlier from this clone's copy.
    cp "$WORK/convoy/appcast.xml" "$PAGES/convoy/appcast.xml"

    # 2. latest.json: what the website's download buttons read.
    mb() { awk -v b="$(wc -c <"$1" | tr -d ' ')" 'BEGIN { printf "%.1f MB", b / 1048576 }'; }
    cat >"$PAGES/convoy/latest.json" <<EOF
{
  "version": "$VERSION",
  "repo": "$r",
  "tag": "$TAG",
  "pkg": "Convoy-$VERSION.pkg",
  "dmg": "Convoy-$VERSION.dmg",
  "pkgSize": "$(mb "$DIST/Convoy-$VERSION.pkg")",
  "dmgSize": "$(mb "$DIST/Convoy-$VERSION.dmg")",
  "date": "$((10#$(date +%d))) $(LC_ALL=C date +%B) $(date +%Y)",
  "prerelease": false
}
EOF
    files="convoy/appcast.xml convoy/latest.json ${CONVOY_PAGES_EXTRA:-}"

    # 3. The extension update list, when this release brings a new extension.
    if [[ "$(release_files)" == *.xpi* ]]; then
        local ext xpi
        ext="$(plutil -extract version raw -o - Extensions/Chromium/manifest.json)"
        xpi="$ROOT/Extensions/Firefox/dist/convoy-$ext.xpi"
        python3 - "$PAGES/convoy/firefox-updates.json" "$ROOT/Extensions/Firefox/manifest.json" "$ext" \
            "https://github.com/$r/releases/download/$TAG/convoy-$ext.xpi" "$(shasum -a 256 <"$xpi" | cut -d' ' -f1)" <<'PY'
import json, os, sys
path, manifest, version, link, digest = sys.argv[1:6]
addon_id = json.load(open(manifest))["browser_specific_settings"]["gecko"]["id"]
doc = json.load(open(path)) if os.path.exists(path) else {"addons": {}}
updates = doc["addons"].setdefault(addon_id, {"updates": []})["updates"]
updates[:] = [u for u in updates if u["version"] != version]
updates.append({"version": version, "update_link": link, "update_hash": "sha256:" + digest})
updates.sort(key=lambda u: [int(p) for p in u["version"].split(".")])
with open(path, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY
        files="$files convoy/firefox-updates.json"
    fi

    # Show exactly what is about to go live, and what is being left out.
    echo ""
    echo "  Will be committed to the Pages repo: $files"
    others="$(git -C "$PAGES" status --porcelain | while IFS= read -r line; do
        path="${line:3}"
        [[ " $files " == *" $path "* ]] || echo "    $line"
    done)"
    [ -z "$others" ] || { echo "  Modified there but NOT part of this release (left alone):"; echo "$others"; }
    echo ""
    echo "  convoy/latest.json:"; sed 's/^/    /' "$PAGES/convoy/latest.json"
    git -C "$PAGES" --no-pager diff --stat -- convoy | sed 's/^/  /'
    confirm "Commit and push these? Installed copies will be offered $VERSION." || die "not pushed" "The files are written in the Pages clone; rerun this step when ready."

    # shellcheck disable=SC2086
    git -C "$PAGES" add -- $files
    if git -C "$PAGES" diff --cached --quiet; then
        echo "  nothing new to commit (already committed)"
    else
        git -C "$PAGES" commit -q -m "Convoy $VERSION"
    fi
    git -C "$PAGES" push origin "HEAD:$branch"
    ok "pushed to the Pages repo"
    echo ""
    echo "GitHub Pages takes a minute or two. Then run: ./ship.sh $TAG live"
}

# ---------------------------------------------------------------------------
# 8. live -- what users will fetch is what was pushed.
# ---------------------------------------------------------------------------
step_live() {
    step "8. Check what users will fetch"
    local feed base name i seen
    feed="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" Resources/Info.plist)"
    base="${feed%/appcast.xml}"
    for name in appcast.xml latest.json firefox-updates.json; do
        git -C "$PAGES" show "HEAD:convoy/$name" >"$TMP/expected" 2>/dev/null || continue
        seen=""
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
            if curl -fsS "$base/$name?cb=$(date +%s)" -o "$TMP/live" 2>/dev/null && cmp -s "$TMP/live" "$TMP/expected"; then seen=1; break; fi
            [ "$i" -gt 1 ] || echo "  waiting for GitHub Pages to publish $name ..."
            sleep 10
        done
        [ -n "$seen" ] || die "the live $name does not match what was pushed after 3 minutes" "$base/$name"
        ok "live $name is what was pushed"
    done
    echo ""
    echo "$VERSION is out. Now watch a real 1.1.0 install update itself: Convoy > Check for Updates."
}

# ---------------------------------------------------------------------------
STEPS="checks extension tag build verify"

if [ -n "$ONLY" ]; then
    case " $STEPS push pages live " in
        *" $ONLY "*) "step_$ONLY" ;;
        *) die "unknown step '$ONLY'" "Steps: $STEPS push pages live" ;;
    esac
    exit 0
fi

for s in $STEPS; do "step_$s"; done

echo ""
echo "Prepared $TAG (build $BUILD). Nothing has been pushed or published."
echo "  $DIST/Convoy-$VERSION.{dmg,pkg,zip} and their checksums"
echo "  appcast item (scratch copy): $WORK/convoy/appcast.xml"
echo "  tag $TAG exists locally; to abandon this release: git tag -d $TAG"
echo "  Next, when you are ready to go public: ./ship.sh $TAG push"
