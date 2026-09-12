import XCTest
@testable import CouncilCore

/// The rules of a verdict run, one test per arrow: who is asked, what happens when somebody does not answer,
/// and when the moderator is allowed to start. Pure — no files, no processes, no clock.
final class VerdictOrchestratorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_789_000_000)

    private func make(rounds: Int = 1, order: [String] = ["claude", "codex", "deepseek"],
                      moderator: String = "deepseek", displays: [String: String] = [:]) -> VerdictOrchestrator {
        VerdictOrchestrator(question: "Should we ship?", order: order, rounds: rounds,
                            length: "about 300 words", moderator: moderator, displays: displays)
    }

    private func asked(_ effects: [VerdictOrchestrator.Effect]) -> [String] {
        effects.compactMap { if case .ask(let m, _, _) = $0 { return m } else { return nil } }
    }

    private func records(_ effects: [VerdictOrchestrator.Effect]) -> [(String, Int, String, RunDone)] {
        effects.compactMap { if case .record(let m, let r, let a, let d) = $0 { return (m, r, a, d) } else { return nil } }
    }

    /// Built by the real decoder, because the point is what the runtime is actually handed.
    private func unreadable(from sender: String) -> Message {
        let line = #"{"id": 7, "ts": "", "from": "SENDER", "kind": "msg", "text": "cut"#
            .replacingOccurrences(of: "SENDER", with: sender)
        return Bus.decodeLines(Data((line + "\n").utf8))[0]
    }

    // MARK: a post nobody could read is not an answer

    /// An unreadable record reaches the runtime as a message whose text is the app's own diagnostic. Passed to
    /// `answered` it is non-empty, so the run recorded it as an `ok` answer: the member's answer, in the run's
    /// own files and in front of the moderator, became a sentence the app wrote about its failure to read one.
    func testAPostNobodyCouldReadIsNotAnAnswer() {
        var o = make()
        _ = o.begin(now: t0)
        let effects = o.received(unreadable(from: "claude"), now: t0.addingTimeInterval(5))
        let written = records(effects)
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written[0].3.status, "error", "the diagnostic was accepted as an answer")
        XCTAssertEqual(written[0].2, "", "the diagnostic must not be kept as the member's words")
        XCTAssertFalse(o.answeredMembers.contains("claude"), "it would count toward the minimum for synthesis")
        XCTAssertTrue(o.isWaiting(on: "claude") == false, "the turn still has to close")
    }

    /// The same record from the moderator would have become the verdict, and the run would have been complete.
    func testAVerdictNobodyCouldReadIsNotAVerdict() {
        var o = make()
        _ = o.begin(now: t0)
        for member in ["claude", "codex", "deepseek"] { _ = o.answered(member, text: "an answer", now: t0) }
        guard case .moderating = o.phase else { return XCTFail("the moderator was never asked: \(o.phase)") }
        let effects = o.received(unreadable(from: "deepseek"), now: t0.addingTimeInterval(30))
        XCTAssertEqual(o.phase, .abandoned(Bus.unreadableReason), "an unreadable verdict completed the run")
        XCTAssertTrue(effects.contains { if case .abandon(_, let moderatorFailed) = $0 { return moderatorFailed } else { return false } })
        XCTAssertFalse(o.retryModerator(now: t0.addingTimeInterval(40)).isEmpty, "recovery has to stay available")
    }

    // MARK: round one

    func testEveryMemberIsAskedTheQuestionItself() {
        var o = make()
        let effects = o.begin(now: t0)
        XCTAssertEqual(asked(effects), ["claude", "codex", "deepseek"])
        XCTAssertEqual(o.phase, .asking(round: 1))
        guard case .ask(_, _, let text) = effects[0] else { return XCTFail("no ask") }
        XCTAssertTrue(text.contains("Should we ship?"))
        XCTAssertTrue(text.contains("about 300 words"), "the run's requested length reaches the member")
        XCTAssertTrue(text.hasSuffix("Post exactly one message, and put the whole answer in it."))
        XCTAssertTrue(text.contains("council post --as claude"), "the member is told how to answer")
    }

    func testAnAnswerIsRecordedWithItsWordCountAndElapsedTime() {
        var o = make()
        _ = o.begin(now: t0)
        let effects = o.answered("claude", text: "one two three\n\n", now: t0.addingTimeInterval(12.34))
        let written = records(effects)
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written[0].0, "claude")
        XCTAssertEqual(written[0].1, 1)
        XCTAssertEqual(written[0].2, "one two three", "trailing whitespace is stripped, as the CLI does")
        XCTAssertEqual(written[0].3.status, "ok")
        XCTAssertEqual(written[0].3.words, 3)
        XCTAssertEqual(written[0].3.elapsed, 12.3)
        XCTAssertTrue(o.isWaiting(on: "codex"), "the round is not over until everybody has answered")
    }

    func testTheClockStartsWhenTheTerminalTakesThePrompt() {
        var o = make()
        _ = o.begin(now: t0)
        // A CLI that has not drawn its prompt yet is not thinking; the wait must not be billed as elapsed.
        o.delivered("claude", now: t0.addingTimeInterval(20))
        let effects = o.answered("claude", text: "an answer", now: t0.addingTimeInterval(29))
        XCTAssertEqual(records(effects).first?.3.elapsed, 9)

        // And the answer timeout measures the same thing: both remaining members are still inside it at
        // 1810 s because neither took its prompt until 20 s in.
        o.delivered("codex", now: t0.addingTimeInterval(20))
        o.delivered("deepseek", now: t0.addingTimeInterval(20))
        XCTAssertTrue(o.tick(now: t0.addingTimeInterval(1810)).isEmpty, "still inside the timeout")
        XCTAssertFalse(o.tick(now: t0.addingTimeInterval(1821)).isEmpty)
    }

    func testThreeAnswersProduceThreeRecordsAndThenTheModerator() {
        var o = make(displays: ["claude": "Claude", "codex": "Codex", "deepseek": "DeepSeek"])
        _ = o.begin(now: t0)
        var all: [VerdictOrchestrator.Effect] = []
        all += o.answered("claude", text: "A", now: t0.addingTimeInterval(1))
        all += o.answered("codex", text: "B", now: t0.addingTimeInterval(2))
        all += o.answered("deepseek", text: "C", now: t0.addingTimeInterval(3))
        XCTAssertEqual(records(all).count, 3)
        XCTAssertTrue(records(all).allSatisfy { $0.3.status == "ok" })
        XCTAssertEqual(o.phase, .moderating)
        guard case .moderate(let who, let text) = all.last else { return XCTFail("no moderate: \(all)") }
        XCTAssertEqual(who, "deepseek")
        XCTAssertTrue(text.contains("## Claude\n\nA"), text)
        XCTAssertTrue(text.contains("## Codex\n\nB"), text)
        XCTAssertTrue(text.contains("council post --as deepseek"))
    }

    func testMembersAreReleasedWhenTheirWorkIsDoneButTheModeratorIsNot() {
        var o = make()
        _ = o.begin(now: t0)
        _ = o.answered("claude", text: "A", now: t0)
        _ = o.answered("codex", text: "B", now: t0)
        let effects = o.answered("deepseek", text: "C", now: t0)
        let released = effects.compactMap { if case .release(let m) = $0 { return m } else { return nil } }
        XCTAssertEqual(released, ["claude", "codex"], "deepseek moderates, so its terminal stays")
    }

    // MARK: members that do not answer

    func testAMemberThatTimesOutIsRecordedAsFailedAndTheRestGoOn() {
        var o = make()
        _ = o.begin(now: t0)
        _ = o.answered("claude", text: "A", now: t0)
        _ = o.answered("codex", text: "B", now: t0)
        XCTAssertTrue(o.tick(now: t0.addingTimeInterval(60)).isEmpty, "nothing happens before the timeout")
        let effects = o.tick(now: t0.addingTimeInterval(1801))
        let written = records(effects)
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written[0].0, "deepseek")
        XCTAssertEqual(written[0].3.status, "error")
        XCTAssertEqual(written[0].3.error, "no answer in 30 minutes")
        XCTAssertEqual(written[0].2, "", "a failed round writes an empty answer file, as cmd_member does")
        XCTAssertEqual(o.phase, .moderating, "two answers are enough to synthesize")
    }

    func testTheModeratorIsToldWhoDidNotAnswer() {
        var o = make(displays: ["claude": "Claude", "codex": "Codex", "deepseek": "DeepSeek"])
        _ = o.begin(now: t0)
        _ = o.answered("claude", text: "A", now: t0)
        _ = o.answered("codex", text: "B", now: t0)
        let effects = o.failed("deepseek", reason: "exited with status 1", now: t0)
        guard case .moderate(_, let text) = effects.last else { return XCTFail("no moderate") }
        XCTAssertTrue(text.contains("## DeepSeek\n\n(no answer: exited with status 1)"), text)
        XCTAssertTrue(effects.contains(.note("DeepSeek did not answer: exited with status 1")))
    }

    func testUnderTwoAnswersThereIsNothingToSynthesize() {
        var o = make()
        _ = o.begin(now: t0)
        _ = o.failed("claude", reason: "crashed", now: t0)
        _ = o.failed("codex", reason: "crashed", now: t0)
        let effects = o.answered("deepseek", text: "C", now: t0)
        XCTAssertFalse(effects.contains { if case .moderate = $0 { return true } else { return false } })
        XCTAssertTrue(effects.contains(.abandon(reason: VerdictOrchestrator.tooFewAnswers, moderatorFailed: false)))
        XCTAssertEqual(o.phase, .abandoned(VerdictOrchestrator.tooFewAnswers))
    }

    func testAnEmptyPostIsNotAnAnswer() {
        var o = make()
        _ = o.begin(now: t0)
        let effects = o.answered("claude", text: "   \n ", now: t0)
        XCTAssertEqual(records(effects).first?.3.status, "error")
    }

    // MARK: more than one round

    func testTheSecondRoundCarriesThePeersAndTheMembersOwnAnswer() {
        var o = make(rounds: 2)
        _ = o.begin(now: t0)
        _ = o.answered("claude", text: "claude one", now: t0)
        _ = o.answered("codex", text: "codex one", now: t0)
        let effects = o.answered("deepseek", text: "deepseek one", now: t0)
        XCTAssertEqual(Set(asked(effects)), ["claude", "codex", "deepseek"])
        XCTAssertEqual(o.phase, .asking(round: 2))
        guard case .ask(_, let round, let text) = effects.first(where: {
            if case .ask("claude", _, _) = $0 { return true } else { return false }
        }) else { return XCTFail("claude was not asked again") }
        XCTAssertEqual(round, 2)
        XCTAssertTrue(text.contains("This is round 2 of 2."))
        XCTAssertTrue(text.contains("codex one"), "peers' answers are carried in")
        XCTAssertTrue(text.hasPrefix(VerdictPrompts.memberSystem(length: "about 300 words")))
        XCTAssertTrue(text.contains("# Your previous answer\n\nclaude one"))
        XCTAssertFalse(text.contains("Codex"), "peers are unlabelled, so a round-2 prompt cannot out them")
    }

    func testAMemberWithNoAnswerIsLeftOutOfTheNextRound() {
        var o = make(rounds: 2, displays: ["codex": "Codex"])
        _ = o.begin(now: t0)
        _ = o.answered("claude", text: "a", now: t0)
        _ = o.failed("codex", reason: "crashed", now: t0)
        let effects = o.answered("deepseek", text: "c", now: t0)
        XCTAssertEqual(Set(asked(effects)), ["claude", "deepseek"])
        XCTAssertTrue(effects.contains(.release(member: "codex")))
        XCTAssertTrue(effects.contains(.note("Codex is left out of round 2: it did not answer round 1")))
        // Its silence still reaches the others, as council.py shows it.
        guard case .ask(_, _, let text) = effects.first(where: {
            if case .ask("claude", _, _) = $0 { return true } else { return false }
        }) else { return XCTFail("claude was not asked again") }
        XCTAssertTrue(text.contains("(no answer produced)"), text)
    }

    func testOneSurvivorCannotCritiqueSoTheRunGoesStraightToTheVerdict() {
        var o = make(rounds: 3)
        _ = o.begin(now: t0)
        _ = o.answered("claude", text: "a", now: t0)
        _ = o.failed("codex", reason: "crashed", now: t0)
        let effects = o.failed("deepseek", reason: "crashed", now: t0)
        XCTAssertTrue(asked(effects).isEmpty)
        XCTAssertEqual(o.phase, .abandoned(VerdictOrchestrator.tooFewAnswers))
    }

    func testTheModeratorSeesTheFinalRound() {
        var o = make(rounds: 2, displays: ["claude": "Claude", "codex": "Codex", "deepseek": "DeepSeek"])
        _ = o.begin(now: t0)
        for m in ["claude", "codex", "deepseek"] { _ = o.answered(m, text: "\(m) round one", now: t0) }
        _ = o.answered("claude", text: "claude revised", now: t0)
        _ = o.answered("codex", text: "codex revised", now: t0)
        let effects = o.answered("deepseek", text: "deepseek revised", now: t0)
        guard case .moderate(_, let text) = effects.last else { return XCTFail("no moderate") }
        XCTAssertTrue(text.contains("## Claude\n\nclaude revised"), text)
        XCTAssertFalse(text.contains("claude round one"), "only the final round is synthesized")
        XCTAssertTrue(text.contains("(final round 2 of 2)"))
    }

    // MARK: the verdict

    func testTheVerdictIsScoredAndTheModeratorReleased() {
        var o = make()
        _ = o.begin(now: t0)
        for m in ["claude", "codex", "deepseek"] { _ = o.answered(m, text: "x", now: t0) }
        let effects = o.moderated("## Verdict\n\nShip it.\n\n## Consensus\nScore: 82/100 because.\n", now: t0)
        XCTAssertEqual(effects, [.release(member: "deepseek"),
                                 .finish(verdict: "## Verdict\n\nShip it.\n\n## Consensus\nScore: 82/100 because.",
                                         score: 82)])
        XCTAssertEqual(o.phase, .complete(score: 82))
        XCTAssertTrue(o.isFinished)
    }

    func testAVerdictWithNoScoreIsStillAVerdict() {
        var o = make()
        _ = o.begin(now: t0)
        for m in ["claude", "codex", "deepseek"] { _ = o.answered(m, text: "x", now: t0) }
        let effects = o.moderated("no number here", now: t0)
        XCTAssertEqual(effects.last, .finish(verdict: "no number here", score: nil))
    }

    func testAModeratorThatGivesUpLeavesTheAnswersAloneAndCanBeRetried() {
        var o = make()
        _ = o.begin(now: t0)
        for m in ["claude", "codex", "deepseek"] { _ = o.answered(m, text: "x", now: t0) }
        let failed = o.moderatorFailed("kept failing with an API error", now: t0)
        XCTAssertTrue(failed.contains(.abandon(reason: "kept failing with an API error", moderatorFailed: true)))

        let retry = o.retryModerator(now: t0.addingTimeInterval(60))
        XCTAssertEqual(o.phase, .moderating)
        guard case .moderate(_, let text) = retry.first else { return XCTFail("retry did not ask again") }
        XCTAssertTrue(text.contains("Produce the verdict now."))
        XCTAssertEqual(o.answer("claude", round: 1)?.text, "x", "the answers are kept, only the synthesis runs again")
    }

    func testAModeratorThatNeverAnswersTimesOutToo() {
        var o = make()
        _ = o.begin(now: t0)
        for m in ["claude", "codex", "deepseek"] { _ = o.answered(m, text: "x", now: t0) }
        let effects = o.tick(now: t0.addingTimeInterval(1801))
        XCTAssertTrue(effects.contains(.abandon(reason: "no answer in 30 minutes", moderatorFailed: true)))
    }

    func testAFinishedVerdictIsNotSynthesizedTwice() {
        var o = make()
        _ = o.begin(now: t0)
        for m in ["claude", "codex", "deepseek"] { _ = o.answered(m, text: "x", now: t0) }
        _ = o.moderated("Score: 60/100", now: t0)
        XCTAssertTrue(o.retryModerator(now: t0).isEmpty, "a good verdict is not overwritten by a second opinion")
        XCTAssertEqual(o.phase, .complete(score: 60))
    }

    func testARunWithOneAnswerCannotBeModeratedByHand() {
        var o = make()
        _ = o.begin(now: t0)
        _ = o.failed("claude", reason: "x", now: t0)
        _ = o.failed("codex", reason: "x", now: t0)
        _ = o.answered("deepseek", text: "c", now: t0)
        XCTAssertTrue(o.retryModerator(now: t0).isEmpty)
    }

    // MARK: resume

    func testAResumeAsksOnlyForTheAnswersThatAreMissing() {
        let ok = RunDone(status: "ok", elapsed: 4, words: 1)
        var o = VerdictOrchestrator(question: "Q", order: ["claude", "codex", "deepseek"], rounds: 1,
                                    length: "short", moderator: "deepseek",
                                    answers: [1: ["claude": .init(text: "a", done: ok),
                                                  "codex": .init(text: "b", done: ok)]])
        let effects = o.begin(now: t0)
        XCTAssertEqual(asked(effects), ["deepseek"], "the two answers already on disk are not asked for again")
        XCTAssertEqual(o.phase, .asking(round: 1))
    }

    func testARunWhoseAnswersAreAllInResumesIntoTheModerator() {
        let ok = RunDone(status: "ok", elapsed: 4, words: 1)
        var o = VerdictOrchestrator(question: "Q", order: ["claude", "codex"], rounds: 1, length: "short",
                                    moderator: "claude",
                                    answers: [1: ["claude": .init(text: "a", done: ok),
                                                  "codex": .init(text: "b", done: ok)]])
        let effects = o.begin(now: t0)
        XCTAssertEqual(o.phase, .moderating)
        XCTAssertEqual(effects.compactMap { if case .release(let m) = $0 { return m } else { return nil } }, ["codex"])
    }

    func testBeginIsIgnoredOnceARunHasStarted() {
        var o = make()
        _ = o.begin(now: t0)
        XCTAssertTrue(o.begin(now: t0).isEmpty)
    }

    func testAPostFromAMemberThatIsNotBeingWaitedOnIsIgnored() {
        var o = make()
        _ = o.begin(now: t0)
        _ = o.answered("claude", text: "a", now: t0)
        XCTAssertTrue(o.answered("claude", text: "again", now: t0).isEmpty, "one post per round is the answer")
        XCTAssertEqual(o.answer("claude", round: 1)?.text, "a")
    }

    // MARK: anonymity

    func testAnAnonymousRunShowsTheModeratorAliasesOnly() {
        var o = make(displays: ["claude": "Model A", "codex": "Model B", "deepseek": "Model C"])
        _ = o.begin(now: t0)
        _ = o.answered("claude", text: "a", now: t0)
        _ = o.answered("codex", text: "b", now: t0)
        let effects = o.answered("deepseek", text: "c", now: t0)
        guard case .moderate(_, let text) = effects.last else { return XCTFail("no moderate") }
        XCTAssertTrue(text.contains("## Model A"), text)
        XCTAssertFalse(text.lowercased().contains("claude"), "the real names never reach the moderator")
    }
    // MARK: picking a run back up off disk

    private func runOnDisk() throws -> (VerdictRun, URL) {
        let root = try Fixtures.tempDir("orchestrator-run")
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
            .create(question: "Should we ship?", members: ["claude", "codex", "deepseek"],
                    moderator: "deepseek", rounds: 1, now: t0)
        return (try VerdictRun(directory: dir), root)
    }

    private func answerEverybody(_ run: VerdictRun) throws {
        for m in run.order {
            try run.record(m, round: 1, answer: "\(m) answered",
                           done: RunDone(status: "ok", elapsed: 1, words: 2, finished: MessageTime.format(t0)))
        }
    }

    /// A moderator that gave up leaves its marker in `verdict.md`, so the run reads back as abandoned — and
    /// abandoned counts as finished, which is why simply starting the run again does nothing at all. Retry is
    /// the only way back in, and it has to produce a moderation rather than silence.
    func testAModeratorFailedRunReadsBackAsAbandonedAndOnlyRetryRevivesIt() throws {
        let (run, root) = try runOnDisk()
        defer { try? FileManager.default.removeItem(at: root) }
        try answerEverybody(run)
        try run.writeVerdict("\(RunState.moderatorFailurePrefix) the model never answered)")

        var o = VerdictOrchestrator(run: run)
        XCTAssertTrue(o.isFinished, "abandoned reads as finished, so an ordinary start declines the run")
        XCTAssertTrue(o.begin(now: t0).isEmpty, "which is exactly why starting it again achieved nothing")

        let retry = o.retryModerator(now: t0)
        XCTAssertTrue(retry.contains { if case .moderate = $0 { return true } else { return false } },
                      "retry asks the moderator again")
        XCTAssertEqual(o.phase, .moderating)
        XCTAssertTrue(asked(retry).isEmpty, "and nobody who already answered is asked a second time")
    }

    /// The other half of the same rule: however the retry is reached, a run that has a verdict keeps it.
    func testARunThatAlreadyHasAVerdictIsNeverReModeratedFromDisk() throws {
        let (run, root) = try runOnDisk()
        defer { try? FileManager.default.removeItem(at: root) }
        try answerEverybody(run)
        try run.writeVerdict("They agree.\n\nScore: 81/100\n")

        var o = VerdictOrchestrator(run: run)
        XCTAssertEqual(o.phase, .complete(score: 81))
        XCTAssertTrue(o.retryModerator(now: t0).isEmpty, "a written verdict is not overwritten")
        XCTAssertEqual(o.phase, .complete(score: 81))
    }

    /// And a run that was interrupted part way still asks only for what is missing.
    func testAnInterruptedRunAsksOnlyForTheAnswersItDoesNotHave() throws {
        let (run, root) = try runOnDisk()
        defer { try? FileManager.default.removeItem(at: root) }
        try run.record("claude", round: 1, answer: "claude answered before the app was quit",
                       done: RunDone(status: "ok", elapsed: 1, words: 6, finished: MessageTime.format(t0)))

        var o = VerdictOrchestrator(run: run)
        XCTAssertFalse(o.isFinished)
        XCTAssertEqual(asked(o.begin(now: t0)), ["codex", "deepseek"], "claude is left alone")
    }
}
