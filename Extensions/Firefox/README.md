# Firefox build

The Firefox extension is not a second codebase. `build-firefox.sh` lays this
folder over `Extensions/Chromium`: this folder's `manifest.json` replaces the
Chromium one, and `Background/firefox-compat.js` is added. The version comes
from the Chromium manifest, so there is one number to bump.

`firefox-compat.js` fills the two gaps in Firefox's `chrome` namespace that
`background.js` hits: `downloads.onDeterminingFilename` (re-fired from
`downloads.onCreated`) and notification buttons. Anything else browser-specific
goes there or behind a feature check, not in a copy of a shared file.

```bash
./Extensions/build-firefox.sh .build/firefox     # assemble
./Extensions/build-firefox.sh --lint             # assemble + web-ext lint
```

Load it for development: `about:debugging#/runtime/this-firefox` > Load
Temporary Add-on > `manifest.json` from the assembled folder.

## Signing and shipping

Release Firefox runs only extensions Mozilla has signed. Self-distribution
(AMO "unlisted") signs automatically, with no review queue.

1. Create API keys at addons.mozilla.org > Developer Hub > API keys.
2. Tag the commit, then sign, pointing at a clone of the Pages repo:
   `AMO_JWT_ISSUER=... AMO_JWT_SECRET=... CONVOY_PAGES_DIR=<clone of thedynamicpunk.github.io> ./Extensions/build-firefox.sh --sign`
3. The signed `convoy-<version>.xpi` lands in `Extensions/Firefox/dist/`
   (gitignored). `build.sh` bundles it as `Convoy.xpi` only if its version
   matches the extension; the app then offers **Add to Firefox**.
4. The same step adds the version to `convoy/firefox-updates.json` in the Pages
   clone, next to `appcast.xml`. Upload the `.xpi` to the tag's GitHub release
   first, then commit and push the Pages repo, as with the appcast.

AMO signs a version once. Bump `version` in `Extensions/Chromium/manifest.json`
before signing a changed build.

## Decide before the first signed release

- **Extension ID** (`convoy@thedynamicpunk.github.io`) is permanent once signed.
  It must match `BrowserIntegration.firefoxExtensionID`; a test checks this.
- **`update_url`** points at `thedynamicpunk.github.io/convoy/firefox-updates.json`,
  hosted beside the Sparkle appcast. `--sign` with `CONVOY_PAGES_DIR` writes
  it. An installed copy keeps the URL it shipped with, so that URL must keep
  working. A list entry whose `.xpi` isn't uploaded makes update checks fail.
  A listed AMO build must not carry the key.
- **`data_collection_permissions`** declares `browsingActivity` and
  `websiteContent`. Mozilla counts data handed to anything outside the add-on
  or the browser, which includes the native app, so `none` would be inaccurate
  even though nothing leaves the Mac.

## Known gaps

- Firefox has no hold point before its own prompt. With "Always ask where to
  save files" on, the user sees Firefox's dialog first, then Convoy takes over.
- `fileSize` is unknown when the download is created, so the Re-link size
  check has nothing to compare for Firefox downloads.
- Cookies come from the default store. Container tabs (and Zen workspaces tied
  to a container) will download without their login cookies.
- Private windows need the user to allow the extension there.
