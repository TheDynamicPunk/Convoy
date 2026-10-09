#!/bin/bash
#
# Assembles the Firefox extension: the shared tree in Extensions/Chromium with
# Extensions/Firefox laid over it (its manifest and adapter). One source for
# the code; the version comes from the Chromium manifest so there is no second
# number to bump.
#
#   ./Extensions/build-firefox.sh <out-dir>     assemble into <out-dir>
#   ./Extensions/build-firefox.sh --lint        assemble, then web-ext lint
#   ./Extensions/build-firefox.sh --sign        assemble, sign (AMO unlisted)
#
# --sign needs Node and AMO_JWT_ISSUER / AMO_JWT_SECRET (addons.mozilla.org >
# Developer Hub > API keys). The signed .xpi lands in Extensions/Firefox/dist/
# as convoy-<version>.xpi, which build.sh bundles into the app. With
# CONVOY_PAGES_DIR (a clone of thedynamicpunk.github.io) it also adds the
# version to convoy/firefox-updates.json, the way release.sh does the appcast;
# the tag at HEAD names the GitHub release the .xpi is expected on, or set
# CONVOY_FIREFOX_URL_PREFIX. AMO signs a version number once: bump "version"
# in Extensions/Chromium/manifest.json before signing a changed build.
#
set -e

EXT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED="${EXT_DIR}/Chromium"
OVERLAY="${EXT_DIR}/Firefox"
DIST="${OVERLAY}/dist"

MODE="assemble"
case "${1:-}" in
    --lint) MODE="lint"; shift ;;
    --sign) MODE="sign"; shift ;;
esac

OUT="${1:-}"
if [ -z "$OUT" ]; then
    OUT="$(cd "${EXT_DIR}/.." && pwd)/.build/firefox/extension"
fi

json_version() {
    if command -v plutil >/dev/null 2>&1; then
        plutil -extract version raw -o - "$1"
    else
        python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$1"
    fi
}

VERSION="$(json_version "${SHARED}/manifest.json")"
if [ -z "$VERSION" ]; then
    echo "ERROR: no version in ${SHARED}/manifest.json" >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
rsync -a --exclude '.*' --exclude 'manifest.json' "${SHARED}/" "${OUT}/"
rsync -a --exclude '.*' --exclude 'manifest.json' --exclude 'dist' --exclude 'README.md' "${OVERLAY}/" "${OUT}/"
sed "s/__VERSION__/${VERSION}/" "${OVERLAY}/manifest.json" > "${OUT}/manifest.json"

if grep -q "__VERSION__" "${OUT}/manifest.json"; then
    echo "ERROR: version placeholder left in the Firefox manifest" >&2
    exit 1
fi
echo "Firefox extension ${VERSION} assembled at ${OUT}"

run_webext() {
    if ! command -v npx >/dev/null 2>&1; then
        echo "ERROR: --lint and --sign need Node (npx)." >&2
        exit 1
    fi
    npx --yes web-ext@10 "$@"
}

if [ "$MODE" = "lint" ]; then
    run_webext lint --source-dir "$OUT" --self-hosted
elif [ "$MODE" = "sign" ]; then
    if [ -z "${AMO_JWT_ISSUER:-}" ] || [ -z "${AMO_JWT_SECRET:-}" ]; then
        echo "ERROR: set AMO_JWT_ISSUER and AMO_JWT_SECRET." >&2
        exit 1
    fi
    run_webext lint --source-dir "$OUT" --self-hosted
    mkdir -p "$DIST"
    run_webext sign --source-dir "$OUT" --artifacts-dir "$DIST" --channel unlisted \
        --api-key "$AMO_JWT_ISSUER" --api-secret "$AMO_JWT_SECRET"

    # Fixed name, so the update link below is predictable and build.sh finds it.
    SIGNED="$(ls -t "${DIST}"/*.xpi | head -1)"
    PACKAGE="${DIST}/convoy-${VERSION}.xpi"
    [ "$SIGNED" = "$PACKAGE" ] || mv "$SIGNED" "$PACKAGE"
    echo ""
    echo "Signed: ${PACKAGE}"

    # Self-hosted updates: add this version to convoy/firefox-updates.json in
    # the Pages clone, beside appcast.xml. Earlier versions stay listed.
    if [ -n "${CONVOY_PAGES_DIR:-}" ]; then
        TAG="$(git -C "$EXT_DIR" describe --tags --exact-match 2>/dev/null || true)"
        PREFIX="${CONVOY_FIREFOX_URL_PREFIX:-}"
        if [ -z "$PREFIX" ]; then
            if [ -z "$TAG" ]; then
                echo "ERROR: HEAD is not tagged. Tag it, or set CONVOY_FIREFOX_URL_PREFIX." >&2
                exit 1
            fi
            PREFIX="https://github.com/TheDynamicPunk/Convoy/releases/download/${TAG}/"
        fi
        UPDATES="${CONVOY_PAGES_DIR}/convoy/firefox-updates.json"
        mkdir -p "$(dirname "$UPDATES")"
        python3 - "$UPDATES" "${OUT}/manifest.json" "$VERSION" "${PREFIX}convoy-${VERSION}.xpi" \
            "$(shasum -a 256 "$PACKAGE" | cut -d' ' -f1)" <<'PY'
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
        echo "Updated ${UPDATES}"
        echo "Upload ${PACKAGE} to ${PREFIX} first, then commit and push the Pages repo:"
        echo "an update list that points at a missing file makes every update check fail."
    else
        echo "Set CONVOY_PAGES_DIR to your Pages clone to also write firefox-updates.json."
    fi
fi
