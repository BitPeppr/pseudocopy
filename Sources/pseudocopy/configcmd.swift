import Foundation

// PLAN.md §3: configcmd.swift — `pseudocopy config` (§2.7).
//
// The settings file is the single source of truth for the agent, so every
// knob can be changed from the command line without reinstalling anything.

/// Runs `pseudocopy config …`.
func runConfigCommand(_ positional: [String], config: Configuration) throws {
    let action = positional.first ?? "list"
    let rest = Array(positional.dropFirst())

    switch action {
    case "list":
        printSettingsList(config: config)
    case "path":
        print(SettingsStore.fileURL.path)
    case "get":
        guard let key = try settingKey(rest.first) else {
            throw CLIError.usage("pseudocopy config get <key> — known keys: \(settingKeyNames())")
        }
        print(effectiveValue(for: key, config: config))
    case "set":
        guard let key = try settingKey(rest.first) else {
            throw CLIError.usage("pseudocopy config set <key> <value> — known keys: \(settingKeyNames())")
        }
        guard rest.count >= 2 else {
            throw CLIError.usage("pseudocopy config set \(key.rawValue) <value>")
        }
        var settings = SettingsStore.load()
        try applySetting(key, rest[1], to: &settings)
        try SettingsStore.save(settings)
        print("\(key.rawValue) = \(effectiveValue(for: key, config: try Configuration.resolve(settings: settings, arguments: [], validate: false)))")
        print("settings: \(SettingsStore.fileURL.path)")
        printWarnings(config: try Configuration.resolve(settings: settings, arguments: [], validate: false))
        printRestartHint()
    case "unset":
        guard let key = try settingKey(rest.first) else {
            throw CLIError.usage("pseudocopy config unset <key> — known keys: \(settingKeyNames())")
        }
        var settings = SettingsStore.load()
        removeSetting(key, from: &settings)
        try SettingsStore.save(settings)
        print("\(key.rawValue) is back to its default")
        printRestartHint()
    case "reset":
        let settings = SettingsStore.load()
        try SettingsStore.remove()
        print("removed \(SettingsStore.fileURL.path)")
        if settings.dir != nil || settings.ttl != nil || settings.interval != nil {
            print("  the built-in defaults apply again")
        }
        printRestartHint()
    default:
        throw CLIError.usage("""
            unknown config action '\(action)'; expected one of: \
            list, get, set, unset, reset, path
            """)
    }
}

/// Parses a setting name.
private func settingKey(_ raw: String?) throws -> SettingKey? {
    guard let raw = raw else { return nil }
    guard let key = SettingKey(rawValue: raw) else {
        throw CLIError.usage("unknown setting '\(raw)' — known keys: \(settingKeyNames())")
    }
    return key
}

private func settingKeyNames() -> String {
    SettingKey.allCases.map(\.rawValue).joined(separator: ", ")
}

/// Stores one setting, after checking the value.
private func applySetting(_ key: SettingKey, _ raw: String, to settings: inout Settings) throws {
    switch key {
    case .dir:
        // The watch folder guard runs here too: a setting may not point the
        // reaper at the home directory.
        settings.dir = try Configuration.resolvePath(raw).path
    case .ttl:
        settings.ttl = try Configuration.parseTTL(raw)
    case .interval:
        settings.interval = try Configuration.parseInterval(raw)
    case .permanent:
        settings.permanent = try parseBool(raw)
    case .verbose:
        settings.verbose = try parseBool(raw)
    case .logPath:
        settings.logPath = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            .standardizedFileURL.path
    case .stateDir:
        settings.stateDir = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            .standardizedFileURL.path
    case .textLimit:
        settings.textLimit = try Configuration.parseByteLimit(raw, flag: "--text-limit")
    case .embedLimit:
        settings.embedLimit = try Configuration.parseByteLimit(raw, flag: "--embed-limit")
    case .materialiseLimit:
        settings.materialiseLimit = try Configuration.parseByteLimit(raw, flag: "--materialise-limit")
    }
}

/// Removes one setting.
private func removeSetting(_ key: SettingKey, from settings: inout Settings) {
    switch key {
    case .dir: settings.dir = nil
    case .ttl: settings.ttl = nil
    case .interval: settings.interval = nil
    case .permanent: settings.permanent = nil
    case .verbose: settings.verbose = nil
    case .logPath: settings.logPath = nil
    case .stateDir: settings.stateDir = nil
    case .textLimit: settings.textLimit = nil
    case .embedLimit: settings.embedLimit = nil
    case .materialiseLimit: settings.materialiseLimit = nil
    }
}

/// Parses a boolean.
private func parseBool(_ raw: String) throws -> Bool {
    switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
    case "true", "yes", "on", "1": return true
    case "false", "no", "off", "0": return false
    default:
        throw CLIError.usage("'\(raw)' is not a boolean (use true or false)")
    }
}

/// The effective value of one setting, as a printable string.
func effectiveValue(for key: SettingKey, config: Configuration) -> String {
    switch key {
    case .dir: return config.watchDir.path
    case .ttl: return "\(formatSeconds(config.ttl))s"
    case .interval: return "\(formatSeconds(config.interval))s"
    case .permanent: return config.permanent ? "true" : "false"
    case .verbose: return config.verbose ? "true" : "false"
    case .logPath: return config.logPath.path
    case .stateDir: return config.stateDir.path
    case .textLimit: return formatBytes(config.textLimitBytes)
    case .embedLimit: return formatBytes(config.embedLimitBytes)
    case .materialiseLimit: return formatBytes(config.materialiseLimitBytes)
    }
}

/// Formats a duration without a trailing `.0`.
func formatSeconds(_ value: TimeInterval) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
}

/// Formats a byte count.
func formatBytes(_ value: Int) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var size = Double(value)
    var unit = 0
    while size >= 1024, unit < units.count - 1 {
        size /= 1024
        unit += 1
    }
    return unit == 0 ? "\(value)B" : String(format: "%.1f%@", size, units[unit])
}

/// Prints every setting, its effective value and where that value came from.
func printSettingsList(config: Configuration) {
    print("settings file: \(SettingsStore.fileURL.path)")
    print("")
    for key in SettingKey.allCases {
        let source = config.sources[key.rawValue] ?? "default"
        let value = effectiveValue(for: key, config: config)
        let name = key.rawValue.padding(toLength: 19, withPad: " ", startingAt: 0)
        print("  \(name) \(value)  (\(source))")
    }
    print("")
    print("change one with:  pseudocopy config set <key> <value>")

    // A hand-edited settings file may point at a folder the guard refuses.
    do {
        try Configuration.validateWatchDir(config.watchDir)
    } catch {
        print("")
        print("warning: \(config.watchDir.path) is refused by the watch-folder guard")
    }
}

/// Reminds the user that two settings only take effect after a restart.
func printRestartHint() {
    print("note: the agent picks this up on its next cycle; the log path and the")
    print("      check interval live in the agent's plist — re-run 'pseudocopy install'")
    print("      (or 'brew services restart pseudocopy') for those to change")
}
