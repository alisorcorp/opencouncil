import XCTest
@testable import CouncilCore

final class EventNormalizerTests: XCTestCase {
    private func events(_ fixture: String) throws -> [(RawEvent, [MemberEvent])] {
        let url = Fixtures.root.appendingPathComponent("hooks/\(fixture)")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").map { line in
            let raw = RawEvent.decode(line: String(line))!
            return (raw, EventNormalizer.normalize(raw))
        }
    }

    func testClaudeHooks() throws {
        let all = try events("claude-events.jsonl").map(\.1)
        XCTAssertEqual(all[0], [.started(sessionId: "4f2c1c1e-1111-4bd7-9a7e-000000000001", reason: "startup")])
        XCTAssertEqual(all[1], [.turnStarted])
        XCTAssertEqual(all[2], [.toolStarted(tool: "Read", activity: "reading chat.py")])
        XCTAssertEqual(all[3], [.toolEnded(tool: "Read", failed: false)])
        XCTAssertEqual(all[4], [.toolStarted(tool: "Bash", activity: "ran council post --as claude \"hello from th…")])
        XCTAssertEqual(all[5], [.blocked(reason: "permission prompt")])
        XCTAssertEqual(all[6], [], "idle_prompt is not a state change")
        XCTAssertEqual(all[7], [.turnEnded(lastMessage: "Posted.")])
        XCTAssertEqual(all[8], [], "unknown hooks are ignored")
        XCTAssertEqual(all[9], [.ended(reason: "exit")])
    }

    func testCodexHooks() throws {
        let all = try events("codex-events.jsonl").map(\.1)
        XCTAssertEqual(all[0], [.started(sessionId: "019a-codex-thread", reason: "startup")])
        XCTAssertEqual(all[1], [.turnStarted])
        XCTAssertEqual(all[2], [.toolStarted(tool: "shell", activity: "ran bash -lc pytest -q")])
        XCTAssertEqual(all[3], [.blocked(reason: "approval requested for shell")])
        XCTAssertEqual(all[4], [.turnEnded(lastMessage: nil)])
        XCTAssertEqual(all[5], [.turnEnded(lastMessage: nil)], "an interrupt ends the turn")
    }

    /// Captured from the round that failed on 2026-09-12: kimi answered round 1, then its provider rejected
    /// the round-2 request outright. Kimi Code follows the Claude Code hook contract except on this one hook,
    /// where the reason lives under `error_message` — and a reason the app cannot read is a reason the
    /// maintainer only finds by opening events.jsonl.
    func testKimiHooks() throws {
        let all = try events("kimi-events.jsonl").map(\.1)
        XCTAssertEqual(all[0], [.started(sessionId: "session_3179d2e5-0000-4000-8000-000000000001", reason: "startup")])
        XCTAssertEqual(all[1], [.turnStarted])
        XCTAssertEqual(all[2], [.toolStarted(tool: "Bash", activity: "ran council post --as kimi - <<\'COUNCIL\' **…")])
        XCTAssertEqual(all[3], [.toolEnded(tool: "Bash", failed: false)])
        XCTAssertEqual(all[4], [.turnEnded(lastMessage: nil)], "kimi's Stop carries no last_assistant_message")
        XCTAssertEqual(all[5], [.turnStarted])
        XCTAssertEqual(all[6], [.failed(message: "400 The request was rejected because it was considered high risk")],
                       "the provider's own words, not \"turn failed\"")
    }

    func testPiExtensionEvents() throws {
        let all = try events("pi-events.jsonl").map(\.1)
        XCTAssertEqual(all[0], [.started(sessionId: "a1b2c3d4-0000-4000-8000-000000000000", reason: "startup")])
        XCTAssertEqual(all[1], [], "raw input is not a state change")
        XCTAssertEqual(all[2], [.turnStarted])
        XCTAssertEqual(all[3], [.toolStarted(tool: "bash", activity: "ran council log --tail 5")])
        XCTAssertEqual(all[4], [.toolEnded(tool: "bash", failed: false)])
        XCTAssertEqual(all[5], [.turnEnded(lastMessage: "Posted my reply.")])
        XCTAssertEqual(all[6], [.blocked(reason: "trust prompt")])
    }

    func testUnknownBackendAndGarbage() {
        XCTAssertNil(RawEvent.decode(line: "not json"))
        let raw = RawEvent(ts: "", member: "x", backend: "carrier-pigeon", hook: "Stop", payload: .object([:]))
        XCTAssertEqual(EventNormalizer.normalize(raw), [])
    }

    func testActivityDescriptions() {
        XCTAssertEqual(ActivityDescriber.describe(tool: "Edit", input: .object(["file_path": .string("/a/b/c.swift")])), "editing c.swift")
        XCTAssertEqual(ActivityDescriber.describe(tool: "Grep", input: nil), "searching the project")
        XCTAssertEqual(ActivityDescriber.describe(tool: "WebFetch", input: nil), "browsing the web")
        XCTAssertEqual(ActivityDescriber.describe(tool: "mcp__foo__bar", input: nil), "using mcp__foo__bar")
        XCTAssertEqual(ActivityDescriber.describe(tool: "Bash", input: .object(["command": .string("ls   -la\n  /tmp")])), "ran ls -la /tmp")
    }

    func testEventTailDeliversInOrder() throws {
        let dir = try Fixtures.tempDir("events")
        defer { try? FileManager.default.removeItem(at: dir) }
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var got: [(String, MemberEvent)] = []
            func add(_ m: String, _ e: [MemberEvent]) { lock.lock(); got += e.map { (m, $0) }; lock.unlock() }
            func count() -> Int { lock.lock(); defer { lock.unlock() }; return got.count }
            func all() -> [(String, MemberEvent)] { lock.lock(); defer { lock.unlock() }; return got }
        }
        let box = Box()
        let tail = EventTail(directory: dir) { m, _, e in box.add(m, e) }
        defer { tail.stop() }
        tail.start()
        Thread.sleep(forTimeInterval: 0.2)
        let src = try String(contentsOf: Fixtures.root.appendingPathComponent("hooks/claude-events.jsonl"), encoding: .utf8)
        let fh = try FileHandle(forWritingTo: dir.appendingPathComponent("events.jsonl"))
        try fh.seekToEnd(); try fh.write(contentsOf: src.data(using: .utf8)!); try fh.close()
        let deadline = Date().addingTimeInterval(3)
        while box.count() < 8 && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let all = box.all()
        XCTAssertEqual(all.count, 8)
        XCTAssertEqual(all.first?.0, "claude")
        XCTAssertEqual(all.first?.1, .started(sessionId: "4f2c1c1e-1111-4bd7-9a7e-000000000001", reason: "startup"))
        XCTAssertEqual(all.last?.1, .ended(reason: "exit"))
    }
}
