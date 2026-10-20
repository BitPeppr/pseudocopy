# pseudocopy

A tiny native-macOS helper that watches **one folder** (by default `~/Temp`),
copies every new, finished file to the **clipboard** — smart about its type —
and moves files that are older than an hour to the **Trash**.

It is a single Swift executable driven by a `launchd` LaunchAgent: every five
seconds it wakes up, does one cycle and exits again. No menu bar icon, no
background daemon, no Homebrew, no third-party dependencies — AppKit and
Foundation only.

```
~/Temp/notes.txt   ->  clipboard (plain text)
~/Temp/photo.png   ->  clipboard (image data)
~/Temp/paper.pdf   ->  clipboard (PDF data)
~/Temp/archive.zip ->  clipboard (file reference + embedded bytes)
```

## Install

```sh
git clone <this repo> pseudocopy
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
```

You can also install by hand:

```sh
swift build -c release
mkdir -p ~/bin && cp .build/release/pseudocopy ~/bin/
~/bin/pseudocopy install --dir ~/Temp
```

## Uninstall

```sh
pseudocopy uninstall          # or: ~/bin/pseudocopy uninstall
```

This removes the LaunchAgent and its plist. The watch folder and the state
store (`~/Library/Application Support/pseudocopy/`) are kept; stale records
are pruned on the next run.

## Use

1. Point your browser's "ask where to save each file" option at `~/Temp`
   (Chrome: *Settings → Downloads → Ask where to save each file*).
2. Download something. A few seconds later it is on your clipboard.
3. Paste it wherever you want.

The same works for anything else that writes into the folder — screenshots,
`curl -O`, a drag-and-drop from the Finder.

Text, images and PDFs are embedded in the pasteboard, so they survive the
file being deleted an hour later. Anything else is pasted as a file
reference (so Finder creates a copy) plus, for files up to 64 MB, the raw
bytes.

> **Use a dedicated folder.** Everything in the *top level* of the watch
> folder is subject to the one hour reaper — do not point `pseudocopy` at a
> shared directory such as `/tmp`.

### Commands

```
pseudocopy run                 # one watch+reap cycle (what launchd calls)
pseudocopy loop [--interval N] # resident loop, for foreground development only
pseudocopy clean [--no-trash]  # force-reap right now (files older than the TTL)
pseudocopy clip <path...>      # clip a file manually, bypassing the settle logic
pseudocopy gen-tests <dir>     # write sample files for testing
pseudocopy install             # write the LaunchAgent plist + launchctl bootstrap
pseudocopy uninstall           # launchctl bootout + remove the plist
pseudocopy status              # exit 0 if the agent is loaded, 1 otherwise
pseudocopy help                # usage
```

Global flags: `--dir <path>` (watch folder, default `~/Temp`), `--ttl <seconds>`
(default `3600`), `--verbose` (log every cycle), `--no-trash` (delete
permanently instead of using the Trash).

Exit codes: `0` on success, `1` on a runtime error (the reason is written to
stderr).

## How it decides what to copy

A file is only copied once it is **settled**: it was seen in two consecutive
cycles with the same size and modification time. That is what keeps a file
that is still downloading from landing on your clipboard half-written. The
same rule protects the reaper — a file that is still growing is never
deleted, no matter how old its timestamp is.

Because of that second observation, a file appears on the clipboard roughly
5–10 seconds after it was written: the agent checks every 5 seconds and
needs two identical readings.

Ignored entirely: directories, symlinks, dotfiles and partial downloads
(`.crdownload`, `.part`, `.download`, `.tmp`, `.partial`).

## Log

The agent writes to `~/Library/Logs/pseudocopy.log`. Nothing is logged while
the folder is idle — only events:

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
- Very large files are best kept out of this folder: everything is copied
  into the clipboard, which lives in RAM. Nothing breaks, it is just
  wasteful.
- **Manual edits in `~/Temp` are silently deleted after an hour.**
- Stale partial downloads (`.crdownload` and friends) are ignored by
  `pseudocopy` — they are never copied and never reaped. Remove them by
  hand.
- The reaper uses the older of the creation and modification date, so a file
  that was moved into the folder keeps its original age and may disappear
  right away.

## Development

```sh
swift build                 # debug build
swift build -c release      # release build
Scripts/smoke.sh            # headless end-to-end test
```

`Scripts/smoke.sh` builds the tool, runs a full cycle in a sandbox folder and
checks clipping, reaping and the exclusion of partial downloads. It writes to
the system pasteboard and restores the previous clipboard content when it
finishes.

The implementation follows `PLAN.md`; the phase-by-phase build log is in the
git history.
