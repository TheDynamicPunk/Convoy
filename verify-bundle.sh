#!/bin/bash
#
# Gates an assembled Convoy.app before it is allowed anywhere near a
# user. Run by release.sh; also runnable by hand against any bundle,
# including one extracted back out of a shipped DMG.
#
#   ./verify-bundle.sh <Convoy.app> [expected-arch ...]
#
# Set CONVOY_VERIFY_RELEASE=1 to additionally require real (tag-derived)
# version numbers, which a development build does not have.
#
# Exits non-zero if any gate fails, after running all of them -- a partial
# report would just mean a second round trip.
#
# The failure this exists to catch: a mis-signed bundle still launches
# normally as an app, while the browser silently cannot start its native
# messaging host. Chrome renders that identically to the app not being
# installed at all, so without a gate here it reaches users as an
# unreproducible "it just doesn't work" bug report.

APP_DIR="${1:-}"
shift || true
EXPECTED_ARCHS=("$@")

if [ -z "$APP_DIR" ] || [ ! -d "$APP_DIR" ]; then
    echo "usage: $0 <Convoy.app> [expected-arch ...]"
    exit 2
fi

APP_NAME="Convoy"
HOST_NAME="NativeMessagingHost"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
INFO_PLIST="${APP_DIR}/Contents/Info.plist"
APP_BIN="${MACOS_DIR}/${APP_NAME}"
HOST_BIN="${MACOS_DIR}/${HOST_NAME}"

FAILURES=0
if [ -t 1 ]; then GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'; else GREEN=""; RED=""; RESET=""; fi
pass() { printf "  %sok%s    %s\n" "$GREEN" "$RESET" "$1"; }
fail() { printf "  %sFAIL%s  %s\n" "$RED" "$RESET" "$1"; FAILURES=$((FAILURES + 1)); }
note() { printf "  --    %s\n" "$1"; }

echo "Verifying ${APP_DIR}"
echo ""

# --- 1. Structure ----------------------------------------------------------
echo "structure"
for f in "$APP_BIN" "$HOST_BIN" "$INFO_PLIST" "${APP_DIR}/Contents/Resources/AppIcon.icns"; do
    if [ -f "$f" ]; then pass "present: ${f#$APP_DIR/}"; else fail "missing: ${f#$APP_DIR/}"; fi
done

ICON_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$INFO_PLIST" 2>/dev/null || echo "")
if [ -n "$ICON_NAME" ] && [ -f "${APP_DIR}/Contents/Resources/${ICON_NAME}.icns" ]; then
    pass "CFBundleIconFile=${ICON_NAME} resolves to a real file"
else
    fail "CFBundleIconFile=${ICON_NAME:-<unset>} does not resolve"
fi

# --- 2. Version ------------------------------------------------------------
echo ""
echo "version"
SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || echo "")
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST" 2>/dev/null || echo "")
# Only a hard gate for a release (CONVOY_VERIFY_RELEASE=1, set by release.sh).
# A development build legitimately carries the untagged fallback, and a check
# that always fails for developers is a check developers learn to ignore.
if [ "${CONVOY_VERIFY_RELEASE:-0}" = "1" ]; then release_check=fail; else release_check=note; fi

if [ -n "$SHORT_VERSION" ] && [ "$SHORT_VERSION" != "0.0.0" ]; then
    pass "CFBundleShortVersionString=${SHORT_VERSION}"
else
    $release_check "CFBundleShortVersionString=${SHORT_VERSION:-<unset>} -- untagged fallback, not a release version"
fi
# Sparkle compares this to decide an update exists. A zero or unset value
# means updates silently never appear, which no amount of testing surfaces.
if [ -n "$BUNDLE_VERSION" ] && [ "$BUNDLE_VERSION" != "0" ]; then
    pass "CFBundleVersion=${BUNDLE_VERSION}"
else
    $release_check "CFBundleVersion=${BUNDLE_VERSION:-<unset>} -- Sparkle would never offer an update"
fi

# --- 3. Architectures ------------------------------------------------------
echo ""
echo "architectures"
for bin in "$APP_BIN" "$HOST_BIN"; do
    archs=$(lipo -archs "$bin" 2>/dev/null || echo "")
    if [ ${#EXPECTED_ARCHS[@]} -eq 0 ]; then
        note "$(basename "$bin"): ${archs:-<unreadable>} (no expectation given)"
    else
        missing=""
        for want in "${EXPECTED_ARCHS[@]}"; do
            echo " $archs " | grep -q " $want " || missing="$missing $want"
        done
        if [ -z "$missing" ]; then
            pass "$(basename "$bin"): ${archs}"
        else
            fail "$(basename "$bin"): has '${archs}', missing:${missing}"
        fi
    fi
done

# --- 4. Signature validity -------------------------------------------------
#
# This is the gate that separates "unnotarized" from "broken", which is the
# difference between a user seeing a scary-but-survivable "Apple could not
# verify this app" dialog and an unrecoverable "app is damaged, move it to
# Trash". spctl rejects both cases identically for an ad-hoc signature, so
# codesign's own validity check is what draws the line.
echo ""
echo "signature"
if codesign --verify --deep --strict "$APP_DIR" 2>/dev/null; then
    pass "bundle signature is valid and complete (codesign --verify --deep --strict)"
else
    fail "bundle signature is INVALID -- users would see 'app is damaged', not 'unverified developer'"
    codesign --verify --deep --strict --verbose=2 "$APP_DIR" 2>&1 | sed 's/^/        /'
fi

for bin in "$APP_BIN" "$HOST_BIN"; do
    if codesign --verify --strict "$bin" 2>/dev/null; then
        pass "$(basename "$bin"): individually signed and valid"
    else
        fail "$(basename "$bin"): not validly signed"
    fi
done

# --- 5. No entitlements ----------------------------------------------------
#
# Anything here means something re-introduced the sandbox keys. On the host
# binary in particular, com.apple.security.app-sandbox is fatal: macOS
# SIGKILLs it the moment the browser exec()s it.
echo ""
echo "entitlements"
for bin in "$APP_BIN" "$HOST_BIN"; do
    ents=$(codesign -d --entitlements - "$bin" 2>/dev/null | grep -c "com.apple.security" || true)
    if [ "${ents:-0}" = "0" ]; then
        pass "$(basename "$bin"): no entitlements, as intended"
    else
        fail "$(basename "$bin"): carries ${ents} com.apple.security entitlement(s)"
        codesign -d --entitlements - "$bin" 2>/dev/null | sed 's/^/        /'
    fi
done

if grep -q "<key>com.apple.security" "$INFO_PLIST"; then
    fail "Info.plist has com.apple.security.* keys -- inert, but they misrepresent how this app is built"
else
    pass "Info.plist carries no entitlement-shaped keys"
fi

# --- 5b. Bundled helper list -----------------------------------------------
#
# The list of helper binaries and their expected hashes. A bundle without it
# still launches and still downloads ordinary files, but YouTube support can
# never be set up -- which looks like a broken feature rather than a packaging
# mistake.
echo ""
echo "bundled helper list"
HELPER_MANIFEST="${APP_DIR}/Contents/Resources/helpers.json"
if [ -f "$HELPER_MANIFEST" ]; then
    pass "helpers.json is present"
    if command -v python3 >/dev/null 2>&1; then
        seq=$(python3 -c "import json;print(json.load(open('$HELPER_MANIFEST'))['sequence'])" 2>/dev/null || echo "?")
        note "sequence $seq"
    fi
else
    fail "helpers.json missing -- the app could not install a single helper"
fi

# --- 5c. Sparkle -----------------------------------------------------------
#
# Each of these fails silently in the field: the app runs, and updates just
# never arrive. The missing key is the worst, because Sparkle starts anyway,
# falls back to Apple code signing, and rejects every ad-hoc-signed update,
# whose signature never matches the previous version's.
echo ""
echo "sparkle"
SPARKLE_FW="${APP_DIR}/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ] && codesign --verify --strict "$SPARKLE_FW" 2>/dev/null; then
    pass "Sparkle.framework embedded and validly signed"
else
    fail "Sparkle.framework missing or not validly signed"
fi
if otool -l "$APP_BIN" 2>/dev/null | grep -q "@executable_path/../Frameworks"; then
    pass "${APP_NAME} loads frameworks from Contents/Frameworks"
else
    fail "no @executable_path/../Frameworks rpath -- ${APP_NAME} cannot load Sparkle and will not launch"
fi

FEED_URL=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$INFO_PLIST" 2>/dev/null || echo "")
if [[ "$FEED_URL" == https://* ]]; then
    pass "SUFeedURL=${FEED_URL}"
else
    fail "SUFeedURL=${FEED_URL:-<unset>} -- must be set, and https"
fi

# An invalid key stops Sparkle from starting at all, so that one fails even
# for a development build.
ED_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$INFO_PLIST" 2>/dev/null || echo "")
if [ -z "$ED_KEY" ]; then
    $release_check "no SUPublicEDKey -- every update would be rejected. Run generate_keys and add the public key to Resources/Info.plist"
elif [ "$(printf '%s' "$ED_KEY" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" = "32" ]; then
    pass "SUPublicEDKey is a 32-byte Ed25519 public key"
else
    fail "SUPublicEDKey is not a valid Ed25519 public key -- Sparkle will refuse to start"
fi

# --- 6. Designated requirements --------------------------------------------
#
# IPCPeerVerification builds its trust requirement out of the sibling
# binary's designated requirement. If either binary has none, the app and
# its native messaging host refuse to talk to each other -- browser
# integration is dead, and the only visible symptom is Chrome's
# indistinguishable "Native host has exited".
echo ""
echo "IPC trust anchors"
for bin in "$APP_BIN" "$HOST_BIN"; do
    dr=$(codesign -d -r- "$bin" 2>&1 | grep "designated =>" | sed 's/^# *//' || true)
    if [ -n "$dr" ]; then
        pass "$(basename "$bin"): ${dr}"
    else
        fail "$(basename "$bin"): no designated requirement -- IPC peer verification cannot work"
    fi
done

# --- 7. Native messaging host round trip -----------------------------------
#
# The end-to-end version of gate 6: actually speak Chrome's native messaging
# protocol (4-byte little-endian length prefix + UTF-8 JSON) to the signed
# binary and require a well-formed answer. Everything above can pass while
# this still fails.
echo ""
echo "native messaging round trip"
PING_RESULT=$(python3 - "$HOST_BIN" <<'PY' 2>&1
import json, struct, subprocess, sys
msg = json.dumps({"type": "ping", "payload": {}}).encode()
try:
    p = subprocess.run([sys.argv[1]], input=struct.pack("<I", len(msg)) + msg,
                       capture_output=True, timeout=30)
except Exception as e:
    print(f"ERROR {type(e).__name__}: {e}")
    sys.exit(0)
out = p.stdout
if len(out) < 4:
    print(f"ERROR no framed reply (exit={p.returncode}, stdout={out[:80]!r}, stderr={p.stderr[:160]!r})")
    sys.exit(0)
n = struct.unpack("<I", out[:4])[0]
try:
    reply = json.loads(out[4:4+n])
except Exception as e:
    print(f"ERROR unparseable reply: {e}")
    sys.exit(0)
print("OK " + json.dumps(reply, sort_keys=True) if reply.get("status") == "ok"
      else "ERROR unexpected reply: " + json.dumps(reply, sort_keys=True))
PY
)
if [[ "$PING_RESULT" == OK* ]]; then
    pass "host answered a ping: ${PING_RESULT#OK }"
else
    fail "host did not answer a ping: ${PING_RESULT#ERROR }"
fi

# --- 8. Gatekeeper, for the record -----------------------------------------
#
# Expected to reject: there is no notarization ticket. Reported rather than
# gated, so that the day a Developer ID certificate does exist, the change in
# this line is visible instead of silent.
echo ""
echo "gatekeeper"
SPCTL=$(spctl -a -vvv -t exec "$APP_DIR" 2>&1 | tr '\n' ' ')
if echo "$SPCTL" | grep -q "accepted"; then
    note "spctl ACCEPTED -- this bundle is notarized. Update the distribution docs."
else
    note "spctl rejected (expected: no notarization ticket). Users get the"
    note "'Apple could not verify' dialog and the System Settings > Privacy &"
    note "Security > Open Anyway flow. Gate 4 is what guarantees they do not"
    note "instead get 'app is damaged'."
fi

echo ""
if [ "$FAILURES" = "0" ]; then
    echo "All gates passed."
    exit 0
else
    echo "${FAILURES} gate(s) FAILED -- do not ship this bundle."
    exit 1
fi
