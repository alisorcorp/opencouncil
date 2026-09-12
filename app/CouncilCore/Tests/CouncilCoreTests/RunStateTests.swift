import XCTest
@testable import CouncilCore

/// A run says what became of it through its own files, so the app can be quit mid-run — or the CLI can have
/// started it — and the next launch still knows what is missing.
final class RunStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    private func makeRun(rounds: Int = 1) throws -> (VerdictRun, URL) {
        let root = try Fixtures.tempDir("state")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("runs"), withIntermediateDirectories: true)
        let config = try CouncilConfig.parse("""
        [members.claude]
        backend = "claude"
        [members.codex]
        backend = "codex"
        [members.deepseek]
        backend = "pi"
        """)
        let dir = try RunFactory(paths: CouncilPaths(root: root), config: config)
            .create(question: "Q", members: ["claude", "codex", "deepseek"], moderator: "deepseek",
                    rounds: rounds, now: now)
        return (try VerdictRun(directory: dir), root)
    }

    private func ok(_ words: Int = 2) -> RunDone {
        RunDone(status: "ok", elapsed: 3, words: words, finished: MessageTime.format(now))
    }
    private func bad(_ why: String) -> RunDone {
        RunDone(status: "error", error: why, elapsed: 3, words: 0, finished: MessageTime.format(now))
    }

    func testAFreshRunHasNotStarted() throws {
        let (run, root) = try makeRun()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = RunState.read(run)
        XCTAssertEqual(state.phase, .notStarted)
        XCTAssertFalse(state.isInterrupted, "a run nobody has asked anything of is new, not interrupted")
        XCTAssertEqual(state.pending.map(\.member), ["claude", "codex", "deepseek"])
    }

    func testARunStoppedPartWayNamesWhatIsMissing() throws {
        let (run, root) = try makeRun()
        defer { try? FileManager.default.removeItem(at: root) }
        try run.record("claude", round: 1, answer: "a", done: ok())
        let state = RunState.read(run)
        XCTAssertEqual(state.phase, .answering(round: 1))
        XCTAssertTrue(state.isInterrupted)
        XCTAssertEqual(state.pending.map(\.member), ["codex", "deepseek"])
        XCTAssertEqual(state.pending.map(\.round), [1, 1])
        XCTAssertEqual(state.answered, ["claude"])
    }

    func testASecondRoundIsOnlyPendingForMembersThatAnsweredTheFirst() throws {
        let (run, root) = try makeRun(rounds: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        try run.record("claude", round: 1, answer: "a", done: ok())
        try run.record("codex", round: 1, answer: "b", done: ok())
        try run.record("deepseek", round: 1, answer: "", done: bad("crashed"))
        let state = RunState.read(run)
        XCTAssertEqual(state.phase, .answering(round: 2))
        XCTAssertEqual(state.pending.map(\.member), ["claude", "codex"], "deepseek has nothing to critique with")
    }

    func testEveryAnswerInAndNoVerdictMeansTheModeratorIsOwed() throws {
        let (run, root) = try makeRun()
        defer { try? FileManager.default.removeItem(at: root) }
        for m in ["claude", "codex", "deepseek"] { try run.record(m, round: 1, answer: "x", done: ok()) }
        let state = RunState.read(run)
        XCTAssertEqual(state.phase, .awaitingModerator)
        XCTAssertTrue(state.isInterrupted)
        XCTAssertTrue(state.pending.isEmpty)
    }

    func testUnderTwoAnswersTheRunIsOverWithoutAVerdict() throws {
        let (run, root) = try makeRun()
        defer { try? FileManager.default.removeItem(at: root) }
        try run.record("claude", round: 1, answer: "x", done: ok())
        try run.record("codex", round: 1, answer: "", done: bad("crashed"))
        try run.record("deepseek", round: 1, answer: "", done: bad("crashed"))
        let state = RunState.read(run)
        XCTAssertEqual(state.phase, .tooFewAnswers)
        XCTAssertFalse(state.isInterrupted, "there is nothing a resume could do")
    }

    func testAVerdictCompletesTheRunAndCarriesItsScore() throws {
        let (run, root) = try makeRun()
        defer { try? FileManager.default.removeItem(at: root) }
        for m in ["claude", "codex", "deepseek"] { try run.record(m, round: 1, answer: "x", done: ok()) }
        try run.writeVerdict("## Consensus\nScore: 74/100 mostly agreed.")
        let state = RunState.read(run)
        XCTAssertEqual(state.phase, .complete)
        XCTAssertEqual(state.score, 74)
        XCTAssertTrue(state.isComplete)
    }

    func testAModeratorThatGaveUpLeavesItsMarkerBehind() throws {
        let (run, root) = try makeRun()
        defer { try? FileManager.default.removeItem(at: root) }
        for m in ["claude", "codex", "deepseek"] { try run.record(m, round: 1, answer: "x", done: ok()) }
        try run.writeVerdict("(moderator failed: kept failing with an API error)")
        let state = RunState.read(run)
        XCTAssertEqual(state.phase, .moderatorFailed("kept failing with an API error"))
        XCTAssertTrue(state.isInterrupted, "the answers are there; only the synthesis has to run again")
        XCTAssertEqual(state.answered.count, 3)
    }

    func testTheFixtureRunTheCLIWroteReadsAsComplete() throws {
        let run = try VerdictRun(directory: Fixtures.runDir)
        let state = RunState.read(run)
        XCTAssertEqual(state.phase, .complete)
        XCTAssertEqual(state.score, 85, "council.py's own verdict.md, scored by the app's parser")
        XCTAssertFalse(state.answered.isEmpty)
    }
}
