import Foundation

// PLAN.md §3: installer.swift — LaunchAgent plist + launchctl integration (§5).

// MARK: - Paths

/// Locations used by the LaunchAgent (§5.2).
enum AgentPaths {
    static var libraryDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
    }

    static var launchAgentsDirectory: URL {
        libraryDirectory.appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    static var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent(Constants.plistFileName, isDirectory: false)
    }

    static var logURL: URL {
        libraryDirectory.appendingPathComponent("Logs/pseudocopy.log", isDirectory: false)
    }

    static var logsDirectory: URL {
        libraryDirectory.appendingPathComponent("Logs", isDirectory: true)
    }
}

// MARK: - launchctl

/// The result of a `launchctl` invocation.
struct LaunchctlResult {
    var status: Int32
    var output: String
}

enum Launchctl {
    /// The GUI domain of the current user.
    static var domain: String {
        "gui/\(getuid())"
    }

    /// The full label of the agent inside the domain.
    static var label: String {
        "\(domain)/\(Constants.agentLabel)"
    }

    /// The full launchd label for a service name.
    static func label(for name: String) -> String {
        "\(domain)/\(name)"
    }

    /// Every loaded agent label: the one `pseudocopy install` owns and the
    /// ones `brew services` may have created. Checking only the first match
    /// would miss a second, conflicting agent.
    static func loadedAgents() -> [(name: String, output: String)] {
        var agents: [(name: String, output: String)] = []
        for name in [Constants.agentLabel] + Constants.homebrewAgentLabels {
            let result = run(["print", label(for: name)])
            if result.status == 0 { agents.append((name, result.output)) }
        }
        return agents
    }

    /// The first loaded agent, if any: the built-in one takes precedence.
    static func loadedAgent() -> (name: String, output: String)? {
        loadedAgents().first
    }

    /// True when this label belongs to a Homebrew-managed service.
    static func isHomebrew(label name: String) -> Bool {
        Constants.homebrewAgentLabels.contains(name)
    }

    /// Runs `launchctl` with the given arguments.
    @discardableResult
    static func run(_ arguments: [String]) -> LaunchctlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return LaunchctlResult(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return LaunchctlResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }
}

// MARK: - Plist

/// The absolute path of the running executable.
///
/// A Homebrew binary lives in a versioned Cellar directory that `brew upgrade`
/// deletes. If the program was started through one of Homebrew's stable
/// symlinks (`bin/pseudocopy`, `opt/pseudocopy/bin/pseudocopy`), that symlink
/// is the right path to freeze into the LaunchAgent: it keeps pointing at the
/// current version. The same applies to any other symlink the user invoked.
func executablePath() -> String {
    let current = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        .resolvingSymlinksInPath().path

    if current.contains("/Cellar/") {
        for candidate in executableCandidates() where
            URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path == current {
            return candidate
        }
    }
    if let invoked = invokedExecutablePath(),
       URL(fileURLWithPath: invoked).resolvingSymlinksInPath().path == current {
        return invoked
    }
    return current
}

/// The path the user actually ran, without resolving a final symlink.
private func invokedExecutablePath() -> String? {
    let argument = CommandLine.arguments.first ?? ""
    guard !argument.isEmpty else { return nil }

    if argument.contains("/") {
        let candidate = argument.hasPrefix("/")
            ? URL(fileURLWithPath: argument)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(argument)
        let path = candidate.standardizedFileURL.path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(argument).path
        if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    return nil
}

/// Stable executable paths to try when the running binary is in the Cellar.
private func executableCandidates() -> [String] {
    var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":")
        .map { URL(fileURLWithPath: String($0)).appendingPathComponent("pseudocopy").path }
    candidates.append("/opt/homebrew/bin/pseudocopy")
    candidates.append("/usr/local/bin/pseudocopy")
    return candidates
}

/// The LaunchAgent plist (§5.2). All placeholders are absolute paths —
/// launchd does not expand `~`.
///
/// The agent is started without any settings flags: everything comes from the
/// settings file, so changing a setting does not require a reinstall. The
/// plist only carries what launchd itself has to know — the binary, the
/// interval and the log file.
///
/// `ThrottleInterval` is needed because launchd otherwise applies its
/// default throttle of 10 seconds, which would stretch a `StartInterval` of
/// 5 seconds to an effective 10 second cycle.
///
/// The plist is serialised by Foundation instead of being written by hand,
/// so that paths containing `&` or `<` cannot produce an invalid file.
func launchAgentPlist(binaryPath: String, interval: TimeInterval, logPath: String) throws -> Data {
    let seconds = max(1, Int(interval.rounded()))
    let plist: [String: Any] = [
        "Label": Constants.agentLabel,
        "ProgramArguments": [binaryPath, "run"],
        "RunAtLoad": true,
        "StartInterval": seconds,
        "ThrottleInterval": seconds,
        "ProcessType": "Interactive",
        "StandardOutPath": logPath,
        "StandardErrorPath": logPath,
    ]
    return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
}

// MARK: - Commands

/// Writes the LaunchAgent plist and bootstraps the agent (§5).
func installAgent(config: Configuration) throws {
    let fileManager = FileManager.default

    // Two agents would double the clipboard traffic. If Homebrew already
    // manages the service, the built-in install has to wait — and it must
    // notice *every* Homebrew label, not whichever one launchctl lists first.
    if let agent = Launchctl.loadedAgents().first(where: { Launchctl.isHomebrew(label: $0.name) }) {
        throw CLIError.usage("""
            a Homebrew-managed service is already running (\(agent.name)); \
            run 'brew services stop pseudocopy' first, or keep using brew services
            """)
    }

    // A folder under /Volumes that is missing usually means the external
    // volume is not mounted. Creating it would put a stray folder on the
    // boot volume and the agent would watch the wrong place.
    if config.watchDir.path.hasPrefix("/Volumes/"),
       !fileManager.fileExists(atPath: config.watchDir.path) {
        throw CLIError.usage("""
            watch directory \(config.watchDir.path) is on an unmounted volume — \
            mount it first, or choose a folder on the boot volume
            """)
    }

    // The watch directory has to exist before the agent starts.
    let watchDirExisted = fileManager.fileExists(atPath: config.watchDir.path)
    try fileManager.createDirectory(at: config.watchDir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
    try fileManager.createDirectory(at: AgentPaths.launchAgentsDirectory, withIntermediateDirectories: true)

    // The log lists the names of the files that were copied — keep it
    // readable by the user only.
    let logDirectory = config.logPath.deletingLastPathComponent()
    try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    if !fileManager.fileExists(atPath: config.logPath.path) {
        fileManager.createFile(atPath: config.logPath.path, contents: nil)
    }
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.logPath.path)

    // The state store has to exist too; it holds the settle bookkeeping.
    let stateDirExisted = fileManager.fileExists(atPath: config.stateDir.path)
    try fileManager.createDirectory(at: config.stateDir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])

    // Everything the user asked for on the command line becomes the stored
    // configuration. The rest of the settings file is left alone.
    let settings = SettingsStore.load()
    var updated = settings
    updated.version = 1
    if let dir = config.explicit.dir { updated.dir = dir }
    if let ttl = config.explicit.ttl { updated.ttl = ttl }
    if let interval = config.explicit.interval { updated.interval = interval }
    if let permanent = config.explicit.permanent { updated.permanent = permanent }
    if let verbose = config.explicit.verbose { updated.verbose = verbose }
    if let logPath = config.explicit.logPath { updated.logPath = logPath }
    if let stateDir = config.explicit.stateDir { updated.stateDir = stateDir }
    if let limit = config.explicit.textLimit { updated.textLimit = limit }
    if let limit = config.explicit.embedLimit { updated.embedLimit = limit }
    if let limit = config.explicit.materialiseLimit { updated.materialiseLimit = limit }
    // An install without any flags must not leave an empty settings file
    // behind — but it may refresh an existing one.
    if !config.explicit.isEmpty || !updated.isEmpty {
        try SettingsStore.save(updated)
    }

    // Existing content is not copied retroactively, and anything older than
    // the TTL will be reaped. Say so before arming the agent.
    let existingFiles = (try? topLevelEntries(config.watchDir))?
        .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        .count ?? 0
    if existingFiles > 0 {
        print("warning: \(config.watchDir.path) already contains \(existingFiles) file(s); "
              + "files older than \(Int(config.ttl))s will be moved to the Trash")
    }

    printWarnings(config: config)
    if !watchDirExisted {
        print("warning: \(config.watchDir.path) did not exist and was created")
    }
    if !stateDirExisted {
        print("warning: the state store \(config.stateDir.path) did not exist and was created")
    }

    let binary = executablePath()
    let plist = try launchAgentPlist(
        binaryPath: binary,
        interval: config.interval,
        logPath: config.logPath.path
    )
    let previousPlist = try? Data(contentsOf: AgentPaths.plistURL)
    try plist.write(to: AgentPaths.plistURL, options: [.atomic])

    // (Re-)install: bootout first, so that a changed plist takes effect.
    _ = Launchctl.run(["bootout", Launchctl.label])
    let result = Launchctl.run(["bootstrap", Launchctl.domain, AgentPaths.plistURL.path])
    guard result.status == 0 else {
        // Roll back: a failed install must not leave the tool unloaded with a
        // broken plist on disk.
        if let previousPlist {
            try? previousPlist.write(to: AgentPaths.plistURL, options: [.atomic])
            _ = Launchctl.run(["bootstrap", Launchctl.domain, AgentPaths.plistURL.path])
            Logger.log(.error, "agent", "could not load the LaunchAgent — the previous one was restored")
        } else {
            try? FileManager.default.removeItem(at: AgentPaths.plistURL)
        }
        throw CLIError.usage("could not load the LaunchAgent: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    print("installed \(Constants.agentLabel)")
    print("  watch dir : \(config.watchDir.path)")
    print("  ttl       : \(Int(config.ttl))s")
    print("  interval  : \(Int(config.interval))s")
    print("  deletion  : \(config.permanent ? "permanent" : "Trash")")
    print("  binary    : \(binary)")
    print("  plist     : \(AgentPaths.plistURL.path)")
    print("  log       : \(config.logPath.path)")
    print("  settings  : \(SettingsStore.fileURL.path)")
}

/// Prints everything that is worth knowing before the agent starts watching
/// a folder.
func printWarnings(config: Configuration) {
    let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path

    // Personal folders are allowed, but everything in them is subject to the
    // reaper — the user should know that.
    let personal = [home + "/Downloads", home + "/Desktop", home + "/Documents"]
    if personal.contains(config.watchDir.path) {
        print("warning: \(config.watchDir.path) is a personal folder — every file in its top level "
              + "is subject to the \(Int(config.ttl))s reaper")
    }
    if config.watchDir.path.hasPrefix("/Volumes/") {
        print("warning: \(config.watchDir.path) is on an external volume — cycles are skipped while it is not mounted")
    }
    if config.ttl == 0 {
        print("warning: the TTL is 0 — every file is reaped on the next cycle")
    }
    if config.ttl < config.interval * 2 {
        print("warning: the TTL (\(Int(config.ttl))s) is shorter than two cycles (\(Int(config.interval * 2))s) — "
              + "files can be reaped before they were ever copied")
    }
    if config.interval < 2 {
        print("warning: the interval is \(config.interval)s — the agent wakes up very often and uses more energy")
    }
    if config.interval > 60 {
        print("warning: the interval is \(Int(config.interval))s — a new file can take that long to be copied")
    }
    if config.permanent {
        print("warning: files are deleted permanently — the Trash cannot bring them back")
    }
    if config.verbose {
        print("warning: verbose logging writes one line per cycle — the log grows quickly")
    }
    if config.logPath.path.hasPrefix(home + "/Library/Logs/") == false {
        print("warning: the log is written to \(config.logPath.path) — outside ~/Library/Logs it may be backed up or synced")
    }
    if config.textLimitBytes > Constants.textLimitBytes
        || config.embedLimitBytes > Constants.embedLimitBytes
        || config.materialiseLimitBytes > Constants.materialiseLimitBytes {
        print("warning: the pasteboard size limits are raised above the defaults — "
              + "a file of that size is copied into memory (and the pasteboard)")
    }
    if config.stateDir.path == config.watchDir.path
        || config.watchDir.path.hasPrefix(config.stateDir.path + "/") {
        print("warning: the state store is inside the watched folder — its files would be reaped as well")
    }
    if ProcessInfo.processInfo.environment["PSEUDOCOPY_STATE_ROOT"] != nil {
        print("warning: PSEUDOCOPY_STATE_ROOT is set — the settings and the state live in "
              + "\(config.stateDir.path); the agent under launchd does not have that variable "
              + "and would not see them")
    }

    // A Homebrew service that is not running but whose plist is still on disk
    // would come back the next time the user runs 'brew services start' and
    // put a second agent next to this one. That is only a problem when the
    // built-in agent exists as well — a Homebrew plist on its own is normal.
    if FileManager.default.fileExists(atPath: AgentPaths.plistURL.path) {
        for name in Constants.homebrewAgentLabels {
            let plist = AgentPaths.launchAgentsDirectory.appendingPathComponent("\(name).plist")
            guard FileManager.default.fileExists(atPath: plist.path) else { continue }
            print("warning: \(plist.path) still exists — 'brew services start pseudocopy' "
                  + "would load a second agent next to \(Constants.agentLabel)")
        }
    }
}

/// Removes the LaunchAgent and its plist (§5).
///
/// Only the agent written by `pseudocopy install` is touched. A Homebrew
/// service belongs to `brew services` and is left alone.
func uninstallAgent() throws {
    let hadPlist = FileManager.default.fileExists(atPath: AgentPaths.plistURL.path)
    let builtInLoaded = Launchctl.loadedAgents().contains { $0.name == Constants.agentLabel }

    guard hadPlist || builtInLoaded else {
        print("nothing to uninstall — no agent was written by 'pseudocopy install'")
        if let agent = Launchctl.loadedAgents().first(where: { Launchctl.isHomebrew(label: $0.name) }) {
            print("  \(agent.name) is managed by Homebrew: brew services stop pseudocopy")
        }
        return
    }

    if builtInLoaded {
        let result = Launchctl.run(["bootout", Launchctl.label])
        guard result.status == 0 else {
            // Removing the plist while the job is still loaded would leave a
            // running agent that cannot be unloaded cleanly until logout.
            throw CLIError.usage("""
                could not unload \(Constants.agentLabel): \
                \(result.output.trimmingCharacters(in: .whitespacesAndNewlines)); the plist was kept
                """)
        }
    }
    if hadPlist {
        try FileManager.default.removeItem(at: AgentPaths.plistURL)
    }
    print("uninstalled \(Constants.agentLabel)")
    print("  watch dir, state and settings are kept")
    print("  'pseudocopy config reset' removes the settings file")
    if let agent = Launchctl.loadedAgents().first(where: { Launchctl.isHomebrew(label: $0.name) }) {
        print("  note: \(agent.name) is managed by Homebrew: brew services stop pseudocopy")
    }
}

/// Forces one cycle of the running agent right now (§5.3).
func kickAgent() throws {
    guard let agent = Launchctl.loadedAgent() else {
        throw CLIError.usage("the agent is not loaded")
    }
    // `-k` replaces a cycle that happens to be running, so a kick always
    // produces a fresh look at the folder.
    let result = Launchctl.run(["kickstart", "-k", Launchctl.label(for: agent.name)])
    guard result.status == 0 else {
        throw CLIError.usage("could not start a cycle of \(agent.name): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    print("kicked \(agent.name)")
}

/// Prints the agent status; exits 1 when the agent is not loaded (§5.3).
func printAgentStatus(config: Configuration) throws {
    let agents = Launchctl.loadedAgents()
    guard let agent = agents.first else {
        let names = ([Constants.agentLabel] + Constants.homebrewAgentLabels).joined(separator: ", ")
        throw CLIError.usage("not loaded (checked \(names))")
    }
    print(agent.output.trimmingCharacters(in: .whitespacesAndNewlines))
    if Launchctl.isHomebrew(label: agent.name) {
        print("\nmanaged by Homebrew — use 'brew services' to start, stop or restart it")
    }
    if agents.count > 1 {
        let others = agents.dropFirst().map { $0.name }.joined(separator: ", ")
        print("\nwarning: more than one agent is loaded — also \(others)")
    }

    // The settings the agent actually works with.
    print("\nsettings")
    print("  watch dir : \(config.watchDir.path)")
    print("  ttl       : \(Int(config.ttl))s")
    print("  interval  : \(Int(config.interval))s")
    print("  deletion  : \(config.permanent ? "permanent" : "Trash")")
    print("  log       : \(config.logPath.path)")
    print("  settings  : \(SettingsStore.fileURL.path)")
}
