# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [semantic versioning](https://semver.org/).

## [1.0.2] — 2026-10-20

### Fixed

- A file whose clip failed is no longer reaped. It stays in the folder and the
  clip is retried, so an unreadable or busy file cannot be deleted before its
  content reaches the clipboard.
- A watch folder that is unavailable (for example an unmounted external
  volume) no longer wipes its state namespace. The cycle is skipped and the
  history is kept, so remounting does not re-clip every file.
- Files that settle together in one cycle are written to the pasteboard in a
  single transaction instead of one clear-and-write per file. The last file in
  a burst no longer wins by accident, and a multi-file batch carries file
  references to all of them.
- A single text, image or PDF clip no longer also advertises a file reference.
  This matches PLAN §2.2 and stops apps that prefer `public.file-url` from
  pasting a file object instead of the content.
- The state file is no longer rewritten every five seconds. The per-folder
  "seen" timestamp is refreshed hourly; an idle cycle leaves the file
  untouched.
- Recovering a damaged state file now restores the `seen` and `clipErrors`
  maps (JSON numbers were being cast to `Date` and silently dropped, and the
  reference-date epoch was mistaken for 1970), and a namespace without a
  timestamp gets the full 24-hour grace instead of being pruned immediately.
- The agent now recognises Homebrew's launchd labels as well, so a missing
  watch folder is quiet under `brew services` instead of logging every cycle.
- `--no-trash` is stored in the LaunchAgent plist when `pseudocopy install`
  is used; it previously applied only to the install cycle.
- The agent log is forced to mode 0600 under `brew services` (launchd creates
  it 0644).
- `pseudocopy uninstall` fails and keeps the plist if `launchctl bootout`
  fails, instead of reporting success with a job still loaded. `kick` uses
  `kickstart -k`, and `status` reports a second loaded agent.
- Installing from a Homebrew Cellar path uses the stable
  `/opt/homebrew/bin/pseudocopy` (or `opt`) symlink, so `brew upgrade` cannot
  leave the plist pointing at a deleted version directory.
- The Homebrew formula runs the service with `ProcessType Interactive`,
  matching the built-in installer.

### Added

- `pseudocopy install` and `run` refuse `/`, the home folder, another user's
  home, system and shared roots (`/Users`, `/System`, `/Library`, `/var`,
  `/Volumes`, `/tmp`, …), the root of an external volume and the state store
  itself. `install` warns when the target already contains files and refuses
  an unmounted `/Volumes/...` path.
- A state file written by a newer version is reported and left untouched; the
  cycle stops instead of overwriting it (which could otherwise lose a newer
  version's history after a downgrade).
- Existing files on the first run (or after state loss) are treated as
  leftovers consistently: they are not copied, and expired ones are still
  reaped. This matches the README instead of flooding the clipboard with the
  backlog.
- `PSEUDOCOPY_STATE_ROOT` for hermetic tests. The smoke test now uses a
  private state store and covers unreadable files, corrupt state, the reset
  rule, multi-file batches, idle-state stability and the directory guards.
- CI runs the smoke test and asserts both architectures.
- `--` ends option parsing, so `pseudocopy clip -- -notes.txt` works.

### Changed

- `pseudocopy clean` documentation states its force semantics: it bypasses
  the settle rule and must not be run during a download.
- `Scripts/release.sh` resumes a tag that still points at `HEAD`, verifies
  both slices and the ad-hoc signature, and checks the uploaded assets. The
  Homebrew caveats now explain the stop-before-`install` rule.

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
