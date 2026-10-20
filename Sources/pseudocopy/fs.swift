import Darwin
import Foundation

// PLAN.md §3: fs.swift holds the filesystem core and stays free of AppKit
// imports so that it remains testable on its own.

/// How a file should be represented on the pasteboard (§2.2).
enum FileKind: String {
    case text
    case image
    case pdf
    case other
}

/// The (size, mtime) fingerprint used for the settle check (§2.1).
struct Fingerprint: Codable, Equatable {
    var size: Int
    var mtime: Date
}

/// The outcome of inspecting one directory entry.
enum FileVerification {
    /// Not a candidate at all (directory, symlink, dotfile).
    case ignored
    /// A partial download in progress.
    case partial
    /// Fingerprint unchanged since the previous scan — safe to act on.
    case settled(Fingerprint)
    /// Fingerprint changed since the previous scan — still settling.
    case settling
}

/// One inspected entry of the watch directory.
struct ScanEntry {
    var url: URL
    /// Normalized path, used as the state store key.
    var path: String
    var fingerprint: Fingerprint?
    /// Creation date of the file (as reported by the file system).
    var created: Date?
    /// Modification date of the file.
    var modified: Date?
    var verification: FileVerification
}

// MARK: - Classification

/// Classifies a file by extension, case-insensitively (§2.2).
func classifyFile(_ url: URL) -> FileKind {
    let ext = url.pathExtension.lowercased()
    if ExtensionSets.text.contains(ext) { return .text }
    if ExtensionSets.image.contains(ext) { return .image }
    if ExtensionSets.pdf.contains(ext) { return .pdf }
    return .other
}

/// True when the file name carries a partial-download marker (§2.1).
func partialFileExtension(_ name: String) -> Bool {
    let ext = (name as NSString).pathExtension.lowercased()
    return ExtensionSets.partial.contains(ext)
}

// MARK: - Filesystem access

/// Top level regular files of `dir`: no directories, no symlinks, no dotfiles.
func topLevelEntries(_ dir: URL) throws -> [URL] {
    let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey,
        .fileSizeKey, .contentModificationDateKey, .creationDateKey,
    ]
    let contents = try FileManager.default.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
    )

    var result: [URL] = []
    for url in contents {
        let values = try? url.resourceValues(forKeys: keys)
        if values?.isSymbolicLink == true { continue }
        if values?.isDirectory == true { continue }
        if values?.isRegularFile != true { continue }
        result.append(url)
    }
    return result
}

/// The (size, mtime) fingerprint of a regular file, or nil when the file is
/// not a regular file (or vanished between listing and stat'ing).
func fingerprint(of url: URL) throws -> Fingerprint? {
    let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]
    let values = try url.resourceValues(forKeys: keys)
    guard values.isSymbolicLink != true, values.isRegularFile == true else { return nil }
    guard let size = values.fileSize, let mtime = values.contentModificationDate else { return nil }
    return Fingerprint(size: size, mtime: mtime)
}

/// True when the file is older than the TTL (§2.3). The older of the
/// creation and the modification date decides.
func isExpired(created: Date?, modified: Date?, now: Date, ttl: TimeInterval) -> Bool {
    guard let mtime = modified else { return false }
    let ctime = created ?? mtime
    return min(ctime, mtime).timeIntervalSince(now) < -ttl
}

// MARK: - Paths

/// Normalized state key for a file: absolute, symlink free, no trailing slash.
func normalizedPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
}

/// Human readable path, with the home directory abbreviated to `~`.
func displayPath(_ url: URL) -> String {
    let path = url.path
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

// MARK: - Process lock (§2.6)

/// The result of trying to take the process lock.
enum LockResult {
    /// The lock was taken.
    case acquired
    /// Another cycle is running.
    case held
    /// The lock could not be taken at all — the tool must not pretend to work.
    case failed(String)
}

/// A lock file that keeps two cycles from overlapping.
///
/// The lock file contains the PID of the owning process, but the mutual
/// exclusion itself is done with `flock(2)`: the kernel drops the lock when
/// the owner dies, so a lock file left behind by a killed process can never
/// wedge the tool. Deciding staleness from the PID alone is not safe — the
/// PID may have been recycled by an unrelated process, which would leave
/// pseudocopy silently doing nothing forever.
final class ProcessLock {
    private let url: URL
    private var descriptor: Int32 = -1

    init(url: URL) {
        self.url = url
    }

    /// Tries to take the lock.
    func acquire() -> LockResult {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return .failed("could not create \(url.deletingLastPathComponent().path): \(error.localizedDescription)")
        }

        let handle = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard handle >= 0 else {
            return .failed("could not open \(url.path): \(String(cString: strerror(errno)))")
        }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else {
            // Another cycle is running — leave its lock alone.
            close(handle)
            return .held
        }
        descriptor = handle

        // The PID is informational only; it never decides staleness.
        ftruncate(handle, 0)
        lseek(handle, 0, SEEK_SET)
        let pid = "\(getpid())\n"
        _ = pid.withCString { pointer in
            write(handle, pointer, strlen(pointer))
        }
        return .acquired
    }

    /// Releases the lock. The file itself is left in place on purpose:
    /// unlinking it would race with a process that already opened it.
    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}

// MARK: - Cycle

/// Scans the watch directory and classifies every top level entry.
///
/// A missing watch directory is recreated when its parent still exists (the
/// user may simply have deleted it); when the parent is gone as well the
/// volume is probably not mounted, and the agent stays quiet instead of
/// filling the log every five seconds.
private func scanEntries(_ dir: URL, previous: [String: Fingerprint]) throws -> [ScanEntry] {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory)

    if !exists {
        let parent = dir.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            Logger.verboseLog(.error, "dir", "recreated the watch directory \(dir.path)")
        } else if isRunningAsAgent() {
            // The volume is not mounted — there is nothing to do and nobody to
            // tell: the agent would otherwise log this every five seconds.
            Logger.verboseLog(.error, "dir", "watch directory \(dir.path) is unavailable")
            return []
        } else {
            throw CLIError.usage("watch directory does not exist: \(dir.path)")
        }
    } else if !isDirectory.boolValue {
        throw CLIError.usage("watch directory is not a directory: \(dir.path)")
    }

    var entries: [ScanEntry] = []
    for url in try topLevelEntries(dir) {
        let path = normalizedPath(url)
        if partialFileExtension(url.lastPathComponent) {
            entries.append(ScanEntry(url: url, path: path, fingerprint: nil, created: nil, modified: nil, verification: .partial))
            continue
        }
        // One stat per file: the values are reused for the fingerprint, the
        // expiry check and the settle comparison.
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        guard let size = values?.fileSize, let mtime = values?.contentModificationDate else {
            // The file vanished between the listing and the stat — that is
            // normal, not an error worth aborting the cycle for.
            entries.append(ScanEntry(url: url, path: path, fingerprint: nil, created: nil, modified: nil, verification: .ignored))
            continue
        }
        let fingerprint = Fingerprint(size: size, mtime: mtime)
        let verification: FileVerification = (previous[path] == fingerprint) ? .settled(fingerprint) : .settling
        entries.append(ScanEntry(
            url: url,
            path: path,
            fingerprint: fingerprint,
            created: values?.creationDate,
            modified: mtime,
            verification: verification
        ))
    }
    return entries
}

/// True when this process was started by the LaunchAgent.
func isRunningAsAgent() -> Bool {
    ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == Constants.agentLabel
}

/// True when the reaper may act on a file (§2.3).
///
/// "Settled" means the state store knows the file and its fingerprint did
/// not change since the previous observation — a file that is still being
/// written changes its size or its modification time. A file that was already
/// copied to the pasteboard is known to be complete.
///
/// `force` is used by the explicit `clean` command: there the user asked for
/// the old files to go, so files that were never seen before are reaped too
/// (the file is re-read right before it is moved, so a file that is being
/// written right now is still spared).
private func isSettledForReaping(record: StateRecord?, observed: Fingerprint, force: Bool) -> Bool {
    if force {
        // The user asked for it explicitly. The file is read again right
        // before it is moved, so a file that is being written right now is
        // still spared.
        return true
    }
    guard let record = record else {
        // Never observed before: the state store does not mark it as settled.
        return false
    }
    if record.lastFingerprint == observed { return true }
    if record.clippedFingerprint == observed { return true }
    return false
}


/// One watch + reap cycle (§2.1, §2.3, §4.3).
func runCycle(config: Configuration) throws {
    try performCycle(config: config, clipping: true, force: false)
}

/// The shared cycle: scan → clip → reap → prune → save.
private func performCycle(config: Configuration, clipping: Bool, force: Bool) throws {
    Logger.verbose = config.verbose

    var store = StateStore(watchDir: config.watchDir)

    // Guard against overlapping invocations (§2.6): launchd starts a new
    // cycle every 5 seconds, a slow cycle (a 64 MB embed) could still run.
    // The lock is taken before the state is read, so that two cycles can
    // never work on the same snapshot.
    let lock = ProcessLock(url: store.lockFileURL)
    switch lock.acquire() {
    case .acquired:
        break
    case .held:
        Logger.verboseLog(.cycle, "lock", "another cycle is running — skipping")
        return
    case .failed(let reason):
        // Not being able to lock is not the same as another cycle running:
        // the tool must not pretend that it works.
        Logger.log(.error, "lock", reason)
        throw CLIError.usage("could not acquire the lock: \(reason)")
    }
    defer { lock.release() }

    store.load()
    let previous = store.lastScan
    var records = store.records

    let entries = try scanEntries(config.watchDir, previous: previous)
    let now = Date()

    // --- clip pass -------------------------------------------------------
    if clipping {
        if store.wasReset {
            // The state was lost, so the tool cannot know which of these
            // files are new. They are treated as already handled, so that the
            // whole folder is not copied onto the clipboard one file after
            // the other. A file that is downloaded again has a new fingerprint
            // and is copied then.
            for entry in entries {
                guard let current = entry.fingerprint else { continue }
                var record = records[entry.path] ?? StateRecord(lastFingerprint: current, clippedFingerprint: nil)
                record.lastFingerprint = current
                record.clippedFingerprint = current
                records[entry.path] = record
            }
            Logger.verboseLog(.scan, "state", "the state was rebuilt — the files that were already there are not copied")
        } else {
            for entry in entries {
                guard case .settled = entry.verification, let current = entry.fingerprint else {
                    continue
                }
                if records[entry.path]?.clippedFingerprint == current {
                    Logger.verboseLog(.scan, "file", "\(displayPath(entry.url)) already clipped")
                    continue
                }

                let kind = classifyFile(entry.url)
                let written: FileKind
                do {
                    written = try putOnClipboard(kind: kind, url: entry.url, embedLimit: config.embedLimitBytes)
                } catch {
                    // The file stays unclipped and is retried on the next cycle.
                    Logger.log(.error, "clip", "\(displayPath(entry.url)): \(error.localizedDescription)")
                    continue
                }
                Logger.log(.clip, written.rawValue, displayPath(entry.url))

                var record = records[entry.path] ?? StateRecord(lastFingerprint: current, clippedFingerprint: nil)
                record.lastFingerprint = current
                record.clippedFingerprint = current
                records[entry.path] = record
            }
        }
    }

    // --- reap pass -------------------------------------------------------
    // `records` still holds the fingerprints of the previous scan here, which
    // is exactly the "settled" signal the reaper needs (§2.3).
    var reaped = Set<String>()
    for entry in entries {
        guard let observed = entry.fingerprint else { continue }
        guard isExpired(created: entry.created, modified: entry.modified, now: now, ttl: config.ttl) else { continue }

        let record = records[entry.path]
        guard isSettledForReaping(record: record, observed: observed, force: force) else {
            Logger.verboseLog(.scan, "file", "\(displayPath(entry.url)) expired but not settled, keeping it")
            continue
        }
        // Safety net: the file must not have changed since the scan.
        guard let current = try? fingerprint(of: entry.url), current == observed else {
            Logger.verboseLog(.scan, "file", "\(displayPath(entry.url)) still changing, keeping it")
            continue
        }

        do {
            if config.permanent {
                try FileManager.default.removeItem(at: entry.url)
            } else {
                try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
            }
            reaped.insert(entry.path)
            Logger.log(.reap, "file", displayPath(entry.url))
        } catch {
            Logger.log(.error, "reap", "\(displayPath(entry.url)): \(error.localizedDescription)")
        }
    }
    for path in reaped {
        records.removeValue(forKey: path)
    }

    // --- settle bookkeeping ----------------------------------------------
    var scan: [String: Fingerprint] = [:]
    for entry in entries where !reaped.contains(entry.path) {
        guard let fingerprint = entry.fingerprint else { continue }
        scan[entry.path] = fingerprint
        var record = records[entry.path] ?? StateRecord(lastFingerprint: fingerprint, clippedFingerprint: nil)
        record.lastFingerprint = fingerprint
        records[entry.path] = record

        switch entry.verification {
        case .settling:
            Logger.verboseLog(.scan, "file", "\(displayPath(entry.url)) settling")
        case .settled:
            Logger.verboseLog(.scan, "file", "\(displayPath(entry.url)) settled")
        case .partial:
            Logger.verboseLog(.scan, "part", "\(displayPath(entry.url)) partial download, ignored")
        case .ignored:
            break
        }
    }

    // --- prune + save ----------------------------------------------------
    // Records of files that are gone are dropped (§2.3). Everything that is
    // still on disk is in `scan`, so no extra stat calls are needed.
    let missing = Set(records.keys).subtracting(scan.keys)
    for path in missing {
        records.removeValue(forKey: path)
    }
    store.setRecords(records)
    store.setLastScan(scan)
    store.prune(missing: missing)
    do {
        try store.save()
    } catch {
        Logger.log(.error, "state", "could not save state: \(error.localizedDescription)")
    }
}

/// Resident loop, for foreground development only (§2.7).
func runLoop(config: Configuration, interval: TimeInterval) throws {
    Logger.verbose = config.verbose
    Logger.log(.cycle, "loop", "watching \(displayPath(config.watchDir)) every \(Int(interval))s")
    while true {
        do {
            try runCycle(config: config)
        } catch {
            Logger.log(.error, "cycle", error.localizedDescription)
        }
        Thread.sleep(forTimeInterval: interval)
    }
}

/// Force-reap everything older than the TTL right now (§2.7).
func runClean(config: Configuration) throws {
    // `clean` is an explicit request: files that are older than the TTL go
    // now, even when they were never seen before.
    try performCycle(config: config, clipping: false, force: true)
}

/// Clip files manually, bypassing the settle logic (§2.7).
func clipPaths(_ paths: [String], config: Configuration) throws {
    guard !paths.isEmpty else {
        throw CLIError.usage("clip needs at least one file path")
    }
    for (index, path) in paths.enumerated() {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CLIError.usage("not a file: \(path)")
        }
        let kind = classifyFile(url)
        // The pasteboard is emptied once, so that several files can be put on
        // it at the same time.
        let written = try writeToPasteboard(
            kind: kind,
            url: url,
            embedLimit: config.embedLimitBytes,
            clearing: index == 0
        )
        Logger.log(.clip, written.rawValue, displayPath(url))
    }
}
