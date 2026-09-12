import XCTest
import CouncilCore
@testable import Council

/// Landing in a session that was just created. The bug this covers: the directory watcher fires on the new
/// folder, `refresh` skips a scan while one is already running, and a single refresh could therefore return
/// before the session was listed — leaving the row selected in the sidebar and "No session selected" beside it.
final class SessionSelectionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-select-\(UUID().uuidString)")
        for sub in ["chats", "runs"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(sub),
                                                    withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func makeRun(_ name: String) throws -> URL {
        let dir = root.appendingPathComponent("runs/\(name)")
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
        return dir
    }

    @MainActor
    func testTheNewSessionIsListedBeforeItIsSelected() async throws {
        let model = SessionsModel(paths: CouncilPaths(root: root))
        await model.refresh()
        let dir = try makeRun("2026-01-01_120000_walk-or-drive")

        // A scan kicked off just before, as the directory watcher does when the folder appears.
        let concurrent = Task { await model.refresh() }
        await model.select(newSessionAt: dir)
        await concurrent.value

        XCTAssertEqual(model.selectedID, "2026-01-01_120000_walk-or-drive")
        XCTAssertTrue(model.sessions.contains { $0.id == model.selectedID },
                      "the selected id has to resolve to a session, or the detail pane has nothing to show")
    }

    @MainActor
    func testAskingStraightAwayIsOfferedOnceAndOnlyToThatSession() async throws {
        let model = SessionsModel(paths: CouncilPaths(root: root))
        let dir = try makeRun("2026-01-01_120000_walk-or-drive")
        await model.select(newSessionAt: dir, startImmediately: true)

        XCTAssertFalse(model.takeAutoStart(for: "some-other-session"))
        XCTAssertTrue(model.takeAutoStart(for: dir.lastPathComponent))
        XCTAssertFalse(model.takeAutoStart(for: dir.lastPathComponent),
                       "re-selecting the session later must not start it again")
    }

    @MainActor
    func testASessionOpenedNormallyIsNotStarted() async throws {
        let model = SessionsModel(paths: CouncilPaths(root: root))
        let dir = try makeRun("2026-01-01_120000_walk-or-drive")
        await model.select(newSessionAt: dir)
        XCTAssertFalse(model.takeAutoStart(for: dir.lastPathComponent))
    }

    /// A chat created from the sheet starts its members too, not only a run. Until it did, the members
    /// introduced themselves after the first message instead of before it, which read as though they had
    /// ignored what was typed.
    @MainActor
    func testAChatCreatedFromTheSheetAsksToStartAsWell() async throws {
        let model = SessionsModel(paths: CouncilPaths(root: root))
        let dir = root.appendingPathComponent("chats/2026-01-01_120000_a-chat")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "created": "2026-01-01T00:00:00", "title": "a chat", "cwd": root.path,
            "order": ["claude"], "budget": 20,
            "members": ["claude": ["name": "claude", "backend": "claude", "label": "Claude"]],
        ]
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("config.json"))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("chat.jsonl").path, contents: Data())

        await model.select(newSessionAt: dir, startImmediately: true)
        XCTAssertTrue(model.takeAutoStart(for: dir.lastPathComponent), "a new chat does not start its members")
    }
}
