import Foundation

/// Timing and sizing constants (§2.4).
enum Constants {
    /// Seconds between cycles when running in resident `loop` mode.
    /// The LaunchAgent uses the same value as its `StartInterval`.
    static let cycleInterval: TimeInterval = 5

    /// Default reaper time-to-live: one hour.
    static let defaultTTL: TimeInterval = 3600

    /// Maximum size of a file whose raw bytes get embedded in the pasteboard.
    static let embedLimitBytes: Int = 64 << 20

    /// LaunchAgent label.
    static let agentLabel = "com.pseudocopy"

    /// Folder name inside `~/Library/Application Support`.
    static let appSupportFolder = "pseudocopy"

    /// State file name inside the app-support folder.
    static let stateFileName = "state.json"

    /// Lock file name inside the app-support folder.
    static let lockFileName = "lock"

    /// LaunchAgent plist name inside `~/Library/LaunchAgents`.
    static let plistFileName = "com.pseudocopy.plist"

    /// Schema version of the state file.
    static let stateVersion = 1
}

/// Event kinds used in the log format (§2.5).
enum LogEvent: String {
    case clip
    case reap
    case scan
    case cycle
    case state
    case error
    case info
}

/// Event logger (§2.5). Everything is written to stderr, which the
/// LaunchAgent redirects into `~/Library/Logs/pseudocopy.log`.
enum Logger {
    /// `true` while verbose logging is enabled.
    static var verbose = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Logs an event. `event` is one of the `LogEvent` kinds, `kind` a short
    /// label for the subject and `message` the detail.
    static func log(_ event: LogEvent, _ kind: String, _ message: String) {
        // The kind is padded to a fixed width so that the log stays aligned:
        // "2026-10-20 14:03:12 [clip] text  ~/Temp/notes.txt"
        let paddedKind = kind.count >= 5 ? kind : kind + String(repeating: " ", count: 5 - kind.count)
        let line = "\(dateFormatter.string(from: Date())) [\(event.rawValue)] \(paddedKind) \(message)"
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Logs only when verbose mode is on (§2.5: stay silent when idle).
    static func verboseLog(_ event: LogEvent, _ kind: String, _ message: String) {
        guard Logger.verbose else { return }
        log(event, kind, message)
    }
}

/// Extension sets used for "smart by type" classification (§2.2).
enum ExtensionSets {
    /// Extensions treated as UTF-8 text. Anything that fails to decode as
    /// UTF-8 falls through to the generic *Other* representation.
    ///
    /// "rtf" is deliberately absent: RTF is not UTF-8 text, pasting it as
    /// plain text would put the markup on the clipboard instead of the
    /// document.
    static let text: Set<String> = [
        "txt", "text", "md", "markdown", "log", "csv", "tsv", "json", "jsonl",
        "yaml", "yml", "toml", "ini", "cfg", "conf", "plist", "xml", "html",
        "htm", "css", "scss", "sh", "bash", "zsh", "fish", "py", "rb", "php",
        "pl", "lua", "swift", "js", "mjs", "ts", "tsx", "jsx", "c", "h", "cc",
        "cpp", "hpp", "m", "mm", "java", "kt", "go", "rs", "sql", "diff",
        "patch", "tex", "srt", "vtt", "ics", "rst", "adoc", "properties",
    ]

    /// Extensions treated as images.
    static let image: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tif", "tiff", "heic",
    ]

    /// Extensions treated as PDF documents.
    static let pdf: Set<String> = [
        "pdf",
    ]

    /// Extensions that mark an in-progress (partial) download. Files with
    /// these extensions are ignored entirely (§2.1).
    static let partial: Set<String> = [
        "crdownload", "part", "download", "tmp", "partial",
    ]
}
