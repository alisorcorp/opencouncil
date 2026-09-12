import XCTest
import CouncilCore
@testable import Council

/// Taking a live slot has to start the session that asked for one. Chats and runs share the live cap and the
/// sheet that offers to free a slot, but the callback used to call `startMembers` whatever the session was —
/// and `startMembers` accepts only chats. A run that took a slot therefore stopped somebody else's members and
/// then quietly did nothing, leaving the user to press Ask again without being told why.
///
/// Neither branch can actually launch anything here: the view model is built without a council folder, which
/// is what makes the two distinguishable. The run branch reports that it could not start; the chat branch is
/// silent. That difference is the dispatch.
final class LiveSlotTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-slot-\(UUID().uuidString)")
        for sub in ["chats", "runs"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(sub),
                                                    withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRun() throws {
        let dir = root.appendingPathComponent("runs/2026-01-01_000000_walk-or-drive")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("r1"), withIntermediateDirectories: true)
        let config: [String: Any] = [
            "created": "2026-01-01T00:00:00", "question_preview": "Walk or drive?",
            "order": ["claude", "codex"], "rounds": 1, "anonymous": false,
            "members": ["claude": ["name": "claude", "backend": "claude", "label": "Claude"],
                        "codex": ["name": "codex", "backend": "codex", "label": "Codex"]],
            "moderator": ["name": "claude", "backend": "claude", "label": "Claude"],
        ]
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("config.json"))
        try "Walk or drive?\n".write(to: dir.appendingPathComponent("question.md"), atomically: true, encoding: .utf8)
    }

    private func makeChat() throws {
        let dir = root.appendingPathComponent("chats/2026-01-01_000000_a-chat")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "created": "2026-01-01T00:00:00", "title": "a chat", "cwd": root.path,
            "order": ["claude", "codex"], "budget": 20,
            "members": ["claude": ["name": "claude", "backend": "claude", "label": "Claude"],
                        "codex": ["name": "codex", "backend": "codex", "label": "Codex"]],
        ]
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("config.json"))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("chat.jsonl").path, contents: Data())
    }

    private func summary(_ kind: SessionKind) throws -> SessionSummary {
        let found = SessionStore(paths: CouncilPaths(root: root)).scan().first { $0.kind == kind }
        return try XCTUnwrap(found, "no \(kind) session was scanned")
    }

    @MainActor
    func testTakingASlotForARunStartsTheRun() throws {
        try makeRun()
        let vm = SessionViewModel(summary: try summary(.verdict))
        XCTAssertNil(vm.startError, "nothing has been attempted yet")
        vm.takeSlot(from: "some-other-session")
        XCTAssertNotNil(vm.startError, "the run branch was never taken: the slot was freed and nothing used it")
    }

    @MainActor
    func testTakingASlotForAChatStillGoesToTheChatPath() throws {
        try makeChat()
        let vm = SessionViewModel(summary: try summary(.chat))
        vm.takeSlot(from: "some-other-session")
        XCTAssertNil(vm.startError, "a chat goes to startMembers, which says nothing without a live registry")
    }

    /// Retry on a run that is not live goes through the same start, so it must reach the run branch too.
    @MainActor
    func testRetryingAModeratorOnARunThatIsNotLiveAttemptsAStart() throws {
        try makeRun()
        let vm = SessionViewModel(summary: try summary(.verdict))
        vm.retryModerator()
        XCTAssertNotNil(vm.startError, "retry did not attempt to start the run at all")
    }
}
