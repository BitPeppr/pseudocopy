import Foundation

// PLAN.md §3: fs.swift holds the filesystem core and stays free of AppKit
// imports so that it remains testable on its own.

/// How a file should be represented on the pasteboard (§2.2).
enum FileKind: String {
    case text
    case image
    case pdf
    case other
}

/// The (size, mtime) fingerprint used for the settle check (§2.1).
struct Fingerprint: Codable, Equatable {
    var size: Int
    var mtime: Date
}

/// The outcome of inspecting one directory entry.
enum FileVerification {
    /// Not a candidate at all (directory, symlink, dotfile).
    case ignored
    /// A partial download in progress.
    case partial
    /// Fingerprint unchanged since the previous scan — safe to act on.
    case settled(Fingerprint)
    /// Fingerprint changed since the previous scan — still settling.
    case settling
}

// MARK: - Subcommands (implemented in later phases)

/// One watch + reap cycle.
func runCycle(config: Configuration) throws {
    print("not implemented")
}

/// Resident loop, for foreground development only.
func runLoop(config: Configuration, interval: TimeInterval) throws {
    print("not implemented")
}

/// Force-reap everything older than the TTL right now.
func runClean(config: Configuration) throws {
    print("not implemented")
}

/// Clip files manually, bypassing the settle logic.
func clipPaths(_ paths: [String], config: Configuration) throws {
    print("not implemented")
}
