import XCTest
@testable import CouncilCore

/// The app and the CLI must put the same question to the same models, or two runs of the same council are not
/// comparable. These read the templates out of `council.py` and fail when either side is edited alone.
final class VerdictPromptsTests: XCTestCase {
    func testTemplatesMatchThePythonSource() throws {
        let source = try councilPySource()
        XCTAssertEqual(pythonLiteral("MEMBER_SYSTEM", in: source), VerdictPrompts.memberSystem)
        XCTAssertEqual(pythonLiteral("CRITIQUE_PROMPT", in: source), VerdictPrompts.critiquePrompt)
        XCTAssertEqual(pythonLiteral("MODERATOR_SYSTEM", in: source), VerdictPrompts.moderatorSystem)
        XCTAssertEqual(pythonLiteral("MODERATOR_PROMPT", in: source), VerdictPrompts.moderatorPrompt)
    }

    func testNothingIsLeftUnsubstituted() {
        let round1 = VerdictPrompts.memberPaste(name: "claude", round: 1, rounds: 2, length: "about 300 words",
                                                question: "Q?", peerAnswers: [], ownPrevious: nil)
        XCTAssertFalse(round1.contains("{"), round1)
        let round2 = VerdictPrompts.memberPaste(name: "claude", round: 2, rounds: 2, length: "about 300 words",
                                                question: "Q?", peerAnswers: ["A", "B"], ownPrevious: "mine")
        XCTAssertFalse(round2.contains("{"), round2)
        let moderator = VerdictPrompts.moderatorPaste(name: "pi", question: "Q?", rounds: 2,
                                                      answers: [("Model A", "x", nil), ("Model B", nil, "timed out")])
        XCTAssertFalse(moderator.contains("{"), moderator)
    }

    func testRoundOneAsksTheQuestionAndNothingElse() {
        XCTAssertEqual(VerdictPrompts.memberUser(round: 1, rounds: 3, question: "What now?",
                                                 peerAnswers: ["ignored"], ownPrevious: "ignored"),
                       "What now?")
    }

    func testACritiqueNumbersThePeersAndCarriesTheOwnAnswer() {
        let text = VerdictPrompts.memberUser(round: 2, rounds: 3, question: "What now?",
                                             peerAnswers: ["peer one", ""], ownPrevious: "mine")
        XCTAssertTrue(text.hasPrefix("This is round 2 of 3."))
        XCTAssertTrue(text.contains("# Response 1\n\npeer one"))
        XCTAssertTrue(text.contains("# Response 2\n\n(no answer produced)"), "an absent peer is named, not skipped")
        XCTAssertTrue(text.hasSuffix("# Your previous answer\n\nmine"))
    }

    func testAMemberWithNoPreviousAnswerSaysSo() {
        let text = VerdictPrompts.memberUser(round: 2, rounds: 2, question: "Q", peerAnswers: ["a"], ownPrevious: nil)
        XCTAssertTrue(text.hasSuffix("# Your previous answer\n\n(none)"))
    }

    func testTheModeratorIsToldWhoDidNotAnswerAndWhy() {
        let text = VerdictPrompts.moderatorUser(question: "Q", rounds: 1,
                                                answers: [("Claude", "an answer", nil),
                                                          ("Codex", nil, "no answer in 300s")])
        XCTAssertTrue(text.contains("## Claude\n\nan answer"))
        XCTAssertTrue(text.contains("## Codex\n\n(no answer: no answer in 300s)"))
        XCTAssertFalse(text.contains("final round"), "one round needs no round note")
        XCTAssertTrue(text.hasSuffix("Produce the verdict now."))
    }

    func testSeveralRoundsAreMentionedToTheModerator() {
        XCTAssertTrue(VerdictPrompts.moderatorSystem(rounds: 3)
            .contains("then critiqued each other's answers over 3 rounds"))
        XCTAssertFalse(VerdictPrompts.moderatorSystem(rounds: 1).contains("critiqued"))
        XCTAssertTrue(VerdictPrompts.moderatorUser(question: "Q", rounds: 2, answers: [("A", "x", nil)])
            .contains("# Member answers (final round 2 of 2)"))
    }

    func testEveryPasteEndsWithHowToPostTheAnswer() {
        let paste = VerdictPrompts.memberPaste(name: "deepseek", round: 1, rounds: 1, length: "short",
                                               question: "Q", peerAnswers: [], ownPrevious: nil)
        XCTAssertTrue(paste.contains("council post --as deepseek"))
        XCTAssertTrue(paste.hasPrefix("You are one member of a council"), "the system half comes first")
    }

    // MARK: peer order

    func testPeerOrderIsStableForAMemberAndRound() {
        let peers = ["claude", "codex", "deepseek", "gemini"]
        let first = VerdictPrompts.peerOrder(peers, for: "claude", round: 2)
        XCTAssertEqual(first, VerdictPrompts.peerOrder(peers, for: "claude", round: 2), "same prompt every time")
        XCTAssertEqual(Set(first), Set(peers), "everyone is shown, once")
    }

    func testPeerOrderDiffersBetweenMembersSoNobodyIsAlwaysFirst() {
        let peers = ["claude", "codex", "deepseek", "gemini"]
        let orders = Set(["a", "b", "c", "d", "e"].map { VerdictPrompts.peerOrder(peers, for: $0, round: 2) })
        XCTAssertGreaterThan(orders.count, 1)
    }

    // MARK: reading chat.py's sibling

    private func councilPySource() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        let file = url.appendingPathComponent("council.py")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file.path), "council.py not found at \(file.path)")
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func pythonLiteral(_ name: String, in source: String) -> String? {
        guard let assignment = source.range(of: "\n\(name) = ") else { return nil }
        let rest = source[assignment.upperBound...]
        guard rest.hasPrefix("\"\"\"") else { return nil }
        var body = rest.dropFirst(3)
        if body.hasPrefix("\\\n") { body = body.dropFirst(2) }     // """\ : no leading newline
        guard let end = body.range(of: "\"\"\"") else { return nil }
        return String(body[..<end.lowerBound])
    }
}
