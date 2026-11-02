# Releasing Convoy

A release has two halves. The first is scripted and entirely local. The second
puts things on the internet and is **not scripted yet**.

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
| 2 | `extension` | A stale signed `.xpi` (the source changed after signing). If there is no signed package for this version it signs one, after asking. This is the only step that cannot be undone. |
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

## 2. Publish (by hand for now)

Order matters. The appcast is what makes installed copies update, so it goes
**last**: an appcast that points at a missing file breaks every update check.

1. Push `main` and the tag.
2. Create the GitHub release with `Convoy-X.dmg`, `.dmg.sha256`, `Convoy-X.pkg`,
   `.pkg.sha256`, `Convoy-X.zip`, plus the new `convoy-<ext version>.xpi` if the
   extension was signed this time.
3. Download the uploaded files and compare their SHA-256 with the local ones.
4. Pages repo: copy in `.build/ship-pages/convoy/appcast.xml`; add the extension
   to `convoy/firefox-updates.json` if it was signed this time; update
   `convoy/latest.json` (what the website's download buttons read). Commit and
   push the Pages repo only now, and only those files: anything else half-edited
   in that clone would go live too.
5. Fetch the live appcast and check it shows the new version.

This is the next piece to script. It will be the same shape as `ship.sh`: small
steps, each checking its own precondition, with the appcast last.

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
