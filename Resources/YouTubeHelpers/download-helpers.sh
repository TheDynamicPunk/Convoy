#!/bin/bash
# Downloads/updates the helpers Convoy shells out to for YouTube URL
# resolution and downloading:
#   - yt-dlp        (does the actual signature/PO-Token/SABR extraction)
#   - bgutil-pot    (local PO-Token provider yt-dlp talks to on 127.0.0.1:4416)
#   - the PO-Token yt-dlp plugin (without it yt-dlp ignores bgutil-pot)
#   - qjs           (QuickJS: the JS runtime yt-dlp solves challenges in)
#
# None is bundled in the repo — all are pulled from their own releases, which
# is also how you "hot plug" updates later: just re-run this script whenever
# yt-dlp breaks against a new YouTube change.
#
# This is the by-hand equivalent of the in-app installer, which additionally
# pins every download to a SHA-256 in a signed manifest. This script does not;
# prefer the app's Settings button unless you are debugging.
#
# Usage: ./download-helpers.sh

set -euo pipefail

DEST_DIR="$HOME/Library/Application Support/Convoy/bin"
mkdir -p "$DEST_DIR"

ARCH="$(uname -m)"
echo "Detected architecture: $ARCH"

echo ""
echo "== yt-dlp =========================================================="
YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
curl -L --fail --progress-bar -o "$DEST_DIR/yt-dlp" "$YTDLP_URL"
chmod +x "$DEST_DIR/yt-dlp"
echo "Installed: $DEST_DIR/yt-dlp"
"$DEST_DIR/yt-dlp" --version

echo ""
echo "== bgutil-pot (PO-Token provider) =================================="
if [ "$ARCH" = "arm64" ]; then
  POT_ASSET="bgutil-pot-macos-aarch64"
else
  POT_ASSET="bgutil-pot-macos-x86_64"
fi
POT_URL="https://github.com/jim60105/bgutil-ytdlp-pot-provider-rs/releases/latest/download/${POT_ASSET}"
if curl -L --fail --progress-bar -o "$DEST_DIR/bgutil-pot" "$POT_URL"; then
  chmod +x "$DEST_DIR/bgutil-pot"
  echo "Installed: $DEST_DIR/bgutil-pot"
else
  echo "WARNING: couldn't fetch a prebuilt bgutil-pot asset for this arch."
  echo "Check the release page for the current asset name and adjust POT_ASSET above:"
  echo "https://github.com/jim60105/bgutil-ytdlp-pot-provider-rs/releases/latest"
fi

echo ""
echo "== bgutil-pot's yt-dlp plugin (separate from the server above!) ===="
# The bgutil-pot binary above is just the token server — yt-dlp has no idea
# it exists until this plugin is installed too. Without it, yt-dlp silently
# ignores the PO-Token provider, YouTube hides its real formats, and
# downloads fall back to old, heavily throttled ones (e.g. format 18).
POT_PLUGIN_URL="https://github.com/jim60105/bgutil-ytdlp-pot-provider-rs/releases/latest/download/bgutil-ytdlp-pot-provider-rs.zip"
POT_PLUGIN_TMP="$(mktemp -d)"
if curl -L --fail --progress-bar -o "$POT_PLUGIN_TMP/plugin.zip" "$POT_PLUGIN_URL"; then
  unzip -o -q "$POT_PLUGIN_TMP/plugin.zip" -d "$POT_PLUGIN_TMP"
  mkdir -p "$DEST_DIR/yt-dlp-plugins"
  if [ -d "$POT_PLUGIN_TMP/yt_dlp_plugins" ]; then
    rm -rf "$DEST_DIR/yt-dlp-plugins/bgutil-ytdlp-pot-provider"
    mkdir -p "$DEST_DIR/yt-dlp-plugins/bgutil-ytdlp-pot-provider"
    cp -R "$POT_PLUGIN_TMP/." "$DEST_DIR/yt-dlp-plugins/bgutil-ytdlp-pot-provider/"
  else
    # zip already contains its own top-level package folder
    rm -rf "$DEST_DIR/yt-dlp-plugins/bgutil-ytdlp-pot-provider"
    PKG_DIR="$(find "$POT_PLUGIN_TMP" -maxdepth 2 -type d -name yt_dlp_plugins -exec dirname {} \; | head -1)"
    if [ -n "$PKG_DIR" ]; then
      cp -R "$PKG_DIR" "$DEST_DIR/yt-dlp-plugins/bgutil-ytdlp-pot-provider"
    fi
  fi
  if [ -d "$DEST_DIR/yt-dlp-plugins/bgutil-ytdlp-pot-provider/yt_dlp_plugins" ]; then
    echo "Installed: $DEST_DIR/yt-dlp-plugins/bgutil-ytdlp-pot-provider"
  else
    echo "WARNING: plugin zip didn't have the expected layout — install manually, see:"
    echo "https://github.com/jim60105/bgutil-ytdlp-pot-provider-rs#step-2-install-the-yt-dlp-plugin"
  fi
else
  echo "WARNING: couldn't fetch the PO-Token yt-dlp plugin."
  echo "Check the release page: https://github.com/jim60105/bgutil-ytdlp-pot-provider-rs/releases/latest"
fi
rm -rf "$POT_PLUGIN_TMP"

echo ""
echo "== quickjs (JS runtime, for YouTube's challenge scripts) =========="
# yt-dlp runs its EJS challenge-solver scripts in a real JS runtime. It
# accepts deno, node, bun or quickjs and treats them as equivalent challenge
# providers, so this pulls the smallest by a wide margin: ~1.2 MB against
# Deno's ~77 MB installed. Without any runtime yt-dlp still resolves most
# videos, but warns that extraction is deprecated and some formats may be
# missing. See https://github.com/yt-dlp/yt-dlp/wiki/EJS
#
# Convoy runs yt-dlp with --no-js-runtimes before naming this one, so
# it is the runtime used even on a Mac that has Deno or Node installed --
# yt-dlp would otherwise prefer a PATH deno over the one named on the command
# line, and "which runtime ran" would depend on the user's machine.
if [ "$ARCH" = "arm64" ]; then
  QJS_ASSET="qjs-darwin-arm64"
else
  QJS_ASSET="qjs-darwin-x86_64"
fi
QJS_URL="https://github.com/quickjs-ng/quickjs/releases/latest/download/${QJS_ASSET}"
if curl -L --fail --progress-bar -o "$DEST_DIR/qjs" "$QJS_URL"; then
  chmod +x "$DEST_DIR/qjs"
  xattr -d com.apple.quarantine "$DEST_DIR/qjs" 2>/dev/null || true
  echo "Installed: $DEST_DIR/qjs"
  "$DEST_DIR/qjs" --help 2>&1 | head -1
else
  echo "WARNING: couldn't fetch quickjs. yt-dlp will warn that some formats may be missing."
  echo "Check the release page and adjust QJS_ASSET above if needed:"
  echo "https://github.com/quickjs-ng/quickjs/releases/latest"
fi

echo ""
echo "Done. Binaries live in: $DEST_DIR"
echo "Convoy looks for them there automatically — no further setup needed."
