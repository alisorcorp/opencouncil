import XCTest
@testable import CouncilCore

/// `transcript.md` is shared with the CLI: members read it when a chat resumes and `council` users open it
/// directly. The golden file in the fixture was written by chat.py's own `transcript()` from the same chat.jsonl.
final class TranscriptTests: XCTestCase {
    func testRenderMatchesThePythonTranscriptByteForByte() throws {
        let dir = Fixtures.chatDir
        let config = try ChatConfig.load(from: dir)
        let messages = try Bus(directory: dir).readAll()
        let golden = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertEqual(Transcript.render(config: config, messages: messages), golden)
    }

    func testNotesAreItalicAndTheUserIsCalledYou() {
        let config = ChatConfig(created: "2026-09-10T11:00:00", cwd: "/w", title: "t",
                               members: ["claude": .init(label: "Claude")], order: ["claude"])
        let text = Transcript.render(config: config, messages: [
            Message(id: 1, ts: "2026-09-10T11:00:01", sender: "user", text: "hello"),
            Message(id: 2, ts: "2026-09-10T11:00:02", sender: "system", kind: Message.kindNote, text: "claude had nothing to add"),
        ])
        XCTAssertTrue(text.contains("**you** · 11:00:01\n\nhello\n"))
        XCTAssertTrue(text.contains("_11:00:02 · claude had nothing to add_"))
        XCTAssertTrue(text.contains("members: Claude"))
    }

    func testResumedChatsListTheirRestarts() {
        let config = ChatConfig(created: "2026-09-10T11:00:00", cwd: "/w", title: "t", members: [:], order: [],
                                budget: 12, effort: "medium", resumed: ["2026-09-10T12:00:00"])
        XCTAssertTrue(Transcript.render(config: config, messages: []).contains("resumed: 2026-09-10T12:00:00"))
    }

    func testWriteLandsBesideTheLog() throws {
        let dir = try Fixtures.tempDir("transcript")
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = ChatConfig(created: "2026-09-10T11:00:00", cwd: "/w", title: "t", members: [:], order: [])
        try Transcript.write(config: config, messages: [], to: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path))
    }
}
