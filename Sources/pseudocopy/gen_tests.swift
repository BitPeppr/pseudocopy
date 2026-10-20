import Foundation

// PLAN.md §3: gen_tests.swift — sample file generator (§6, Phase 8).

/// Writes the sample file set used for manual and scripted testing.
func generateTestFiles(_ paths: [String]) throws {
    let dir = URL(fileURLWithPath: paths.first ?? "./")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    print("not implemented")
}
