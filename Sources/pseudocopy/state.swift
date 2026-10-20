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

    init(watchDir: URL) {
        self.watchDir = watchDir
        self.namespaceKey = watchDir.standardizedFileURL.resolvingSymlinksInPath().path
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.root = appSupport.appendingPathComponent(Constants.appSupportFolder, isDirectory: true)
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
        guard let data = try? Data(contentsOf: stateFileURL) else {
            file = StateFile()
            lastWritten = nil
            wasReset = true
            return
        }

        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode(StateFile.self, from: data) {
            if decoded.version > Constants.stateVersion {
                // A file from a newer version: do not try to interpret it.
                Logger.log(.error, "state", "state file version \(decoded.version) is newer than the supported \(Constants.stateVersion)")
                file = StateFile()
                wasReset = true
            } else {
                file = decoded
                wasReset = false
            }
        } else {
            file = StateFile()
            wasReset = true
            var recovered = 0
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                recovered = decodeLeniently(json, decoder: decoder)
            } else {
                let backup = stateFileURL.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: backup)
                try? data.write(to: backup)
                Logger.log(.error, "state", "could not decode \(stateFileURL.path); kept a copy at \(backup.path)")
            }
            if recovered > 0 {
                Logger.log(.error, "state", "recovered \(recovered) watch folder(s) from a damaged \(stateFileURL.path)")
            }
        }
        lastWritten = try? encoder.encode(file)
    }

    /// Decodes every namespace separately, so that one broken entry cannot
    /// wipe the rest of the store. Returns the number of recovered folders.
    private mutating func decodeLeniently(_ json: [String: Any], decoder: JSONDecoder) -> Int {
        var recovered = 0

        if let namespaces = json["dirs"] as? [String: Any] {
            for (name, value) in namespaces {
                guard let encoded = try? JSONSerialization.data(withJSONObject: value),
                      let records = try? decoder.decode([String: StateRecord].self, from: encoded) else { continue }
                file.dirs[name] = records
                recovered += 1
            }
        }
        if let namespaces = json["lastScan"] as? [String: Any] {
            for (name, value) in namespaces {
                guard let encoded = try? JSONSerialization.data(withJSONObject: value),
                      let scan = try? decoder.decode([String: Fingerprint].self, from: encoded) else { continue }
                file.lastScan[name] = scan
            }
        }
        return recovered
    }

    /// Writes the store. Nothing is written when the content did not change —
    /// the cycle runs every five seconds, forever.
    mutating func save() throws {
        let data = try encoder.encode(file)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // The folder may have been created with looser permissions before.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        if let last = lastWritten, last == data {
            return
        }
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

    /// Removes records whose files no longer exist (§2.3) and watch folders
    /// that are gone for good.
    mutating func prune(missing: Set<String>) {
        var records = file.dirs[namespaceKey] ?? [:]
        for path in missing {
            records.removeValue(forKey: path)
        }
        file.dirs[namespaceKey] = records

        var scan = file.lastScan[namespaceKey] ?? [:]
        for path in missing {
            scan.removeValue(forKey: path)
        }
        file.lastScan[namespaceKey] = scan

        // Whole namespaces for watch folders that no longer exist.
        for key in file.dirs.keys where !FileManager.default.fileExists(atPath: key) {
            file.dirs.removeValue(forKey: key)
            file.lastScan.removeValue(forKey: key)
        }
    }
}
