# pseudocopy

[![CI](https://github.com/BitPeppr/pseudocopy/actions/workflows/ci.yml/badge.svg)](https://github.com/BitPeppr/pseudocopy/actions/workflows/ci.yml)

A tiny native-macOS helper that watches **one folder** (by default `~/Temp`),
copies every new, finished file to the **clipboard** — smart about its type —
and moves files that are older than an hour to the **Trash**.

It is a single Swift executable driven by a `launchd` LaunchAgent: every five
seconds it wakes up, does one cycle and exits again. No menu bar icon, no
background daemon, no third-party dependencies — only Apple's system
frameworks (AppKit, Foundation, CoreGraphics, ImageIO and
UniformTypeIdentifiers).

```
~/Temp/notes.txt   ->  clipboard (plain text)
~/Temp/photo.png   ->  clipboard (image data)
~/Temp/paper.pdf   ->  clipboard (whole PDF + file reference)
~/Temp/archive.zip ->  clipboard (file reference + embedded bytes)
```

## Install

### Homebrew (recommended)

```sh
brew install BitPeppr/tap/pseudocopy
brew services start pseudocopy
```

The formula installs the universal binary and a LaunchAgent that runs
`pseudocopy run` every five seconds. It watches `~/Temp` by default — every
setting is configurable with `pseudocopy config` (see
[Configuration](#configuration)). To watch another folder, change the setting
instead of installing a second agent:

```sh
pseudocopy config set dir ~/Downloads
brew services restart pseudocopy
```

Do **not** run `pseudocopy install` while the Homebrew service is loaded — it
refuses. `pseudocopy status` and `pseudocopy kick` work with the Homebrew
service; use `brew services` to start, stop, or restart it.

### From source

```sh
git clone https://github.com/BitPeppr/pseudocopy.git
cd pseudocopy
Scripts/install.sh
```

The script builds a release binary, copies it to `~/bin/pseudocopy`, creates
the watch folder and registers the LaunchAgent `com.pseudocopy`.

Options:

```sh
Scripts/install.sh --prefix ~/bin      # where the binary goes (default ~/bin)
Scripts/install.sh --dir ~/Downloads   # the folder to watch (default ~/Temp)
Scripts/install.sh --ttl 600           # reap after 10 minutes (default 3600)
Scripts/install.sh --interval 10       # check every 10 seconds (default 5)
```

You can also install by hand:

```sh
swift build -c release
mkdir -p ~/bin && cp .build/release/pseudocopy ~/bin/
~/bin/pseudocopy install --dir ~/Temp
```

The flags are written into the settings file, not into the agent's plist, so
changing a setting later means `pseudocopy config set …` — not another
install.

## Uninstall

```sh
pseudocopy uninstall          # or: ~/bin/pseudocopy uninstall
```

This removes the LaunchAgent and its plist. The watch folder and the state
store (`~/Library/Application Support/pseudocopy/`) are kept, so reinstalling
with the same folder preserves the history.

## Use

1. Point your browser's "ask where to save each file" option at `~/Temp`
   (Chrome: *Settings → Downloads → Ask where to save each file*).
2. Download something. A few seconds later it is on your clipboard.
3. Paste it wherever you want.

The same works for anything else that writes into the folder — screenshots,
`curl -O`, a drag-and-drop from the Finder.

Text, images and PDFs are embedded in the pasteboard, so they survive the
file being deleted an hour later. Text is pasted as text, an image as the
image (the type is read from the bytes, not the name) and a PDF as the whole
document. A PDF also carries a file reference — the complete file for apps
that cannot take PDF data — and a multi-page PDF logs a warning, because
macOS itself rasterises only the first page when a target asks for an image.
Anything else is pasted as a file reference (so Finder creates a copy) plus,
for files up to 64 MB, the raw bytes. A multi-file batch adds file references
for every file so the Finder can copy them all.

> **Use a dedicated folder.** Everything in the *top level* of the watch
> folder is subject to the one hour reaper — do not point `pseudocopy` at a
> shared directory such as `/tmp`. `install` and `run` refuse `/`, your home
> folder, another user's home, `/Users`, `/System`, `/Library`, `/var`,
> `/Volumes`, the root of an external volume, the shared temp roots and the
> state store itself. Personal folders such as `~/Downloads` are allowed, but
> everything there is subject to the reaper; `install` warns if the target
> already contains files.

### Commands

```
pseudocopy run                 # one watch+reap cycle (what launchd calls)
pseudocopy loop [--interval N] # resident loop, for foreground development only
pseudocopy clean [--no-trash]  # force-reap now; bypasses the settle rule
pseudocopy clip <path...>      # clip a file manually, bypassing the settle logic
pseudocopy gen-tests <dir>     # write sample files for testing
pseudocopy install             # write the LaunchAgent plist + launchctl bootstrap
pseudocopy uninstall           # launchctl bootout + remove the plist
pseudocopy status              # exit 0 if the agent is loaded, 1 otherwise
pseudocopy config [action]     # read and change the settings file
pseudocopy kick                # force one cycle of the agent right now
pseudocopy version             # print the version
pseudocopy help                # usage
```

Global flags: `--dir <path>` (watch folder, default `~/Temp`), `--ttl <seconds>`
(default `3600`), `--interval <seconds>` (check interval, default `5`),
`--verbose` (log every cycle), `--no-trash` (delete permanently instead of
using the Trash), `--log <path>`, `--state-dir <path>`, `--text-limit`,
`--embed-limit`, `--materialise-limit`.

## Configuration

Every setting lives in one file:

```
~/Library/Application Support/pseudocopy/config.json
```

The command line always wins over the file, so a single cycle can run with
different settings without changing anything permanent.

```sh
pseudocopy config list                  # every setting, its value and where it came from
pseudocopy config get ttl               # one effective value
pseudocopy config set ttl 600           # change one setting
pseudocopy config set dir ~/Downloads
pseudocopy config set interval 10
pseudocopy config set permanent true    # delete instead of using the Trash
pseudocopy config unset ttl             # back to the default
pseudocopy config reset                 # remove the file
pseudocopy config path                  # where the file is
```

| Setting | Flag | Default | Meaning |
|---|---|---|---|
| `dir` | `--dir` | `~/Temp` | the folder that is watched |
| `ttl` | `--ttl` | `3600` | how long a file may stay before it is reaped (seconds) |
| `interval` | `--interval` | `5` | how often the folder is checked (seconds) |
| `permanent` | `--no-trash` | `false` | delete files permanently instead of using the Trash |
| `verbose` | `--verbose` | `false` | log every cycle, not just events |
| `log-path` | `--log` | `~/Library/Logs/pseudocopy.log` | where the agent writes its log |
| `state-dir` | `--state-dir` | `~/Library/Application Support/pseudocopy` | where the state store lives |
| `text-limit` | `--text-limit` | `16MB` | largest text file that is embedded as text |
| `embed-limit` | `--embed-limit` | `64MB` | largest generic file whose bytes are embedded |
| `materialise-limit` | `--materialise-limit` | `256MB` | largest image or PDF that is materialised |

The agent reads the file on every cycle, so **changing a setting takes effect
immediately — no reinstall**. Two values live in the agent's plist instead of
in the file, because launchd itself needs them: the check interval and the log
path. After changing those, re-run `pseudocopy install` (or
`brew services restart pseudocopy`).

`pseudocopy install` writes the flags it was given into the settings file, so
installing with `pseudocopy install --ttl 600` stores `ttl: 600` and leaves
every other setting alone. The installed plist itself stays minimal
(`pseudocopy run`), which is why `brew upgrade` can never break it.

The Homebrew service reads the same file: `brew services start` copies the
check interval and the log path from it into the plist, and the agent reads
everything else itself. The watch-folder guard applies to the file too — a
hand-edited `dir` cannot point the reaper at your home directory.

`pseudocopy clip a.txt b.txt` puts several files on the pasteboard at once:
a paste into the Finder copies all of them, a paste into a text field
inserts the first one — a pasteboard holds a single value per type. `clip`
does not update the agent's state, so the agent may copy a file again when
it settles.

`clean` is an explicit override: it reaps every file older than the TTL
right now, including files the agent has never seen. Do not run it while a
download is in progress.

Exit codes: `0` on success, `1` on a runtime error (the reason is written to
stderr). Without a subcommand nothing happens — `pseudocopy` prints the usage
instead of quietly starting a cycle.

## How it decides what to copy

A file is only copied once it is **settled**: it was seen in two consecutive
cycles with the same size and modification time. That is what keeps a file
that is still downloading from landing on your clipboard half-written. The
same rule protects the reaper — a file that is still growing is never
deleted, no matter how old its timestamp is.

Because of that second observation, a file appears on the clipboard roughly
5–10 seconds after it was written: the agent checks every 5 seconds and
needs two identical readings.

### What lands on the clipboard

| File | Pasteboard representation |
|---|---|
| **Text** — the extension list, or a file with no meaningful extension whose bytes are UTF-8 | the text, under both `public.utf8-plain-text` and `public.plain-text` |
| **Image** — whatever ImageIO can decode (PNG, JPEG, GIF, TIFF, HEIC, WebP, BMP, AVIF, …) | the image bytes, under the type the *content* is; AppKit adds a TIFF for older apps |
| **PDF** | the whole document under `com.adobe.pdf`, plus a `public.file-url` for apps that cannot take PDF data |
| **Other** | `public.file-url` (plus the legacy Finder file list) and, up to 64 MB, the raw bytes under the file's UTI |

The content wins over the name: a PNG called `.jpg` is advertised as
`public.png`, and a WebP download is pasted as an image, not as a file. A
binary file is never pasted as text — a NUL byte rules it out — and a file
with no extension is pasted as text only when its bytes are valid UTF-8
(`Dockerfile`, `Makefile`, `LICENSE`).

A PDF is the one case where the format itself limits what an app can show:
macOS rasterises a PDF to a single image when the target cannot take PDF
data, and that image is always page 1. Pseudocopy keeps every page in the
PDF representation, offers the file itself as a second representation, and
logs a warning for a document with more than one page. To get all pages,
paste into a PDF-aware app (Preview, Pages, Word) or as a file.

An old file that arrives after the state exists (one that was copied in with
an older timestamp) is copied to the clipboard as well and then removed from
the folder — you get the content and the folder stays clean. This does not
apply to files that were already there when the folder was first seen; see
"The first minute".

Ignored entirely: directories, symlinks, dotfiles and partial downloads
(`.crdownload`, `.part`, `.download`, `.tmp`, `.partial`). A partial download
is never copied and never reaped; remove it by hand when it is stale.

### The first minute

When pseudocopy sees a folder for the first time (right after install, or
after the state file was lost or damaged), it cannot know which files are
new. Every existing file is recorded as a leftover: it is not copied, so the
folder is not emptied onto the clipboard all at once. Files that are already
older than the TTL are still moved to the Trash on that first cycle; the rest
are reaped normally when they expire. Files that arrive afterwards are copied
as usual. `install` warns when the target folder already contains files.

If the state file is damaged it is kept next to the state store as
`state.json.corrupt` for diagnosis, and the state is rebuilt with the same
leftover rule.

### Safety

- A file whose clip failed is **not** reaped. It stays in the folder and the
  clip is retried; this is what keeps an unreadable or busy file from being
  deleted before you ever got its content.
- If the watch folder is unavailable (an external volume that is not
  mounted), the cycle is skipped and its state namespace is kept. When the
  volume returns, the files that were already copied are not copied again.
- A state file written by a **newer** pseudocopy is never overwritten. The
  cycle stops and the log says which version wrote it, so a downgrade cannot
  silently discard the newer history.
- `install` and `run` refuse the folders listed above, `install` refuses an
  unmounted `/Volumes/...` path, and `install` warns before arming the agent
  over existing content.

## Log

The agent writes to `~/Library/Logs/pseudocopy.log`; the file is kept private
to the user (mode 0600, including when launchd creates it for a Homebrew
service). Nothing is logged while the folder is idle — only events:

```
2026-10-20 14:03:12 [clip] text  ~/Temp/notes.txt
2026-10-20 14:31:44 [reap] file  ~/Temp/old-download.pdf
```

Add `--verbose` for a line per cycle (handy while developing with
`pseudocopy loop`).

## Caveats

- Each new download **replaces** the clipboard — macOS has a single
  pasteboard.
- Clipboard payloads for text, images and PDFs are embedded copies and
  survive the deletion of the source file. Binary files survive through the
  embedded data as well, but only up to 64 MB; above that, pasting after the
  file was reaped may fail, because the file-object reference needs the
  source to still exist.
- A PDF also offers a reference to the file itself. That reference needs the
  file to still exist: once the reaper has moved it to the Trash, an app
  that takes the file rather than the embedded PDF data will not find it.
  The embedded PDF data is unaffected.
- macOS rasterises a PDF to its **first page** when the target only accepts
  images. Pseudocopy keeps the whole document, offers the file itself and
  logs a warning for a multi-page PDF; paste into a PDF-aware app or as a
  file to get every page. A multi-page TIFF has the same limitation: the
  image target sees the first frame.
- Text files are only pasted as text up to 16 MB — bigger ones are offered
  as a file reference instead, because the bytes would cost about three
  times their size in memory. Images and PDFs are not materialised above
  256 MB.
- Very large files are best kept out of this folder: everything is copied
  into the clipboard, which lives in RAM. Nothing breaks, it is just
  wasteful.
- **Manual edits in `~/Temp` are silently deleted after an hour.**
- Stale partial downloads (`.crdownload` and friends) are ignored by
  `pseudocopy` — they are never copied and never reaped. Remove them by
  hand.
- The reaper uses the older of the creation and modification date, so a file
  that was moved into the folder keeps its original age and may disappear
  right away. It is copied to the clipboard first (unless it was already
  there when the folder was first seen), so you still get its content.
- `pseudocopy clean` force-reaps everything older than the TTL immediately,
  bypassing the settle rule. Do not run it during a download.
- A download that stalls for a full hour is treated like any other finished
  file: it is copied to the clipboard and then removed. Use a longer `--ttl`
  if you resume large downloads by hand.

## Development

```sh
swift build                 # debug build
swift build -c release      # release build
Scripts/smoke.sh            # headless end-to-end test
Scripts/release.sh          # universal binary + GitHub release (maintainers)
```

`Scripts/smoke.sh` builds the tool, runs full cycles in a private sandbox
folder and checks clipping, reaping, the exclusion rules (partial downloads,
dotfiles, directories, symlinks), the process lock, and the safety paths
(unreadable files, a damaged state file, missing external-volume paths and
the watch-directory guards). It compiles
[`Scripts/pasteboard_inspector.swift`](Scripts/pasteboard_inspector.swift) to
assert the exact pasteboard representation of every file type, and it
snapshots and restores the *whole* clipboard (not only its text). It uses a
private state store via `PSEUDOCOPY_STATE_ROOT`. It is part of CI.

Packaging — the Homebrew tap, the release tarball and why there is no DMG —
is described in [`docs/DISTRIBUTION.md`](docs/DISTRIBUTION.md).

### Deviations from PLAN.md

`PLAN.md` is normative. Four clipboard rules were extended after real-world
testing; everything else follows the plan, and the phase-by-phase build log
is in the git history.

1. **Classification is content-first.** §2.2 decides the type by extension;
   pseudocopy checks the PDF header (CoreGraphics) and lets ImageIO identify
   images before falling back to the extension lists. Both are system
   frameworks that AppKit already links — there is still no third-party
   dependency. This is what makes a mislabelled image, WebP/BMP and
   extensionless text work.
2. **Text is written under two UTIs.** §2.2 names only
   `public.utf8-plain-text`; `public.plain-text` is written alongside it so
   apps using the modern identifier get the text.
3. **A PDF also carries a file reference.** §2.2 gives a PDF only the
   `com.adobe.pdf` data. Without the file URL, an app that cannot take PDF
   data lets macOS rasterise page 1, and the other pages are lost.
4. **Extensionless UTF-8 files are text.** §2.2's text set is a fixed
   extension list; a file whose extension is unknown (or absent) is treated
   as text when its bytes are valid UTF-8 without NUL bytes.

The smoke test asserts each of these, so the behaviour cannot regress
silently.

### Internals

- The state lives in `~/Library/Application Support/pseudocopy/state.json`
  (mode 0600), one namespace per watch folder. It is written atomically and
  only when something actually changed; the per-folder "seen" timestamp is
  refreshed hourly rather than every cycle, so an idle agent does not rewrite
  it.
- The settings live next to it in
  `~/Library/Application Support/pseudocopy/config.json` (mode 0600). The
  agent reads it on every cycle, so a change takes effect without a restart.
- `PSEUDOCOPY_STATE_ROOT` points both the store and the settings file at
  another directory. It exists for the smoke test; normal use does not need
  it.
- Cycles are serialised with an `flock` on `…/pseudocopy/lock`. The kernel
  releases it when the process dies, so a lock left behind by a killed cycle
  can never wedge the tool. The file contains the PID for diagnostics.
- The agent runs with `StartInterval` **and** `ThrottleInterval` of 5
  seconds: without the latter, launchd applies its default 10 second
  throttle and the reaction time doubles.
- A state namespace whose watch folder is gone is pruned after 24 hours. A
  folder under `/Volumes` that is not mounted never causes a prune: the
  cycle is skipped without touching the state.
