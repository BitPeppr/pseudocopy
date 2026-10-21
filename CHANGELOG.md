# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [semantic versioning](https://semver.org/).

## [1.2.0] — 2026-10-21

### Added

- **UTF-16 text files are pasted as text.** A `.txt`, `.csv` or any other
  text file saved with a UTF-16 BOM used to fall through to *Other* (or put
  its UTF-16 bytes under a text type). It is now transcoded to UTF-8, so the
  text is pasted correctly. A UTF-8 BOM is removed for the same reason: it
  used to become an invisible character at the start of the paste.
- **More text types are recognized.** An extension whose macOS UTI already
  conforms to `public.plain-text` counts as text without being in the
  hard-coded list (Fortran, Pascal, Ada, Make, …), and `.asm`, `.edn`,
  `.ndjson`, `.geojson`, `.mts`, `.cjs` and `.cts` were added explicitly.
  `.mts` is also a video extension; the bytes still decide, so a real MPEG
  transport stream keeps its file representation and is not pasted as text.
- **A multi-page TIFF is completed like a PDF.** A TIFF whose pages have the
  same dimensions now carries a file reference (the whole document) and logs
  the same first-page warning. A single-page TIFF — and a TIFF whose second
  IFD is only a thumbnail — is unchanged.
- `clip` refuses devices and FIFOs instead of blocking on them.

### Fixed

- **Empty images and PDFs are no longer advertised as content.** A zero-byte
  `.png` or `.pdf` used to be written as an empty image/document; it now
  carries only a file reference.
- **An image extension whose bytes are not an image is no longer advertised
  as one.** A text or damaged file named `.png`/`.jpg`/… falls back to a file
  reference plus `public.data` instead of handing broken bytes to an
  image-aware app.
- **A `.txt` containing NUL bytes is no longer pasted as text.** It is a
  binary file and is offered as a file.
- **A failed text file can no longer shadow a valid one in the same batch.**
  The fallback representation uses `public.data` for text-typed extensions,
  so an invalid `.txt` and a valid `.txt` no longer collide on
  `public.plain-text`.
- **Unknown extensions use `public.data`, not a dynamic UTI.** A dynamic
  `dyn.…` identifier is unique to the extension and no app can request it;
  the raw bytes are now offered under `public.data` (the file reference is
  unchanged).
- **Control characters in a file name can no longer corrupt the log.** Tabs,
  newlines, escape sequences, C1 controls and Unicode line separators are
  escaped in every log line, so a downloaded name cannot inject a terminal
  escape or a fake log entry.

### Changed

- The README documents the new text handling, the image/file fallbacks and
  the fifth deviation from `PLAN.md`.
- The smoke test covers UTF-16 and BOM handling, legacy encodings, NUL
  bytes, empty and mislabelled files, SVG/RTF, unknown extensions, binary
  `.ts`, the batch text collision, devices/FIFOs, log escaping and
  multi-page TIFFs.

## [1.1.0] — 2026-10-21

### Fixed

- **A multi-page PDF no longer loses its pages.** The whole document was
  already on the pasteboard, but macOS rasterises a PDF to **the first page**
  when an app asks for an image (chat, mail, notes, upload fields), and the
  other pages disappeared without a word. A PDF now also carries a file
  reference, so file-aware apps receive the complete document, and a PDF
  with more than one page logs a warning. Pasting into a PDF-aware app
  (Preview, Pages, Word) still inserts every page.
- **Text is visible to modern apps.** The pasteboard used to carry only the
  legacy `public.utf8-plain-text`; apps that ask for `public.plain-text`
  (the modern `UTType.plainText`) saw an empty pasteboard. Both are written
  now.
- **The file type is read from the content, not the name.** A PNG named
  `.jpg` is advertised as `public.png`, and `.webp`, `.bmp`, `.avif` and the
  like are treated as images instead of being offered as files. Every format
  ImageIO can decode now behaves exactly like `.png`.
- **Extensionless text files are pasted as text.** `Dockerfile`, `Makefile`
  and `LICENSE` used to land as file references; a file whose extension says
  nothing is now pasted as text when its bytes are valid UTF-8 without NUL
  bytes.

### Changed

- A PDF clip carries `public.file-url` next to `com.adobe.pdf`; a single
  text or image clip still carries no file reference.
- The README documents the representation of every type, the PDF page
  caveat, and the deliberate deviations from `PLAN.md` §2.2.

### Added

- The smoke test compiles a small pasteboard inspector and asserts the exact
  representation set for text, images (including mislabelled ones), a
  multi-page PDF, extensionless text and a binary file. It snapshots and
  restores the *whole* clipboard instead of only its text.

## [1.0.4] — 2026-10-20

### Fixed

- The warning about a leftover Homebrew plist only appears when the built-in
  agent exists as well. A Homebrew plist on its own is the normal case for
  `brew services` users and was a false alarm.

## [1.0.3] — 2026-10-20

### Added

- **Every setting is configurable from the command line.** The new
  `pseudocopy config` subcommand reads and writes one settings file
  (`~/Library/Application Support/pseudocopy/config.json`): `config list`,
  `config get <key>`, `config set <key> <value>`, `config unset <key>`,
  `config reset` and `config path`. `config list` shows every value and
  where it came from (command line, settings file, default).
- New settings, each with a matching flag: `dir`, `ttl`, `interval`,
  `permanent`, `verbose`, `log-path`, `state-dir`, `text-limit`,
  `embed-limit` and `materialise-limit`. The size limits accept plain byte
  counts and `16MB`/`1GiB` style values.
- `--interval` is now honoured by `install` (it used to be accepted and
  ignored there) and by the `loop` command.
- `--log` chooses where the agent writes its log, `--state-dir` where the
  state store lives.
- The Homebrew formula reads the settings file, so `brew services start`
  copies the check interval and the log path from it into the plist. The
  service and the command line can no longer disagree.
- `Scripts/install.sh` learned `--interval` and `--no-trash`.

### Changed

- The agent's plist is now minimal (`pseudocopy run`): the settings live in
  the settings file, which the agent reads on every cycle. **Changing a
  setting takes effect immediately — no reinstall.** Only the check interval
  and the log path stay in the plist, because launchd needs them; after
  changing those, re-run `pseudocopy install` or `brew services restart`.
- `pseudocopy install` stores the flags it was given in the settings file
  and leaves every other setting alone. The watch folder and the state store
  are still never touched by an install.
- The command line always wins over the settings file, and
  `PSEUDOCOPY_STATE_ROOT` still wins over the file for the state store.
- The watch-folder guard also applies to values that come from the settings
  file: a hand-edited `dir` cannot point the reaper at your home directory.

### Warnings

`install` and `config set` now say what could bite:

- the watched folder already contains files, is a personal folder
  (`~/Downloads`, `~/Desktop`, `~/Documents`) or lives on an external volume
- the TTL is 0, or shorter than two cycles (files could be reaped before
  they were ever copied)
- the interval is very short (the agent wakes up often) or very long (a
  download takes that long to appear)
- files are deleted permanently, or the log grows one line per cycle
- the log is written outside `~/Library/Logs`
- the pasteboard size limits are above the defaults
- the state store is inside the watched folder
- a Homebrew service plist is still on disk — `brew services start` would
  load a second agent
- `PSEUDOCOPY_STATE_ROOT` is set, so the agent under launchd would not see
  the settings

### Fixed

- A damaged settings file is kept as `config.json.corrupt` and the defaults
  apply, instead of the tool refusing to run.
- `pseudocopy config` works even when the stored settings are broken — it
  must be possible to repair them.
- Negative numbers are accepted as values (`pseudocopy config set ttl -1`
  reports a proper error instead of "unknown option").
- `pseudocopy status` now also prints the settings the agent works with.

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
