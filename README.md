# Convoy

Convoy is a native macOS download manager written in Swift and SwiftUI, with a
browser extension that hands downloads to the app. Free software under the GPL.

<img width="1000" height="566" alt="Convoy taking a download from Chrome, pausing and resuming it, and grabbing a video from a web page, with both downloads running in parallel parts" src="https://github.com/user-attachments/assets/414ce46a-afd3-453f-8ff4-a903990e8fd5" />

**[Download the latest release](https://github.com/TheDynamicPunk/Convoy/releases/latest)**,
as an installer package or a disk image. Convoy isn't notarized by Apple, so
macOS asks you to approve it once — see [Installing](#installing).

## Features

- **Segmented downloads** — each file is fetched over several connections at
  once (1–16, configurable), with a single-connection fallback for servers
  that don't support ranges.
- **Pause and resume**, including across quitting and reopening the app.
- **Browser integration** for Chromium browsers (Chrome, Brave, Edge, Vivaldi,
  Opera, Arc, Chromium): intercepts downloads, adds right-click items for
  links, images and media, and shows a download button over videos it finds on
  a page. Sends the page's cookies and headers so downloads behind a login
  work; incognito windows keep their own cookies.
- **Video streams** — HLS and DASH, including streams whose video and audio
  come separately, merged afterwards with AVFoundation.
- **YouTube** through yt-dlp, which the app installs on request from
  Settings → YouTube. Newer versions of it arrive with Convoy updates.
- **Updates itself** — checks once a day and asks before installing.
- **Queue** — filter by status (downloading, completed, paused, failed) and
  search.
- **Menu bar item** — active downloads at a glance, with Pause All and Resume
  All.
- **Notifications** when downloads finish, with an optional sound.
- **Storage cleanup** — finds what interrupted downloads left behind and
  clears it when you ask (Settings → Advanced).
- **Light, dark or system appearance.**

Not supported: Safari (Apple's extension route needs a paid certificate) and
Firefox (needs its own build of the extension). The Mac App Store doesn't
allow apps in this category.

## Requirements

macOS 14 (Sonoma) or later, on Apple silicon or Intel.

## Installing

Each [release](https://github.com/TheDynamicPunk/Convoy/releases) comes with
two installers holding the same app. Use whichever you prefer:

- **`Convoy-<version>.pkg`**, an installer package. It installs Convoy in
  Applications and asks for an administrator password.
- **`Convoy-<version>.dmg`**, a disk image. Open it and drag Convoy onto
  Applications.

Convoy isn't notarized (that needs a paid Apple developer account), so the
first time you open the package, or the app from the disk image, macOS says it
can't verify it. To allow it:

1. Close that message.
2. Open **System Settings → Privacy & Security**, scroll down to the line
   about Convoy, and click **Open Anyway**.
3. Confirm, and enter your password when asked.

You do this once. With the package you approve the installer, and the app it
installs then opens without asking.

Each file has a `.sha256` checksum beside it. To check a download arrived
intact, put both in one folder and run, with your file's name:

```bash
shasum -a 256 -c Convoy-1.0.0.pkg.sha256
```

## Updating

Convoy checks for updates once a day and asks before installing one. To check
now, choose **Convoy → Check for Updates…**. Settings → General turns the
daily check off. Updates are signed, and Convoy installs only ones signed with
this project's key.

## Setting up the browser extension

On first launch the app asks which installed browsers to set up, and then
shows how to load the extension. Settings → Browser does the same later, and
can remove the setup again before you delete the app.

Loading it, once per browser:

1. Open the browser's extensions page (`chrome://extensions`) and turn on
   Developer mode.
2. Drag `~/Library/Application Support/Convoy/Extension` onto that page, or
   click **Load unpacked** and choose it. Settings → Browser has a button
   that opens the folder.

The app keeps that copy of the extension up to date, and browsers pick up
changes when they restart.

## Building from source

Building needs Xcode installed *and selected* as the active developer
directory. SwiftUI's property wrappers are macros that only Xcode ships, and
`swift test` needs XCTest from it.

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

`./build.sh` checks this first and prints the fix if it's wrong. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the rest of the toolchain notes.

```bash
git clone https://github.com/TheDynamicPunk/Convoy.git
cd Convoy
./build.sh
```

That produces `.build/release/Convoy.app`. `swift build -c release`
builds the binaries alone, without assembling or signing the bundle.
`./verify-bundle.sh .build/release/Convoy.app` checks the result,
including a real conversation with the native messaging host.

To install it, copy the app to `/Applications` with Finder. To package it
like a release, run `./make-pkg.sh` for the installer package or
`./make-dmg.sh` for the disk image; the disk image also needs Python 3.10 or
later.

## How browser integration works

1. The extension (a Chromium extension) captures a download, a right-click, or
   a video found on the page, and collects the URL, referrer, cookies and
   headers.
2. It sends that to `NativeMessagingHost`, a small binary inside the app
   bundle that the browser launches.
3. The host forwards it to the running app over a local Unix socket. Both ends
   check that the other really is this app's binary before exchanging
   anything.
4. The app starts the download and brings its window forward.

The app registers the host with each browser itself, by writing a small file
into that browser's own folder, and repoints those files if the app is moved.

## Architecture

```
Convoy/
├── Sources/
│   ├── Convoy/                 # SwiftUI app: windows, settings, menu bar
│   ├── DownloadEngine/         # Downloading, streams, muxing, helpers
│   ├── IPCKit/                 # Unix-socket IPC shared by app and host
│   ├── NativeMessagingHost/    # Browser ↔ app bridge
│   └── HelperManifestTool/     # Maintainer tool: builds the helper list
├── Extensions/
│   └── Chromium/               # The browser extension
└── Resources/                  # Info.plist, icons, helper list
```

## Download engine

`DownloadEngine` is a library target, usable on its own:

```swift
let task = try await DownloadManager.shared.addDownload(
    url: URL(string: "https://example.com/file.zip")!,
    segmentCount: 8
)

await DownloadManager.shared.pauseDownload(task)
try await DownloadManager.shared.resumeDownload(task)
```

## Reading the logs

Each download logs its milestones (started, merging, finished, stopped) at the
`notice` level, which macOS keeps for several days, and real failures at
`error`. To see the last hour:

```bash
/usr/bin/log show --last 1h --predicate 'subsystem == "Convoy"'
```

Or filter on `Convoy` in Console. Use the full `/usr/bin/log` path: in
zsh, a bare `log` is a shell built-in and fails with "too many arguments".

URLs, file names and video titles appear as `<private>`. Download IDs
(`task=<id>`), format IDs and status codes stay readable, so every line for one
download can be found by its `task=` value.

## Contributing

Bug reports and focused patches are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) — it covers building and testing, the house
rules, and the two licensing terms every contribution is accepted under.

## Trademarks and attribution

"Convoy", its icon and its branding are not covered by the GPL, and no
trademark rights are granted with the code (GPLv3 section 7(e)). If you
distribute a modified build, give it your own name and icon.

Apple, Mac and macOS are trademarks of Apple Inc. Convoy is not affiliated
with, endorsed by, or sponsored by Apple, Google, YouTube, or any other site it
can download from.

## Using it responsibly

Convoy is a general-purpose download manager. You are responsible for
complying with the terms of the sites you use it with, and with copyright law
where you live. Download things you have the right to download.

## License

Copyright (C) 2026 Ashutosh Gupta.

Convoy is free software: you can redistribute it and/or modify it under
the terms of the **GNU General Public License, version 3 or (at your option)
any later version** — see [LICENSE](LICENSE).

It is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
A PARTICULAR PURPOSE. See the GNU General Public License for more details.

The helper programs Convoy downloads at runtime — yt-dlp, the QuickJS
JavaScript runtime and the bot-check provider — are separate works under their
own licences and are not distributed with this app.

## Acknowledgments

- Inspired by Internet Download Manager (IDM)
- YouTube support stands on [yt-dlp](https://github.com/yt-dlp/yt-dlp)
- Built with Swift, SwiftUI and Swift Concurrency
