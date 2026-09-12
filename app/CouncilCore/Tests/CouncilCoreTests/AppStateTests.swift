import XCTest
@testable import CouncilCore

final class AppStateTests: XCTestCase {
    func testMissingFileYieldsDefaults() throws {
        let dir = try Fixtures.tempDir("appstate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = SessionAppState.load(from: dir)
        XCTAssertEqual(s, SessionAppState())
        XCTAssertFalse(s.live)
    }

    func testRoundTrip() throws {
        let dir = try Fixtures.tempDir("appstate-rt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = try SessionAppState.update(in: dir) {
            $0.sessionIds = ["claude": "9c1b…", "codex": "thread-1"]
            $0.cwdOverride = "/Users/x/proj"
            $0.lastSeenId = 42
            $0.live = true
        }
        XCTAssertEqual(SessionAppState.load(from: dir), s)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("app.json").path))
        // config.json is untouched by app state.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path))
    }

    func testAnUnsentDraftSurvivesARoundTrip() throws {
        let dir = try Fixtures.tempDir("appstate-draft")
        defer { try? FileManager.default.removeItem(at: dir) }
        try SessionAppState.update(in: dir) {
            $0.draft = "half a question about @codex"
            $0.budget = 20
        }
        XCTAssertEqual(SessionAppState.load(from: dir).draft, "half a question about @codex")
        // Clearing it is a real state, not a missing key: the next load must not resurrect the old draft.
        try SessionAppState.update(in: dir) { $0.draft = nil }
        XCTAssertNil(SessionAppState.load(from: dir).draft)
        XCTAssertEqual(SessionAppState.load(from: dir).budget, 20, "clearing the draft keeps the rest")
    }

    func testUnreadCount() {
        let msgs = [
            Message(id: 1, ts: "", sender: "user", text: "q"),
            Message(id: 2, ts: "", sender: "codex", text: "a"),
            Message(id: 3, ts: "", sender: "system", kind: Message.kindNote, text: "n"),
            Message(id: 4, ts: "", sender: "claude", text: "b"),
        ]
        XCTAssertEqual(SessionAppState().unreadCount(in: msgs), 2)
        XCTAssertEqual(SessionAppState(lastSeenId: 2).unreadCount(in: msgs), 1)
        XCTAssertEqual(SessionAppState(lastSeenId: 4).unreadCount(in: msgs), 0)
    }

    /// The view model and the runtime each hold their own copy of this file. Neither may write its copy back
    /// whole: everything the other changed since that copy was loaded would go with it. `update` is the only
    /// public way to change the file, so a stale owner can no longer undo the other's work — and because the
    /// whole-struct write is private, that is enforced at compile time rather than by convention.
    func testAStaleOwnerCannotUndoTheOthersChanges() throws {
        let dir = try Fixtures.tempDir("appstate-owners")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Both owners load the file at the same moment: empty.
        let viewModelCopy = SessionAppState.load(from: dir)
        XCTAssertNil(viewModelCopy.lastSeenId)

        // The runtime starts the members and records what it owns.
        try SessionAppState.update(in: dir) {
            $0.sessionIds = ["claude": "sess-1", "codex": "thread-9"]
            $0.live = true
            $0.muted = ["deepseek"]
            $0.budget = 5
        }

        // The view model, still holding its pre-start copy, marks the chat read and saves a draft.
        try SessionAppState.update(in: dir) { $0.lastSeenId = 77 }
        try SessionAppState.update(in: dir) { $0.draft = "half a thought" }

        let merged = SessionAppState.load(from: dir)
        XCTAssertEqual(merged.sessionIds, ["claude": "sess-1", "codex": "thread-9"], "resume information was lost")
        XCTAssertTrue(merged.live, "the chat was still live")
        XCTAssertEqual(merged.muted, ["deepseek"], "the mute was lost")
        XCTAssertEqual(merged.budget, 5, "the budget was lost")
        XCTAssertEqual(merged.lastSeenId, 77)
        XCTAssertEqual(merged.draft, "half a thought")
    }

    /// And the other way round: the runtime writing after the view model must keep the draft and read position.
    func testTheRuntimeWritingLastKeepsTheDraftAndReadPosition() throws {
        let dir = try Fixtures.tempDir("appstate-owners-2")
        defer { try? FileManager.default.removeItem(at: dir) }
        try SessionAppState.update(in: dir) { $0.draft = "unsent"; $0.lastSeenId = 12 }
        try SessionAppState.update(in: dir) { $0.live = true; $0.sessionIds = ["claude": "s"] }
        let merged = SessionAppState.load(from: dir)
        XCTAssertEqual(merged.draft, "unsent", "an unsent draft is not the runtime's to throw away")
        XCTAssertEqual(merged.lastSeenId, 12)
        XCTAssertTrue(merged.live)
    }
}
