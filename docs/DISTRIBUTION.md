# Distribution

pseudocopy is a command-line tool, not an app bundle. That shapes how it
should be shipped.

## Channels

| Channel | Status | How |
|---|---|---|
| Homebrew tap | **recommended** | `brew install BitPeppr/tap/pseudocopy` + `brew services start pseudocopy` |
| GitHub release tarball | available | universal binary + LICENSE + README, checksummed |
| Source checkout | available | `git clone` + `Scripts/install.sh` |
| DMG | not used | a CLI has nothing to drag to *Applications*; see below |
| Mac App Store | no | the App Sandbox forbids a LaunchAgent, arbitrary folder access and clipboard writes |

## Why Homebrew first

- **Upgrades are solved.** `brew upgrade` replaces the binary; `brew services`
  regenerates the LaunchAgent so it keeps pointing at the current instalment.
  A hand-copied `~/bin` binary has to be updated by re-running `install.sh`.
- **No Gatekeeper problem.** Homebrew downloads over `curl`, so the archive
  never gets the quarantine attribute. The binary is ad-hoc signed, and
  macOS runs it normally when it was not downloaded by a browser.
- **The service fits the design.** The formula's `service` block emits
  `StartInterval 5` plus `ThrottleInterval 5`, which is exactly what the
  built-in `pseudocopy install` writes: one short-lived cycle every five
  seconds, no resident daemon.

## Why not a DMG

A DMG is a delivery format for `.app` bundles: mount, drag to *Applications*,
eject. pseudocopy is a single executable that has to end up on `PATH` and be
registered with `launchd`; a DMG adds a mount/copy step without removing any
of that work. It would also raise the expectation that the tool can be
double-clicked.

Gatekeeper makes the DMG actively worse today: this project has no Developer
ID certificate, so the binary is only **ad-hoc signed**. A file downloaded
through a browser is quarantined, and the first launch is blocked with
*"Apple could not verify … is free of malware"*. Homebrew and `curl` avoid
that path; a DMG does not.

A DMG becomes reasonable only together with a signed, notarised `.pkg`
inside it (see below). Until then it is an extra step that makes the install
worse, not better.

## If a signed installer is wanted later

1. Join the Apple Developer Program and create a **Developer ID Application**
   certificate (~$99/year).
2. Sign the release binary with the hardened runtime:
   `codesign --force --options runtime --timestamp --sign "Developer ID Application: …" pseudocopy`
3. Build a payload-free installer that drops the binary into `/usr/local/bin`
   (`pkgbuild` + `productbuild`), sign it with a **Developer ID Installer**
   certificate.
4. Notarise and staple:
   `xcrun notarytool submit pseudocopy.pkg --wait` then
   `xcrun stapler staple pseudocopy.pkg`.
5. Optionally wrap the `.pkg` in a DMG. At that point a Homebrew **cask**
   pointing at the notarised `.pkg` becomes an option as well.

None of this is required for the Homebrew tap or for `curl` downloads; it
only removes the “right-click → Open” step for browser downloads.

## The tap

The formula lives in a separate repository so that users only download the
formula, not the source tree:

```
BitPeppr/homebrew-tap
└── Formula/pseudocopy.rb
```

`Scripts/release.sh` renders the formula from
`Distribution/homebrew/pseudocopy.rb.template` into `dist/pseudocopy.rb`,
with the version and the SHA-256 of the published tarball already filled in.

## Release checklist

1. Bump `Constants.version` in `Sources/pseudocopy/constants.swift` and add a
   `CHANGELOG.md` entry.
2. Commit everything (`Scripts/release.sh` refuses a dirty tree).
3. Run `Scripts/release.sh`. It builds arm64 and x86_64, `lipo`s them into a
   universal binary, verifies it, writes
   `dist/pseudocopy-<version>-macos-universal.tar.gz` plus its `.sha256`,
   tags `v<version>`, pushes, and creates the GitHub release.
4. Copy `dist/pseudocopy.rb` to `Formula/pseudocopy.rb` in
   `BitPeppr/homebrew-tap`, commit and push.
5. `brew update && brew upgrade pseudocopy` to verify the tap.

The script needs a full Xcode installation (the x86_64 SDK) and an
authenticated `gh` CLI.

## Homebrew core

The tap is the right home for now. A `homebrew-core` submission needs a
stable release history, a meaningful test, a licence (MIT here) and bottles
built by BrewTestBot; it can be proposed once the tool has some users.
