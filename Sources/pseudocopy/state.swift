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

    // MARK: - Persistence

    mutating func load() {
        guard let data = try? Data(contentsOf: stateFileURL) else {
            file = StateFile()
            return
        }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode(StateFile.self, from: data) {
            file = decoded
        } else {
            Logger.log(.error, "state", "could not decode \(stateFileURL.path); starting from an empty store")
            file = StateFile()
        }
    }

    mutating func save() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: stateFileURL, options: [.atomic])
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

    /// Removes records whose files no longer exist (§2.3).
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
    }
}
