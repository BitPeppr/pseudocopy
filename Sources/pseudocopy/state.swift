import Foundation

// PLAN.md §3: state.swift — persisted settle/clip bookkeeping (§4.3).

/// Per-path bookkeeping.
struct StateRecord: Codable {
    /// Fingerprint observed during the previous scan.
    var lastFingerprint: Fingerprint
    /// Fingerprint of the content that was last copied to the pasteboard.
    var clippedFingerprint: Fingerprint?
}

/// On-disk representation of `state.json`.
private struct StateFile: Codable {
    var version: Int = 1
    /// watch dir -> path -> fingerprint, as of the previous cycle.
    var lastScan: [String: [String: Fingerprint]] = [:]
    /// watch dir -> path -> record.
    var dirs: [String: [String: StateRecord]] = [:]
    /// watch dir -> when it was last seen. A watch folder that is only
    /// temporarily gone (an unmounted volume) keeps its history for a while.
    var seen: [String: Date] = [:]
    /// path -> when the last clip error was reported, to keep the log quiet.
    var clipErrors: [String: Date] = [:]
}

/// The persisted state store, namespaced per watch directory (§2.7).
struct StateStore {
    /// `~/Library/Application Support/pseudocopy`
    let root: URL
    /// The watch directory this store instance operates on.
    let watchDir: URL
    /// Namespace key for the current watch directory.
    let namespaceKey: String

    private var file: StateFile
    /// The bytes that are currently on disk, to avoid rewriting them (§2.5).
    private var lastWritten: Data?
    /// True when the store had to be built from scratch because the file was
    /// missing or damaged — every file then looks brand new.
    private(set) var wasReset = false
    /// True when the state file was written by a newer pseudocopy. The cycle
    /// must not touch it: overwriting it would discard a newer version's
    /// history (and could re-clip or reap files after a downgrade).
    private(set) var isBlockedByNewerVersion = false
    /// How long a watch folder may be gone before its history is dropped.
    private static let namespaceGrace: TimeInterval = 24 * 3600

    /// - Parameter root: where `state.json` and the lock live. The caller
    ///   decides — the settings file can move the store somewhere else.
    init(watchDir: URL, root: URL? = nil) {
        self.watchDir = watchDir
        self.namespaceKey = canonicalPath(watchDir)
        self.root = root ?? SettingsStore.defaultRootDirectory
        self.file = StateFile()
    }

    var stateFileURL: URL {
        root.appendingPathComponent(Constants.stateFileName, isDirectory: false)
    }

    var lockFileURL: URL {
        root.appendingPathComponent(Constants.lockFileName, isDirectory: false)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    // MARK: - Persistence

    /// Loads the store. A damaged file never takes the other watch folders
    /// down with it: every namespace is decoded on its own, and a file that
    /// cannot be parsed at all is kept as `.corrupt` for diagnosis.
    mutating func load() {
        isBlockedByNewerVersion = false
        guard let data = try? Data(contentsOf: stateFileURL) else {
            file = StateFile()
            lastWritten = nil
            wasReset = true
            return
        }

        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode(StateFile.self, from: data) {
            if decoded.version > Constants.stateVersion {
                // A file from a newer version: do not interpret it, and above
                // all do not overwrite it. The cycle stops instead.
                Logger.log(.error, "state", "state file version \(decoded.version) is newer than the supported \(Constants.stateVersion) — skipping this cycle")
                file = StateFile()
                lastWritten = nil
                wasReset = false
                isBlockedByNewerVersion = true
                return
            } else {
                file = decoded
                // A watch folder that the store has never seen is unknown, not
                // damaged — its files must not be copied all at once either.
                wasReset = file.dirs[namespaceKey] == nil && file.lastScan[namespaceKey] == nil
            }
        } else {
            file = StateFile()
            wasReset = true
            var recovered = 0
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                recovered = decodeLeniently(json, decoder: decoder)
            }
            // Always keep the evidence — a file with the wrong shape is the
            // interesting kind of damage.
            keepCorruptCopy(data)
            if recovered > 0 {
                Logger.log(.error, "state", "recovered \(recovered) watch folder(s) from a damaged \(stateFileURL.path)")
            }
            // If *this* watch folder survived, its bookkeeping is still good
            // and its files must not be treated as new.
            if file.dirs[namespaceKey] != nil || file.lastScan[namespaceKey] != nil {
                wasReset = false
            }
        }

        // A state file from an older version (or one recovered leniently)
        // may have no `seen` entry. Give those namespaces the full grace
        // period instead of treating them as ancient and pruning immediately.
        let now = Date()
        for key in file.dirs.keys where file.seen[key] == nil {
            file.seen[key] = now
        }

        lastWritten = try? encoder.encode(file)
    }

    /// Decodes every namespace separately, so that one broken entry cannot
    /// wipe the rest of the store. Returns the number of recovered folders.
    private mutating func decodeLeniently(_ json: [String: Any], decoder: JSONDecoder) -> Int {
        var recovered = 0

        if let namespaces = json["dirs"] as? [String: Any] {
            for (name, value) in namespaces {
                guard let encoded = StateStore.lenientData(value),
                      let records = try? decoder.decode([String: StateRecord].self, from: encoded) else {
                    Logger.log(.error, "state", "could not read the records of a watch folder; it was skipped")
                    continue
                }
                file.dirs[name] = records
                recovered += 1
            }
        }
        if let namespaces = json["lastScan"] as? [String: Any] {
            for (name, value) in namespaces {
                guard let encoded = StateStore.lenientData(value),
                      let scan = try? decoder.decode([String: Fingerprint].self, from: encoded) else {
                    Logger.log(.error, "state", "could not read the scan of a watch folder; it was skipped")
                    continue
                }
                file.lastScan[name] = scan
            }
        }
        // `JSONSerialization` turns the encoded dates into `NSNumber`, not
        // `Date`; casting straight to `[String: Date]` always fails and would
        // silently drop the namespace grace information. `JSONEncoder`'s
        // default strategy stores seconds since 2001-01-01 (the reference
        // date), not since 1970.
        if let seen = json["seen"] as? [String: Any] {
            for (key, value) in seen {
                guard let number = value as? NSNumber else { continue }
                file.seen[key] = Date(timeIntervalSinceReferenceDate: number.doubleValue)
            }
        }
        if let errors = json["clipErrors"] as? [String: Any] {
            for (key, value) in errors {
                guard let number = value as? NSNumber else { continue }
                file.clipErrors[key] = Date(timeIntervalSinceReferenceDate: number.doubleValue)
            }
        }
        return recovered
    }

    /// Re-serialises one namespace.
    ///
    /// `JSONSerialization.data(withJSONObject:)` raises an Objective-C
    /// exception — which `try?` cannot catch, and which would abort the
    /// process — when the value is not a container. `isValidJSONObject`
    /// rejects those values without raising.
    private static func lenientData(_ value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value)
    }

    /// Keeps a damaged state file for diagnosis.
    private func keepCorruptCopy(_ data: Data) {
        let backup = stateFileURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backup)
        try? data.write(to: backup, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        Logger.log(.error, "state", "could not decode \(stateFileURL.path); kept a copy at \(backup.path)")
    }

    /// Writes the store. Nothing is written when the content did not change —
    /// the cycle runs every five seconds, forever.
    mutating func save() throws {
        let data = try encoder.encode(file)
        // Nothing to write when the content did not change — the cycle runs
        // every five seconds, forever. The file-exists check covers a state
        // file that was removed behind our back.
        if let last = lastWritten, last == data,
           FileManager.default.fileExists(atPath: stateFileURL.path) {
            return
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // The folder may have been created with looser permissions before.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try data.write(to: stateFileURL, options: [.atomic])
        // The state file lists every file that was ever clipped — keep it
        // private to the user.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFileURL.path)
        lastWritten = data
    }

    // MARK: - Access

    /// Fingerprints recorded by the previous cycle for the current watch dir.
    var lastScan: [String: Fingerprint] {
        file.lastScan[namespaceKey] ?? [:]
    }

    /// Records for the current watch dir.
    var records: [String: StateRecord] {
        file.dirs[namespaceKey] ?? [:]
    }

    mutating func setRecords(_ records: [String: StateRecord]) {
        file.dirs[namespaceKey] = records
    }

    mutating func setLastScan(_ scan: [String: Fingerprint]) {
        file.lastScan[namespaceKey] = scan
    }

    /// Records that this watch folder was seen in this cycle.
    ///
    /// The timestamp is only used for the 24-hour namespace grace period, so
    /// updating it every five seconds would rewrite the state file forever
    /// without changing the outcome. One-hour granularity is plenty.
    mutating func markSeen(at date: Date = Date()) {
        if let last = file.seen[namespaceKey],
           date.timeIntervalSince(last) < Constants.seenRefreshInterval {
            return
        }
        file.seen[namespaceKey] = date
    }

    /// True when the clip error for this path should be written to the log.
    /// Repeated failures are only reported once a minute (§2.5).
    func shouldReportError(path: String, now: Date = Date()) -> Bool {
        guard let last = file.clipErrors[path] else { return true }
        return now.timeIntervalSince(last) >= 60
    }

    /// Remembers that a clip error was reported.
    mutating func noteError(path: String, at date: Date = Date()) {
        file.clipErrors[path] = date
    }

    /// Forgets a previous clip error after the file was delivered.
    mutating func clearError(path: String) {
        file.clipErrors.removeValue(forKey: path)
    }

    /// Removes records whose files no longer exist (§2.3) and watch folders
    /// that are gone for good.
    mutating func prune(missing: Set<String>) {
        var records = file.dirs[namespaceKey] ?? [:]
        for path in missing {
            records.removeValue(forKey: path)
            file.clipErrors.removeValue(forKey: path)
        }
        file.dirs[namespaceKey] = records

        var scan = file.lastScan[namespaceKey] ?? [:]
        for path in missing {
            scan.removeValue(forKey: path)
        }
        file.lastScan[namespaceKey] = scan

        // Whole namespaces for watch folders that no longer exist — but only
        // after they have been gone for a while, so that an unmounted volume
        // does not lose its history.
        let now = Date()
        for key in Array(file.dirs.keys) where !FileManager.default.fileExists(atPath: key) {
            let lastSeen = file.seen[key] ?? now
            guard now.timeIntervalSince(lastSeen) >= StateStore.namespaceGrace else { continue }
            file.dirs.removeValue(forKey: key)
            file.lastScan.removeValue(forKey: key)
            file.seen.removeValue(forKey: key)
        }

        // Clip errors are only needed for log throttling; do not keep them
        // for paths that have been gone for more than a day.
        let cutoff = now.addingTimeInterval(-24 * 3600)
        file.clipErrors = file.clipErrors.filter { $0.value >= cutoff }
    }
}
