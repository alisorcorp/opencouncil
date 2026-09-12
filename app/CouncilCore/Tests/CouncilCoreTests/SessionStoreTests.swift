import XCTest
@testable import CouncilCore

final class SessionStoreTests: XCTestCase {
    func testScansChatsAndRunsNewestFirst() throws {
        let store = SessionStore(paths: CouncilPaths(root: Fixtures.root))
        let sessions = store.scan()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.map(\.kind), [.chat, .verdict], "the chat (Sep 10) is newer than the run (Sep 9)")

        let chat = sessions[0]
        XCTAssertEqual(chat.title, "router")
        XCTAssertEqual(chat.memberOrder, ["claude", "codex", "deepseek"])
        XCTAssertEqual(chat.memberLabels["codex"], "Codex GPT-6 Astra", "effort suffix stripped for display")
        XCTAssertEqual(chat.messageCount, 9)
        XCTAssertEqual(chat.cwd, "/Users/you/Code/demo")
        XCTAssertNil(chat.score)

        let run = sessions[1]
        XCTAssertTrue(run.title.hasPrefix("Is it worth adding type hints"))
        XCTAssertEqual(run.memberOrder, ["codex", "gemini"])
        XCTAssertEqual(run.score, 85)
        XCTAssertTrue(run.hasVerdict)
        XCTAssertEqual(run.memberLabels["gemini"], "Gemini 3.8 Flash")
    }

    func testSkipsDirectoriesWithoutConfigAndSymlinks() throws {
        let root = try Fixtures.tempDir("store")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CouncilPaths(root: root)
        let fm = FileManager.default
        try fm.createDirectory(at: paths.chats.appendingPathComponent("2026-01-01_000000_junk"), withIntermediateDirectories: true)
        try fm.copyItem(at: Fixtures.chatDir, to: paths.chats.appendingPathComponent(Fixtures.chatDir.lastPathComponent))
        try fm.createSymbolicLink(at: paths.chats.appendingPathComponent("current"),
                                  withDestinationURL: paths.chats.appendingPathComponent(Fixtures.chatDir.lastPathComponent))
        let sessions = SessionStore(paths: paths).scan()
        XCTAssertEqual(sessions.map(\.id), [Fixtures.chatDir.lastPathComponent])
    }

    func testTitleFallsBackToDirectoryName() {
        XCTAssertEqual(SessionStore.titleFromDirectoryName("2026-09-10_113600_router"), "router")
        XCTAssertEqual(SessionStore.titleFromDirectoryName("2026-09-10_113600_two_words"), "two_words")
        XCTAssertEqual(SessionStore.titleFromDirectoryName("odd"), "odd")
    }

    func testConsensusScoreParsing() {
        XCTAssertEqual(ConsensusScore.parse("## Verdict\n\nScore: **85**/100"), 85)
        XCTAssertEqual(ConsensusScore.parse("Score: 40 / 100"), 40)
        XCTAssertEqual(ConsensusScore.parse("Score: 250/100"), 100)
        XCTAssertNil(ConsensusScore.parse("no score here"))
    }

    /// Runs only on the development machine, against the real council folder.
    func testRealCouncilFolderIfPresent() throws {
        guard let paths = CouncilPaths.discoverRoot(), paths.isValid else { throw XCTSkip("no council folder") }
        let sessions = SessionStore(paths: paths).scan()
        XCTAssertFalse(sessions.isEmpty)
        XCTAssertTrue(sessions.contains { $0.kind == .chat })
        XCTAssertTrue(sessions.contains { $0.kind == .verdict })
        for (a, b) in zip(sessions, sessions.dropFirst()) {
            XCTAssertGreaterThanOrEqual(a.lastActivity ?? .distantPast, b.lastActivity ?? .distantPast)
        }
    }
}
