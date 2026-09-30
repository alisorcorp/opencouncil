import XCTest
import CouncilCore
@testable import Council

/// Export reads the session from disk, not from the window, so it is exercised here the same way: a chat folder
/// written in the shape the CLI and the app both write, scanned, then exported.
final class SessionExportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("council-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chats"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func makeChat() throws -> SessionSummary {
        let dir = root.appendingPathComponent("chats/2026-09-22_121025_agent-swarms")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "created": "2026-09-22T12:10:25", "title": "Agent swarms", "cwd": root.path,
            "order": ["claude", "codex"],
            "members": ["claude": ["name": "claude", "backend": "claude", "label": "Claude Opus 5.5"],
                        "codex": ["name": "codex", "backend": "codex", "label": "Codex"]],
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: dir.appendingPathComponent("config.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("notes/plan.md").path, contents: Data())
        let lines = [
            #"{"id": 1, "ts": "2026-09-22T12:10:50", "from": "user", "kind": "msg", "text": "@codex thoughts?", "to": ["codex"]}"#,
            #"{"id": 2, "ts": "2026-09-22T12:11:10", "from": "codex", "kind": "msg", "text": "See [the plan](notes/plan.md:4).", "to": []}"#,
            #"{"id": 3, "ts": "2026-09-22T12:11:25", "from": "claude", "kind": "msg", "text": "Agreed with **codex**.", "to": []}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("chat.jsonl"), atomically: true, encoding: .utf8)
        return try XCTUnwrap(SessionStore(paths: CouncilPaths(root: root)).scan().first)
    }

    @MainActor
    func testAChatExportsItsWholeHistoryFromDisk() throws {
        let page = try SessionExport.page(for: try makeChat())
        XCTAssertTrue(page.contains("<span class=\"mention\"><strong>@codex</strong></span>"), "mentions as the app shows them")
        XCTAssertTrue(page.contains("<span class=\"who\">Codex</span>"))
        XCTAssertTrue(page.contains("<strong>codex</strong>"))
        XCTAssertTrue(page.contains("--c:\(Palette.css(Palette.memberHex[0]))"), "members coloured as in the app")
        // A relative path in a message resolves against the chat's working folder, as a click in the window does.
        let plan = URL(fileURLWithPath: root.appendingPathComponent("notes/plan.md").path).standardizedFileURL
        XCTAssertTrue(page.contains("<a href=\"\(plan.absoluteString)\">the plan</a>"), page)
        XCTAssertTrue(page.contains("3 messages"))
    }

    @MainActor
    func testFileNames() {
        XCTAssertEqual(SessionExport.fileName(for: "Agent swarms"), "Agent swarms.html")
        XCTAssertEqual(SessionExport.fileName(for: "a/b: c"), "a-b- c.html")
        XCTAssertEqual(SessionExport.fileName(for: "  "), "Council session.html")
    }
}
