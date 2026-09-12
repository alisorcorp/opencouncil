import XCTest
@testable import CouncilCore

/// Drives the real `council` CLI, when installed, to prove the helper contract the app relies on.
final class CLIEventInteropTests: XCTestCase {
    private func run(_ cli: URL, _ args: [String], env: [String: String], stdin: String? = nil) throws -> (Int32, String, String) {
        let p = Process()
        p.executableURL = cli
        p.arguments = args
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        if let stdin {
            let inPipe = Pipe()
            p.standardInput = inPipe
            try p.run()
            inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
            try inPipe.fileHandleForWriting.close()
        } else {
            p.standardInput = FileHandle.nullDevice
            try p.run()
        }
        p.waitUntilExit()
        return (p.terminationStatus,
                String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    private func makeChat() throws -> URL {
        let dir = try Fixtures.tempDir("cli-interop")
        let config = """
        {"created": "2026-09-10T12:00:00", "cwd": "/tmp", "title": "t", "order": ["claude", "codex"],
         "members": {"claude": {"label": "Claude"}, "codex": {"label": "Codex"}}, "budget": 12, "effort": "medium"}
        """
        try config.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        return dir
    }

    func testEventAppendsHookPayloadAndStaysSilent() throws {
        guard let cli = Fixtures.councilCLI else { throw XCTSkip("council CLI not installed") }
        let dir = try makeChat()
        defer { try? FileManager.default.removeItem(at: dir) }
        var env = ShellEnvironment.resolve().memberBaseEnvironment()
        env["COUNCIL_CHAT"] = dir.path
        env["COUNCIL_AS"] = "claude"
        let payload = #"{"session_id": "abc", "hook_event_name": "PreToolUse", "tool_name": "Read", "tool_input": {"file_path": "/x/chat.py"}}"#
        let (code, out, err) = try run(cli, ["event", "--backend", "claude"], env: env, stdin: payload)
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, "", "hook stdout must stay empty")
        XCTAssertEqual(err, "")
        let lines = try String(contentsOf: dir.appendingPathComponent("events.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let raw = try XCTUnwrap(RawEvent.decode(line: String(lines[0])))
        XCTAssertEqual(raw.member, "claude")
        XCTAssertEqual(raw.backend, "claude")
        XCTAssertEqual(raw.hook, "PreToolUse")
        XCTAssertEqual(EventNormalizer.normalize(raw), [.toolStarted(tool: "Read", activity: "reading chat.py")])

        // Garbage on stdin and a missing COUNCIL_CHAT are both quiet no-ops.
        let (c2, o2, _) = try run(cli, ["event", "--backend", "codex", "--hook", "Stop"], env: env, stdin: "not json")
        XCTAssertEqual(c2, 0); XCTAssertEqual(o2, "")
        var noChat = env; noChat.removeValue(forKey: "COUNCIL_CHAT")
        let (c3, o3, _) = try run(cli, ["event", "--backend", "codex"], env: noChat, stdin: "{}")
        XCTAssertEqual(c3, 0); XCTAssertEqual(o3, "")
        let all = try String(contentsOf: dir.appendingPathComponent("events.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(RawEvent.decode(line: String(all[1]))?.hook, "Stop")
    }

    func testPostRefusesToImpersonateWhenPinned() throws {
        guard let cli = Fixtures.councilCLI else { throw XCTSkip("council CLI not installed") }
        let dir = try makeChat()
        defer { try? FileManager.default.removeItem(at: dir) }
        var env = ShellEnvironment.resolve().memberBaseEnvironment()
        env["COUNCIL_CHAT"] = dir.path
        env["COUNCIL_AS"] = "codex"
        let (ok, _, _) = try run(cli, ["post", "--as", "codex", "hello"], env: env)
        XCTAssertEqual(ok, 0)
        let (asOther, _, err1) = try run(cli, ["post", "--as", "claude", "hi"], env: env)
        XCTAssertNotEqual(asOther, 0); XCTAssertTrue(err1.contains("posts as 'codex'"), err1)
        let (asUser, _, err2) = try run(cli, ["post", "--as", "user", "hi"], env: env)
        XCTAssertNotEqual(asUser, 0); XCTAssertTrue(err2.contains("posts as 'codex'"), err2)
        let msgs = try Bus(directory: dir).readAll()
        XCTAssertEqual(msgs.map(\.sender), ["codex"])
        // Without the pin (a human at a terminal), any member name still works.
        env.removeValue(forKey: "COUNCIL_AS")
        let (free, _, _) = try run(cli, ["post", "--as", "claude", "hi"], env: env)
        XCTAssertEqual(free, 0)
    }
}
