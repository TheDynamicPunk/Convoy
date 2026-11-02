# Releasing Convoy

A release has two halves. The first is scripted and entirely local. The second
puts things on the internet: three scripted commands with one manual step (the
GitHub release, made in the browser) in the middle.

## 1. Prepare (scripted, local, safe to repeat)

```
./ship.sh v1.2.0            # all five steps, stopping at the first failure
./ship.sh v1.2.0 verify     # or one step on its own
```

Before you run it:

- Commit everything. `main` must be clean.
- **If anything under `Extensions/` changed since the last release, bump
  `"version"` in `Extensions/Chromium/manifest.json` and commit.** AMO signs a
  version number once; step 2 refuses to continue if the signed package no
  longer matches the source.
- For a release where the extension changed: `AMO_JWT_ISSUER` and
  `AMO_JWT_SECRET` set, and Node installed (`npx`).
- The Pages clone of `thedynamicpunk.github.io` next to this repo (or set
  `CONVOY_PAGES_DIR`).
- The Sparkle private key in the login Keychain. Expect a few Keychain prompts.

What each step does, and why it is there:

| # | Step | Protects against |
|---|------|------------------|
| 1 | `checks` | On `main`, clean tree, not behind origin; tag free and newer than the last; build number above the appcast's (Sparkle compares it); toolchain; Sparkle key matches the Keychain; `swift test`. All cheap, and all before anything irreversible. |
| 2 | `extension` | A stale signed `.xpi` (the source changed after signing). The signed package is compared with what the source builds: `manifest.json` as data (signing re-lays it out with the same content, so a byte comparison always fails), every other file byte for byte. If there is no signed package for this version it signs one, after asking. This is the only step that cannot be undone. |
| 3 | `tag` | `release.sh` builds from the tag at HEAD. The tag stays local. |
| 4 | `build` | Runs `release.sh` unchanged: universal build, gates, DMG, pkg, update zip, appcast item. The appcast is written to a scratch copy under `.build/ship-pages/`, so the real Pages clone is never touched and a rerun never leaves a mess. |
| 5 | `verify` | What `release.sh` does not check: the app inside the update **zip** passes every gate (the DMG and pkg are checked, the zip is not, and every installed copy updates from the zip), and the appcast item points at the right file, has the right length and build number, has no hardware restriction, and its EdDSA signature verifies. |

It ends with "Nothing has been pushed or published." To abandon a release:
`git tag -d vX.Y.Z`.

## Extension: when to bump, and how signing works

Firefox only installs extensions Mozilla has signed, and Mozilla signs each
version number **once**. So any change under `Extensions/` needs a new version
before a release, or `ship.sh` step 2 stops with "STALE". (Precedent: 1.0.1 was
used up at Mozilla, and the 1.0.3 bump was for the same reason as 1.0.4.)

### Bump the version

The only place is `"version"` in `Extensions/Chromium/manifest.json`. The
Firefox manifest takes it from there through a placeholder. Commit it on its
own, in this style:

```
git add Extensions/Chromium/manifest.json
git commit -m "Bump the extension to 1.0.4" -m "The signed 1.0.3 package was made before <what changed>.
AMO signs a version number once, so a changed build needs a new one."
```

Keep the bump the last thing that touches `Extensions/` before the release. If
the extension changes again after signing, bump again.

### One-time: AMO API credentials

1. Sign in at addons.mozilla.org with the account that owns the Convoy add-on.
2. Developer Hub > Tools > Manage API Keys
   (`https://addons.mozilla.org/developers/addon/api/key/`).
3. Generate credentials. You get two values:
   - **JWT issuer**, looks like `user:12345:67` (this is `AMO_JWT_ISSUER`)
   - **JWT secret**, 64 hex characters (this is `AMO_JWT_SECRET`)
   Copy both now. If the secret is lost, generate a new pair; that replaces the
   old one.
4. Keep them out of the repo and out of your shell history. The project already
   keeps private material under `~/.config/convoy/`, so put them there:

```
mkdir -p ~/.config/convoy
touch ~/.config/convoy/amo.env && chmod 600 ~/.config/convoy/amo.env
open -e ~/.config/convoy/amo.env        # paste the two lines below, save, close
```

```
export AMO_JWT_ISSUER='user:12345:67'
export AMO_JWT_SECRET='<the 64 hex characters>'
```

Anyone with the secret can submit versions as you. If it leaks, regenerate it.

### Each time you need to sign

```
source ~/.config/convoy/amo.env         # once per Terminal window
npx --version                           # Node must be installed: brew install node
./Extensions/build-firefox.sh --lint    # free check, signs nothing
./ship.sh vX.Y.Z checks                 # make sure nothing else will fail first
./ship.sh vX.Y.Z extension              # asks, then signs
```

The signed package lands in `Extensions/Firefox/dist/convoy-<version>.xpi`. That
folder is gitignored: keep the file, the app build bundles it. A later
`./ship.sh vX.Y.Z extension` run compares it with the source and says "matches".

If signing fails part way (a network error, a lint error), check whether
Mozilla used the version up before retrying. If it did, bump to the next
number, as happened with 1.0.1.

## 2. Publish

Run these in order, one at a time. Don't commit anything between the prepare
half and the end of this one: the tag must still point at what was built (`push`
refuses if it doesn't).

| # | Command | What it does |
|---|---------|--------------|
| 6 | `./ship.sh vX.Y.Z push` | Re-verifies the built files, asks, then pushes `main` and the tag. Writes a draft of the release notes (commit subjects plus checksums) to `.build/dist/release-notes.md` and prints the link and the exact files to attach. |
| | **You, in the browser** | Create the release for the tag: title `Convoy X.Y.Z`, notes from the draft, attach exactly the listed files (do not rebuild them), publish as a normal release (not a draft, not a pre-release). |
| 7 | `./ship.sh vX.Y.Z pages` | Refuses unless the tag is on origin and every file on the release is byte for byte the one that was built. Then writes the appcast, `convoy/latest.json` (what the website's download buttons read) and, when the extension is new, its entry in `convoy/firefox-updates.json`; shows what it will commit and what it leaves alone; asks; commits and pushes the Pages repo. **This is the moment installed copies learn about the update.** |
| 8 | `./ship.sh vX.Y.Z live` | Waits for GitHub Pages (up to 3 minutes per file) and checks the live appcast, `latest.json` and update list are exactly what was pushed. |

A release is **5 files**, or **6** when the extension is new: `Convoy-X.dmg`,
`.dmg.sha256`, `Convoy-X.pkg`, `.pkg.sha256`, `Convoy-X.zip` (the one Sparkle
downloads), and the signed `convoy-<extension version>.xpi` (used only for
Firefox auto-updates). `push` prints the list; nobody counts.

Other things in the Pages clone are never swept in: only the three generated
files are committed. If the website's wording changes with this release, edit
`index.html` in the Pages clone first and run `pages` as
`CONVOY_PAGES_EXTRA=index.html ./ship.sh vX.Y.Z pages`, so it goes live in the
same push. The fallback text in `index.html` (shown with JavaScript off) is still
edited by hand.

Order matters because the appcast is what makes installed copies update, so it
goes **last**: an appcast pointing at a missing file breaks every update check.

**After `live`:** keep an older install (1.1.0) around and use Convoy > Check for
Updates on it. No script can watch a real copy update itself.

### If something stops

Every step is safe to rerun.
- `push` or `pages` refuses: read the message; nothing public has changed.
- `pages` pushed but `live` fails: the files are pushed and Pages is probably
  still publishing; rerun `live` in a minute.
- Wrong file on the release: delete it there, attach the one `pages` names, rerun
  `pages`.
- To abandon before `push`: `git tag -d vX.Y.Z`.

## Not automated, on purpose

- **GitHub Actions.** It would put the Sparkle private key in GitHub secrets.
  Whoever holds that key can ship code to every installed copy, and the public
  key inside shipped apps cannot be rotated. The build also needs the newest
  macOS SDK. If this is revisited, a hybrid keeps the key on this Mac: CI builds
  and verifies into a draft release; a local step signs the zip and writes the
  appcast.
- **Notarization.** There is no Developer ID. When there is one: swap the
  identity in `build.sh` and insert `notarytool submit --wait` and
  `stapler staple` between the gates and the DMG in `release.sh`.
