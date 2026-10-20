# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [semantic versioning](https://semver.org/).

## [1.0.1] — 2026-10-20

### Fixed

- `status` and `kick` now find the agent when it is managed by
  `brew services` (Homebrew 5 uses `sh.brew.pseudocopy`; older versions use
  `homebrew.mxcl.pseudocopy`) instead of only looking for the label written
  by `pseudocopy install`.
- `install` refuses to register a second agent while a Homebrew-managed
  service is running, and `uninstall` no longer claims to have removed it.

## [1.0.0] — 2026-10-20

First release.

### Added

- Watch one folder (`~/Temp` by default) from a `launchd` LaunchAgent that
  runs a cycle every five seconds.
- Smart clipboard payloads: UTF-8 text, images, PDFs, and a file reference
  plus embedded bytes (up to 64 MB) for everything else.
- Settle detection based on a `(size, mtime)` fingerprint seen twice in a
  row, so a download is never copied half-written.
- Reaper that moves files older than the TTL (one hour by default) to the
  Trash, and copies them to the clipboard first.
- State store in `~/Library/Application Support/pseudocopy/state.json`, one
  namespace per watch folder, written atomically, `0600`, and only when
  something changed.
- `flock`-based cycle lock that the kernel releases when a process dies.
- Watch folders, TTL and permanent deletion configured through
  `pseudocopy install`, or the global flags `--dir`, `--ttl` and `--no-trash`.
- Commands: `run`, `loop`, `clean`, `clip`, `gen-tests`, `install`,
  `uninstall`, `status`, `kick`, `version`, `help`.
- `Scripts/install.sh` for a self-contained install into `~/bin`.
- `Scripts/smoke.sh`, a headless end-to-end test in a private sandbox.
- Universal release binary (arm64 + x86_64).
