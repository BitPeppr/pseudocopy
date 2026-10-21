import Foundation

/// Timing and sizing constants (§2.4).
enum Constants {
    /// The released version. `Scripts/release.sh` reads this value and
    /// refuses to publish a tag that does not match it.
    static let version = "1.2.1"

    /// Seconds between cycles when running in resident `loop` mode.
    /// The LaunchAgent uses the same value as its `StartInterval`.
    static let cycleInterval: TimeInterval = 5

    /// Default reaper time-to-live: one hour.
    static let defaultTTL: TimeInterval = 3600

    /// How often the `seen` timestamp of a watch folder is refreshed. It only
    /// drives the 24-hour namespace grace, so a coarse value keeps the state
    /// file from being rewritten on every idle cycle.
    static let seenRefreshInterval: TimeInterval = 3600

    /// Maximum size of a file whose raw bytes get embedded in the pasteboard.
    static let embedLimitBytes: Int = 64 << 20

    /// Maximum size of a text file that is embedded as text. Text costs about
    /// three times its size in memory (the bytes, the decoded string and the
    /// pasteboard's own copy), so the limit is much lower than for binary data.
    static let textLimitBytes: Int = 16 << 20

    /// Maximum size of an image or PDF that is materialised. Such a file is
    /// copied into the pasteboard byte for byte, so there has to be a limit —
    /// a multi gigabyte "PDF" would otherwise take the process down with it.
    static let materialiseLimitBytes: Int = 256 << 20

    /// Hard ceiling for the configurable size limits. The limits exist to keep
    /// the pasteboard (and the machine) alive; a setting may lower them, but
    /// not remove them.
    static let byteLimitCeiling: Int = 4 << 30

    /// LaunchAgent label.
    static let agentLabel = "com.pseudocopy"

    /// Formula name used by `brew services` in the launchd label.
    static let homebrewFormulaName = "pseudocopy"

    /// Labels a Homebrew-managed service may use. Homebrew 5 names the agent
    /// `sh.brew.<formula>`; older versions used `homebrew.mxcl.<formula>`.
    static var homebrewAgentLabels: [String] {
        ["sh.brew." + homebrewFormulaName, "homebrew.mxcl." + homebrewFormulaName]
    }

    /// Folder name inside `~/Library/Application Support`.
    static let appSupportFolder = "pseudocopy"

    /// State file name inside the app-support folder.
    static let stateFileName = "state.json"

    /// Settings file name inside the app-support folder.
    static let settingsFileName = "config.json"

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
///
/// The content is inspected first (`inspectFile`): a file whose bytes are
/// identifiable is classified by what it is, not by what it is called. These
/// lists are the fallback for files that cannot be identified, and they decide
/// which extensions are text without having to read the whole file.
enum ExtensionSets {
    /// Extensions treated as text. Anything that cannot be decoded as text
    /// falls through to the generic *Other* representation.
    ///
    /// Most plain-text types do not need to be listed: macOS already assigns
    /// them a `public.plain-text`-conforming UTI, and an extension that is
    /// merely dynamic is decided by the bytes. The entries below are the
    /// exceptions — text formats whose registered UTI is *not* plain text
    /// (`asm`, `edn`, `ndjson`, `geojson`, `mts`) — plus the common cases that
    /// make the intent obvious.
    ///
    /// "rtf" is deliberately absent: RTF is not UTF-8 text, pasting it as
    /// plain text would put the markup on the clipboard instead of the
    /// document.
    static let text: Set<String> = [
        "txt", "text", "md", "markdown", "log", "csv", "tsv", "json", "jsonl",
        "ndjson", "geojson", "yaml", "yml", "toml", "ini", "cfg", "conf",
        "plist", "xml", "html", "htm", "css", "scss", "sh", "bash", "zsh",
        "fish", "py", "rb", "php", "pl", "lua", "swift", "js", "mjs", "cjs",
        "ts", "mts", "cts", "tsx", "jsx", "c", "h", "cc", "cpp", "hpp", "m",
        "mm", "java", "kt", "go", "rs", "sql", "diff", "patch", "tex", "srt",
        "vtt", "ics", "rst", "adoc", "properties", "asm", "edn",
        // `.strings`/`.stringsdict` are Xcode text resources; on some macOS
        // versions their registered UTI is known but not plain text.
        "strings", "stringsdict", "xcstrings",
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
