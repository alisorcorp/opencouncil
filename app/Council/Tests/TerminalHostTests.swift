import XCTest
import CouncilCore
@testable import Council

/// Real ptys, no CLIs: a small bash TUI stands in for a member to prove paste framing, the input lock, screen
/// reading and exit detection. Isolation sits on the methods, not the class: XCTest instantiates test cases off
/// the main thread while discovering them.
final class TerminalHostTests: XCTestCase {
    /// Enables bracketed paste, reads one paste followed by Enter byte by byte, then reports the line count and
    /// whether Enter arrived on its own after the paste end marker. Pure shell: no interpreter startup, so none of
    /// the privacy prompts an interpreter can raise inside a test host.
    private static let bashTUI = """
    stty raw -echo
    printf '\\033[?2004h> '
    buf=""
    while :; do
      c=$(dd bs=1 count=1 2>/dev/null; printf x); c=${c%x}
      [ -z "$c" ] && break
      buf="$buf$c"
      case "$buf" in *$'\\033[201~'*$'\\r') break;; esac
    done
    body="${buf#*$'\\033[200~'}"; body="${body%%$'\\033[201~'*}"
    after="${buf##*$'\\033[201~'}"
    n=$(printf '%s\\n' "$body" | wc -l | tr -d ' ')
    if [ "$after" = $'\\r' ]; then t=CR; else t=other; fi
    printf 'LINES=%s TAIL=%s\\r\\n' "$n" "$t"
    """

    private nonisolated func plan(_ exe: String, _ args: [String]) -> LaunchPlan {
        LaunchPlan(backend: .claude, executable: URL(fileURLWithPath: exe), arguments: args,
                   environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8", "HOME": NSHomeDirectory()],
                   currentDirectory: URL(fileURLWithPath: NSTemporaryDirectory()), sessionId: nil, isResume: false)
    }

    @MainActor
    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func testHostGuardKeepsTheAppAwayFromTheCouncilFolder() {
        XCTAssertTrue(AppEnvironment.isTestHost, "the test host must not bootstrap against ~/Documents")
    }

    @MainActor
    func testPasteArrivesAsOneBracketedSubmission() async throws {
        let host = TerminalHost(member: "t")
        var exit: Int32? = -1
        host.onExit = { _, code in exit = code }
        host.launch(plan("/bin/bash", ["-c", Self.bashTUI]))

        let bracketed = await waitUntil { host.getTerminal().bracketedPasteMode }
        XCTAssertTrue(bracketed, "TUI should enable bracketed paste; screen: \(host.recentLines())")
        XCTAssertNotNil(host.lastOutputAt)
        XCTAssertGreaterThan(host.outputBytes, 0)

        await host.paste("one\ntwo\nthree")
        // The report follows the prompt on the same line ("> LINES=3 TAIL=CR"): raw mode, no echo, no newline.
        let reported = await waitUntil { host.recentLines().contains { $0.contains("LINES=") } }
        XCTAssertTrue(reported, host.recentLines().joined(separator: "\n"))
        let screen = host.recentLines().first { $0.contains("LINES=") } ?? ""
        let line = screen[(screen.range(of: "LINES=")?.lowerBound ?? screen.startIndex)...]
        XCTAssertTrue(line.hasPrefix("LINES=3 "), "three lines must arrive as one submission: \(line)")
        XCTAssertTrue(line.contains("TAIL=CR"), "Enter must follow the paste end marker on its own: \(line)")

        let exited = await waitUntil { host.hasExited }
        XCTAssertTrue(exited)
        XCTAssertEqual(exit, 0)
        XCTAssertEqual(host.exitStatus, 0)
        XCTAssertFalse(host.isRunning)
    }

    @MainActor
    func testLockedUserInputIsDroppedButOwnWritesPass() async throws {
        let host = TerminalHost(member: "t")
        host.launch(plan("/bin/cat", []))
        let running = await waitUntil(3) { host.isRunning }
        XCTAssertTrue(running)

        host.inputLocked = true
        host.send(txt: "x")                                   // what a key press does
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(host.recentLines().joined().contains("x"), "locked input must not reach the pty")

        host.write("y\r")                                     // the app's own write
        let echoed = await waitUntil { host.recentLines().joined().contains("y") }
        XCTAssertTrue(echoed, host.recentLines().joined(separator: "\n"))

        host.inputLocked = false
        host.send(txt: "z")
        let z = await waitUntil { host.recentLines().joined().contains("z") }
        XCTAssertTrue(z)

        var exitSeen: Int32? = nil
        host.onExit = { _, code in exitSeen = code }
        host.stop()
        XCTAssertTrue(host.hasExited)
        XCTAssertFalse(host.isRunning)
        XCTAssertEqual(exitSeen, 128 + SIGTERM)
    }

    func testDecodeWaitStatus() {
        XCTAssertEqual(TerminalHost.decodeWaitStatus(0), 0)
        XCTAssertEqual(TerminalHost.decodeWaitStatus(1 << 8), 1)
        XCTAssertEqual(TerminalHost.decodeWaitStatus(130 << 8), 130)
        XCTAssertEqual(TerminalHost.decodeWaitStatus(SIGKILL), 128 + SIGKILL)
    }
}
