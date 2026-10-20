import Foundation

// PLAN.md §3: installer.swift — LaunchAgent plist + launchctl integration (§5).

/// Writes the LaunchAgent plist and bootstraps the agent.
func installAgent(config: Configuration) throws {
    CLI.fail("install is not implemented yet")
}

/// Removes the LaunchAgent and its plist.
func uninstallAgent() throws {
    CLI.fail("uninstall is not implemented yet")
}

/// Prints the agent status; exits 1 when the agent is not loaded.
func printAgentStatus() throws {
    CLI.fail("status is not implemented yet")
}
