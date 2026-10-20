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
            try runLoop(config: invocation.config, interval: invocation.config.interval)
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
            try printAgentStatus(config: invocation.config)
        case .config:
            try runConfigCommand(invocation.positional, config: invocation.config)
        case .kick:
            try kickAgent()
        case .version:
            print("pseudocopy \(Constants.version)")
        }
    }
}

/// The parsed command line.
struct Invocation {
    var command: Command
    var config: Configuration
    var positional: [String]
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
    case config
    case kick
    case version
    case help
}

/// The global flags that take a value. Every one of them can also be stored
/// in the settings file; the command line always wins.
private let globalFlagsWithValue: [String] = [
    "--dir", "--ttl", "--interval", "--log", "--state-dir",
    "--text-limit", "--embed-limit", "--materialise-limit",
]

/// Command line parsing (§2.7).
enum CLI {
    static func parse(_ args: [String]) throws -> Invocation {
        var command: Command? = nil
        var positional: [String] = []
        /// The global flags, handed over to `Configuration`.
        var globalFlags: [String] = []

        var index = 0
        while index < args.count {
            let arg = args[index]

            // Everything after `--` is a positional argument, so a file called
            // `-notes.txt` can still be clipped.
            if arg == "--" {
                positional.append(contentsOf: args[(index + 1)...])
                break
            }

            func value(for flag: String) throws -> String {
                index += 1
                guard index < args.count else { throw CLIError.usage("missing value for \(flag)") }
                return args[index]
            }

            switch arg {
            case "--dir", "--ttl", "--interval", "--log", "--state-dir",
                 "--text-limit", "--embed-limit", "--materialise-limit":
                globalFlags.append(contentsOf: [arg, try value(for: arg)])
            case "--verbose", "--no-trash":
                globalFlags.append(arg)
            case "-h", "--help":
                command = .help
            case "-V", "--version":
                command = .version
            default:
                if arg.hasPrefix("--") {
                    // The `--flag=value` form is normalised to two arguments.
                    if let (flag, value) = splitAssignment(arg),
                       globalFlagsWithValue.contains(flag) {
                        globalFlags.append(contentsOf: [flag, value])
                    } else {
                        throw CLIError.usage("unknown option '\(arg)'")
                    }
                } else if arg.hasPrefix("-") {
                    // A negative number is a value, not an option.
                    if Double(arg.dropFirst()) != nil, command != nil {
                        positional.append(arg)
                    } else {
                        throw CLIError.usage("unknown option '\(arg)'")
                    }
                } else if command == nil, let parsed = Command(rawValue: arg) {
                    command = parsed
                } else if command == nil {
                    throw CLIError.usage("unknown subcommand '\(arg)' (try 'pseudocopy help')")
                } else {
                    positional.append(arg)
                }
            }
            index += 1
        }

        // The `config` command has to work even when the stored settings are
        // broken — otherwise the user could not repair them.
        let config = try Configuration.resolve(
            settings: SettingsStore.load(),
            arguments: globalFlags,
            validate: command != .config
        )

        return Invocation(
            // Without a subcommand nothing happens — a bare `pseudocopy` must
            // not silently start a real cycle against ~/Temp.
            command: command ?? .help,
            config: config,
            positional: positional
        )
    }

    /// Splits `--flag=value` into its two parts.
    private static func splitAssignment(_ arg: String) -> (String, String)? {
        guard let separator = arg.firstIndex(of: "=") else { return nil }
        let flag = String(arg[arg.startIndex..<separator])
        let value = String(arg[arg.index(after: separator)...])
        return (flag, value)
    }

    static func printUsage() {
        let usage = """
        pseudocopy — watch a folder, clip every new file, reap old ones

        USAGE:
          pseudocopy run                 # one watch+reap cycle (what launchd calls)
          pseudocopy loop [--interval N] # resident loop, for foreground development only
          pseudocopy clean [--no-trash]  # force-reap now; bypasses the settle rule
          pseudocopy clip <path...>      # clip a file manually, bypassing settle logic
          pseudocopy gen-tests <dir>     # write sample files for testing
          pseudocopy install             # write the LaunchAgent plist + launchctl bootstrap
          pseudocopy uninstall           # launchctl bootout + remove the plist
          pseudocopy status              # exit 0 if the agent is loaded, 1 otherwise
          pseudocopy config [action]     # read and change the settings file
          pseudocopy kick                # force one cycle of the agent right now
          pseudocopy version             # print the version
          pseudocopy help                # usage

        GLOBAL FLAGS (they win over the settings file):
          --dir <path>           watch dir (default ~/Temp); refuses /, your home
                                 folder, other users' homes, /Volumes, shared roots
          --ttl <seconds>        reaper time-to-live (default 3600)
          --interval <seconds>   how often the folder is checked (default 5)
          --log <path>           where the agent writes its log
          --state-dir <path>     where the state store lives
          --text-limit <bytes>   largest text file that is embedded as text
          --embed-limit <bytes>  largest generic file whose bytes are embedded
          --materialise-limit <bytes>  largest image or PDF that is materialised
          --verbose              log every cycle, not just events
          --no-trash             delete permanently instead of moving to the Trash

        SETTINGS FILE:
          ~/.Library/Application Support/pseudocopy/config.json
          pseudocopy config list        show every setting and where it comes from
          pseudocopy config get <key>   print one effective value
          pseudocopy config set <key> <value>   change one setting
          pseudocopy config unset <key> back to the default
          pseudocopy config reset       remove the file
          pseudocopy config path        print the file's path

        NOTES:
          Files already in the folder when it is first seen (or after the state
          was lost) are treated as leftovers and are not copied.
          `clean` is an explicit override: do not run it while a download is
          in progress. `clip` does not update the agent's state.

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
