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

/// One watch + reap cycle (§2.1, §2.3, §4.3).
func runCycle(config: Configuration) throws {
    Logger.verbose = config.verbose

    var store = StateStore(watchDir: config.watchDir)
    store.load()

    let previous = store.lastScan
    var records = store.records

    let entries = try scanEntries(config.watchDir, previous: previous)
    let now = Date()

    // --- clip pass -------------------------------------------------------
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
        // The pasteboard writer is wired in Phase 4.
        Logger.log(.clip, kind.rawValue, displayPath(entry.url))

        var record = records[entry.path] ?? StateRecord(lastFingerprint: current, clippedFingerprint: nil)
        record.lastFingerprint = current
        record.clippedFingerprint = current
        records[entry.path] = record
    }

    // --- settle bookkeeping ----------------------------------------------
    var scan: [String: Fingerprint] = [:]
    for entry in entries {
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
    var missing = Set<String>()
    for path in records.keys where !FileManager.default.fileExists(atPath: path) {
        missing.insert(path)
    }
    store.prune(missing: missing)
    store.setRecords(records)
    store.setLastScan(scan)
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
    CLI.fail("clean is not implemented yet")
}

/// Clip files manually, bypassing the settle logic (§2.7).
func clipPaths(_ paths: [String], config: Configuration) throws {
    CLI.fail("clip is not implemented yet")
}
