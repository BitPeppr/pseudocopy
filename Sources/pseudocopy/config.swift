import Foundation

/// Runtime configuration (§3).
///
/// The effective value of every setting comes from one of four places, in
/// this order: the command line, `PSEUDOCOPY_STATE_ROOT` (the state store
/// only), the settings file and the built-in default. `config list` shows
/// which one won.
struct Configuration {
    /// Watched folder. Resolved to an absolute, standardized path.
    var watchDir: URL
    /// Reaper time-to-live in seconds.
    var ttl: TimeInterval
    /// Seconds between two cycles. The LaunchAgent uses this as its
    /// `StartInterval`; `loop` uses it as its sleep.
    var interval: TimeInterval
    /// Maximum size of a text file that is embedded as text.
    var textLimitBytes: Int
    /// Maximum size of a generic file whose bytes are embedded.
    var embedLimitBytes: Int
    /// Maximum size of an image or PDF that is materialised.
    var materialiseLimitBytes: Int
    /// Log every cycle instead of only events.
    var verbose: Bool
    /// Delete permanently instead of moving files to the Trash.
    var permanent: Bool
    /// Where the agent writes its log.
    var logPath: URL
    /// Where the state store lives.
    var stateDir: URL
    /// Where each effective value came from, for `config list`.
    var sources: [String: String] = [:]

    /// The values that were given on the command line, as settings.
    ///
    /// `install` writes exactly these into the settings file, so a command
    /// line flag changes the stored configuration and nothing else.
    var explicit: Settings = Settings()

    static var `default`: Configuration {
        Configuration(
            watchDir: URL(fileURLWithPath: canonicalPath(
                URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Temp")
            )),
            ttl: Constants.defaultTTL,
            interval: Constants.cycleInterval,
            textLimitBytes: Constants.textLimitBytes,
            embedLimitBytes: Constants.embedLimitBytes,
            materialiseLimitBytes: Constants.materialiseLimitBytes,
            verbose: false,
            permanent: false,
            logPath: URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Logs/pseudocopy.log"),
            stateDir: SettingsStore.defaultRootDirectory
        )
    }

    /// Builds the effective configuration.
    ///
    /// The settings file is read first, then the environment, then the
    /// command line — the most specific source wins.
    ///
    /// `validate` may be turned off for `pseudocopy config`, which has to
    /// work even when the stored settings are broken.
    static func resolve(settings: Settings, arguments: [String], validate: Bool = true) throws -> Configuration {
        var config = Configuration.default

        config.apply(settings: settings)
        config.apply(environment: ProcessInfo.processInfo.environment)
        try config.apply(arguments: arguments)

        if validate {
            try config.validate()
        }
        return config
    }

    /// The configuration for the current invocation: the settings file plus
    /// the global flags.
    static func parse(_ arguments: [String]) throws -> Configuration {
        try resolve(settings: SettingsStore.load(), arguments: arguments)
    }

    // MARK: - Sources

    private mutating func apply(settings: Settings) {
        if let dir = settings.dir {
            watchDir = URL(fileURLWithPath: canonicalPath(URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)))
            sources[SettingKey.dir.rawValue] = "settings file"
        }
        if let ttl = settings.ttl {
            self.ttl = ttl
            sources[SettingKey.ttl.rawValue] = "settings file"
        }
        if let interval = settings.interval {
            self.interval = interval
            sources[SettingKey.interval.rawValue] = "settings file"
        }
        if let permanent = settings.permanent {
            self.permanent = permanent
            sources[SettingKey.permanent.rawValue] = "settings file"
        }
        if let verbose = settings.verbose {
            self.verbose = verbose
            sources[SettingKey.verbose.rawValue] = "settings file"
        }
        if let logPath = settings.logPath {
            self.logPath = URL(fileURLWithPath: (logPath as NSString).expandingTildeInPath).standardizedFileURL
            sources[SettingKey.logPath.rawValue] = "settings file"
        }
        if let stateDir = settings.stateDir {
            self.stateDir = URL(fileURLWithPath: (stateDir as NSString).expandingTildeInPath).standardizedFileURL
            sources[SettingKey.stateDir.rawValue] = "settings file"
        }
        if let limit = settings.textLimit {
            textLimitBytes = limit
            sources[SettingKey.textLimit.rawValue] = "settings file"
        }
        if let limit = settings.embedLimit {
            embedLimitBytes = limit
            sources[SettingKey.embedLimit.rawValue] = "settings file"
        }
        if let limit = settings.materialiseLimit {
            materialiseLimitBytes = limit
            sources[SettingKey.materialiseLimit.rawValue] = "settings file"
        }
    }

    private mutating func apply(environment: [String: String]) {
        // The state store can be moved with the environment; the settings
        // file and the command line still win over it.
        guard let override = environment["PSEUDOCOPY_STATE_ROOT"],
              !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sources[SettingKey.stateDir.rawValue] != "command line" else { return }
        stateDir = URL(fileURLWithPath: (override as NSString).expandingTildeInPath).standardizedFileURL
        sources[SettingKey.stateDir.rawValue] = "PSEUDOCOPY_STATE_ROOT"
    }

    private mutating func apply(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            func value(_ flag: String) throws -> String {
                index += 1
                guard index < arguments.count else { throw CLIError.usage("missing value for \(flag)") }
                return arguments[index]
            }

            switch arg {
            case "--dir":
                let raw = try value("--dir")
                watchDir = try Configuration.resolvePath(raw)
                explicit.dir = watchDir.path
                sources[SettingKey.dir.rawValue] = "command line"
            case "--ttl":
                let raw = try value("--ttl")
                ttl = try Configuration.parseTTL(raw)
                explicit.ttl = ttl
                sources[SettingKey.ttl.rawValue] = "command line"
            case "--interval":
                let raw = try value("--interval")
                interval = try Configuration.parseInterval(raw)
                explicit.interval = interval
                sources[SettingKey.interval.rawValue] = "command line"
            case "--text-limit":
                let raw = try value("--text-limit")
                textLimitBytes = try Configuration.parseByteLimit(raw, flag: "--text-limit")
                explicit.textLimit = textLimitBytes
                sources[SettingKey.textLimit.rawValue] = "command line"
            case "--embed-limit":
                let raw = try value("--embed-limit")
                embedLimitBytes = try Configuration.parseByteLimit(raw, flag: "--embed-limit")
                explicit.embedLimit = embedLimitBytes
                sources[SettingKey.embedLimit.rawValue] = "command line"
            case "--materialise-limit":
                let raw = try value("--materialise-limit")
                materialiseLimitBytes = try Configuration.parseByteLimit(raw, flag: "--materialise-limit")
                explicit.materialiseLimit = materialiseLimitBytes
                sources[SettingKey.materialiseLimit.rawValue] = "command line"
            case "--log":
                let raw = try value("--log")
                logPath = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
                explicit.logPath = logPath.path
                sources[SettingKey.logPath.rawValue] = "command line"
            case "--state-dir":
                let raw = try value("--state-dir")
                stateDir = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
                explicit.stateDir = stateDir.path
                sources[SettingKey.stateDir.rawValue] = "command line"
            case "--verbose":
                verbose = true
                explicit.verbose = true
                sources[SettingKey.verbose.rawValue] = "command line"
            case "--no-trash":
                permanent = true
                explicit.permanent = true
                sources[SettingKey.permanent.rawValue] = "command line"
            default:
                if arg.hasPrefix("-") {
                    throw CLIError.usage("unknown option '\(arg)'")
                }
            }
            index += 1
        }
    }

    // MARK: - Validation

    /// Checks the effective configuration.
    ///
    /// The watch folder guard also runs for values that come from the
    /// settings file: a file that was edited by hand must not be able to
    /// point the reaper at the home directory.
    func validate() throws {
        try Configuration.validateWatchDir(watchDir)
        if stateDir.path == watchDir.path || watchDir.path.hasPrefix(stateDir.path + "/") {
            throw CLIError.usage("the state store (\(stateDir.path)) must not be inside the watched folder")
        }
        for (flag, value) in [("--text-limit", textLimitBytes),
                              ("--embed-limit", embedLimitBytes),
                              ("--materialise-limit", materialiseLimitBytes)] {
            guard value >= 0, value <= Constants.byteLimitCeiling else {
                throw CLIError.usage("\(flag) must be between 0 and \(Constants.byteLimitCeiling) bytes")
            }
        }
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

        let stateRoot = canonicalPath(SettingsStore.defaultRootDirectory)
        if path == stateRoot {
            throw CLIError.usage("refusing to watch \(path) — the state store lives there")
        }
    }

    static func parseTTL(_ raw: String) throws -> TimeInterval {
        guard let value = TimeInterval(raw), value.isFinite, value >= 0, value <= 100_000_000 else {
            throw CLIError.usage("invalid --ttl value '\(raw)' (expected a non-negative number of seconds)")
        }
        return value
    }

    static func parseInterval(_ raw: String) throws -> TimeInterval {
        guard let value = TimeInterval(raw), value.isFinite, value > 0, value <= 86_400 else {
            throw CLIError.usage("invalid --interval value '\(raw)' (expected a positive number of seconds)")
        }
        return value
    }

    /// Parses a byte count. `64MB`, `16 MiB` and `1048576` are all valid.
    static func parseByteLimit(_ raw: String, flag: String) throws -> Int {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let suffixes: [(String, Int)] = [
            ("gib", 1 << 30), ("gb", 1 << 30),
            ("mib", 1 << 20), ("mb", 1 << 20),
            ("kib", 1 << 10), ("kb", 1 << 10),
            ("b", 1),
        ]
        var number = text
        var multiplier = 1
        for (suffix, factor) in suffixes where text.hasSuffix(suffix) {
            number = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            multiplier = factor
            break
        }
        guard let value = Double(number), value.isFinite, value >= 0 else {
            throw CLIError.usage("invalid \(flag) value '\(raw)' (expected a byte count such as 64MB)")
        }
        let bytes = Int(value * Double(multiplier))
        guard bytes <= Constants.byteLimitCeiling else {
            throw CLIError.usage("\(flag) must not exceed \(Constants.byteLimitCeiling) bytes")
        }
        return bytes
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
