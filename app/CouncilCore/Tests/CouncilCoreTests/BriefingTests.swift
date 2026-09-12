import XCTest
@testable import CouncilCore

/// The app and the CLI brief the same members, so the prompts must not fork. These tests read the templates
/// straight out of `chat.py` and compare them with the Swift copies; editing one side alone fails the suite.
final class BriefingTests: XCTestCase {
    // MARK: templates match chat.py

    func testTemplatesMatchThePythonSource() throws {
        let source = try chatPySource()
        XCTAssertEqual(pythonLiteral("BRIEFING", in: source), Briefing.briefingTemplate)
        XCTAssertEqual(pythonLiteral("RESUME_BRIEFING", in: source), Briefing.resumeTemplate)
        XCTAssertEqual(pythonLiteral("RESUMED_NOTE", in: source), Briefing.resumedNoteTemplate)
        XCTAssertEqual(pythonLiteral("DELIVERY", in: source), Briefing.deliveryTemplate)
        XCTAssertEqual(pythonLiteral("WRAP_NOTE", in: source), Briefing.wrapNote)
        XCTAssertEqual(pythonJoinedLiteral("RETRY_PROMPT", in: source), Briefing.retryTemplate)
    }

    /// A model copies the example it is given. The chat briefing and the delivery wrapper were taught single
    /// quotes and the heredoc after a member's maths reached the log with `$f_p` deleted and `$0` replaced by
    /// `/bin/bash` — but the resume note, the retry nudge and the whole verdict path still showed the
    /// double-quoted form, which is the one that hands the message to the shell first.
    func testNoPromptShowsAModelADoubleQuotedPost() {
        let prompts: [(String, String)] = [
            ("briefing", Briefing.briefingTemplate),
            ("resume", Briefing.resumeTemplate),
            ("resumed note", Briefing.resumedNoteTemplate),
            ("delivery", Briefing.deliveryTemplate),
            ("reaction", Briefing.reactionTemplate),
            ("retry", Briefing.retryTemplate),
            ("interrupted", Briefing.interruptedNote),
            ("pinned identity", Briefing.pinnedIdentityNote),
            ("wrap note", Briefing.wrapNote),
            ("verdict post instruction", VerdictPrompts.postInstruction),
            ("verdict member system", VerdictPrompts.memberSystem),
            ("verdict critique", VerdictPrompts.critiquePrompt),
            ("verdict moderator system", VerdictPrompts.moderatorSystem),
            ("verdict moderator prompt", VerdictPrompts.moderatorPrompt),
        ]
        let expanding = try! NSRegularExpression(pattern: #"council post --as \S+ *["]"#)
        for (name, text) in prompts {
            let range = NSRange(text.startIndex..., in: text)
            XCTAssertNil(expanding.firstMatch(in: text, range: range),
                         "the \(name) prompt shows the double-quoted form, which the shell expands first")
        }
    }

    func testEveryPlaceholderIsFilled() {
        let text = Briefing.briefing(name: "claude", members: ["claude", "codex", "deepseek"], cwd: "/w",
                                     resumeDirectory: URL(fileURLWithPath: "/chats/x"))
        XCTAssertFalse(text.contains("{"), "unsubstituted placeholder in:\n\(text)")
        let delivery = Briefing.delivery(name: "codex", messages: [message("user", "hi")], wrapping: true)
        XCTAssertFalse(delivery.contains("{"))
        XCTAssertFalse(Briefing.resumedNote(title: "t", name: "pi", directory: URL(fileURLWithPath: "/c")).contains("{"))
    }

    // MARK: substitution

    func testBriefingNamesTheOtherMembersTheWayThePythonDoes() {
        let text = Briefing.briefing(name: "codex", members: ["claude", "codex", "deepseek"], cwd: "/work/repo",
                                     pinnedIdentity: false)
        XCTAssertTrue(text.hasPrefix("You are \"codex\" in a live council chat with a human (\"user\") and other AI agents (claude, deepseek)."))
        XCTAssertTrue(text.contains("Address someone with @claude @deepseek or @user"))
        XCTAssertTrue(text.contains("working directory (/work/repo)"))
        XCTAssertTrue(text.hasSuffix("Post a one-line hello now to confirm you're connected."))
        XCTAssertFalse(text.contains("resumes an earlier conversation"))
    }

    func testResumedBriefingPointsAtTheTranscriptAndKeepsTheListShape() {
        let text = Briefing.briefing(name: "claude", members: ["claude", "codex"], cwd: "/w",
                                     resumeDirectory: URL(fileURLWithPath: "/chats/2026-09-10_x"), pinnedIdentity: false)
        XCTAssertTrue(text.contains("- `council log` prints the whole chat so far.\n- This chat resumes an earlier conversation"))
        XCTAssertTrue(text.contains("/chats/2026-09-10_x/transcript.md"))
    }

    func testPinnedIdentityIsAnExtraBulletTheCLIDoesNotSend() {
        let text = Briefing.briefing(name: "deepseek", members: ["claude", "deepseek"], cwd: "/w")
        XCTAssertTrue(text.contains("- This terminal is pinned to you: `council post` here always posts as \"deepseek\""))
        // It must stay inside the list, above the closing instruction.
        let bullet = try! XCTUnwrap(text.range(of: "- This terminal is pinned"))
        let hello = try! XCTUnwrap(text.range(of: "Post a one-line hello"))
        XCTAssertLessThan(bullet.lowerBound, hello.lowerBound)
    }

    // MARK: deliveries

    func testDeliveryFormatsTheLinesLikeFormatLines() {
        let messages = [
            message("user", "what do you think?", to: ["claude", "codex"]),
            message("claude", "@codex disagrees with me", to: ["codex"]),
            message("system", "budget reached", kind: Message.kindNote),
            message("codex", "my turn"),
        ]
        let text = Briefing.delivery(name: "codex", messages: messages)
        XCTAssertTrue(text.hasPrefix("New council chat messages (you are \"codex\"):\n\n"))
        XCTAssertTrue(text.contains("[user → @claude @codex] what do you think?\n\n[claude → @codex] @codex disagrees with me\n\n[you] my turn"))
        XCTAssertFalse(text.contains("budget reached"), "notes are not delivered")
        XCTAssertTrue(text.hasSuffix("post nothing if you have nothing to add)."))
    }

    func testWrappingAppendsTheFinalWordNote() {
        let text = Briefing.delivery(name: "claude", messages: [message("user", "wrap it up")], wrapping: true)
        XCTAssertTrue(text.hasSuffix(Briefing.wrapNote))
        XCTAssertTrue(text.contains("post one final message with your conclusion, and do not @mention anyone."))
    }

    func testFormatLinesSkipsNotesAndCallsTheReaderYou() {
        let lines = Briefing.formatLines([message("claude", "a"), message("system", "n", kind: Message.kindNote),
                                          message("user", "b", to: ["claude"])], me: "claude")
        XCTAssertEqual(lines, "[you] a\n\n[user → @claude] b")
    }

    // MARK: helpers

    private func message(_ sender: String, _ text: String, kind: String = Message.kindMessage, to: [String] = []) -> Message {
        Message(id: 1, ts: "2026-09-10T12:00:00", sender: sender, kind: kind, text: text, to: to)
    }

    /// chat.py lives beside the package, not in the test bundle.
    private func chatPySource() throws -> String {
        // .../<root>/app/CouncilCore/Tests/CouncilCoreTests/BriefingTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("chat.py")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("chat.py not found at \(path.path)")
        }
        return try String(contentsOf: path, encoding: .utf8)
    }

    /// The value of a module-level Python string constant: `NAME = """..."""` (with or without the `\` that
    /// swallows the first newline) or a single-line `NAME = "..."` with `\n` escapes.
    /// `NAME = ("part one " "part two")`, Python's implicit concatenation, as one string. Used for the
    /// constants chat.py wraps across lines inside parentheses.
    private func pythonJoinedLiteral(_ name: String, in source: String) -> String? {
        guard let assignment = source.range(of: "\(name) = (") else { return nil }
        let rest = source[assignment.upperBound...]
        guard let close = rest.firstIndex(of: ")") else { return nil }
        var parts: [String] = []
        var inside = false
        var current = ""
        var escaped = false
        for ch in rest[..<close] {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; current.append(ch); continue }
            if ch == "\"" {
                if inside { parts.append(current); current = "" }
                inside.toggle()
                continue
            }
            if inside { current.append(ch) }
        }
        return parts.joined()
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    private func pythonLiteral(_ name: String, in source: String) -> String? {
        guard let assignment = source.range(of: "\n\(name) = ") else { return nil }
        let rest = source[assignment.upperBound...]
        if rest.hasPrefix("\"\"\"") {
            var body = rest.dropFirst(3)
            if body.hasPrefix("\\\n") { body = body.dropFirst(2) }     // """\ : no leading newline
            guard let end = body.range(of: "\"\"\"") else { return nil }
            return String(body[..<end.lowerBound])
        }
        guard rest.hasPrefix("\""), let end = rest.dropFirst().firstIndex(of: "\"") else { return nil }
        return String(rest[rest.index(after: rest.startIndex)..<end])
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// A member that posts through a double-quoted shell string hands its message to the shell first. One did,
    /// and `$0` became `/bin/bash` in the middle of a sentence.
    func testTheBriefingSaysHowToQuoteAPost() {
        XCTAssertTrue(Briefing.briefingTemplate.contains("'your message'"), "the example is still double-quoted")
        XCTAssertTrue(Briefing.briefingTemplate.contains("expands $variables"), "nothing says why it matters")
        XCTAssertTrue(Briefing.deliveryTemplate.contains("council post --as {name} '...'"),
                      "the reply instruction still shows double quotes")
    }
}
