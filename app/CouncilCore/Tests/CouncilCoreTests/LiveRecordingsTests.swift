import XCTest
@testable import CouncilCore

/// Real hook payloads recorded on 2026-09-10 from Claude Code 2.1.267, Codex 0.154.0 and pi 0.85.1 running inside the
/// app (`Council --drive` with the prompt "Reply with just the word hello."), home directory scrubbed. Guards the
/// normaliser against the shapes the CLIs actually emit, as opposed to the hand-written fixtures.
final class LiveRecordingsTests: XCTestCase {
    private func events(for member: String) throws -> [MemberEvent] {
        let url = Fixtures.root.appendingPathComponent("hooks/live-2026-09-10.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { RawEvent.decode(line: String($0)) }
            .filter { $0.member == member }
            .flatMap(EventNormalizer.normalize)
    }

    func testClaudeCodeSession() throws {
        XCTAssertEqual(try events(for: "claude"), [
            .started(sessionId: "9c69f2bc-83fd-406c-8d4d-878596c8d627", reason: "startup"),
            .turnStarted,
            .turnEnded(lastMessage: "hello"),
            .ended(reason: "other"),
        ])
    }

    func testCodexSessionReportsItsOwnIdWithTheFirstPrompt() throws {
        // Codex fires SessionStart together with the first UserPromptSubmit, not at launch.
        XCTAssertEqual(try events(for: "codex"), [
            .started(sessionId: "01a08de4-cdf2-75d1-804c-9eb04fcd7aa4", reason: "startup"),
            .turnStarted,
            .turnEnded(lastMessage: "hello"),
        ])
    }

    func testPiExtensionSession() throws {
        // `input`, `turn_start` and `turn_end` are recorded but carry nothing the app acts on.
        XCTAssertEqual(try events(for: "deepseek"), [
            .started(sessionId: "16d30b93-d528-4c75-a81b-d0df70e5ff85", reason: "startup"),
            .turnStarted,
            .turnEnded(lastMessage: "hello"),
            .ended(reason: "quit"),
        ])
    }

    func testRecordingUsesTheSharedTimestampFormat() throws {
        let url = Fixtures.root.appendingPathComponent("hooks/live-2026-09-10.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(separator: "\n") {
            let raw = try XCTUnwrap(RawEvent.decode(line: String(line)))
            XCTAssertNotNil(MessageTime.parse(raw.ts), "\(raw.backend) wrote an unexpected timestamp: \(raw.ts)")
        }
    }
}
