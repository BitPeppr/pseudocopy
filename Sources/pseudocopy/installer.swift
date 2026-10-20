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
/// `ThrottleInterval` is needed because launchd otherwise applies its
/// default throttle of 10 seconds, which would stretch `StartInterval` of
/// 5 seconds to an effective 10 second cycle.
///
/// The plist is serialised by Foundation instead of being written by hand,
/// so that paths containing `&` or `<` cannot produce an invalid file.
func launchAgentPlist(binaryPath: String, watchDir: String, ttl: TimeInterval, home: String,
                      permanent: Bool) throws -> Data {
    var arguments = [binaryPath, "run", "--dir", watchDir, "--ttl", String(ttl)]
    if permanent {
        // Freeze the deletion mode into the agent: `brew services` has no
        // flags of its own, and a later `pseudocopy install --no-trash`
        // must not silently lose the setting.
        arguments.append("--no-trash")
    }
    let plist: [String: Any] = [
        "Label": Constants.agentLabel,
        "ProgramArguments": arguments,
        "RunAtLoad": true,
        "StartInterval": Int(Constants.cycleInterval),
        "ThrottleInterval": Int(Constants.cycleInterval),
        "ProcessType": "Interactive",
        "StandardOutPath": "\(home)/Library/Logs/pseudocopy.log",
        "StandardErrorPath": "\(home)/Library/Logs/pseudocopy.log",
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
    try fileManager.createDirectory(at: config.watchDir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
    try fileManager.createDirectory(at: AgentPaths.launchAgentsDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: AgentPaths.logsDirectory, withIntermediateDirectories: true)
    // The log lists the names of the files that were copied — keep it
    // readable by the user only.
    if !fileManager.fileExists(atPath: AgentPaths.logURL.path) {
        fileManager.createFile(atPath: AgentPaths.logURL.path, contents: nil)
    }
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AgentPaths.logURL.path)

    // Existing content is not copied retroactively, and anything older than
    // the TTL will be reaped. Say so before arming the agent.
    let existingFiles = (try? topLevelEntries(config.watchDir))?
        .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        .count ?? 0
    if existingFiles > 0 {
        print("warning: \(config.watchDir.path) already contains \(existingFiles) file(s); "
              + "files older than \(Int(config.ttl))s will be moved to the Trash")
    }

    let binary = executablePath()
    let plist = try launchAgentPlist(
        binaryPath: binary,
        watchDir: config.watchDir.path,
        ttl: config.ttl,
        home: NSHomeDirectory(),
        permanent: config.permanent
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
    print("  deletion  : \(config.permanent ? "permanent" : "Trash")")
    print("  binary    : \(binary)")
    print("  plist     : \(AgentPaths.plistURL.path)")
    print("  log       : \(AgentPaths.logURL.path)")
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
    print("  watch dir and state are kept")
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
func printAgentStatus() throws {
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
}
