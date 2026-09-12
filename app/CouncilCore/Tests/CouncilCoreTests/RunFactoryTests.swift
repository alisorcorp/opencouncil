import XCTest
@testable import CouncilCore

/// A run the app creates has to be a run the CLI can read: `council runs`, `council show` and a resumed
/// `council ask` all work off this directory layout (R20).
final class RunFactoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)   // 2026-09-09 local

    private func factory() throws -> (RunFactory, CouncilPaths, URL) {
        let root = try Fixtures.tempDir("runs")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("runs"), withIntermediateDirectories: true)
        let config = try CouncilConfig.parse("""
        [defaults]
        members = ["claude", "codex"]
        moderator = "deepseek"
        length = "about 200 words"
        [members.claude]
        backend = "claude"
        label = "Claude"
        [members.codex]
        backend = "codex"
        label = "Codex"
        model = "gpt-6"
        [members.deepseek]
        backend = "pi"
        label = "DeepSeek"
        model = "deepseek/v4.1"
        provider = "openrouter"
        [members.local]
        backend = "openai"
        label = "Local"
        model = "qwen"
        """)
        let paths = CouncilPaths(root: root)
        return (RunFactory(paths: paths, config: config), paths, root)
    }

    func testTheDirectoryLooksLikeThePythonOne() throws {
        let (factory, paths, root) = try factory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try factory.create(question: "Should we ship the router this week?",
                                     members: ["claude", "codex"], moderator: "deepseek", rounds: 2, now: now)
        XCTAssertEqual(dir.deletingLastPathComponent(), paths.runs)
        XCTAssertTrue(dir.lastPathComponent.hasSuffix("_should-we-ship-the-router-this-week"), dir.lastPathComponent)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("r1").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("r2").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("r3").path))
        let question = try String(contentsOf: dir.appendingPathComponent("question.md"), encoding: .utf8)
        XCTAssertEqual(question, "Should we ship the router this week?\n")

        let cfg = try RunConfig.load(from: dir)
        XCTAssertEqual(cfg.order, ["claude", "codex"])
        XCTAssertEqual(cfg.rounds, 2)
        XCTAssertFalse(cfg.anonymous)
        XCTAssertEqual(cfg.length, "about 200 words")
        XCTAssertEqual(cfg.questionPreview, "Should we ship the router this week?")
        XCTAssertEqual(cfg.members["codex"]?.model, "gpt-6")
        XCTAssertEqual(cfg.members["claude"]?.alias, "Claude", "a named run aliases nobody")
        XCTAssertEqual(cfg.moderator.name, "deepseek")
        XCTAssertEqual(cfg.moderator.provider, "openrouter", "the moderator has to be launchable from this alone")
    }

    func testAnAnonymousRunHidesWhoIsWho() throws {
        let (factory, _, root) = try factory()
        defer { try? FileManager.default.removeItem(at: root) }
        // A fixed shuffle, so the test is about the aliasing rather than about luck.
        let dir = try factory.create(question: "Q", members: ["claude", "codex"], moderator: "deepseek",
                                     anonymous: true, now: now, shuffle: { $0.reversed() })
        let cfg = try RunConfig.load(from: dir)
        XCTAssertEqual(cfg.order, ["codex", "claude"], "order follows the shuffle, not the roster")
        XCTAssertEqual(cfg.members["codex"]?.alias, "Model A")
        XCTAssertEqual(cfg.members["claude"]?.alias, "Model B")
        XCTAssertTrue(cfg.anonymous)
    }

    func testAnAttachmentIsFencedLongerThanAnythingInsideIt() throws {
        let (factory, _, root) = try factory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = root.appendingPathComponent("notes.md")
        try "just text\n\n".write(to: plain, atomically: true, encoding: .utf8)
        let fenced = root.appendingPathComponent("readme.md")
        try "before\n```swift\nlet x = 1\n```\nafter\n".write(to: fenced, atomically: true, encoding: .utf8)

        let dir = try factory.create(question: "Look at these", members: ["claude", "codex"],
                                     moderator: "deepseek", attachments: [plain, fenced], now: now)
        let text = try String(contentsOf: dir.appendingPathComponent("question.md"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("Look at these\n"))
        XCTAssertTrue(text.contains("## Attached file: notes.md\n\n```\njust text\n```"), text)
        XCTAssertTrue(text.contains("## Attached file: readme.md\n\n````\nbefore"), "a file with fences needs a longer one")
        XCTAssertTrue(text.contains("after\n````\n"))
        XCTAssertEqual(try RunConfig.load(from: dir).attachments, ["notes.md", "readme.md"])
    }

    func testARunIsNotHalfCreatedWhenSomethingIsWrong() throws {
        let (factory, paths, root) = try factory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("nope.txt")
        XCTAssertThrowsError(try factory.create(question: "Q", members: ["claude", "codex"],
                                                moderator: "deepseek", attachments: [missing], now: now))
        let left = try FileManager.default.contentsOfDirectory(atPath: paths.runs.path)
        XCTAssertTrue(left.isEmpty, "a failed run leaves nothing behind: \(left)")
    }

    func testTheRulesAboutWhoCanBeInARun() throws {
        let (factory, _, root) = try factory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try factory.create(question: "Q", members: ["claude"], moderator: "deepseek", now: now)) {
            XCTAssertEqual($0 as? RunFactory.CreateError, .tooFewMembers)
        }
        XCTAssertThrowsError(try factory.create(question: "Q", members: ["claude", "nobody"],
                                                moderator: "deepseek", now: now)) {
            XCTAssertEqual($0 as? RunFactory.CreateError, .unknownMember("nobody"))
        }
        XCTAssertThrowsError(try factory.create(question: "Q", members: ["claude", "local"],
                                                moderator: "deepseek", now: now)) {
            XCTAssertEqual($0 as? RunFactory.CreateError, .notHostable("local"))
        }
        XCTAssertThrowsError(try factory.create(question: "   ", members: ["claude", "codex"],
                                                moderator: "deepseek", now: now)) {
            XCTAssertEqual($0 as? RunFactory.CreateError, .emptyQuestion)
        }
    }

    // MARK: interop

    /// The strongest check available without spending anyone's quota: council.py's own `Run` class reads the
    /// directory the app wrote, and reports the same fields back.
    func testCouncilPyReadsARunTheAppCreated() throws {
        let repo = try repoRoot()
        let (factory, _, root) = try factory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try factory.create(question: "Is the ledger enough?", members: ["claude", "codex"],
                                     moderator: "deepseek", rounds: 2, anonymous: true, now: now,
                                     shuffle: { $0.reversed() })

        let script = """
        import sys
        sys.path.insert(0, sys.argv[1])
        import council
        run = council.Run(sys.argv[2])
        print(run.rounds, run.anonymous, ",".join(run.order), run.display("claude"), run.cfg["length"], sep="|")
        print(run.answer_path("claude", 1).name, run.done_path("codex", 2).name, sep="|")
        """
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        python.arguments = ["python3", "-c", script, repo.path, dir.path]
        let pipe = Pipe()
        python.standardOutput = pipe
        python.standardError = pipe
        try python.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        python.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(python.terminationStatus, 0, "council.py could not read the run:\n\(output)")
        let lines = output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "2|True|codex,claude|Model B|about 200 words", output)
        XCTAssertEqual(lines.last, "claude.md|codex.done", output)
    }

    private func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.appendingPathComponent("council.py").path),
                          "council.py not found at \(url.path)")
        return url
    }
}
