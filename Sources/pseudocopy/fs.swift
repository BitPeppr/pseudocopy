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
func isExpired(_ url: URL, now: Date, ttl: TimeInterval) -> Bool {
    let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
    guard let values = try? url.resourceValues(forKeys: keys) else { return false }
    let mtime = values.contentModificationDate ?? now
    let ctime = values.creationDate ?? mtime
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

/// A PID based lock file that keeps two cycles from overlapping.
///
/// The lock file contains the PID of the owning process. When the file
/// exists, the PID is checked with `kill(pid, 0)`: a live owner means another
/// cycle is running, a dead owner means the lock is stale and can be taken
/// over.
final class ProcessLock {
    private let url: URL
    private var descriptor: Int32 = -1
    private var ownsLock = false

    init(url: URL) {
        self.url = url
    }

    /// Tries to take the lock. Returns false when another process holds it.
    func acquire() -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if createLockFile() {
            ownsLock = true
            return true
        }

        if let pid = readPID(), pid != getpid(), isAlive(pid) {
            // Another cycle is still running.
            return false
        }

        // Stale lock (or our own leftover): remove it and try once more.
        try? FileManager.default.removeItem(at: url)
        if createLockFile() {
            ownsLock = true
            return true
        }
        return false
    }

    /// Removes the lock file again.
    func release() {
        guard ownsLock else { return }
        ownsLock = false
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func createLockFile() -> Bool {
        let handle = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard handle >= 0 else { return false }
        let pid = "\(getpid())\n"
        _ = pid.withCString { pointer in
            write(handle, pointer, strlen(pointer))
        }
        descriptor = handle
        return true
    }

    private func readPID() -> pid_t? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text = text, let value = Int(text), value > 0 else { return nil }
        return pid_t(value)
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

// MARK: - Cycle

/// Scans the watch directory and classifies every top level entry.
private func scanEntries(_ dir: URL, previous: [String: Fingerprint]) throws -> [ScanEntry] {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory)
    guard exists && isDirectory.boolValue else {
        throw CLIError.usage("watch directory does not exist: \(dir.path)")
    }

    var entries: [ScanEntry] = []
    for url in try topLevelEntries(dir) {
        let path = normalizedPath(url)
        if partialFileExtension(url.lastPathComponent) {
            entries.append(ScanEntry(url: url, path: path, fingerprint: nil, verification: .partial))
            continue
        }
        guard let fingerprint = try fingerprint(of: url) else {
            entries.append(ScanEntry(url: url, path: path, fingerprint: nil, verification: .ignored))
            continue
        }
        let verification: FileVerification = (previous[path] == fingerprint) ? .settled(fingerprint) : .settling
        entries.append(ScanEntry(url: url, path: path, fingerprint: fingerprint, verification: verification))
    }
    return entries
}

/// True when the reaper may act on a file (§2.3).
///
/// A file counts as settled when the state store knows it and its content
/// did not grow since the last observation:
/// - the fingerprint is identical to the previous scan (2-scan stable), or
/// - the fingerprint is the one that was clipped, or
/// - the size is unchanged since the last observation (the file is not being
///   written any more — e.g. it was only touched, or a stalled download has
///   stopped growing).
private func isSettledForReaping(record: StateRecord?, observed: Fingerprint) -> Bool {
    guard let record = record else {
        // Never observed before: the state store does not mark it as settled.
        return false
    }
    if record.lastFingerprint == observed { return true }
    if record.clippedFingerprint == observed { return true }
    if record.lastFingerprint.size == observed.size { return true }
    return false
}

/// One watch + reap cycle (§2.1, §2.3, §4.3).
func runCycle(config: Configuration) throws {
    try performCycle(config: config, clipping: true)
}

/// The shared cycle: scan → clip → reap → prune → save.
private func performCycle(config: Configuration, clipping: Bool) throws {
    Logger.verbose = config.verbose

    var store = StateStore(watchDir: config.watchDir)
    store.load()

    // Guard against overlapping invocations (§2.6): launchd starts a new
    // cycle every 5 seconds, a slow cycle (a 64 MB embed) could still run.
    let lock = ProcessLock(url: store.lockFileURL)
    guard lock.acquire() else {
        Logger.verboseLog(.cycle, "lock", "another cycle is running — skipping")
        return
    }
    defer { lock.release() }

    let previous = store.lastScan
    var records = store.records

    let entries = try scanEntries(config.watchDir, previous: previous)
    let now = Date()

    // --- clip pass -------------------------------------------------------
    if clipping {
        for entry in entries {
            guard case .settled = entry.verification, let current = entry.fingerprint else {
                continue
            }
            if records[entry.path]?.clippedFingerprint == current {
                Logger.verboseLog(.scan, "file", "\(displayPath(entry.url)) already clipped")
                continue
            }
            if isExpired(entry.url, now: now, ttl: config.ttl) {
                // About to be reaped — do not put it on the pasteboard.
                Logger.verboseLog(.scan, "file", "\(displayPath(entry.url)) expired, not clipping")
                continue
            }

            let kind = classifyFile(entry.url)
            let written: FileKind
            do {
                written = try putOnClipboard(kind: kind, url: entry.url, embedLimit: config.embedLimitBytes)
            } catch {
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

    // --- reap pass -------------------------------------------------------
    // `records` still holds the fingerprints of the previous scan here, which
    // is exactly the "settled" signal the reaper needs (§2.3).
    var reaped = Set<String>()
    for entry in entries {
        guard let observed = entry.fingerprint else { continue }
        guard isExpired(entry.url, now: now, ttl: config.ttl) else { continue }

        let record = records[entry.path]
        guard isSettledForReaping(record: record, observed: observed) else {
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
    // Records of files that no longer exist are dropped (§2.3).
    var missing = Set<String>()
    for path in records.keys where !FileManager.default.fileExists(atPath: path) {
        missing.insert(path)
    }
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
    try performCycle(config: config, clipping: false)
}

/// Clip files manually, bypassing the settle logic (§2.7).
func clipPaths(_ paths: [String], config: Configuration) throws {
    guard !paths.isEmpty else {
        throw CLIError.usage("clip needs at least one file path")
    }
    for path in paths {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CLIError.usage("not a file: \(path)")
        }
        let kind = classifyFile(url)
        let written = try putOnClipboard(kind: kind, url: url, embedLimit: config.embedLimitBytes)
        Logger.log(.clip, written.rawValue, displayPath(url))
    }
}
