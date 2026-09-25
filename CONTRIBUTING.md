# Contributing to Convoy

Thanks for taking an interest. Bug reports and small, focused patches are
welcome.

## Licensing of contributions — please read before sending a patch

Convoy is released under the **GNU General Public License v3.0 or
later** (see [LICENSE](LICENSE)). Contributions are accepted on these terms:

1. Your contribution is licensed under **GPL-3.0-or-later**, like the rest of
   the project.
2. You also grant the maintainer a **perpetual, worldwide, non-exclusive,
   irrevocable, royalty-free right to use, modify and distribute your
   contribution under other licence terms**, including commercial ones.
3. You confirm you wrote the contribution, or otherwise have the right to
   submit it under these terms.

Point 2 exists for one practical reason: it keeps open the option of selling
ready-built, signed copies, or listing the app on a subscription service, to
fund upkeep. Without it, a single contribution would close that option
permanently. The source stays under the GPL either way, and nothing you
contribute stops being free software.

**You keep the copyright in your own work.** This is a licence grant, not an
assignment — you may use your own contribution however you like, elsewhere.

To accept the terms, include this line in the pull request description:

```
I agree to the contribution terms in CONTRIBUTING.md.
```

A `Signed-off-by:` line (`git commit -s`) is welcome as a statement of
authorship, but on its own it does not grant point 2, so the sentence above is
what matters.

## Name, icon and branding

The GPL covers the code. It does **not** license the project's name or icon,
and no trademark rights are granted (as permitted by GPLv3 section 7(e)). A
fork or rebuild you distribute must carry its own name and icon and must not
suggest it comes from this project.

## How the app is described

Please keep user-facing text, issue titles and commit messages describing what
the app does — a download manager — rather than encouraging people to take
content they have no right to. This isn't squeamishness: in US law a tool's
distributor can become liable for how it is *promoted*, so the wording is part
of keeping the project safe to work on.

## Building and testing

```bash
./build.sh                                     # assembles Convoy.app
./verify-bundle.sh .build/release/Convoy.app   # signing and layout checks
swift test                                     # unit tests
```

One test failure is currently expected: the checked-in helper list is
unsigned, so `testTheCommittedManifestVerifiesAgainstTheCompiledInKey` fails.
Everything else should pass before you send a patch.

### Toolchain

`./verify-toolchain.sh` checks three things, and `build.sh` runs it first. Run
it directly when a build fails in files you haven't touched — all three fail
that way.

**1. Xcode isn't selected.** Installing Xcode.app doesn't select it;
`xcode-select` keeps pointing at the Command Line Tools until told otherwise.
The symptom is *"external macro implementation type
'SwiftUIMacros.StateMacro' could not be found"* on every `@State`.

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

**2. Something is shadowing the toolchain.** [swiftly](https://www.swift.org/swiftly/),
if installed, puts its own toolchain first on `PATH`; the symptom is `unknown
argument: '-target-arch-variant'` and a compiler crash. A swift.org toolchain
can't build this app at all, since it has no SwiftUI, AVFoundation or
Security.framework. `.swift-version` pins the toolchain to `xcode` so swiftly
defers, and must contain that single word with no comment. `build.sh` and
`release.sh` change into the repo root first, because that file is resolved
from the current directory rather than from `--package-path`.

**3. Anything else.** The check compiles a small SwiftUI view, so if 1 and 2
pass and it still fails, something new has happened.

**SDKs.** Build against the newest SDK Xcode provides; that's unrelated to the
macOS versions supported, which comes from `platforms: [.macOS(.v14)]` in
`Package.swift`. Don't pin an older SDK to work around point 1. `build.sh`
records the SDK in the binary via `-Xlinker -platform_version`: SwiftPM
otherwise writes the deployment target into both the `minos` and `sdk` fields,
and macOS reads `sdk` to decide which control appearance the app gets, so
reporting 14 renders the whole app in the pre-26 design.

## House rules

- **Don't bundle the helper binaries.** yt-dlp, the JavaScript runtime and the
  bot-check helper are downloaded at runtime and verified against a checksum
  list. Shipping them inside the app would change the project's licensing and
  legal position.
- **The browser extension (`Extensions/Chromium/`) is a Chromium extension.**
  Safari is not supported and isn't planned.
- **Match the surrounding code**: the same comment density, naming and
  structure as the file you're editing. Comments explain *why*, not *what*.
- **Tests belong with behaviour changes**, in `Tests/DownloadEngineTests`.
- **User-facing text is plain English** — no jargon, no internal component
  names in the interface.

## Reporting a bug

Include the macOS version, the app version (Settings → Advanced → About), the
site or link if relevant, and what you expected versus what happened. For
browser integration problems, Settings → Browser shows the connection state.
