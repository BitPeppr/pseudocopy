import Foundation

// PLAN.md §3 places the entry point in `main.swift`. Swift forbids the `@main`
// attribute in a file called `main.swift` (such a file may only contain
// top-level code), so the entry point lives in a `Pseudocopy` struct that is
// invoked from top-level code.
struct Pseudocopy {
    static func main() {
        do {
            let invocation = try CLI.parse(Array(CommandLine.arguments.dropFirst()))
            try dispatch(invocation)
        } catch let error as CLIError {
            CLI.fail(error.message)
        } catch {
            CLI.fail(error.localizedDescription)
        }
    }

    static func dispatch(_ invocation: Invocation) throws {
        switch invocation.command {
        case .help:
            CLI.printUsage()
        case .run:
            try runCycle(config: invocation.config)
        case .loop:
            try runLoop(config: invocation.config, interval: invocation.interval)
        case .clean:
            try runClean(config: invocation.config)
        case .clip:
            try clipPaths(invocation.positional, config: invocation.config)
        case .genTests:
            try generateTestFiles(invocation.positional)
        case .install:
            try installAgent(config: invocation.config)
        case .uninstall:
            try uninstallAgent()
        case .status:
            try printAgentStatus()
        }
    }
}

/// The parsed command line.
struct Invocation {
    var command: Command
    var config: Configuration
    var positional: [String]
    var interval: TimeInterval
}

/// Supported subcommands (§2.7).
enum Command: String {
    case run
    case loop
    case clean
    case clip
    case genTests = "gen-tests"
    case install
    case uninstall
    case status
    case help
}

/// Command line parsing (§2.7).
enum CLI {
    static func parse(_ args: [String]) throws -> Invocation {
        var command: Command? = nil
        var positional: [String] = []
        var watchDir: String? = nil
        var ttl: TimeInterval? = nil
        var interval: TimeInterval? = nil
        var verbose = false
        var permanent = false

        var index = 0
        while index < args.count {
            let arg = args[index]

            func value(for flag: String) throws -> String {
                index += 1
                guard index < args.count else {
                    throw CLIError.usage("missing value for \(flag)")
                }
                return args[index]
            }

            switch arg {
            case "--dir":
                watchDir = try value(for: "--dir")
            case "--ttl":
                ttl = try Configuration.parseTTL(try value(for: "--ttl"))
            case "--interval":
                guard let raw = TimeInterval(try value(for: "--interval")), raw > 0 else {
                    throw CLIError.usage("invalid --interval value (expected a positive number of seconds)")
                }
                interval = raw
            case "--verbose":
                verbose = true
            case "--no-trash":
                permanent = true
            case "-h", "--help":
                command = .help
            default:
                if arg.hasPrefix("--") {
                    if let value = argValue(arg, prefix: "--dir=") {
                        watchDir = value
                    } else if let value = argValue(arg, prefix: "--ttl=") {
                        ttl = try Configuration.parseTTL(value)
                    } else if let value = argValue(arg, prefix: "--interval=") {
                        guard let raw = TimeInterval(value), raw > 0 else {
                            throw CLIError.usage("invalid --interval value (expected a positive number of seconds)")
                        }
                        interval = raw
                    } else {
                        throw CLIError.usage("unknown option '\(arg)'")
                    }
                } else if arg.hasPrefix("-") {
                    throw CLIError.usage("unknown option '\(arg)'")
                } else if command == nil, let parsed = Command(rawValue: arg) {
                    command = parsed
                } else {
                    positional.append(arg)
                }
            }
            index += 1
        }

        var config = try Configuration.parse(args)
        if let watchDir = watchDir {
            config.watchDir = Configuration.resolvePath(watchDir)
        }
        if let ttl = ttl {
            config.ttl = ttl
        }
        config.verbose = verbose || config.verbose
        config.permanent = permanent || config.permanent

        return Invocation(
            command: command ?? .run,
            config: config,
            positional: positional,
            interval: interval ?? Constants.cycleInterval
        )
    }

    private static func argValue(_ arg: String, prefix: String) -> String? {
        guard arg.hasPrefix(prefix) else { return nil }
        return String(arg.dropFirst(prefix.count))
    }

    static func printUsage() {
        let usage = """
        pseudocopy — watch a folder, clip every new file, reap old ones

        USAGE:
          pseudocopy run                 # one watch+reap cycle (what launchd calls)
          pseudocopy loop [--interval N] # resident loop, for foreground development only
          pseudocopy clean [--no-trash]  # force-reap right now (files older than TTL)
          pseudocopy clip <path...>      # clip a file manually, bypassing settle logic
          pseudocopy gen-tests <dir>     # write sample files for testing
          pseudocopy install             # write LaunchAgent plist + launchctl bootstrap
          pseudocopy uninstall           # launchctl bootout + remove plist
          pseudocopy status              # exit 0 if agent is loaded, 1 otherwise
          pseudocopy help                # usage

        GLOBAL FLAGS:
          --dir <path>      watch dir (default ~/Temp); created on install if missing
          --ttl <seconds>   reaper time-to-live (default 3600)
          --verbose         log every cycle, not just events
          --no-trash        delete permanently instead of moving to the Trash
          --interval <secs> cycle interval for `loop` (default 5)

        EXIT CODES:
          0  success
          1  runtime error (reason is written to stderr)
        """
        print(usage)
    }

    /// Writes a message to stderr and exits with status 1 (§2.7).
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("pseudocopy: " + message + "\n").utf8))
        exit(1)
    }
}

Pseudocopy.main()
