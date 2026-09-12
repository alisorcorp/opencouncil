import XCTest
@testable import CouncilCore

/// The routing rules are the ones the CLI has today (chat.py `Router.route` / `deliver_loop`), plus the reaction
/// pass the app adds (R11a). Every test drives the router with an explicit clock and readiness set.
final class ChatRouterTests: XCTestCase {
    private let roster = ["claude", "codex", "deepseek"]
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var nextId: Int64 = 1

    private func router(budget: Int = 20) -> ChatRouter {
        ChatRouter(members: roster, budget: budget)
    }

    private func msg(_ sender: String, _ text: String, to: [String]? = nil, kind: String = Message.kindMessage) -> Message {
        nextId += 1
        return Message(id: nextId, ts: "2026-09-10T12:00:00", sender: sender, kind: kind, text: text,
                       to: to ?? Mentions.extract(from: text, members: roster))
    }

    private func recipients(_ effects: [ChatRouter.Effect]) -> [String] {
        effects.compactMap { if case .deliver(let m, _) = $0 { return m } else { return nil } }
    }

    private func notes(_ effects: [ChatRouter.Effect]) -> [String] {
        effects.compactMap { if case .note(let n) = $0 { return n } else { return nil } }
    }

    /// Everything that was queued, delivered once the coalescing window has passed.
    private func flush(_ r: inout ChatRouter, ready: Set<String>? = nil, after: TimeInterval = 5) -> [ChatRouter.Effect] {
        r.tick(now: t0.addingTimeInterval(after), ready: ready ?? Set(roster))
    }

    /// A record nobody could read is a transport failure, not something a member said. Quoting the app's own
    /// diagnostic to the others as that member's words puts a sentence in its mouth, and a `to` list that never
    /// decoded must not route anything either.
    func testAPostNobodyCouldReadIsNotQuotedToTheOthers() {
        var r = router()
        r.append([msg("user", "what do you all think?")], now: t0)
        _ = flush(&r)
        let broken = Bus.decodeLines(Data((#"{"id": 8, "ts": "", "from": "claude", "kind": "msg", "text": "@codex cut"# + "\n").utf8))[0]
        XCTAssertTrue(broken.isUnreadable)
        r.append([broken, msg("codex", "@deepseek does that hold?")], now: t0.addingTimeInterval(1))
        let delivered = flush(&r, after: 10).compactMap { effect -> String? in
            if case .deliver(_, let text) = effect { return text } else { return nil }
        }
        XCTAssertEqual(delivered.count, 1, "the readable post should still be delivered")
        XCTAssertTrue(delivered[0].contains("does that hold?"))
        for text in delivered {
            XCTAssertFalse(text.contains("could not be read"), "a member was quoted the app's diagnostic:\n\(text)")
        }
    }

    // MARK: routing

    func testAUserMessageWithoutMentionsGoesToEveryMember() {
        var r = router()
        r.append([msg("user", "what do you all think?")], now: t0)
        XCTAssertEqual(recipients(flush(&r)), roster)
    }

    func testAUserMessageWithAMentionGoesOnlyToThatMember() {
        var r = router()
        r.append([msg("user", "@codex can you check the build?")], now: t0)
        XCTAssertEqual(recipients(flush(&r)), ["codex"])
    }

    func testAMutedMemberNeverReceivesAnything() {
        var r = router()
        r.mute("deepseek")
        r.append([msg("user", "everyone in")], now: t0)
        XCTAssertEqual(recipients(flush(&r)), ["claude", "codex"])
    }

    func testAMemberReplyReachesTheMembersItMentionsButNotItselfOrTheUser() {
        var r = router()
        r.append([msg("claude", "@codex @deepseek @user @claude take a look")], now: t0)
        XCTAssertEqual(Set(recipients(flush(&r))), ["codex", "deepseek"])
    }

    func testAMemberMessageWithoutMentionsIsPostedButRoutedToNobody() {
        var r = router()
        r.append([msg("claude", "just thinking out loud")], now: t0)
        XCTAssertTrue(flush(&r).isEmpty)
    }

    func testNotesAreNeverRoutedOrDelivered() {
        var r = router()
        r.append([msg("system", "@claude something happened", kind: Message.kindNote)], now: t0)
        XCTAssertTrue(flush(&r).isEmpty)
    }

    // MARK: budget

    func testAHopSpendsOnlyTheSendersOwnReplies() {
        var r = router(budget: 3)
        r.append([msg("user", "go")], now: t0)
        XCTAssertEqual(r.repliesLeft(for: "claude"), 3)
        r.append([msg("claude", "@codex thoughts?")], now: t0)
        XCTAssertEqual(r.repliesLeft(for: "claude"), 2)
        XCTAssertEqual(r.repliesLeft(for: "codex"), 3, "one member's hop must not spend another's replies")
        r.append([msg("codex", "@claude yes")], now: t0)
        XCTAssertEqual(r.repliesLeft(for: "codex"), 2)
        XCTAssertEqual(r.status.budgetLeft, 2, "the toolbar reports the member with the fewest left")
    }

    func testTheBudgetNoteIsPostedOncePerMemberAndFurtherMentionsAreDropped() {
        var r = router(budget: 1)
        r.append([msg("user", "go")], now: t0)
        _ = flush(&r)                                             // the user's round is out; queues are empty
        r.append([msg("claude", "@codex one")], now: t0.addingTimeInterval(6))   // claude's only reply
        let first = r.append([msg("claude", "@codex two")], now: t0.addingTimeInterval(6))
        XCTAssertEqual(notes(first), ["reply budget (1) reached for claude; say something to continue"])
        let second = r.append([msg("claude", "@codex three")], now: t0.addingTimeInterval(6))
        XCTAssertTrue(second.isEmpty, "the note is posted once per member, not on every dropped mention")
        let other = r.append([msg("codex", "@deepseek mine is untouched")], now: t0.addingTimeInterval(6))
        XCTAssertTrue(notes(other).isEmpty, "codex still has its own reply to spend")
        XCTAssertEqual(recipients(flush(&r, after: 20)), ["codex", "deepseek"],
                       "claude's dropped mentions prompted nobody; codex's hop did")
    }

    func testTheNextUserMessageRestoresEveryMembersReplies() {
        var r = router(budget: 1)
        r.append([msg("user", "go")], now: t0)
        r.append([msg("claude", "@codex one")], now: t0)
        _ = r.append([msg("claude", "@codex two")], now: t0)
        XCTAssertEqual(r.repliesLeft(for: "claude"), 0)
        r.append([msg("user", "carry on")], now: t0)
        XCTAssertEqual(r.repliesLeft(for: "claude"), 1)
    }

    // MARK: wrap-up

    func testWrapUpIsDetectedTheWayThePythonRegexDoesIt() {
        XCTAssertTrue(ChatRouter.isWrapUp("ok, wrap it up"))
        XCTAssertTrue(ChatRouter.isWrapUp("Let's start wrapping up now"))
        XCTAssertTrue(ChatRouter.isWrapUp("/wrap"))
        XCTAssertFalse(ChatRouter.isWrapUp("that's a wrap on the video"))
        XCTAssertFalse(ChatRouter.isWrapUp("please don't /wrap yet mid-sentence"))
    }

    func testWrappingUpMarksEveryDeliveryAsFinal() {
        var r = router()
        r.append([msg("user", "let's wrap it up")], now: t0)
        XCTAssertTrue(r.wrapping)
        for case .deliver(_, let text) in flush(&r) {
            XCTAssertTrue(text.hasSuffix(Briefing.wrapNote))
        }
    }

    func testLateMentionsDuringWrapUpAreNotRoutedAndSaySoOnce() {
        var r = router()
        r.append([msg("user", "wrap it up please")], now: t0)
        _ = flush(&r)
        let first = r.append([msg("claude", "@codex one last thing")], now: t0)
        XCTAssertEqual(notes(first), ["mentions are not routed during wrap-up"])
        XCTAssertTrue(r.append([msg("codex", "@claude and another")], now: t0).isEmpty)
        XCTAssertTrue(flush(&r, after: 30).isEmpty)
    }

    // MARK: coalescing and readiness

    func testABurstOfMessagesArrivesAsOneDelivery() {
        var r = router()
        r.append([msg("user", "first")], now: t0)
        r.append([msg("claude", "@codex second")], now: t0.addingTimeInterval(1))
        XCTAssertTrue(r.tick(now: t0.addingTimeInterval(3), ready: Set(roster)).isEmpty, "window still open")
        let effects = flush(&r)
        XCTAssertEqual(recipients(effects).filter { $0 == "codex" }.count, 1)
        guard case .deliver(_, let text)? = effects.first(where: { if case .deliver("codex", _) = $0 { return true }; return false }) else {
            return XCTFail("no delivery for codex")
        }
        XCTAssertTrue(text.contains("[user] first"), text)
        XCTAssertTrue(text.contains("[claude → @codex] @codex second"), text)
    }

    func testADeliveryWaitsWhileTheMemberIsBusyAndGoesOutWhenItIsFree() {
        var r = router()
        r.append([msg("user", "go")], now: t0)
        XCTAssertEqual(recipients(flush(&r, ready: ["claude"])), ["claude"])
        XCTAssertEqual(Set(recipients(flush(&r, ready: Set(roster), after: 9))), ["codex", "deepseek"])
    }

    func testAMemberNeverSeesItsOwnMessagesAndNeverRepeatsADelivery() {
        var r = router()
        r.append([msg("user", "go")], now: t0)
        r.append([msg("claude", "@codex here")], now: t0)
        let text = recipientText(flush(&r), "codex")
        XCTAssertNotNil(text)
        XCTAssertTrue(flush(&r, after: 20).isEmpty, "nothing new since the last delivery")
    }

    private func recipientText(_ effects: [ChatRouter.Effect], _ member: String) -> String? {
        for case .deliver(let m, let text) in effects where m == member { return text }
        return nil
    }

    /// Members prompted by the reaction pass, as opposed to an ordinary delivery of new messages.
    private func reactions(_ effects: [ChatRouter.Effect]) -> [String] {
        effects.compactMap {
            if case .deliver(let m, let text) = $0, text.hasPrefix("The others have now replied") { return m }
            return nil
        }
    }

    // MARK: reaction pass (R11a)

    /// The pass only opens once every member prompted by the user has finished its turn.
    func testEveryoneIsAskedToReactOnceTheWholeCouncilHasAnswered() {
        var r = router()
        r.append([msg("user", "what do you think?")], now: t0)
        XCTAssertEqual(recipients(flush(&r)).count, 3)
        for m in roster { r.append([msg(m, "my answer from \(m)")], now: t0.addingTimeInterval(6)) }
        for m in roster { r.memberFinished(m) }
        let pass = flush(&r, after: 20)
        XCTAssertEqual(Set(reactions(pass)), Set(roster))
        let text = recipientText(pass, "claude")!
        XCTAssertTrue(text.hasPrefix("The others have now replied (you are \"claude\"):"))
        XCTAssertTrue(text.contains("[codex] my answer from codex"))
        XCTAssertTrue(text.contains("[deepseek] my answer from deepseek"))
        XCTAssertFalse(text.contains("my answer from claude"), "a member is not shown its own post")
        XCTAssertTrue(text.contains("Reply only if you have something to add"))
    }

    func testTheReactionPassHappensOncePerUserMessage() {
        var r = router()
        r.append([msg("user", "go")], now: t0)
        _ = flush(&r)
        for m in roster { r.append([msg(m, "answer")], now: t0.addingTimeInterval(6)); r.memberFinished(m) }
        XCTAssertEqual(Set(reactions(flush(&r, after: 20))), Set(roster))
        for m in roster { r.memberFinished(m) }
        XCTAssertTrue(reactions(flush(&r, after: 40)).isEmpty, "the gate does not reopen")
    }

    func testNoReactionPassWhileAMemberIsStillWorking() {
        var r = router()
        r.append([msg("user", "go")], now: t0)
        _ = flush(&r)
        r.append([msg("claude", "answer")], now: t0.addingTimeInterval(6))
        r.memberFinished("claude")
        r.memberFinished("codex")
        XCTAssertTrue(reactions(flush(&r, after: 20)).isEmpty, "deepseek has not finished")
        r.memberFinished("deepseek")
        XCTAssertFalse(reactions(flush(&r, after: 30)).isEmpty)
    }

    func testAMemberThatWillNotAnswerDoesNotHoldTheGateClosed() {
        var r = router()
        r.append([msg("user", "go")], now: t0)
        _ = flush(&r)
        r.append([msg("claude", "a")], now: t0.addingTimeInterval(6))
        r.append([msg("codex", "b")], now: t0.addingTimeInterval(6))
        r.memberFinished("claude")
        r.memberFinished("codex")
        r.memberUnavailable("deepseek")          // stuck on a dialog, or gone
        XCTAssertEqual(Set(reactions(flush(&r, after: 20))), ["claude", "codex"])
    }

    func testAMemberPulledBackInByAMentionIsNotAskedToReact() {
        var r = router()
        r.append([msg("user", "go")], now: t0)
        _ = flush(&r)
        r.append([msg("claude", "@deepseek what about this?")], now: t0.addingTimeInterval(6))
        r.append([msg("codex", "done")], now: t0.addingTimeInterval(6))
        r.append([msg("deepseek", "done too")], now: t0.addingTimeInterval(6))
        for m in roster { r.memberFinished(m) }
        XCTAssertEqual(Set(reactions(flush(&r, after: 20))), ["claude", "codex"],
                       "deepseek already has the mention to answer")
    }

    func testADirectedQuestionGetsNoReactionPass() {
        var r = router()
        r.append([msg("user", "@codex just you")], now: t0)
        _ = flush(&r)
        r.append([msg("codex", "answer")], now: t0.addingTimeInterval(6))
        r.memberFinished("codex")
        XCTAssertTrue(reactions(flush(&r, after: 20)).isEmpty)
    }

    func testNoReactionPassWhileWrappingUp() {
        var r = router()
        r.append([msg("user", "wrap it up")], now: t0)
        _ = flush(&r)
        for m in roster { r.append([msg(m, "final word")], now: t0.addingTimeInterval(6)); r.memberFinished(m) }
        XCTAssertTrue(reactions(flush(&r, after: 20)).isEmpty)
    }

    func testTheReactionPassSpendsOneReplyFromEachMemberItPrompts() {
        var r = router(budget: 2)
        r.append([msg("user", "go")], now: t0)
        _ = flush(&r)
        for m in roster { r.append([msg(m, "answer")], now: t0.addingTimeInterval(6)); r.memberFinished(m) }
        XCTAssertEqual(Set(reactions(flush(&r, after: 20))), Set(roster))
        for m in roster { XCTAssertEqual(r.repliesLeft(for: m), 1, "\(m) spent one on the pass") }
    }

    func testTheReactionPassNeedsTwoMembersThatStillHaveReplies() {
        var r = router(budget: 1)
        r.append([msg("user", "go")], now: t0)
        _ = flush(&r)
        r.append([msg("claude", "@codex hop")], now: t0.addingTimeInterval(6))   // claude spends its only reply
        for m in roster { r.append([msg(m, "answer")], now: t0.addingTimeInterval(6)); r.memberFinished(m) }
        // claude has nothing left and codex was already pulled back in by the mention: one candidate is not a pass.
        XCTAssertTrue(reactions(flush(&r, after: 20)).isEmpty, "not enough members left to react")
        XCTAssertTrue(reactions(flush(&r, after: 40)).isEmpty)
    }

    // MARK: reopening a chat

    /// A chat that already has a transcript when its members start. The router is handed that history so its
    /// cursors and its buffer are counted in the same units. The bug this covers had the cursors set to the
    /// length of the whole log while the buffer held only what arrived afterwards, so the slice in `tick` came
    /// back empty and the first question after reopening was dropped — silently, because the cursor had already
    /// advanced and the pending delivery had already been cleared.
    func testTheFirstQuestionAfterReopeningIsDelivered() {
        let history = (1...10).map { msg("claude", "old message \($0)") }
        var r = ChatRouter(members: roster, budget: 20, history: history)
        r.append([msg("user", "what should we do next?")], now: t0)
        let effects = flush(&r)
        XCTAssertEqual(recipients(effects), roster, "every member gets the question, not just the second one asked")
        for case .deliver(let member, let text) in effects {
            XCTAssertTrue(text.contains("what should we do next?"), "\(member) was sent a delivery without the question in it")
        }
    }

    func testReopeningDoesNotReplayTheHistoryItWasGiven() {
        let history = (1...10).map { msg("claude", "old message \($0)") }
        var r = ChatRouter(members: roster, budget: 20, history: history)
        r.append([msg("user", "fresh question")], now: t0)
        let effects = flush(&r)
        XCTAssertEqual(recipients(effects), roster, "nothing is proved by a pass with no deliveries in it")
        for case .deliver(_, let text) in effects {
            XCTAssertFalse(text.contains("old message"), "history is context the members already have, not something to re-ask")
        }
    }

    func testTheFirstQuestionAfterReopeningIsDeliveredOnlyOnce() {
        var r = ChatRouter(members: roster, budget: 20, history: (1...10).map { msg("claude", "old \($0)") })
        r.append([msg("user", "fresh question")], now: t0)
        XCTAssertEqual(recipients(flush(&r)), roster)
        XCTAssertTrue(recipients(flush(&r, after: 10)).isEmpty, "a question already delivered is not delivered again")
    }

    /// A member speaking before the user does must not shift the cursor out from under the question that follows.
    func testAMemberPostAfterReopeningDoesNotSwallowTheNextQuestion() {
        var r = ChatRouter(members: roster, budget: 20, history: (1...4).map { msg("user", "old \($0)") })
        r.append([msg("claude", "picking up where we left off")], now: t0)
        r.append([msg("user", "and now the new question")], now: t0)
        let effects = flush(&r)
        XCTAssertEqual(recipients(effects), roster)
        for case .deliver(let member, let text) in effects {
            XCTAssertTrue(text.contains("and now the new question"), "\(member) did not get the question")
        }
        for case .deliver(let member, let text) in effects where member != "claude" {
            XCTAssertTrue(text.contains("picking up where we left off"), "\(member) should also see what claude said")
        }
    }

    /// The empty-history case has always worked — it is the one the tests and every fresh chat exercised, and
    /// the reason 205 green tests said nothing about the bug above.
    func testAChatWithNoHistoryBehavesAsBefore() {
        var r = ChatRouter(members: roster, budget: 20, history: [])
        r.append([msg("user", "first thing anybody has said")], now: t0)
        XCTAssertEqual(recipients(flush(&r)), roster)
    }
}
