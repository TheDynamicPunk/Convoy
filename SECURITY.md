# Security policy

## Reporting a vulnerability

Please report security problems **privately**, not in a public issue.

Use GitHub's private reporting: on the
[repository's Security tab](https://github.com/TheDynamicPunk/Convoy/security),
choose **Report a vulnerability**. Include the Convoy version (Convoy → About
Convoy), your macOS version, and steps to reproduce.

You'll get an acknowledgement as soon as I can manage it. Convoy is maintained by
one person, so please allow a few days, and I'll tell you what I decide to do and
roughly when. I'm happy to credit you in the release notes unless you'd rather
not be named.

## What counts

Convoy runs unsandboxed, talks to browsers, and installs and runs helper
programs, so the areas that matter most are:

- The app ↔ browser connection (the native messaging host and its local socket).
- The updater: Sparkle's signed updates and the appcast.
- Verification and installation of the helpers (the YouTube tools and the
  BitTorrent client).
- The BitTorrent helper's control connection. rqbit listens for Convoy on the
  loopback address only, on a random port, and requires a random password made
  for each launch. It also accepts incoming peer connections from the internet
  on a separate port.
- Anything that makes Convoy write, run or send something the user didn't ask for.

Problems in the sites Convoy downloads from, or in yt-dlp, rqbit and the other
helpers themselves, belong with those projects.

## Supported versions

Only the latest release gets security fixes. Convoy updates itself, so most
people are on it already.

## Verifying a download

Each release lists SHA-256 checksums, and every file has a `.sha256` beside it.
Convoy isn't notarized by Apple, so these checksums, and downloading only from the
[releases page](https://github.com/TheDynamicPunk/Convoy/releases), are how to
tell a genuine copy from a tampered one.
