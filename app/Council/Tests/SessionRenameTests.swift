import XCTest
import CouncilCore
@testable import Council

/// Renaming a chat has to leave the CLI able to find it: `council session <name>` looks the directory up by
/// the slug in its name, so the folder moves with the title.
final class SessionRenameTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chats"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("runs"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A chat directory in the CLI's shape, with a member field the app does not model so the rewrite can be
    /// checked for dropping it.
    @discardableResult
    private func makeChat(_ name: String, title: String) throws -> URL {
        let dir = root.appendingPathComponent("chats/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "created": "2026-01-01T00:00:00", "cwd": root.path, "title": title,
            "order": ["claude"], "budget": 20, "effort": "medium",
            "members": ["claude": ["name": "claude", "backend": "claude", "label": "Claude",
                                   "chat_args": ["--dangerously-skip-permissions"], "chat_kind": "herdr",
                                   "agent": "claude-c1234", "max_tokens": 8192]],
        ]
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("config.json"))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("chat.jsonl").path, contents: Data())
        return dir
    }

    @MainActor
    private func summary(_ model: SessionsModel, _ id: String) -> SessionSummary? {
        model.sessions.first { $0.id == id }
    }

    @MainActor
    func testTheFolderMovesWithTheTitle() async throws {
        try makeChat("2026-01-01_120000_old-name", title: "old name")
        let model = SessionsModel(paths: CouncilPaths(root: root))
        await model.refresh()
        let session = try XCTUnwrap(summary(model, "2026-01-01_120000_old-name"))

        let problem = await model.rename(session, to: "shipping the router", live: nil)
        XCTAssertNil(problem)

        let moved = root.appendingPathComponent("chats/2026-01-01_120000_shipping-the-router")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path), "the slug follows the new name")
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.path))
        XCTAssertEqual(try ChatConfig.load(from: moved).title, "shipping the router")
        XCTAssertEqual(model.selectedID, nil)
        XCTAssertNotNil(summary(model, moved.lastPathComponent), "the list shows it under the new name")
    }

    @MainActor
    func testTheCLIsOwnFieldsSurviveTheRewrite() async throws {
        try makeChat("2026-01-01_120000_old-name", title: "old name")
        let model = SessionsModel(paths: CouncilPaths(root: root))
        await model.refresh()
        let session = try XCTUnwrap(summary(model, "2026-01-01_120000_old-name"))
        _ = await model.rename(session, to: "new name", live: nil)

        let moved = root.appendingPathComponent("chats/2026-01-01_120000_new-name/config.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: moved)) as? [String: Any])
        let member = try XCTUnwrap((json["members"] as? [String: Any])?["claude"] as? [String: Any])
        XCTAssertEqual(member["agent"] as? String, "claude-c1234", "herdr's own field is not dropped")
        XCTAssertEqual(member["max_tokens"] as? Int, 8192, "nor is a field the app does not model")
        XCTAssertEqual(json["title"] as? String, "new name")
    }

    @MainActor
    func testTheCurrentLinkFollowsTheRename() async throws {
        let dir = try makeChat("2026-01-01_120000_old-name", title: "old name")
        let link = root.appendingPathComponent("chats/current")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        let model = SessionsModel(paths: CouncilPaths(root: root))
        await model.refresh()
        let session = try XCTUnwrap(summary(model, "2026-01-01_120000_old-name"))
        _ = await model.rename(session, to: "new name", live: nil)

        let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertTrue(target.hasSuffix("2026-01-01_120000_new-name"), target)
    }

    @MainActor
    func testAClashingNameIsRefusedAndNothingMoves() async throws {
        try makeChat("2026-01-01_120000_old-name", title: "old name")
        try makeChat("2026-01-01_120000_taken", title: "taken")
        let model = SessionsModel(paths: CouncilPaths(root: root))
        await model.refresh()
        let session = try XCTUnwrap(summary(model, "2026-01-01_120000_old-name"))

        let problem = await model.rename(session, to: "taken", live: nil)
        XCTAssertNotNil(problem)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.path))
        XCTAssertEqual(try ChatConfig.load(from: session.directory).title, "old name",
                       "a refused rename leaves the title alone")
    }

    @MainActor
    func testAnEmptyNameAndAVerdictRunAreRefused() async throws {
        try makeChat("2026-01-01_120000_old-name", title: "old name")
        let model = SessionsModel(paths: CouncilPaths(root: root))
        await model.refresh()
        let session = try XCTUnwrap(summary(model, "2026-01-01_120000_old-name"))
        let problem = await model.rename(session, to: "   ", live: nil)
        XCTAssertNotNil(problem)
        XCTAssertEqual(try ChatConfig.load(from: session.directory).title, "old name")
    }

    @MainActor
    func testRenamingToTheSameNameDoesNothing() async throws {
        try makeChat("2026-01-01_120000_old-name", title: "old name")
        let model = SessionsModel(paths: CouncilPaths(root: root))
        await model.refresh()
        let session = try XCTUnwrap(summary(model, "2026-01-01_120000_old-name"))
        let problem = await model.rename(session, to: "old name", live: nil)
        XCTAssertNil(problem)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.path))
    }
}
