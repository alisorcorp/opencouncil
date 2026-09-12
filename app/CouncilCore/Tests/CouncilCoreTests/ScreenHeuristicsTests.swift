import XCTest
@testable import CouncilCore

final class ScreenHeuristicsTests: XCTestCase {
    // Screens as captured from the real CLIs on 2026-09-10 inside the app's terminals.
    private let claudeTrust = [
        "Accessing workspace:", "/Users/x/Documents/AI/council", "",
        "Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work",
        "from your team). If not, take a moment to review what's in this folder first.", "",
        "Claude Code'll be able to read, edit, and execute files here.", "", "Security guide", "",
        " ❯ No, exit", "   Yes, I trust this folder", "", " Enter to confirm · Esc to cancel",
    ]
    private let codexHooks = [
        "  Hooks need review", "  8 hooks are new or changed.", "  Hooks can run outside the sandbox after you trust them.", "",
        "› 1. Review hooks", "  2. Trust all and continue", "  3. Continue without trusting (hooks won't run)",
    ]
    private let codexPrompt = [
        ">_ OpenAI Codex (v0.154.0)", "model: gpt-6-astra medium  /model to change", "directory: ~/Documents/AI/council",
        "• You have 2 usage limit resets available. Run /usage to use one.", "› Ask Codex to do anything",
        "gpt-6-astra medium · ~/Documents/AI/council · Context 0% used · weekly 76% left",
    ]

    func testRecognisesTheDialogsTheCLIsShowBeforeASessionExists() {
        XCTAssertEqual(ScreenHeuristics.blockingDialog(in: claudeTrust)?.reason, "folder trust dialog")
        XCTAssertEqual(ScreenHeuristics.blockingDialog(in: codexHooks)?.reason, "hooks review dialog")
        XCTAssertEqual(ScreenHeuristics.blockingDialog(in: ["Select login method", "1. Claude account"])?.reason, "login required")
        XCTAssertNil(ScreenHeuristics.blockingDialog(in: codexPrompt))
        XCTAssertNil(ScreenHeuristics.blockingDialog(in: []))
    }

    func testReadinessNeedsADrawnScreenThatStaysTheSameAfterTheGracePeriod() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        // Nothing drawn yet: never ready, however long the (empty) screen has been stable.
        XCTAssertFalse(ScreenHeuristics.looksReady(lines: [], outputBytes: 0, screenStableFor: 60, launchedAt: t0, now: t0 + 30))
        XCTAssertFalse(ScreenHeuristics.looksReady(lines: ["", ""], outputBytes: 12, screenStableFor: 60, launchedAt: t0, now: t0 + 30))
        // Prompt drawn: not before the grace period, ready once the text has been stable for 3 s after it.
        XCTAssertFalse(ScreenHeuristics.looksReady(lines: codexPrompt, outputBytes: 900, screenStableFor: 3, launchedAt: t0, now: t0 + 4))
        XCTAssertFalse(ScreenHeuristics.looksReady(lines: codexPrompt, outputBytes: 900, screenStableFor: 2, launchedAt: t0, now: t0 + 9))
        XCTAssertTrue(ScreenHeuristics.looksReady(lines: codexPrompt, outputBytes: 900, screenStableFor: 3, launchedAt: t0, now: t0 + 5))
        // Stable text but a dialog on it: blocked, not ready.
        XCTAssertFalse(ScreenHeuristics.looksReady(lines: claudeTrust, outputBytes: 900, screenStableFor: 30, launchedAt: t0, now: t0 + 20))
    }

    func testNormalizationRemovesCodexTwinklingDecorationButKeepsWords() {
        // Two consecutive frames of Codex 0.154's idle composer, as read from the terminal buffer.
        let frame1 = ["    ⠈                           ⠁ ⢀              ⠐ ⠐                    ⠄", "›⠁Ask Codex to do anything⡀             ⠁                    ⠈\u{0}\u{0}",
                      "      ⠠             ⠠                        ⢀         ⠂  ⡀", "gpt-6-astra medium · ~/Documents/AI · Context 0% used"]
        let frame2 = ["    ⠈                       ⠈           ⠁        ⠐", "›⠁Ask Codex to do anything⡀        ⠈    ⠁ ⠁                  ⠈",
                      "                    ⠠                        ⢀      ⠠ ⠄⠂                       ⠄     \u{0}\u{0}\u{0}", "gpt-6-astra medium · ~/Documents/AI · Context 0% used"]
        XCTAssertEqual(ScreenHeuristics.normalized(frame1), ScreenHeuristics.normalized(frame2))
        XCTAssertEqual(ScreenHeuristics.normalized(frame1), ["›Ask Codex to do anything", "gpt-6-astra medium · ~/Documents/AI · Context 0% used"])
        // Words still matter: a reply appearing is a change.
        XCTAssertNotEqual(ScreenHeuristics.normalized(frame1), ScreenHeuristics.normalized(frame1 + ["hello there"]))
        // Borders and block cursors are decoration too.
        XCTAssertEqual(ScreenHeuristics.normalized(["╭──────╮", "│ >_ Codex │", "> █"]), ScreenHeuristics.normalized(["╭──────╮", "│ >_ Codex │", ">"]))
    }

    func testCursorBlinkAndSpinnerFramesAreCosmetic() {
        let base = codexPrompt
        var blinkOn = base; blinkOn[4] = "› █sk Codex to do anything"
        XCTAssertTrue(ScreenHeuristics.isCosmeticChange(from: base, to: blinkOn))
        XCTAssertTrue(ScreenHeuristics.isCosmeticChange(from: blinkOn, to: base))
        var spinner1 = base; spinner1.append("⠋ thinking"); var spinner2 = base; spinner2.append("⠙ thinking")
        XCTAssertTrue(ScreenHeuristics.isCosmeticChange(from: spinner1, to: spinner2))
        // A cursor on an otherwise empty last line makes that line come and go.
        XCTAssertTrue(ScreenHeuristics.isCosmeticChange(from: base, to: base + ["█"]))
        // Real changes are not cosmetic: new text, two lines changed, a line replaced.
        XCTAssertFalse(ScreenHeuristics.isCosmeticChange(from: base, to: base + ["hello", "world"]))
        var reply = base; reply[4] = "› hello there, this is a reply"
        XCTAssertFalse(ScreenHeuristics.isCosmeticChange(from: base, to: reply))
        var two = blinkOn; two[0] = ">_ OpenAI Codex (v0.155.0)"
        XCTAssertFalse(ScreenHeuristics.isCosmeticChange(from: base, to: two))
        XCTAssertTrue(ScreenHeuristics.isCosmeticChange(from: base, to: base))
    }

    // MARK: API errors (chat.py `trailing_error`)

    func testAScreenEndingOnAnErrorLineIsAnApiError() {
        XCTAssertEqual(ScreenHeuristics.trailingError(in: ["thinking…", "Error: 529 overloaded_error", ""]),
                       "Error: 529 overloaded_error")
        XCTAssertEqual(ScreenHeuristics.trailingError(in: ["✗ request failed"]), "✗ request failed")
        XCTAssertEqual(ScreenHeuristics.trailingError(in: ["Corrupted thought signature in part 0"]),
                       "Corrupted thought signature in part 0")
    }

    func testRealContentAfterTheErrorMeansTheMemberMovedOn() {
        XCTAssertNil(ScreenHeuristics.trailingError(in: [
            "Error: 529 overloaded_error",
            "Right, retrying that — here is what I think about the router design so far.",
        ]))
    }

    func testAThroughputFooterUnderTheErrorIsNotContent() {
        XCTAssertEqual(ScreenHeuristics.trailingError(in: [
            "Error: 529 overloaded_error",
            "  38.2 TPS · 0.42s TTFT · 18k ctx · gpt-5-codex-high-effort-long-name",
        ]), "Error: 529 overloaded_error")
    }

    func testAQuietPromptIsNotAnError() {
        XCTAssertNil(ScreenHeuristics.trailingError(in: ["> ", ""]))
        XCTAssertNil(ScreenHeuristics.trailingError(in: []))
        XCTAssertNil(ScreenHeuristics.trailingError(in: ["errors are handled in Bus.append"]))
    }

    // MARK: dialogs a cursor-positioned TUI draws

    /// Measured against the real Codex, not imagined: it asks about directory trust about a second after
    /// launch, and lays the question out so that the gaps between words arrive as NUL rather than spaces.
    /// Matching the raw rows therefore failed however exactly the wording was copied — so the app saw no
    /// dialog, called the member ready, and pasted the briefing into the prompt. The Enter that came with it
    /// selected the highlighted "Yes, continue", which is the app answering a prompt-injection warning on the
    /// user's behalf by accident, and cost about twenty seconds of the first turn on top.
    func testATrustDialogIsFoundEvenWhenItsSpacesArriveAsNul() {
        let screen = [
            ">You are in /Users/x/Code/project",
            "Do\u{0}you\u{0}trust\u{0}the\u{0}contents\u{0}of\u{0}this\u{0}directory?\u{0}Working\u{0}with\u{0}untrusted",
            "contents\u{0}comes\u{0}with\u{0}higher\u{0}risk\u{0}of\u{0}prompt\u{0}injection.",
            "› 1. Yes, continue",
            "  2. No, exit",
        ]
        let dialog = ScreenHeuristics.blockingDialog(in: screen)
        XCTAssertEqual(dialog?.reason, "folder trust dialog")
        XCTAssertFalse(ScreenHeuristics.looksReady(lines: screen, outputBytes: 3710, screenStableFor: 30,
                                                   launchedAt: Date(timeIntervalSinceNow: -60)),
                       "a member sitting on a trust prompt is not ready for a briefing, however settled its screen")
    }

    /// The same wording with ordinary spaces must keep working, and so must every needle that already did.
    func testTheSameDialogIsFoundWithOrdinarySpacing() {
        XCTAssertEqual(ScreenHeuristics.blockingDialog(in: ["Do you trust the contents of this directory?"])?.reason,
                       "folder trust dialog")
    }

    /// A question that wraps across rows is still one question.
    func testANeedleThatWrapsAcrossTwoRowsIsStillFound() {
        let screen = ["Do you trust the contents", "of this directory?", "› 1. Yes, continue"]
        XCTAssertEqual(ScreenHeuristics.blockingDialog(in: screen)?.reason, "folder trust dialog")
    }

    func testAnOrdinaryScreenIsStillNotADialog() {
        XCTAssertNil(ScreenHeuristics.blockingDialog(in: ["› ", "Ready when you are.", "context left: 94%"]))
    }
}
