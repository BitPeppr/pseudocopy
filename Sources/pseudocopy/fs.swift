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

/// Canonical absolute path for a file or directory.
///
/// `URL.resolvingSymlinksInPath()` deliberately leaves `/var` alone, while
/// the kernel and `pwd -P` report `/private/var` — the same folder under two
/// spellings. `realpath(3)` gives one spelling for both the watch folder and
/// its files, which matters because these paths are state-store keys.
func canonicalPath(_ url: URL) -> String {
    let standardized = url.standardizedFileURL
    let fileManager = FileManager.default

    if fileManager.fileExists(atPath: standardized.path) {
        if let resolved = realpath(standardized.path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
    } else {
        // A missing leaf (the watch folder before `install` creates it) still
        // needs the canonical prefix of its parent.
        let parent = standardized.deletingLastPathComponent()
        if fileManager.fileExists(atPath: parent.path),
           let resolvedParent = realpath(parent.path, nil) {
            defer { free(resolvedParent) }
            return URL(fileURLWithPath: String(cString: resolvedParent))
                .appendingPathComponent(standardized.lastPathComponent).path
        }
    }
    return standardized.path
}

/// Human readable path, with the home directory abbreviated to `~`.
///
/// Newlines and tabs are escaped: a file name may contain them, and they
/// would break the one-line-per-event log format (§2.5).
func displayPath(_ url: URL) -> String {
    let path = url.path
    let home = NSHomeDirectory()
    var shown: String
    if path == home {
        shown = "~"
    } else if path.hasPrefix(home + "/") {
        shown = "~" + path.dropFirst(home.count)
    } else {
        shown = path
    }
    return shown
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
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

/// What the scan found.
private enum ScanOutcome {
    /// The folder was read; these are its top-level entries.
    case entries([ScanEntry])
    /// The folder was missing and has just been recreated. The cycle is
    /// skipped so that the empty folder does not immediately prune the
    /// history of a folder that was renamed or unmounted for a moment.
    case recreated(URL)
    /// The folder cannot be observed (unmounted volume, unreadable parent).
    /// The state must not be touched: an empty listing is not an empty folder.
    case unavailable(URL)
}

/// Scans the watch directory and classifies every top level entry.
///
/// A missing watch directory is recreated when its parent still exists (the
/// user may simply have deleted it); when the parent is gone as well the
/// volume is probably not mounted, and the agent stays quiet instead of
/// filling the log every five seconds.
private func scanEntries(_ dir: URL, previous: [String: Fingerprint]) throws -> ScanOutcome {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory)

    if !exists {
        let parent = dir.deletingLastPathComponent()
        // A folder under /Volumes is the convention for an external drive:
        // if it is gone, the volume is probably not mounted, and creating it
        // again would put a stray folder on the root volume.
        let isVolumePath = parent.path == "/Volumes" || parent.path.hasPrefix("/Volumes/")
        if !isVolumePath,
           FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
                Logger.verboseLog(.error, "dir", "recreated the watch directory \(dir.path)")
                return .recreated(dir)
            } catch {
                Logger.verboseLog(.error, "dir", "could not recreate \(dir.path): \(error.localizedDescription)")
            }
        }
        if isRunningAsAgent() {
            // The volume is not mounted — there is nothing to do and nobody
            // to tell: the agent would otherwise log this every five seconds.
            Logger.verboseLog(.error, "dir", "watch directory \(dir.path) is unavailable — skipping this cycle")
            return .unavailable(dir)
        }
        throw CLIError.usage("watch directory does not exist: \(dir.path)")
    } else if !isDirectory.boolValue {
        throw CLIError.usage("watch directory is not a directory: \(dir.path)")
    }

    let urls: [URL]
    do {
        urls = try topLevelEntries(dir)
    } catch {
        if isRunningAsAgent() {
            Logger.verboseLog(.error, "dir", "cannot read \(dir.path): \(error.localizedDescription)")
            return .unavailable(dir)
        }
        throw error
    }

    // One canonical prefix for every key: the namespace and the file keys
    // must use the same `/private/var` spelling.
    let namespace = canonicalPath(dir)
    var entries: [ScanEntry] = []
    for url in urls {
        let path = namespace + "/" + url.lastPathComponent
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
    return .entries(entries)
}

/// True when this process was started by a LaunchAgent.
///
/// Homebrew 5 names its service `sh.brew.<formula>` and older versions used
/// `homebrew.mxcl.<formula>`; both must be recognised, otherwise the quiet
/// "volume is not mounted" path is dead code on the recommended install.
func isRunningAsAgent() -> Bool {
    guard let service = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] else { return false }
    let labels = [Constants.agentLabel] + Constants.homebrewAgentLabels
    return labels.contains { service == $0 || service.hasSuffix("/" + $0) }
}

/// Keeps the agent log private. Launchd creates the file with the default
/// umask (0644); the built-in installer chmods it, but `brew services` never
/// runs that code. The log lists the names of the files that were copied.
private func ensureLogIsPrivate() {
    let path = AgentPaths.logURL.path
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let permissions = attributes[.posixPermissions] as? NSNumber,
          permissions.intValue & 0o777 != 0o600 else { return }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}

/// True when the reaper may act on a file (§2.3).
///
/// "Settled" means the state store knows the file and its fingerprint did
/// not change since the previous observation — a file that is still being
/// written changes its size or its modification time. A file that was already
/// copied to the pasteboard is known to be complete.
///
/// `force` is used by the explicit `clean` command: the user asked for the
/// old files to go now, so files that were never seen before are reaped too.
/// The reaper re-stats the file immediately before moving it, which catches
/// changes during the scan, but `clean` does not promise to spare a file that
/// is being written at that exact moment.
private func isSettledForReaping(record: StateRecord?, observed: Fingerprint, force: Bool) -> Bool {
    if force {
        // The user asked for it explicitly; the fresh stat before the move
        // still catches files that changed during the scan. It is not a
        // guarantee against a file that is being written at this instant.
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
    if isRunningAsAgent() {
        ensureLogIsPrivate()
    }

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
    if store.isBlockedByNewerVersion {
        // `load` has already explained why. Leave the lock and the file alone.
        return
    }
    let previous = store.lastScan
    var records = store.records

    let outcome = try scanEntries(config.watchDir, previous: previous)
    let entries: [ScanEntry]
    switch outcome {
    case .entries(let scanned):
        entries = scanned
    case .recreated, .unavailable:
        // The folder could not be observed (or was just recreated). Do not
        // prune, mark or save anything: an empty listing is not an empty
        // folder, and wiping the namespace would re-clip the whole folder
        // when an external volume is mounted again.
        return
    }
    let now = Date()

    // Paths whose clip failed in this cycle. They stay out of the reaper so
    // that content which never reached the pasteboard is not deleted.
    var clipFailures = Set<String>()

    // --- clip pass -------------------------------------------------------
    if clipping {
        if store.wasReset {
            // The state was lost, so the tool cannot know which of these
            // files are new. Treat every existing file as a leftover: the
            // folder is not emptied onto the clipboard one file after the
            // other. Files already older than the TTL are still reaped below;
            // the install warning tells the user about that.
            for entry in entries {
                guard let current = entry.fingerprint else { continue }
                var record = records[entry.path] ?? StateRecord(lastFingerprint: current, clippedFingerprint: nil)
                record.lastFingerprint = current
                record.clippedFingerprint = current
                records[entry.path] = record
            }
            let existing = entries.filter { $0.fingerprint != nil }.count
            let expired = entries.filter {
                guard $0.fingerprint != nil else { return false }
                return isExpired(created: $0.created, modified: $0.modified, now: now, ttl: config.ttl)
            }.count
            Logger.log(.state, "state", "the state was rebuilt — \(existing) existing file(s) are treated as leftovers and are not copied")
            if expired > 0 {
                Logger.log(.state, "state", "\(expired) of them are already older than the TTL and will be reaped")
            }
        } else {
            var candidates: [(entry: ScanEntry, fingerprint: Fingerprint)] = []
            for entry in entries {
                guard case .settled = entry.verification, let current = entry.fingerprint else {
                    continue
                }
                if records[entry.path]?.clippedFingerprint == current {
                    Logger.verboseLog(.scan, "file", "\(displayPath(entry.url)) already handled")
                    continue
                }
                candidates.append((entry, current))
            }

            if !candidates.isEmpty {
                do {
                    let batch = try putFilesOnClipboardBestEffort(
                        kinds: candidates.map { classifyFile($0.entry.url) },
                        urls: candidates.map { $0.entry.url },
                        embedLimit: config.embedLimitBytes
                    )
                    for (index, candidate) in candidates.enumerated() {
                        guard let written = batch.kinds[index] else {
                            clipFailures.insert(candidate.entry.path)
                            if store.shouldReportError(path: candidate.entry.path) {
                                let reason = batch.failures.first(where: { $0.index == index })?.error.localizedDescription
                                    ?? "could not be read"
                                Logger.log(.error, "clip", "\(displayPath(candidate.entry.url)): \(reason)")
                            }
                            store.noteError(path: candidate.entry.path)
                            continue
                        }
                        Logger.log(.clip, written.rawValue, displayPath(candidate.entry.url))
                        store.clearError(path: candidate.entry.path)

                        var record = records[candidate.entry.path]
                            ?? StateRecord(lastFingerprint: candidate.fingerprint, clippedFingerprint: nil)
                        record.lastFingerprint = candidate.fingerprint
                        record.clippedFingerprint = candidate.fingerprint
                        records[candidate.entry.path] = record
                    }
                } catch {
                    // The pasteboard transaction itself failed: none of the
                    // batch was delivered, so none may be reaped this cycle.
                    for candidate in candidates {
                        clipFailures.insert(candidate.entry.path)
                        store.noteError(path: candidate.entry.path)
                    }
                    Logger.log(.error, "clip", "could not write the pasteboard: \(error.localizedDescription)")
                }
            }
        }
    }

    // Persist the clip results before reaping. If the process dies during the
    // reap pass, the next cycle must not clip the same files again and
    // overwrite whatever the user copied in the meantime.
    store.setRecords(records)
    do {
        try store.save()
    } catch {
        Logger.log(.error, "state", "could not save state: \(error.localizedDescription)")
    }

    // --- reap pass -------------------------------------------------------
    // `records` still holds the fingerprints of the previous scan here, which
    // is exactly the "settled" signal the reaper needs (§2.3).
    var reaped = Set<String>()
    for entry in entries {
        guard let observed = entry.fingerprint else { continue }
        guard !clipFailures.contains(entry.path) else {
            Logger.verboseLog(.scan, "file", "\(displayPath(entry.url)) could not be clipped, keeping it")
            continue
        }
        guard isExpired(created: entry.created, modified: entry.modified, now: now, ttl: config.ttl) else { continue }

        let record = records[entry.path]
        guard isSettledForReaping(record: record, observed: observed, force: force) else {
            Logger.verboseLog(.scan, "file", "\(displayPath(entry.url)) expired but not settled, keeping it")
            continue
        }
        // Safety net: the file must not have changed since the scan. A fresh
        // URL is used on purpose — the resource values of the URL that came
        // from the directory listing are cached, so asking the same object
        // again would return the values from the scan and never notice a
        // change.
        let fresh = URL(fileURLWithPath: entry.url.path)
        guard let current = try? fingerprint(of: fresh), current == observed else {
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
    store.markSeen()
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
    // now, even when they were never seen before. It deliberately bypasses
    // the settle rule — do not run it while a download is in progress.
    try performCycle(config: config, clipping: false, force: true)
}

/// Clip files manually, bypassing the settle logic (§2.7).
func clipPaths(_ paths: [String], config: Configuration) throws {
    guard !paths.isEmpty else {
        throw CLIError.usage("clip needs at least one file path")
    }

    var urls: [URL] = []
    var kinds: [FileKind] = []
    var failures = 0
    for path in paths {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            // One bad path does not stop the others.
            Logger.log(.error, "clip", "not a file: \(path)")
            failures += 1
            continue
        }
        urls.append(url)
        kinds.append(classifyFile(url))
    }
    guard !urls.isEmpty else {
        throw CLIError.usage("none of the given paths is a file")
    }

    // One transaction for all files: a pasteboard holds one value per type,
    // but every file is offered as a file reference.
    let written = try putFilesOnClipboard(kinds: kinds, urls: urls, embedLimit: config.embedLimitBytes)
    for (index, url) in urls.enumerated() {
        Logger.log(.clip, written[index].rawValue, displayPath(url))
    }
    if failures > 0 {
        throw CLIError.usage("\(failures) path(s) could not be clipped")
    }
}
