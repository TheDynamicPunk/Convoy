#!/bin/bash
#
# Checks this machine can build the app, and names the fix when it cannot.
# Run by build.sh and release.sh; run it directly when a build fails in files
# you have not touched.
#
# It fails rather than working around what it finds. Its predecessor quietly
# selected an older SDK, which hid the problem and pinned the project a year
# back.

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
    echo "" >&2
    echo "toolchain: $1" >&2
    shift
    for line in "$@"; do echo "           $line" >&2; done
    echo "" >&2
    exit 1
}

# ── 1. Xcode must be the active developer directory ────────────────────────
# SwiftUI's property wrappers are macros, and libSwiftUIMacros.dylib ships
# only inside Xcode.app. Installing Xcode does not select it. Symptom:
# "external macro implementation type 'SwiftUIMacros.StateMacro' could not be
# found" on every @State.
developer_dir="$(xcode-select -p 2>/dev/null || true)"
case "$developer_dir" in
    */Xcode*.app/Contents/Developer) ;;
    *)
        xcode_app="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)"
        if [ -n "$xcode_app" ]; then
            fail "the Command Line Tools are active, but SwiftUI needs Xcode." \
                 "Xcode is installed at ${xcode_app}; it is just not selected." \
                 "" \
                 "  sudo xcode-select -s ${xcode_app}/Contents/Developer"
        fi
        fail "Xcode is not installed, and SwiftUI cannot be compiled without it." \
             "The Command Line Tools do not ship libSwiftUIMacros.dylib." \
             "" \
             "Install Xcode, then:" \
             "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        ;;
esac

# ── 2. Nothing may shadow the selected toolchain ───────────────────────────
# Symptom: "unknown argument: '-target-arch-variant'" and a compiler segfault.
# Compared on the version number, not the banner: `swift --version` prefixes a
# swift-driver line that `swift -version` does not, and blocking a working
# build over that would be worse than not checking.
_swift_version() { sed -n 's/.*Apple Swift version \([0-9][0-9.]*\).*/\1/p' | head -1; }

path_banner="$(swift -version 2>/dev/null | head -1 || true)"
xcrun_banner="$(xcrun swift -version 2>/dev/null | head -1 || true)"
path_version="$(printf '%s\n' "$path_banner" | _swift_version)"
xcrun_version="$(printf '%s\n' "$xcrun_banner" | _swift_version)"

if [ -z "$path_banner" ]; then
    fail "there is no 'swift' on PATH." \
         "Xcode is active, so the compiler exists. A new terminal usually fixes this."
fi

if [ -n "$xcrun_version" ] && [ "$path_version" != "$xcrun_version" ]; then
    fail "something on PATH is shadowing Xcode's Swift compiler." \
         "  PATH gives:   ${path_banner}" \
         "  Xcode gives:  ${xcrun_banner}" \
         "" \
         "Usually swiftly. A swift.org toolchain cannot build this app at all --" \
         "it has no SwiftUI, AVFoundation or Security.framework. Remove it:" \
         "" \
         "  ~/.swiftly/bin/swiftly uninstall <version> && rm -rf ~/.swiftly" \
         "  (then drop the swiftly lines from ~/.zprofile)" \
         "" \
         "or keep .swift-version pinned to 'xcode' so swiftly defers. That file" \
         "must hold that single word -- swiftly rejects it if it carries a comment."
fi

# ── 3. Prove SwiftUI compiles ──────────────────────────────────────────────
# The backstop for whatever breaks next. Compiles the capability rather than
# looking for a named file: the previous version searched the toolchain plugin
# directory, and Xcode keeps that plugin under Platforms/ instead.
# Cached against toolchain and SDK identity so it runs only when either moves.
stamp_file="${PROJECT_DIR}/.build/.toolchain-verified"
stamp_now="$(xcrun --find swiftc 2>/dev/null || true)|$(xcrun --show-sdk-path 2>/dev/null || true)|$(xcrun --show-sdk-version 2>/dev/null || true)"

if [ "$(cat "$stamp_file" 2>/dev/null)" != "$stamp_now" ]; then
    probe_dir="$(mktemp -d)"
    trap 'rm -rf "$probe_dir"' EXIT
    cat > "${probe_dir}/probe.swift" <<'PROBE'
import SwiftUI

struct Probe: View {
    @State private var value = 0
    var body: some View { Text("\(value)") }
}
PROBE
    if ! probe_output="$(xcrun swiftc -typecheck "${probe_dir}/probe.swift" 2>&1)"; then
        fail "this toolchain cannot compile SwiftUI." \
             "Checks 1 and 2 passed, so this is something new:" \
             "" \
             "$(echo "$probe_output" | head -5)"
    fi
    mkdir -p "$(dirname "$stamp_file")"
    echo "$stamp_now" > "$stamp_file"
fi

# ── 4. Report ──────────────────────────────────────────────────────────────
# XCTest is noted, never fatal: the app builds without it, only tests need it.
if [ -z "${CONVOY_QUIET_TOOLCHAIN:-}" ]; then
    sdk_name="$(xcrun --show-sdk-path 2>/dev/null)"
    echo "toolchain: Xcode $(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}') · SDK ${sdk_name##*/} $(xcrun --show-sdk-version 2>/dev/null) · $(xcrun swift -version 2>/dev/null | head -1 | sed 's/.*Apple Swift version \([0-9.]*\).*/Swift \1/')"
    if [ ! -d "$(xcode-select -p)/../SharedFrameworks/XCTest.framework" ]; then
        echo "toolchain: note -- XCTest not found, so 'swift test' will not build."
    fi
fi
