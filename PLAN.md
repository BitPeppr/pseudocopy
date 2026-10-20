# pseudocopy — Implementation Plan

> **How to use this document (for the building agent):**
> Implement this exactly as specified, top to bottom, phase by phase. Do not redesign the architecture, do not add third-party dependencies, do not add features beyond what is written. When a detail is unspecified, prefer the simplest implementation that satisfies the stated behavior. Work through Phases 0–8 in order; after each phase, run its DoD check before moving on.

---

## 1. Overview

`pseudocopy` is a small native-macOS utility that watches one folder (default `~/Temp`) and:

1. **Clips** every new, fully-downloaded file onto the system clipboard ("smart by type" — see §2), and
2. **Reaps** files older than one hour out of the folder.

It is shipped as a single Swift executable managed by a `launchd` LaunchAgent, so it runs at login and on a ~5-second cycle forever. No Homebrew, no background resident daemon (the process starts, does one cycle, exits).

### Goals
- Zero external dependencies (Swift standard library + AppKit + Foundation only).
- ~5 second reaction time; effectively instant.
- Survives reboots (LaunchAgent with `RunAtLoad`).
- Safe: never deletes anything outside its watch folder, and folders/symlinks/dotfiles/partial downloads are ignored.
- Uninstallable in one command.

### Non-goals
- Not a resident GUI app, no menu bar icon.
- Not a browser-config tool (the user sets download destination manually).
- No recursive watching of subfolders (top-level files only).
- No clipboard-history features.

---

## 2. Runtime behavior specification

### 2.1 Folder scan & clip semantics

Every cycle (one process invocation):

```
for each top-level entry in watch dir:
    if entry is directory, or symlink, or dotfile (name starts with "."), or
       extension is a partial-download marker (.crdownload, .part, .download, .tmp, .partial)
        -> ignore, do not add to state
    else:
        record (size, modificationTime) fingerprint
```

A file is **clipped** when:
- It has been seen on **two consecutive** cycles with the *same* (size, mtime) fingerprint — this is the "settled" check that prevents clipping a file mid-download; and
- It has not been clipped before (per the state store); and
- The (size, mtime) differs from the last recorded *clipped* fingerprint for that path (so re-downloading the same filename clips again).

After a clip succeeds, the processed fingerprint for that path is stored in the state file so a restart does not re-clip it.

### 2.2 Smart-by-type clipboard rules

`clip` = clear pasteboard, then write the applicable representations (§4.1 has exact code recipes).

| File type (by extension) | Pasteboard representation(s) |
|---|---|
| **Text** set (§7.2 ext list) | `public.utf8-plain-text` with the file's bytes as a UTF-8 string. If the bytes fail UTF-8 decoding → fall through to *Other*. |
| **Image** set: `.png .jpg .jpeg .gif .tif .tiff .heic` | Raw data written under its UTI: `public.png`, `public.jpeg`, `com.compuserve.gif`, `public.tiff`, `public.heic`. This pastes as an image into apps. |
| **PDF**: `.pdf` | `com.adobe.pdf` raw data. |
| **Other** (binary/arbitrary) | Three representations: `public.file-url` (via `writeObjects([url])`), legacy `NSFilenamesPboardType` property list (array of absolute paths) so Finder paste works, and — **only if file size ≤ `embedLimitBytes` (64 MB)** — the raw file data under its UTI (falls back to `public.data` if UTI unknown). |

Path-name mappings must be case-insensitive.

### 2.3 Reaper semantics

Every cycle, after the clip pass:

- For each top-level **regular file** in the watch dir: if `min(creationDate, modificationDate) < now - ttl` → move it to **Trash** (`FileManager.trashItem` is the default so the deletion is recoverable; a `--no-trash` flag switches to permanent unlink). The user-facing contract "gone from the folder within an hour" holds either way.
- Prune state-store records whose files no longer exist.
- Note: the reaper must also verify the file is "settled" (already clipped or at least 2-scan fingerprint-stable) so it never deletes a file that is still being written, even if its mtime exceeds TTL (network stall case).

### 2.4 Timing constants (put in one `constants` file)

| Constant | Value |
|---|---|
| `cycleInterval` | 5 s (`StartInterval` in the LaunchAgent) |
| `defaultTTL` | 3600 s |
| `embedLimitBytes` | 64 << 20 |
| `maxWriteDuration` | not needed; process exits in <1 s |

### 2.5 Logging

- Default: log **only on events** (clip, reap, state errors) to stderr — a 5 s cycle logging "nothing happened" would grow the log file unbounded, so silent when idle.
- `--verbose` logs every cycle.
- LaunchAgent redirects stderr/stdout to `~/Library/Logs/pseudocopy.log` (§5.2). Format: `2026-10-20 14:03:12 [clip] text  ~/Temp/notes.txt`.

### 2.6 Process model

`launchd` starts `pseudocopy run` every 5 s; the process performs one cycle and exits quickly. To guard against overlapping invocations (slow cycle > 5 s, e.g. embedding a 64 MB file), use a lock file:

- Path: `<appSupport>/lock`, contents = current PID.
- Create with `O_CREAT | O_EXCL`. If it already exists, read the PID and check `kill(pid, 0)`: if that PID is alive, exit 0 silently; otherwise the lock is stale → delete it and retry once.
- Lock is removed at exit (also handle it in `defer`/exit paths).

### 2.7 CLI

```
pseudocopy run                 # one watch+reap cycle (what launchd calls). Flags below apply.
pseudocopy loop [--interval N] # resident loop, for foreground development only
pseudocopy clean [--no-trash]  # force-reap right now (files older than TTL)
pseudocopy clip <path...>      # clip a file manually, bypassing settle logic (debug/testing)
pseudocopy gen-tests <dir>     # write sample files for testing (§6.3)
pseudocopy install             # write LaunchAgent plist + launchctl bootstrap (§5)
pseudocopy uninstall           # launchctl bootout + remove plist
pseudocopy status              # exit 0 if agent is loaded, 1 otherwise; prints launchctl print output
pseudocopy help                # usage
```

Global flags: `--dir <path>` (watch dir, default `~/Temp`; created on `install` if missing; different dirs automatically get their own state namespace), `--ttl <seconds>` (default 3600), `--verbose`, `--no-trash`.

Exit codes: 0 OK, 1 runtime error (per §2.5, log reason on stderr).

---

## 3. Project structure

```
pseudocopy/
├── Package.swift
├── PLAN.md                      ← this file
├── README.md                    ← written in Phase 8
├── Scripts/
│   └── install.sh               ← build + copy binary + bootstrap agent
└── Sources/
    └── pseudocopy/
        ├── main.swift           ← arg parsing + subcommand dispatch
        ├── config.swift         ← Configuration struct + flag parsing
        ├── constants.swift      ← §2.4 constants, §7.2 extension lists
        ├── fs.swift              ← scan, classify, settle, reap
        ├── clipboard.swift      ← pasteboard recipes (§4.1)
        ├── state.swift          ← StateStore load/save/prune (§4.3)
        ├── gen_tests.swift      ← sample-file generator
        └── installer.swift      ← plist template + launchctl calls
```

Single target, no test target (`swift build` + smoke script are the test suite). `Package.swift` uses `swift-tools-version:5.9`, platforms: `[.macOS(.v13)]`.

### File responsibilities

**main.swift**
```swift
@main struct Pseudocopy { static func main() }
// parse argv, build Configuration, dispatch subcommand, exit with code
```

**config.swift**
```swift
struct Configuration {
    var watchDir: URL          // resolved absolute, ~ expanded, standardized
    var ttl: TimeInterval
    var embedLimitBytes: Int
    var verbose: Bool
    var permanent: Bool        // --no-trash
    static func parse(_ args: [String]) throws -> Configuration
}
```

**fs.swift** (all core logic; keep it free of AppKit imports so it stays testable)
```swift
enum FileKind { case text, image, pdf, other }
struct Fingerprint: Equatable { var size: Int; var mtime: Date }
enum FileVerification { case ignored, partial, settled(Fingerprint), settling }

func classifyFile(_ url: URL) -> FileKind       // by extension, case-insensitive
func partialFileExtension(_ name: String) -> Bool
func topLevelEntries(_ dir: URL) throws -> [URL]  // regular files only, no dotfiles/symlinks
func fingerprint(of url: URL) throws -> Fingerprint?
func runCycle(config: Configuration) throws
/*
   runCycle order (each step best-effort, errors logged not thrown):
   1. acquire lock (§2.6), defer release
   2. normalise state keys: cleaned path (symlink-free, no trailing /)
   3. scan pass -> fingerprints per file
   4. clip pass: for files whose fingerprint equals last scan's AND not clipped in state
   5. reap pass (§2.3)
   6. prune state, save state
*/
```

**clipboard.swift**
```swift
func putOnClipboard(kind: FileKind, url: URL, embedLimit: Int) throws
// implementations per §4.1 recipes; must call clearContents() first in every branch
```

**state.swift**
```swift
struct StateRecord: Codable { var lastFingerprint: Fingerprint; var clippedFingerprint: Fingerprint? }
struct StateStore {
    // stored at ~/Library/Application Support/pseudocopy/state.json
    // JSON dictionary keyed by absolute normalized path, nested: watchDir -> path -> StateRecord
    mutating func load() ; mutating func save() throws        // atomic via FileManager + write(to:)
    mutating func Prune(missing: Set<String>)                  // rename: prune()
}
```

**installer.swift** — writes the plist from the template in §5.2 with `$HOME`/absolute-path substitution (never `~` in the plist), then shells out to `launchctl` subprocess as documented in §5.3.

**gen_tests.swift** — `gen-tests <dir>` writes: `sample.txt` ("pseudocopy test"), `sample.png` (1×1 PNG decoded from a hardcoded base64 constant), `sample.jpg/gif/tiff` (converted from the PNG by shelling out to `sips -s format jpeg/gif/tiff`), `sample.pdf` (hardcoded minimal PDF skeleton — validity is irrelevant, the pasteboard never parses it), `sample.zip`-like `sample.bin` (64 KB of pseudo-random bytes), plus `sample.still-downloading.crdownload` (must be ignored).

---

## 4. Implementation details & known pitfalls

These are the places a naive implementation typically gets stuck. Follow them.

### 4.1 Pasteboard recipes (AppKit)

General rules:
- Always import `AppKit`, use `NSPasteboard.general`.
- **Always** call `pasteboard.clearContents()` before writing.
- Prefer `setData(_:forType:)` with `NSPasteboard.PasteboardType` built from UTI strings. `writeObjects` is only used for the file-URL case (it does the right conversion for `NSURL`).
- Prefer the deprecated-constant workaround so the project still compiles: `NSPasteboard.PasteboardType("NSFilenamesPboardType")` — reusing the raw string avoids referencing deprecated symbols.
- Use `UTType(filenameExtension:)` from `UniformTypeIdentifiers` (macOS 11+), falling back to `UTType.data`.
- It is safe to write to the general pasteboard from a plain CLI process (this is exactly what `pbcopy` does); no NSApplication needed.
- Write **materialized data** (never lazy promises) so clipboard contents survive when the source file is reaped an hour later.

Recipes:

```swift
// TEXT
let data = try String(contentsOf: url, encoding: .utf8).data(using: .utf8)!
pb.clearContents(); pb.setData(data, forType: .init("public.utf8-plain-text"))

// IMAGE / PDF / embedded OTHER
let raw = try Data(contentsOf: url)
let uti = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
pb.clearContents(); pb.setData(raw, forType: .init(uti))

// OTHER (in addition to the embedded data above, when size ≤ embedLimit):
pb.writeObjects([url as NSURL])                       // gives public.file-url
pb.setPropertyList([url.path], forType: .init("NSFilenamesPboardType"))
```
Order note: for *Other*, write the file-URL representations *and* the data block in one clearContents sequence (multiple setData calls are fine after a single clear).

### 4.2 Filesystem API notes

- Get attributes via `FileManager.default.attributesOfItem(atPath:)` → `.size`, `.modificationDate`, `.creationDate`, `.type`. Prefer `URLResourceValues` (`resourceValues(forKeys:)` with `.fileSizeKey`, `.isRegularFileKey`, `.contentModificationDateKey`, `.creationDateKey`) — cleaner.
- Enumerate directory contents with `FileManager.default.contentsOfDirectory(at:includingPropertiesForKeys:options: [.skipsHiddenFiles])` — dotfiles are already skipped by `skipsHiddenFiles`.
- *Ignore* symlinks via `URLResourceValues.isSymbolicLinkKey`.
- Trash: `FileManager.default.trashItem(at:resultingItemURL:)`, passing `nil` for the out-pointer.
- Permanent delete: `FileManager.default.removeItem(at:)`.
- Creating app-support/state dirs: `FileManager.default.createDirectory(..., withIntermediateDirectories: true)`.
- The state file must always be stored in `~/Library/Application Support/pseudocopy/` — never inside the watch dir (the reaper would eat it).

### 4.3 State / settle algorithm (precise pseudocode)

```
scan  = { path: fingerprint }                      // this cycle
prev  = state.scan (last cycle's fingerprints, transient — NOT persisted)
state = the persisted StateStore (path -> StateRecord)

for path, fp in scan:
    if state[path]?.clippedFingerprint == fp: continue        // already processed
    if prev[path] == fp:                                       // settled over two scans
        clip(path)
        mark state[path].clippedFingerprint = fp
    else:
        // not identical to last scan -> still downloading or settling, skip
        continue

// Reaper (runs every cycle)
for path in topLevel regular files:
    if created-or-modified older than ttl AND settled per above:
        trashItem or removeItem; log; prune state[path]
```

To implement `prev` (fingerprints of the previous scan) without persisting a second copy: persist it inside `state.json` as a separate top-level key (`"lastScan"`) and overwrite each cycle. Simpler for a weak model than a side file.

### 4.4 Gotchas that commonly break naive implementations

1. Forgetting `clearContents()` → mixed old+new clipboard contents.
2. Referencing deprecated `NSFilenamesPboardType` symbol → use the string constructor (§4.1).
3. Writing paths with `~` or placeholders in the LaunchAgent plist (plists do not expand `~`) → install script must substitute absolute paths.
4. `launchctl` old syntax — use the modern namespace commands (§5.3), **not** `launchctl load`.
5. Logging every idle cycle → unbounded log growth (§2.5).
6. State file under a watch dir → gets reaped (§4.2).
7. Race between two overlapping invocations → the lock file in §2.6; remember the stale-owner check.
8. Calling `String(contentsOf:)` on binary text-extensions (e.g. UTF-16 `.txt`) without a fallback → always wrap, fall through to *other* on failure.
9. Assuming pasteboard contents persist lazily — materialize data, do not use `NSPasteboardWriting` promises (§4.1).

---

## 5. Installation & LaunchAgent

### 5.1 `Scripts/install.sh` behavior

```sh
#!/usr/bin/env bash
set -euo pipefail
# flags: --prefix DIR (default "$HOME/bin"), plus pass-through to binary: --dir, --ttl
# 1. swift build -c release              (from repo root via the script's own directory)
# 2. mkdir -p "$prefix"; cp .build/release/pseudocopy "$prefix/"
# 3. mkdir -p "$WATCHDIR" (default ~/Temp; config dir/permission 0700)
# 4. exec "$prefix/pseudocopy" install --dir "$WATCHDIR" [--ttl ...]  (writes plist, bootstraps agent)
# Echo final instructions: PATH note for "$prefix" if not already on PATH.
```

Binary install location: `$HOME/bin/pseudocopy` by default. The LaunchAgent points at the *real* absolute path, so PATH does not matter for automation.

### 5.2 LaunchAgent plist template (`~/Library/LaunchAgents/com.pseudocopy.plist`)

The installer substitutes `<ABSOLUTE_…>` at write time from its own resolved paths/`$HOME`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.pseudocopy</string>
  <key>ProgramArguments</key>
  <array>
    <string><ABSOLUTE_BIN_PATH>/pseudocopy</string>
    <string>run</string>
    <string>--dir</string><string><ABSOLUTE_WATCH_DIR></string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string><HOME>/Library/Logs/pseudocopy.log</string>
  <key>StandardErrorPath</key><string><HOME>/Library/Logs/pseudocopy.log</string>
</dict>
</plist>
```

Notes: `StartInterval: 5` gives the "instant" feel with trivial CPU cost (one ~100 ms process per 5 s). `ProcessType: Interactive` keeps pasteboard priority reasonable for a UI-adjacent job (a background-priority pasteboard write can occasionally be throttled). `RunAtLoad` runs the first cycle at login.

### 5.3 launchctl commands (modern API — do not use `launchctl load`)

```sh
uid=$(id -u)
launchctl bootstrap gui/$uid ~/Library/LaunchAgents/com.pseudocopy.plist   # install (or re-install after bootout)
launchctl bootout gui/$uid/com.pseudocopy                                  # uninstall
launchctl kickstart gui/$uid/com.pseudocopy                                # force one cycle now
launchctl print   gui/$uid/com.pseudocopy                                  # status detail
```

`status` should shell out to `launchctl print` and exit 0 when the label is present.

---

## 6. Development process (phases, in order)

> Rule for the builder: after each phase, run the phase's **DoD**. Any failure must be fixed before proceeding. Keep diffs small and commit-complete (the repo is fresh, initialize git in Phase 1).

### Phase 0 — Environment check
Verify and record: `swiftc --version` ≥ 5.9, `sw_vers -productVersion` ≥ 13, `xcode-select -p` present (CLT installed). If missing, report the exact missing prerequisite and stop.

### Phase 1 — Package skeleton
Create `Package.swift`, source layout from §3 with stub types that compile. `swift build` must pass.
**DoD:** `swift build` succeeds; `swift run pseudocopy help` prints the CLI help text from §2.7.
Commit: `git init`, initial commit.

### Phase 2 — CLI + config
Implement flag parsing (`--dir`, `--ttl`, `--verbose`, `--no-trash`, subcommands) with graceful errors (`exit 1` + stderr message). Subcommands return "not implemented" exit codes yet.
**DoD:** `pseudocopy help`, and bogus flags/subcommands fail with a clear message and exit 1.

### Phase 3 — Filesystem core
Implement `fs.swift`: entry scan, fingerprints, classification, settle logic, and `runCycle` with a **no-op** clip step (log what *would* be clipped). Wire `state.swift` load/save (`lastScan` + records) exactly per §4.3.
**DoD (smoke script or manual):** drop `a.txt` into a temp watch dir; run `pseudocopy run --dir <dir> --verbose` twice; the first run logs "settling", the second logs `clip: text <dir>/a.txt`; state.json contains the record.

### Phase 4 — Clipboard writer
Implement `clipboard.swift` per §4.1 recipes. Wire it into `runCycle` (no more no-op). Add the `clip <path>` subcommand.
**DoD:** `pseudocopy clip sample.txt` → `pbpaste` equals the text; `pseudocopy clip sample.png` → pastes into Preview as an image and into Finder as a file copy.

### Phase 5 — Reaper
Implement reap + prune per §2.3 (respect settle-before-delete).
**DoD:** `touch -A -3700 <dir>/old.txt` (mtime 3700 s in the past), run `pseudocopy run --dir <dir> --ttl 3600` → file disappears to Trash (visible in ~/.Trash); verify "settling" files are never reaped (drop a file and run within 5 s with a tiny TTL).

### Phase 6 — installer + status
Implement `installer.swift` (plist generation, bootstrap/bootout/status, `--dir` passthrough, mkdir watch dir) and `Scripts/install.sh`.
**DoD:** run `Scripts/install.sh`; `launchctl print gui/$(id -u)/com.pseudocopy` shows last exit code 0; file lands in `~/Temp` and is on the clipboard within ~10 s; `pseudocopy uninstall` removes it; re-`install` works.

### Phase 7 — Lockfile + logging polish
Implement §2.6 lock, event-only logging, `--verbose`.
**DoD:** two simultaneous `pseudocopy run` invocations do not double-clip (check state + log); log file only grows on events; log lines match §2.5 format.

### Phase 8 — `gen-tests`, smoke script, README, final pass
- `gen-tests` writes the §3 sample set (PNG via base64 constant; jpg/gif/tiff via `sips` re-encode; minimal PDF; binary; `.crdownload` decoy).
- `Scripts/smoke.sh`: builds, creates a sandbox dir, runs the full loop headlessly (`run` + `run` + `clean` with `--ttl 1 --dir /tmp/pseudocopy-smoke`), checks text via `pbpaste` before/after (warn that it clobbers the clipboard; restore `pbpaste` → `pbcopy` around it), checks reaping, checks `.crdownload` exclusion. Exit 0 = all assertions passed, non-zero with a message otherwise.
- Write `README.md`: what it does, install + uninstall commands, how to use (point browser save dialog at `~/Temp`), caveats (§8).
**DoD:** `Scripts/smoke.sh` passes exit 0; README present.

### Final acceptance
All of §7 passes.

---

## 7. Test plan / acceptance criteria

An acceptance run must demonstrate, end-to-end with the LaunchAgent installed:

1. `swift build` clean, no warnings.
2. Text file dropped into watch dir → `pbpaste` returns its content within ~10 s of the write completing.
3. PNG dropped in → pasteable into Preview as an image (manual check).
4. PDF dropped in → pastes into apps that accept PDF data (manual check).
5. Arbitrary binary dropped in → paste into Finder creates a file copy; content survives even after the original is reaped (data is embedded, §4.1).
6. `.crdownload`/`.part`/dotfile → ignored (state store shows no record, clipboard untouched).
7. File older than TTL → gone from watch dir within one cycle; in Trash (default mode).
8. Settle logic: a file grown slowly (e.g. `dd if=/dev/zero of=<dir>/big bs=1m count=50`) is never clipped before completion and never reaped mid-write.
9. Restart persistence: `launchctl bootout` + re-`install` does not re-clip already-processed files; re-downloading the same filename (changed mtime/size) does.
10. `pseudocopy uninstall` cleanly removes agent + plist; watch dir and state remain (state is pruned on next install).

Formatting note for the checklist: every numbered item must pass before the project is considered complete.

---

## 8. Caveats to document in README (already agreed with the user)

- Each new download **replaces** the clipboard (macOS has a single pasteboard).
- Clipboard payloads for text/image/PDF are embedded copies and survive deletion; binary-file payloads survive via embedded data up to 64 MB, above which pasting after reap may fail (the file-object reference requires the source to exist).
- Very large files are best kept out of this folder (clipboard RAM) — nothing breaks, it is just wasteful.
- Manual editing in `~/Temp` — silently deleted after an hour.

## 9. Guardrails for the building agent

- **No third-party packages.** AppKit, Foundation, UniformTypeIdentifiers only.
- **No `sudo`** anywhere in the toolchain (binary → `~/bin`, plist → `~/Library/LaunchAgents`).
- **Never** modify or delete anything outside: the watch dir's top-level files, `~/Library/Application Support/pseudocopy/`, `~/Library/LaunchAgents/com.pseudocopy.plist`, `~/Library/Logs/pseudocopy.log`, `$HOME/bin`, and this project's own directory.
- **Never** run the reaper on directories or on files the state store marks as not-settled.
- If a step fails, fix it or stop with a clear report — do not invent workarounds that violate the spec in this file.
