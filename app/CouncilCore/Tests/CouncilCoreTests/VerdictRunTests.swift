import XCTest
@testable import CouncilCore

/// The files a run produces. The strongest check here is the last one: council.py writes the transcript of a
/// run the app filled in, and it comes out byte for byte the same.
final class VerdictRunTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    private func makeRun(rounds: Int = 1, anonymous: Bool = false) throws -> (VerdictRun, URL) {
        let root = try Fixtures.tempDir("run")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("runs"), withIntermediateDirectories: true)
        let config = try CouncilConfig.parse("""
        [defaults]
        length = "about 200 words"
        [members.claude]
        backend = "claude"
        label = "Claude Fable 5.1"
        [members.codex]
        backend = "codex"
        label = "Codex"
        [members.deepseek]
        backend = "pi"
        label = "DeepSeek"
        provider = "openrouter"
        """)
        let factory = RunFactory(paths: CouncilPaths(root: root), config: config)
        let dir = try factory.create(question: "Is the ledger enough?", members: ["claude", "codex", "deepseek"],
                                     moderator: "deepseek", rounds: rounds, anonymous: anonymous, now: now,
                                     shuffle: { $0 })
        return (try VerdictRun(directory: dir), root)
    }

    func testARecordedRoundIsReadableAsTheCLIReadsIt() throws {
        let (run, root) = try makeRun()
        defer { try? FileManager.default.removeItem(at: root) }
        try run.record("claude", round: 1, answer: "an answer",
                       done: RunDone(status: "ok", elapsed: 12.3, words: 2, finished: MessageTime.format(now)))
        XCTAssertEqual(run.answer("claude", round: 1), "an answer")
        XCTAssertEqual(run.done("claude", round: 1)?.words, 2)
        XCTAssertTrue(run.done("claude", round: 1)?.isOK ?? false)
        XCTAssertNil(run.done("codex", round: 1))
    }

    func testTheVerdictFileEndsWithOneNewline() throws {
        let (run, root) = try makeRun()
        defer { try? FileManager.default.removeItem(at: root) }
        try run.writeVerdict("## Verdict\n\nShip it.\n\n\n")
        XCTAssertEqual(run.verdict, "## Verdict\n\nShip it.\n")
    }

    func testAnAnonymousRunRevealsWhoWasWhoAtTheEnd() throws {
        let (run, root) = try makeRun(anonymous: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try run.writeVerdict("Score: 70/100")
        let text = try XCTUnwrap(run.verdict)
        XCTAssertTrue(text.hasSuffix("\n## Reveal\n\n- Model A = Claude Fable 5.1\n- Model B = Codex\n- Model C = DeepSeek\n"), text)
        XCTAssertEqual(run.display("claude"), "Model A")
        XCTAssertEqual(run.label("claude"), "Claude Fable 5.1", "the user always sees the real name")
    }

    func testWordCountingAndTimesMatchThePython() {
        XCTAssertEqual(VerdictRun.words("one  two\nthree\t four "), 4)
        XCTAssertEqual(VerdictRun.words("   "), 0)
        XCTAssertEqual(VerdictRun.formatSeconds(9.4), "9s")
        XCTAssertEqual(VerdictRun.formatSeconds(99.9), "100s")
        XCTAssertEqual(VerdictRun.formatSeconds(100), "1.7m")
    }

    // MARK: interop

    /// council.py's own `write_transcript` over the run the app filled in. Any drift in the wording, the order
    /// or the metadata line shows up here rather than in a transcript nobody compares.
    func testTheTranscriptIsTheOneCouncilPyWouldHaveWritten() throws {
        let repo = try repoRoot()
        let (run, root) = try makeRun(rounds: 2, anonymous: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = MessageTime.format(now)
        try run.record("claude", round: 1, answer: "claude one",
                       done: RunDone(status: "ok", elapsed: 12.3, words: 2, finished: stamp))
        try run.record("codex", round: 1, answer: "codex one",
                       done: RunDone(status: "ok", elapsed: 400.0, words: 2, finished: stamp))
        try run.record("deepseek", round: 1, answer: "",
                       done: RunDone(status: "error", error: "no answer in 30 minutes", elapsed: 1800, words: 0,
                                     finished: stamp))
        try run.record("claude", round: 2, answer: "claude two\n",
                       done: RunDone(status: "ok", elapsed: 5, words: 2, finished: stamp))
        try run.record("codex", round: 2, answer: "codex two",
                       done: RunDone(status: "ok", elapsed: 6, words: 2, finished: stamp))

        let verdict = "## Verdict\n\nShip it.\n\nScore: 82/100 because.\n"
        try run.writeTranscript(verdict: verdict)
        let swiftText = try String(contentsOf: run.directory.appendingPathComponent("transcript.md"), encoding: .utf8)

        let script = """
        import sys
        sys.path.insert(0, sys.argv[1])
        import council
        council.write_transcript(council.Run(sys.argv[2]), sys.argv[3])
        """
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        python.arguments = ["python3", "-c", script, repo.path, run.directory.path, verdict]
        let pipe = Pipe()
        python.standardOutput = pipe
        python.standardError = pipe
        try python.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        python.waitUntilExit()
        XCTAssertEqual(python.terminationStatus, 0, "council.py could not write the transcript:\n\(output)")
        let pythonText = try String(contentsOf: run.directory.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertEqual(swiftText, pythonText)
        XCTAssertTrue(swiftText.contains("## Claude Fable 5.1 (as Model A)"), swiftText)
        XCTAssertTrue(swiftText.contains("FAILED: no answer in 30 minutes"), swiftText)
    }

    private func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.appendingPathComponent("council.py").path),
                          "council.py not found at \(url.path)")
        return url
    }
}
