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
            watchDir: Configuration.resolvePath("~/Temp"),
            ttl: Constants.defaultTTL,
            embedLimitBytes: Constants.embedLimitBytes,
            verbose: false,
            permanent: false
        )
    }

    /// Expands `~`, makes the path absolute and removes symlinks so that the
    /// same folder always maps to the same state namespace.
    static func resolvePath(_ raw: String) -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.isEmpty {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        return URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
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
                config.watchDir = Configuration.resolvePath(args[index])
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
        guard let value = TimeInterval(raw), value >= 0 else {
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
