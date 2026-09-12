import XCTest
@testable import CouncilCore

final class BusTests: XCTestCase {
    func testReadsFixtureChat() throws {
        let msgs = try Bus(directory: Fixtures.chatDir).readAll()
        XCTAssertEqual(msgs.count, 9)
        XCTAssertEqual(msgs[0].sender, "deepseek")
        XCTAssertEqual(msgs[3].sender, "user")
        XCTAssertEqual(msgs[3].text, "Should the router coalesce messages I send in quick succession, "
                       + "or deliver each one as its own prompt?")
        XCTAssertEqual(msgs[3].to, [])
        XCTAssertEqual(msgs[3].clock, "11:36:41")
        XCTAssertNotNil(msgs[3].date)
        XCTAssertTrue(msgs.contains { !$0.to.isEmpty }, "fixture should include a message with mentions")
        XCTAssertFalse(msgs[0].isNote)
        XCTAssertTrue(msgs.allSatisfy { $0.kind == Message.kindMessage })
    }

    func testMentionsMatchPython() {
        let members = ["claude", "codex", "deepseek"]
        XCTAssertEqual(Mentions.extract(from: "@codex what do you think?", members: members), ["codex"])
        XCTAssertEqual(Mentions.extract(from: "@Codex, @CLAUDE and @codex again", members: members), ["codex", "claude"])
        XCTAssertEqual(Mentions.extract(from: "hey @all", members: members), members)
        XCTAssertEqual(Mentions.extract(from: "@deepseek then @everyone", members: members), ["deepseek", "claude", "codex"])
        XCTAssertEqual(Mentions.extract(from: "@user please decide", members: members), ["user"])
        XCTAssertEqual(Mentions.extract(from: "@nobody @123 email me@example.com", members: members), [])
        XCTAssertEqual(Mentions.extract(from: "no mentions here", members: members), [])
    }

    func testAppendRoundTripsAndInterleavesWithPythonShape() throws {
        let dir = try Fixtures.tempDir("bus")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bus = Bus(directory: dir)
        let m = try bus.append(sender: "user", text: "hello @codex, see https://example.com/x  \n", members: ["claude", "codex"])
        XCTAssertEqual(m.to, ["codex"])
        XCTAssertEqual(m.text, "hello @codex, see https://example.com/x")
        let raw = try String(contentsOf: bus.logURL, encoding: .utf8)
        XCTAssertEqual(raw.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(raw.contains("\"from\":\"user\""))
        XCTAssertTrue(raw.contains("https://example.com/x"), "slashes must not be escaped")
        // A Python-shaped line (spaces after separators, unicode escapes) reads back identically.
        let py = "{\"id\": 1789054572972220000, \"ts\": \"2026-09-10T11:36:12\", \"from\": \"deepseek\", \"kind\": \"msg\", \"text\": \"caf\\u00e9 \\u2014 ok\", \"to\": []}\n"
        try (raw + py).write(to: bus.logURL, atomically: true, encoding: .utf8)
        let all = try bus.readAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[1].text, "café — ok")
        XCTAssertEqual(all[1].id, 1789054572972220000)
        XCTAssertEqual(all[0], m)
    }

    func testSkipsGarbageLines() throws {
        let dir = try Fixtures.tempDir("bus-garbage")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bus = Bus(directory: dir)
        try "not json\n{\"id\": 1, \"from\": \"a\", \"text\": \"x\"}\n\n   \n".write(to: bus.logURL, atomically: true, encoding: .utf8)
        let all = try bus.readAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].kind, Message.kindMessage)
        XCTAssertEqual(all[0].to, [])
    }

    func testChatConfigLoadsAndLabels() throws {
        let cfg = try ChatConfig.load(from: Fixtures.chatDir)
        XCTAssertEqual(cfg.order, ["claude", "codex", "deepseek"])
        XCTAssertEqual(cfg.title, "router")
        XCTAssertEqual(cfg.budget, 12)
        XCTAssertEqual(cfg.members["claude"]?.agent, "claude-c3600")   // herdr field is read, never needed
        XCTAssertEqual(cfg.label(for: "user"), "you")
        XCTAssertEqual(cfg.label(for: "deepseek"), "DeepSeek V4.1 Flash · medium")
        XCTAssertEqual(cfg.label(for: "ghost"), "ghost")
        XCTAssertEqual(ChatConfig.splitEffortSuffix("Codex GPT-6 Astra · medium").label, "Codex GPT-6 Astra")
        XCTAssertEqual(ChatConfig.splitEffortSuffix("Codex GPT-6 Astra · medium").effort, "medium")
        XCTAssertEqual(ChatConfig.splitEffortSuffix("Plain · Name").label, "Plain · Name")
    }

    /// Interop with the real CLI: `council post` writes, Swift reads; Swift writes, `council log` reads.
    func testInteropWithCouncilCLI() throws {
        guard let cli = Fixtures.councilCLI else { throw XCTSkip("council CLI not installed") }
        let dir = try Fixtures.tempDir("interop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = """
        {"created": "2026-09-10T12:00:00", "cwd": "/tmp", "title": "t", "order": ["a", "b"],
         "members": {"a": {"label": "A"}, "b": {"label": "B"}}, "budget": 12, "effort": "medium"}
        """
        try config.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        let bus = Bus(directory: dir)
        try bus.append(sender: "user", text: "hi @b from swift", members: ["a", "b"])

        let post = Process()
        post.executableURL = cli
        post.arguments = ["post", "--chat", dir.path, "--as", "b", "reply to @a from the cli"]
        post.environment = ShellEnvironment.resolve().memberBaseEnvironment()
        try post.run(); post.waitUntilExit()
        XCTAssertEqual(post.terminationStatus, 0)

        let all = try bus.readAll()
        XCTAssertEqual(all.map(\.sender), ["user", "b"])
        XCTAssertEqual(all[1].to, ["a"])

        let log = Process()
        log.executableURL = cli
        log.arguments = ["log", "--chat", dir.path]
        let out = Pipe(); log.standardOutput = out
        log.environment = post.environment
        try log.run(); log.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("[user → @b] hi @b from swift"), text)
        XCTAssertTrue(text.contains("[b → @a] reply to @a from the cli"), text)
    }

    /// The briefing's posting examples are a promise about the shell, so they are kept as one: every payload
    /// goes through the exact command shape a member is shown and has to come back byte for byte. The message
    /// that started all of this was lost between the model typing it and `council post` reading argv — no
    /// decoder could have helped, because the words were already gone.
    func testThePostingFormsTheBriefingShowsSurviveTheShell() throws {
        guard let cli = Fixtures.councilCLI else { throw XCTSkip("council CLI not installed") }
        let dir = try Fixtures.tempDir("quoting")
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"""
        {"created": "2026-09-10T12:00:00", "cwd": "/tmp", "title": "t", "order": ["a"],
         "members": {"a": {"label": "A"}}, "budget": 12, "effort": "medium"}
        """#.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        let bus = Bus(directory: dir)
        let environment = ShellEnvironment.resolve().memberBaseEnvironment()

        func runInAShell(_ command: String) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", command]
            p.environment = environment
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, command)
        }
        let post = "\(cli.path) post --chat \(dir.path) --as a"

        // Everything that has ever been eaten on the way: expansions, command substitution, escapes, a
        // multi-byte character, the delimiter word itself, and an apostrophe — which is why the briefing does
        // not stop at single quotes.
        let payloads = [
            "the ratio $f_p is 0.3 and $0 is not a variable",
            "`date` and $(pwd) are text here",
            "a backslash \\ survives, and so does \\n",
            "en–dash, 20 °C, 😀",
            "it's got an apostrophe",
            "first line\nsecond line\n\nfourth",
            "a bare delimiter line follows\nEOF\nand the message goes on",
        ]
        for payload in payloads {
            try runInAShell("\(post) - <<'COUNCIL'\n\(payload)\nCOUNCIL\n")
        }
        // The inline form is the short one, and it holds for anything without an apostrophe.
        for payload in payloads where !payload.contains("'") && !payload.contains("\n") {
            try runInAShell("\(post) '\(payload)'")
        }

        let posted = try bus.readAll().map(\.text)
        let expected = payloads + payloads.filter { !$0.contains("'") && !$0.contains("\n") }
        XCTAssertEqual(posted, expected, "a payload was rewritten between the model and the log")
        XCTAssertTrue(Briefing.briefingTemplate.contains("<<'COUNCIL'"),
                      "the briefing must show the delimiter this test proves, not a different one")

        // And the form the three prompts used to show, for the same payload. The shell gets there first; no
        // decoder downstream can put the words back, which is why this is a prompt fix and not a parser one.
        try runInAShell("\(post) \"\(payloads[0])\"")
        let mangled = try XCTUnwrap(try bus.readAll().last?.text)
        XCTAssertNotEqual(mangled, payloads[0], "double quotes no longer cost anything — verify the shell, not the fix")
        XCTAssertFalse(mangled.contains("$f_p"), "the expansion is the whole point: \(mangled)")
    }

    /// The line that made the app tell a user a member "had nothing to add" while that member's reply sat in
    /// the log: a shell ate half a multi-byte character along with its $-expansions, Python wrote the remains
    /// as lone surrogate escapes, and a strict decoder refuses the whole line. Dropping it lost the post twice
    /// over — nothing closed the delivery, and nothing was drawn.
    func testALineWithLoneSurrogatesIsRepairedRatherThanDropped() throws {
        let good = #"{"id": 1, "ts": "2026-09-11T16:17:21", "from": "deepseek", "kind": "msg", "text": "fine", "to": []}"#
        let broken = #"{"id": 2, "ts": "2026-09-11T16:17:40", "from": "gemini", "kind": "msg", "text": "0.3\udc80\udc93 rest", "to": []}"#
        let msgs = Bus.decodeLines(Data((good + "\n" + broken + "\n").utf8))
        XCTAssertEqual(msgs.count, 2, "the unreadable line was dropped, which is how a post becomes 'nothing to add'")
        XCTAssertEqual(msgs[1].sender, "gemini")
        XCTAssertTrue(msgs[1].text.contains("\u{FFFD}"), "the broken halves should be visible: \(msgs[1].text)")
        XCTAssertTrue(msgs[1].text.hasSuffix("rest"), "the rest of the message should survive: \(msgs[1].text)")
    }

    /// A surrogate *pair* is a real character, not damage, and must travel untouched.
    func testAPairedSurrogateIsLeftAlone() throws {
        let line = #"{"id": 3, "ts": "", "from": "a", "kind": "msg", "text": "hi 😀", "to": []}"#
        XCTAssertEqual(Bus.decodeLines(Data((line + "\n").utf8)).first?.text, "hi 😀")
    }

    func testALineNobodyCanReadStillArrivesAttributed() throws {
        let line = #"{"id": 4, "ts": "2026-09-11T16:17:40", "from": "codex", "kind": "msg", "text": "unterminated"#
        let msgs = Bus.decodeLines(Data((line + "\n").utf8))
        XCTAssertEqual(msgs.count, 1, "a line nobody can read is still a message that exists")
        XCTAssertEqual(msgs.first?.sender, "codex")
        XCTAssertTrue(msgs.first?.text.contains("could not be read") == true, msgs.first?.text ?? "")
    }

    /// A line that cannot be read is a transport failure, not something a member said. It keeps its sender and
    /// its place, and says so in its kind, so that a consumer deciding whether an answer arrived can tell the
    /// difference between the two.
    func testAnUnreadableRecordSaysSoInItsKind() {
        let line = #"{"id": 4, "ts": "2026-09-11T16:17:40", "from": "codex", "kind": "msg", "text": "unterminated"#
        let m = Bus.decodeLines(Data((line + "\n").utf8)).first
        XCTAssertEqual(m?.kind, Message.kindUnreadable, "it passes as an ordinary message from codex")
        XCTAssertEqual(m?.sender, "codex", "attribution is the part worth keeping")
        XCTAssertFalse(m?.isNote ?? true)
    }

    /// `readAll` split on newlines but decoded whatever followed the last one too. A reader looking between two
    /// writes could therefore turn a half-written post into a permanent placeholder — and when the writer
    /// finished, the real message landed in the same position with the same count, which every consumer reads
    /// as "nothing new". The answer was consumed before it existed and then never processed. A record is
    /// complete when its newline arrives; `FileTail` has always held partial lines back for the same reason.
    func testAWriteInProgressIsNotAMessageYet() throws {
        let dir = try Fixtures.tempDir("partial")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bus = Bus(directory: dir)
        let whole = #"{"id": 5, "ts": "2026-09-11T16:20:00", "from": "gemini", "kind": "msg", "text": "partial answer", "to": []}"#
        let cut = whole.range(of: "partial")!.upperBound       // id and from are already on disk; the text is not
        try String(whole[..<cut]).write(to: bus.logURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(try bus.readAll().count, 0, "a write in progress was consumed as a finished message")
        let fh = try FileHandle(forWritingTo: bus.logURL)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data((String(whole[cut...]) + "\n").utf8))
        try fh.close()
        XCTAssertEqual(try bus.readAll().map(\.text), ["partial answer"], "the finished post must arrive, as itself")
    }

    /// Two readers, one log. `readAll` repaired and attributed what it could not decode while the live tail
    /// decoded strictly and dropped it, so a damaged record could appear on reopening and never arrive live.
    /// Whatever one reader makes of a complete record, the other has to make of it too.
    func testTheLiveTailAndTheFullReadAgreeOnEveryRecord() throws {
        let dir = try Fixtures.tempDir("agree")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bus = Bus(directory: dir)
        let records = [
            #"{"id": 1, "ts": "", "from": "a", "kind": "msg", "text": "ordinary", "to": []}"#,
            #"{"id": 2, "ts": "", "from": "b", "kind": "msg", "text": "0.3\udc80\udc93 rest", "to": []}"#,
            #"{"id": 3, "ts": "", "from": "c", "kind": "msg", "text": "unterminated"#,
            #"{"id": 4, "ts": "", "from": "system", "kind": "note", "text": "a note", "to": []}"#,
        ]
        try (records.joined(separator: "\n") + "\n").write(to: bus.logURL, atomically: true, encoding: .utf8)
        let collected = TailCollector()
        let tail = BusTail(bus: bus) { collected.add($0) }
        let arrived = expectation(description: "every record reaches the tail")
        collected.expect(count: records.count, arrived)
        tail.start(replayExisting: true)
        wait(for: [arrived], timeout: 5)
        tail.stop()
        XCTAssertEqual(collected.all(), try bus.readAll(), "the two readers disagree about what is in the log")
    }

    /// The tail suppressed a batch that decoded to nothing, so a damaged record was silent unless a healthy
    /// one happened to follow it in the same read. The last post of a turn is exactly where that happens.
    func testADamagedRecordArrivesLiveWithNothingHealthyBehindIt() throws {
        let dir = try Fixtures.tempDir("damaged")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bus = Bus(directory: dir)
        // A healthy record first, and waited for: `start` opens on its own queue, so appending before the open
        // has happened would leave the tail's offset past the new bytes and this test waiting for ever.
        _ = try bus.append(sender: "codex", text: "control", members: ["codex", "gemini"])
        let collected = TailCollector()
        let tail = BusTail(bus: bus) { collected.add($0) }
        let open = expectation(description: "the tail is open")
        collected.expect(count: 1, open)
        tail.start(replayExisting: true)
        wait(for: [open], timeout: 5)

        let arrived = expectation(description: "the damaged record is signalled on its own")
        collected.expect(count: 2, arrived)
        let fh = try FileHandle(forWritingTo: bus.logURL)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data((#"{"id": 9, "ts": "", "from": "gemini", "kind": "msg", "text": "cut"# + "\n").utf8))
        try fh.close()
        tail.poll()
        wait(for: [arrived], timeout: 5)
        tail.stop()
        XCTAssertEqual(collected.all().map(\.sender), ["codex", "gemini"])
        XCTAssertTrue(collected.all().last?.isUnreadable ?? false, "the damaged record never arrived live")
    }
}

/// Gathers what a `BusTail` hands over, from whichever queue it arrives on.
private final class TailCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [Message] = []
    private var waiting: [(count: Int, exp: XCTestExpectation)] = []

    func add(_ new: [Message]) {
        lock.lock()
        messages += new
        let n = messages.count
        let ready = waiting.filter { n >= $0.count }
        waiting.removeAll { n >= $0.count }
        lock.unlock()
        ready.forEach { $0.exp.fulfill() }
    }

    func all() -> [Message] { lock.lock(); defer { lock.unlock() }; return messages }

    func expect(count: Int, _ exp: XCTestExpectation) {
        lock.lock()
        if messages.count >= count { lock.unlock(); exp.fulfill(); return }
        waiting.append((count, exp))
        lock.unlock()
    }
}
