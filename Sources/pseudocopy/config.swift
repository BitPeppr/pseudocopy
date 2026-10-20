import Foundation

/// Runtime configuration (§3).
struct Configuration {
    /// Watched folder. Resolved to an absolute, standardized path.
    var watchDir: URL
    /// Reaper time-to-live in seconds.
    var ttl: TimeInterval
    /// Maximum size of a file whose bytes are embedded in the pasteboard.
    var embedLimitBytes: Int
    /// Log every cycle instead of only events.
    var verbose: Bool
    /// Delete permanently instead of moving files to the Trash.
    var permanent: Bool

    static var `default`: Configuration {
        Configuration(
            watchDir: URL(fileURLWithPath: canonicalPath(
                URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Temp")
            )),
            ttl: Constants.defaultTTL,
            embedLimitBytes: Constants.embedLimitBytes,
            verbose: false,
            permanent: false
        )
    }

    /// Expands `~`, makes the path absolute and removes symlinks so that the
    /// same folder always maps to the same state namespace.
    ///
    /// An empty path is rejected: it would silently watch the current working
    /// directory, and the reaper would move *its* old files to the Trash.
    static func resolvePath(_ raw: String) throws -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        guard !expanded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.usage("--dir must not be empty")
        }
        let url = URL(fileURLWithPath: canonicalPath(URL(fileURLWithPath: expanded)))
        try validateWatchDir(url)
        return url
    }

    /// Refuses folders where the reaper would do more harm than good.
    ///
    /// The tool is built around a *dedicated* folder. Watching the home
    /// directory (or a system/shared root) would move unrelated files to the
    /// Trash one TTL after they were last touched, which is exactly the
    /// accident this guard exists to prevent. Personal folders such as
    /// `~/Downloads` remain allowed — they are the documented use case — but
    /// `install` warns when the target already contains files.
    static func validateWatchDir(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let refused: Set<String> = [
            "/", "/Users", "/Users/Shared",
            "/System", "/Library", "/Applications", "/Volumes",
            "/tmp", "/private/tmp", "/var", "/private/var",
            "/var/tmp", "/private/var/tmp",
            "/etc", "/private/etc", "/usr", "/opt",
            "/bin", "/sbin", "/dev", "/private", "/cores",
            "/Network", "/home", "/net", "/private/var/root",
            home + "/Library", home + "/.Trash",
        ]
        if refused.contains(path) || path == home {
            throw CLIError.usage("refusing to watch \(path) — use a dedicated folder such as ~/Temp")
        }
        if home.hasPrefix(path + "/") {
            throw CLIError.usage("refusing to watch \(path) — it contains your home folder")
        }
        if path.hasPrefix("/Users/") && !path.hasPrefix(home + "/") {
            throw CLIError.usage("refusing to watch \(path) — it is another user's home folder")
        }
        if path.hasPrefix("/Volumes/"),
           URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path == "/Volumes" {
            throw CLIError.usage("refusing to watch the root of an external volume — use a folder inside it")
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let stateRoot = canonicalPath(appSupport.appendingPathComponent(Constants.appSupportFolder))
        if path == stateRoot {
            throw CLIError.usage("refusing to watch \(path) — the state store lives there")
        }
    }

    /// Parses the global flags (`--dir`, `--ttl`, `--verbose`, `--no-trash`).
    /// Bare words (the subcommand and its positional arguments) are ignored
    /// here; they are handled by the CLI parser.
    static func parse(_ args: [String]) throws -> Configuration {
        var config = Configuration.default
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--dir":
                index += 1
                guard index < args.count else { throw CLIError.usage("missing value for --dir") }
                config.watchDir = try Configuration.resolvePath(args[index])
            case "--ttl":
                index += 1
                guard index < args.count else { throw CLIError.usage("missing value for --ttl") }
                config.ttl = try Configuration.parseTTL(args[index])
            case "--verbose":
                config.verbose = true
            case "--no-trash":
                config.permanent = true
            default:
                if arg.hasPrefix("-") {
                    throw CLIError.usage("unknown option '\(arg)'")
                }
            }
            index += 1
        }
        return config
    }

    static func parseTTL(_ raw: String) throws -> TimeInterval {
        guard let value = TimeInterval(raw), value.isFinite, value >= 0, value <= 100_000_000 else {
            throw CLIError.usage("invalid --ttl value '\(raw)' (expected a non-negative number of seconds)")
        }
        return value
    }
}

/// Errors that are reported to the user without a stack trace.
enum CLIError: Error {
    case usage(String)

    var message: String {
        switch self {
        case .usage(let text):
            return text
        }
    }
}
