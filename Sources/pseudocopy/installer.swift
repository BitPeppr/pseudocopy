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
func executablePath() -> String {
    if let path = Bundle.main.executablePath {
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
    return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
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
func launchAgentPlist(binaryPath: String, watchDir: String, ttl: TimeInterval, home: String) throws -> Data {
    let plist: [String: Any] = [
        "Label": Constants.agentLabel,
        "ProgramArguments": [
            binaryPath, "run",
            "--dir", watchDir,
            "--ttl", String(ttl),
        ],
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

    let plist = try launchAgentPlist(
        binaryPath: executablePath(),
        watchDir: config.watchDir.path,
        ttl: config.ttl,
        home: NSHomeDirectory()
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
    print("  binary    : \(executablePath())")
    print("  plist     : \(AgentPaths.plistURL.path)")
    print("  log       : \(AgentPaths.logURL.path)")
}

/// Removes the LaunchAgent and its plist (§5).
func uninstallAgent() throws {
    let result = Launchctl.run(["bootout", Launchctl.label])
    if result.status != 0 {
        Logger.log(.info, "agent", "bootout: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    if FileManager.default.fileExists(atPath: AgentPaths.plistURL.path) {
        try FileManager.default.removeItem(at: AgentPaths.plistURL)
    }
    print("uninstalled \(Constants.agentLabel)")
    print("  watch dir and state are kept")
}

/// Forces one cycle of the running agent right now (§5.3).
func kickAgent() throws {
    let result = Launchctl.run(["kickstart", Launchctl.label])
    guard result.status == 0 else {
        throw CLIError.usage("could not start a cycle: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    print("kicked \(Constants.agentLabel)")
}

/// Prints the agent status; exits 1 when the agent is not loaded (§5.3).
func printAgentStatus() throws {
    let result = Launchctl.run(["print", Launchctl.label])
    if result.status == 0 {
        print(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        return
    }
    FileHandle.standardError.write(Data((result.output.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8))
    throw CLIError.usage("\(Constants.agentLabel) is not loaded")
}
