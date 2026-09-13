import XCTest
@testable import CouncilCore

/// Every arrow of the member state machine in the plan. The supervisor is pure and takes its clock, so a
/// timeout is a date argument rather than a wait.
final class MemberSupervisorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func supervisor(_ members: [String] = ["claude", "codex"]) -> MemberSupervisor {
        var s = MemberSupervisor(members: members)
        for m in members { s.launched(m, now: t0) }
        return s
    }

    private func pastes(_ effects: [MemberSupervisor.Effect]) -> [String] {
        effects.compactMap { if case .paste(let m, _) = $0 { return m } else { return nil } }
    }

    private func notes(_ effects: [MemberSupervisor.Effect]) -> [String] {
        effects.compactMap { if case .note(let n) = $0 { return n } else { return nil } }
    }

    private func outcomes(_ effects: [MemberSupervisor.Effect]) -> [DeliveryOutcome] {
        effects.compactMap { if case .close(_, let o, _) = $0 { return o } else { return nil } }
    }

    private func pasted(_ effects: [MemberSupervisor.Effect]) -> [String] {
        effects.compactMap { if case .paste(_, let text) = $0 { return text } else { return nil } }
    }

    /// A verdict run's supervisor: every member was asked the same direct question, so one silent turn earns
    /// a nudge rather than being taken as an answer.
    private func askingSupervisor(_ members: [String] = ["kimi"]) -> MemberSupervisor {
        var timings = MemberSupervisor.Timings()
        timings.nudgesForMissingAnswer = 1
        var s = MemberSupervisor(members: members, timings: timings)
        for m in members { s.launched(m, now: t0) }
        return s
    }

    /// Drives one member to the end of a silent turn and returns what that produced.
    private func silentTurn(_ s: inout MemberSupervisor, from: TimeInterval = 1) -> [MemberSupervisor.Effect] {
        _ = s.apply(.started(sessionId: nil, reason: nil), to: "kimi", now: at(from))
        _ = s.send("answer this", to: "kimi", upTo: 7, now: at(from + 1))
        _ = s.apply(.turnStarted, to: "kimi", now: at(from + 2))
        return s.apply(.turnEnded(lastMessage: nil), to: "kimi", now: at(from + 4))
    }

    // MARK: starting

    func testLaunchStartsAMemberAndTheSessionEventMakesItReady() {
        var s = supervisor()
        XCTAssertEqual(s.state(of: "claude"), .starting)
        _ = s.apply(.started(sessionId: "abc", reason: "startup"), to: "claude", now: at(1))
        XCTAssertEqual(s.state(of: "claude"), .ready)
    }

    func testABriefingTurnEndAlsoMakesAStartingMemberReady() {
        var s = supervisor()
        _ = s.apply(.turnEnded(lastMessage: nil), to: "claude", now: at(3))
        XCTAssertEqual(s.state(of: "claude"), .ready)
    }

    func testADialogBeforeTheFirstPromptIsBlockedPre() {
        var s = supervisor()
        let e = s.apply(.blocked(reason: "folder trust"), to: "claude", now: at(1))
        XCTAssertEqual(s.state(of: "claude"), .blockedBeforeStart(reason: "folder trust"))
        XCTAssertTrue(e.contains(.unavailable(member: "claude")))
        _ = s.apply(.unblocked, to: "claude", now: at(2))
        XCTAssertEqual(s.state(of: "claude"), .starting, "answering the dialog puts it back on the launch path")
    }

    func testAMemberThatNeverSpeaksBecomesAnErrorAfterTheReadyTimeout() {
        var s = supervisor()
        XCTAssertTrue(s.tick(now: at(299)).isEmpty)
        let e = s.tick(now: at(301))
        XCTAssertEqual(s.state(of: "claude"), .error(reason: MemberSupervisor.noSignOfLife))
        XCTAssertTrue(e.contains(.unavailable(member: "claude")))
        XCTAssertTrue(s.tick(now: at(400)).isEmpty, "the timeout fires once")
    }

    // MARK: delivery

    func testSendingOpensALedgerEntryAndPastesOnce() {
        var s = supervisor()
        _ = s.apply(.started(sessionId: nil, reason: nil), to: "claude", now: at(1))
        let e = s.send("read this", to: "claude", upTo: 7, now: at(2))
        XCTAssertEqual(pastes(e), ["claude"])
        guard case .open(let d) = e.first else { return XCTFail("the delivery is opened before it is pasted") }
        XCTAssertEqual(d.member, "claude")
        XCTAssertEqual(d.upToMessageId, 7)
        XCTAssertEqual(s.state(of: "claude"), .prompted(attempts: 1))
    }

    func testTurnStartUnlocksTheTerminalAndTheMemberIsWorking() {
        var s = supervisor()
        _ = s.apply(.started(sessionId: nil, reason: nil), to: "claude", now: at(1))
        _ = s.send("read this", to: "claude", upTo: 7, now: at(2))
        let e = s.apply(.turnStarted, to: "claude", now: at(3))
        XCTAssertTrue(e.contains(.unlock(member: "claude")))
        XCTAssertEqual(s.state(of: "claude"), .working(activity: nil))
        _ = s.apply(.toolStarted(tool: "Read", activity: "reading chat.py"), to: "claude", now: at(4))
        XCTAssertEqual(s.state(of: "claude"), .working(activity: "reading chat.py"))
    }

    func testAPromptThatIsNotAcknowledgedIsPastedAgainUpToThreeTimes() {
        var s = supervisor()
        _ = s.apply(.started(sessionId: nil, reason: nil), to: "claude", now: at(1))
        _ = s.send("read this", to: "claude", upTo: 7, now: at(2))
        XCTAssertTrue(s.tick(now: at(10)).isEmpty, "still inside the acknowledgement window")
        XCTAssertEqual(pastes(s.tick(now: at(18))), ["claude"], "second attempt")
        XCTAssertEqual(s.state(of: "claude"), .prompted(attempts: 2))
        XCTAssertEqual(pastes(s.tick(now: at(34))), ["claude"], "third attempt")
        let giveUp = s.tick(now: at(50))
        XCTAssertTrue(pastes(giveUp).isEmpty, "three attempts is the limit")
        XCTAssertEqual(notes(giveUp), ["claude did not accept the prompt"])
        XCTAssertEqual(outcomes(giveUp), [.failed])
        XCTAssertTrue(giveUp.contains(.unlock(member: "claude")))
        XCTAssertTrue(giveUp.contains(.unavailable(member: "claude")))
        XCTAssertEqual(s.state(of: "claude"), .error(reason: MemberSupervisor.didNotAcceptPrompt))
    }

    // MARK: the end of a turn

    func testAPostDuringTheTurnClosesTheDeliveryAsPosted() {
        var s = supervisor()
        _ = s.apply(.started(sessionId: nil, reason: nil), to: "claude", now: at(1))
        _ = s.send("read this", to: "claude", upTo: 7, now: at(2))
        _ = s.apply(.turnStarted, to: "claude", now: at(3))
        s.posted(member: "claude", messageId: 9, now: at(4))
        let end = s.apply(.turnEnded(lastMessage: "done"), to: "claude", now: at(5))
        XCTAssertEqual(outcomes(end), [.posted])
        XCTAssertTrue(notes(end).isEmpty, "a member that answered is not announced")
        XCTAssertTrue(end.contains(.finished(member: "claude")))
        XCTAssertEqual(s.state(of: "claude"), .ready)
    }

    func testATurnThatEndsWithoutAPostIsNothingToAdd() {
        var s = supervisor()
        _ = s.apply(.started(sessionId: nil, reason: nil), to: "claude", now: at(1))
        _ = s.send("read this", to: "claude", upTo: 7, now: at(2))
        _ = s.apply(.turnStarted, to: "claude", now: at(3))
        let end = s.apply(.turnEnded(lastMessage: nil), to: "claude", now: at(5))
        XCTAssertEqual(notes(end), ["claude had nothing to add"])
        XCTAssertEqual(outcomes(end), [.nothingToAdd])
    }

    // MARK: a turn that ended without the answer it was asked for

    /// kimi wrote a complete answer to a verdict round, ended its turn without running `council post`, and
    /// the round was recorded as unanswered — which dropped it from every later round. The answer existed
    /// the whole time; only the tool call was missing.
    func testAnAnsweringTurnThatPostsNothingIsNudgedRatherThanClosed() {
        var s = askingSupervisor()
        let end = silentTurn(&s)
        XCTAssertTrue(outcomes(end).isEmpty, "the delivery stays open: the member still has the answer")
        XCTAssertEqual(notes(end), ["kimi ended its turn without posting; asking it to post"])
        XCTAssertEqual(pasted(end), [Briefing.postNudge(name: "kimi")])
        XCTAssertTrue(s.hasDeliveryInFlight(for: "kimi"))
        XCTAssertEqual(s.state(of: "kimi"), .prompted(attempts: 1),
                       "the nudge is a paste like any other, so the acknowledgement timeouts cover it")
    }

    func testTheNudgedMemberThatPostsClosesAsPosted() {
        var s = askingSupervisor()
        _ = silentTurn(&s)
        _ = s.apply(.turnStarted, to: "kimi", now: at(7))
        s.posted(member: "kimi", messageId: 9, now: at(8))
        let end = s.apply(.turnEnded(lastMessage: nil), to: "kimi", now: at(9))
        XCTAssertEqual(outcomes(end), [.posted])
        XCTAssertTrue(notes(end).isEmpty)
    }

    func testASecondSilentTurnEndsTheDeliveryAsBefore() {
        var s = askingSupervisor()
        _ = silentTurn(&s)
        _ = s.apply(.turnStarted, to: "kimi", now: at(7))
        let end = s.apply(.turnEnded(lastMessage: nil), to: "kimi", now: at(9))
        XCTAssertEqual(outcomes(end), [.nothingToAdd], "one nudge, not a loop")
        XCTAssertEqual(notes(end), ["kimi had nothing to add"])
        XCTAssertTrue(end.contains(.finished(member: "kimi")))
    }

    func testANudgeNobodyTakesFailsLikeAPromptNobodyTook() {
        var s = askingSupervisor()
        _ = silentTurn(&s)                                   // nudged at t+5, never acknowledged
        XCTAssertEqual(pastes(s.tick(now: at(21))), ["kimi"])
        XCTAssertEqual(pastes(s.tick(now: at(37))), ["kimi"])
        let gaveUp = s.tick(now: at(53))
        XCTAssertEqual(outcomes(gaveUp), [.failed])
        XCTAssertEqual(s.state(of: "kimi"), .error(reason: MemberSupervisor.didNotAcceptPrompt))
    }

    /// The safety property for chats, where a member that decides not to reply has said something by saying
    /// nothing and a nudge would talk it out of that.
    func testAChatNeverNudges() {
        XCTAssertEqual(MemberSupervisor.Timings().nudgesForMissingAnswer, 0)
        var s = MemberSupervisor(members: ["kimi"])
        s.launched("kimi", now: t0)
        XCTAssertEqual(outcomes(silentTurn(&s)), [.nothingToAdd])
    }

    func testAPostFromAnEarlierTurnDoesNotSatisfyThisDelivery() {
        var s = supervisor()
        _ = s.apply(.started(sessionId: nil, reason: nil), to: "claude", now: at(1))
        _ = s.send("read this", to: "claude", upTo: 7, now: at(2))
        _ = s.apply(.turnStarted, to: "claude", now: at(3))
        s.posted(member: "claude", messageId: 6, now: at(4))       // older than the delivery
        XCTAssertEqual(outcomes(s.apply(.turnEnded(lastMessage: nil), to: "claude", now: at(5))), [.nothingToAdd])
    }

    func testATurnTheUserStartedInTheTerminalIsNotAnnounced() {
        var s = supervisor()
        _ = s.apply(.started(sessionId: nil, reason: nil), to: "claude", now: at(1))
        _ = s.apply(.turnStarted, to: "claude", now: at(2))        // nothing was delivered
        let end = s.apply(.turnEnded(lastMessage: nil), to: "claude", now: at(3))
        XCTAssertTrue(notes(end).isEmpty)
        XCTAssertTrue(outcomes(end).isEmpty)
        XCTAssertTrue(end.contains(.finished(member: "claude")))
    }

    // MARK: interruptions

    func testADialogMidTurnBlocksAndUnblockingResumesTheTurn() {
        var s = supervisor()
        _ = s.apply(.started(sessionId: nil, reason: nil), to: "claude", now: at(1))
        _ = s.send("read this", to: "claude", upTo: 7, now: at(2))
        _ = s.apply(.turnStarted, to: "claude", now: at(3))
        let blocked = s.apply(.blocked(reason: "permission prompt"), to: "claude", now: at(4))
        XCTAssertEqual(s.state(of: "claude"), .blocked(reason: "permission prompt"))
        XCTAssertTrue(blocked.contains(.unavailable(member: "claude")))
        XCTAssertTrue(outcomes(blocked).isEmpty, "the delivery is still open: the member can still answer")
        _ = s.apply(.unblocked, to: "claude", now: at(5))
        XCTAssertEqual(s.state(of: "claude"), .working(activity: nil))
        XCTAssertEqual(outcomes(s.apply(.turnEnded(lastMessage: nil), to: "claude", now: at(6))), [.nothingToAdd])
    }

    func testExitingMidDeliveryClosesItAsFailed() {
        var s = supervisor()
        _ = s.apply(.started(sessionId: nil, reason: nil), to: "claude", now: at(1))
        _ = s.send("read this", to: "claude", upTo: 7, now: at(2))
        let e = s.exited("claude", status: 1, now: at(3))
        XCTAssertEqual(outcomes(e), [.failed])
        XCTAssertTrue(e.contains(.unavailable(member: "claude")))
        XCTAssertEqual(s.state(of: "claude"), .error(reason: "exited with status 1"))
    }

    func testACleanExitIsNotAnError() {
        var s = supervisor()
        _ = s.apply(.started(sessionId: nil, reason: nil), to: "claude", now: at(1))
        _ = s.exited("claude", status: 0, now: at(2))
        XCTAssertEqual(s.state(of: "claude"), .notRunning)
    }

    func testACLIFailureEndsTheDeliveryAndTheMemberCarriesTheReason() {
        var s = supervisor()
        _ = s.apply(.started(sessionId: nil, reason: nil), to: "claude", now: at(1))
        _ = s.send("read this", to: "claude", upTo: 7, now: at(2))
        _ = s.apply(.turnStarted, to: "claude", now: at(3))
        let e = s.apply(.failed(message: "context length exceeded"), to: "claude", now: at(4))
        XCTAssertEqual(outcomes(e), [.failed])
        XCTAssertEqual(s.state(of: "claude"), .error(reason: "context length exceeded"))
    }

    // MARK: API errors

    func testAnApiErrorOnScreenIsRetriedTwiceAndThenGivenUp() {
        var s = supervisor()
        _ = s.apply(.started(sessionId: nil, reason: nil), to: "claude", now: at(1))
        _ = s.send("read this", to: "claude", upTo: 7, now: at(2))
        _ = s.apply(.turnStarted, to: "claude", now: at(3))
        let first = s.sawApiError("Error: 529 overloaded", for: "claude", now: at(20))
        XCTAssertEqual(notes(first), ["claude hit an API error (Error: 529 overloaded); retrying"])
        XCTAssertEqual(pastes(first), ["claude"], "the retry prompt goes back into the terminal")
        let second = s.sawApiError("Error: 529 overloaded", for: "claude", now: at(60))
        XCTAssertEqual(pastes(second), ["claude"])
        let third = s.sawApiError("Error: 529 overloaded", for: "claude", now: at(90))
        XCTAssertTrue(pastes(third).isEmpty, "two retries is the limit")
        XCTAssertEqual(outcomes(third), [.failed])
        XCTAssertEqual(s.state(of: "claude"), .error(reason: MemberSupervisor.apiErrorGaveUp))
    }

    func testAnApiErrorWithNothingInFlightIsIgnored() {
        var s = supervisor()
        _ = s.apply(.started(sessionId: nil, reason: nil), to: "claude", now: at(1))
        XCTAssertTrue(s.sawApiError("Error: nope", for: "claude", now: at(2)).isEmpty)
    }

    // MARK: a long turn

    func testALongTurnIsFlaggedAsSlowWithoutBeingKilled() {
        var s = supervisor()
        _ = s.apply(.started(sessionId: nil, reason: nil), to: "claude", now: at(1))
        _ = s.send("read this", to: "claude", upTo: 7, now: at(2))
        _ = s.apply(.turnStarted, to: "claude", now: at(3))
        XCTAssertFalse(s.isSlow("claude", now: at(600)))
        XCTAssertTrue(s.isSlow("claude", now: at(1000)))
        XCTAssertEqual(s.state(of: "claude"), .working(activity: nil), "slow is not an error")
    }

    // MARK: muting and recovery

    func testRetryingAMemberPutsItBackOnTheLaunchPath() {
        var s = supervisor()
        _ = s.exited("claude", status: 1, now: at(2))
        XCTAssertEqual(s.state(of: "claude"), .error(reason: "exited with status 1"))
        s.launched("claude", now: at(3))
        XCTAssertEqual(s.state(of: "claude"), .starting)
        XCTAssertTrue(s.tick(now: at(200)).isEmpty, "the ready timeout starts again from the relaunch")
    }

    func testOnlyTheMemberThatWasSentToIsAffected() {
        var s = supervisor()
        _ = s.apply(.started(sessionId: nil, reason: nil), to: "claude", now: at(1))
        _ = s.apply(.started(sessionId: nil, reason: nil), to: "codex", now: at(1))
        _ = s.send("read this", to: "claude", upTo: 7, now: at(2))
        XCTAssertEqual(s.state(of: "codex"), .ready)
        XCTAssertTrue(s.tick(now: at(60)).allSatisfy { if case .paste(let m, _) = $0 { return m == "claude" }
                                                      else if case .note = $0 { return true }
                                                      else if case .close = $0 { return true }
                                                      else if case .unlock(let m) = $0 { return m == "claude" }
                                                      else if case .unavailable(let m) = $0 { return m == "claude" }
                                                      else { return true } })
        XCTAssertEqual(s.state(of: "codex"), .ready)
    }
    // MARK: giving up

    /// The premise behind the Retry card. Nothing the supervisor emits ever stops a process — there is no such
    /// effect — so a member that gave up is usually still sitting at its own prompt with nobody listening. A
    /// retry that declines while the host is alive would therefore never fire for exactly the members that
    /// need it, which is what it used to do.
    func testGivingUpOnAPromptLeavesTheProcessRunning() {
        var s = supervisor()
        _ = s.apply(.started(sessionId: nil, reason: nil), to: "claude", now: at(1))
        _ = s.send("read this", to: "claude", upTo: 7, now: at(2))
        _ = s.tick(now: at(18))
        _ = s.tick(now: at(34))
        let giveUp = s.tick(now: at(50))
        XCTAssertTrue(s.state(of: "claude").hasGivenUp)
        XCTAssertNotEqual(s.state(of: "claude"), .notRunning, "nothing here ended the process")
        XCTAssertEqual(outcomes(giveUp), [.failed], "and the question it dropped is left failed in the ledger")
    }

    func testGivingUpOnApiErrorsAlsoLeavesTheProcessRunning() {
        var s = supervisor()
        _ = s.apply(.started(sessionId: nil, reason: nil), to: "claude", now: at(1))
        _ = s.send("read this", to: "claude", upTo: 7, now: at(2))
        _ = s.apply(.turnStarted, to: "claude", now: at(3))
        for t in [20.0, 60.0, 90.0] { _ = s.sawApiError("Error: 529 overloaded", for: "claude", now: at(t)) }
        XCTAssertTrue(s.state(of: "claude").hasGivenUp)
        XCTAssertNotEqual(s.state(of: "claude"), .notRunning)
    }

    func testOnlyAMemberThatGaveUpReportsItself() {
        XCTAssertTrue(MemberState.error(reason: "did not accept the prompt").hasGivenUp)
        let others: [MemberState] = [.notRunning, .starting, .ready, .working(activity: nil),
                                     .prompted(attempts: 1), .blocked(reason: "a dialog"),
                                     .blockedBeforeStart(reason: "folder trust")]
        for state in others { XCTAssertFalse(state.hasGivenUp, "\(state) has not given up") }
    }
}
