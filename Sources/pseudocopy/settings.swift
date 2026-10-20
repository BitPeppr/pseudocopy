import Foundation

// PLAN.md §3: settings.swift — the user settings file.
//
// Every knob the tool has lives in one JSON file next to the state store.
// The command line always wins over the file, so a single cycle can run with
// different settings without changing anything permanent — and a service
// managed by Homebrew picks the settings up without being reinstalled.
//
// Precedence: command line > PSEUDOCOPY_STATE_ROOT (state store only) >
// settings file > built-in default.

/// The persisted settings.
///
/// A `nil` value means "not set": the built-in default applies. The file is
/// written with only the keys the user actually changed.
struct Settings: Codable {
    var version: Int = 1
    /// The watched folder.
    var dir: String?
    /// Reaper time-to-live in seconds.
    var ttl: Double?
    /// Seconds between two cycles.
    var interval: Double?
    /// Delete permanently instead of moving files to the Trash.
    var permanent: Bool?
    /// Log every cycle, not just events.
    var verbose: Bool?
    /// Where the agent writes its log.
    var logPath: String?
    /// Where the state store (state.json, lock) lives.
    var stateDir: String?
    /// Largest text file that is embedded as text.
    var textLimit: Int?
    /// Largest generic file whose bytes are embedded.
    var embedLimit: Int?
    /// Largest image or PDF that is materialised.
    var materialiseLimit: Int?

    /// True when no setting was changed.
    var isEmpty: Bool {
        dir == nil && ttl == nil && interval == nil && permanent == nil
            && verbose == nil && logPath == nil && stateDir == nil
            && textLimit == nil && embedLimit == nil && materialiseLimit == nil
    }
}

/// One settable setting.
enum SettingKey: String, CaseIterable {
    case dir
    case ttl
    case interval
    case permanent
    case verbose
    case logPath = "log-path"
    case stateDir = "state-dir"
    case textLimit = "text-limit"
    case embedLimit = "embed-limit"
    case materialiseLimit = "materialise-limit"

    /// One-line description, shown by `pseudocopy config list`.
    var help: String {
        switch self {
        case .dir: return "the folder that is watched"
        case .ttl: return "how long a file may stay before it is reaped (seconds)"
        case .interval: return "how often the folder is checked (seconds)"
        case .permanent: return "delete files permanently instead of using the Trash"
        case .verbose: return "log every cycle, not just events"
        case .logPath: return "where the agent writes its log"
        case .stateDir: return "where the state store lives"
        case .textLimit: return "largest text file that is embedded as text (bytes)"
        case .embedLimit: return "largest generic file whose bytes are embedded (bytes)"
        case .materialiseLimit: return "largest image or PDF that is materialised (bytes)"
        }
    }

    /// The flag that sets the same value for a single invocation.
    var flag: String {
        "--" + rawValue
    }
}

/// The settings file.
enum SettingsStore {
    /// The directory that holds the settings file.
    ///
    /// `PSEUDOCOPY_STATE_ROOT` moves it (and the state store) somewhere else.
    /// It exists so that the smoke test can run against a private store
    /// without touching the live one.
    static var rootDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["PSEUDOCOPY_STATE_ROOT"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath).standardizedFileURL
        }
        return defaultRootDirectory
    }

    /// The default location: `~/Library/Application Support/pseudocopy`.
    static var defaultRootDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent(Constants.appSupportFolder, isDirectory: true)
    }

    /// The settings file itself.
    static var fileURL: URL {
        rootDirectory.appendingPathComponent(Constants.settingsFileName, isDirectory: false)
    }

    /// Reads the settings. A damaged file is kept for diagnosis and the
    /// built-in defaults apply — the tool must not refuse to run because of
    /// a settings file it wrote itself.
    static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL) else { return Settings() }

        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode(Settings.self, from: data) {
            return decoded
        }

        let backup = fileURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backup)
        try? data.write(to: backup, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        Logger.log(.error, "settings", "could not read \(fileURL.path); kept a copy at \(backup.path) — using the defaults")
        return Settings()
    }

    /// Writes the settings atomically.
    static func save(_ settings: Settings) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootDirectory.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: [.atomic])
        // The settings name the folders the tool may delete from.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Removes the settings file.
    static func remove() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}
