import XCTest
@testable import Council

/// A verdict member asked for permission mid-round. The card said so and offered "Open terminal"; the terminal
/// it opened said the member was not running, and the run sat there until it timed out. Nothing was broken in
/// the runtime — `VerdictRuntime` has had `host(for:)` and `orderedHosts` all along — the pane simply asked
/// `SessionViewModel.runtime`, which is the chat runtime and is nil for a verdict.
///
/// This is a structural guard rather than a behavioural one: driving the pane would need a live run with real
/// terminals, and what actually went wrong is which object was asked. So the rule is written down instead —
/// the terminal pane reaches terminals through the view model, and the view model knows about both runtimes.
final class TerminalRoutingTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)   // …/app/Council/Tests/TerminalRoutingTests.swift
            .deletingLastPathComponent()                 // Tests
            .deletingLastPathComponent()                 // Council
            .deletingLastPathComponent()                 // app
            .deletingLastPathComponent()                 // repo root
        return try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheTerminalPaneDoesNotPickARuntimeItself() throws {
        let pane = try source("app/Council/Views/Terminal/TerminalPane.swift")
        for reference in ["vm.runtime", "vm.verdictRuntime"] {
            XCTAssertFalse(pane.contains(reference),
                           "TerminalPane reads \(reference) directly, so it is right about one kind of session "
                           + "and wrong about the other — ask the view model instead")
        }
    }

    func testTheViewModelLooksInBothRuntimesForATerminal() throws {
        let vm = try source("app/Council/Models/SessionViewModel.swift")
        for accessor in ["func terminalHost(for member: String) -> TerminalHost? {",
                         "var terminalHosts: [TerminalHost] {",
                         "var lockedMembers: Set<String> {"] {
            guard let start = vm.range(of: accessor),
                  let end = vm.range(of: "\n    }", range: start.upperBound..<vm.endIndex) else {
                return XCTFail("SessionViewModel has no `\(accessor)` for the terminal pane to use")
            }
            let body = String(vm[start.upperBound..<end.lowerBound])
            XCTAssertTrue(body.contains("runtime?") && body.contains("verdictRuntime?"),
                          "\(accessor) does not fall through to the verdict runtime, so a verdict member's "
                          + "terminal is unreachable while it waits for an answer")
        }
    }
}
