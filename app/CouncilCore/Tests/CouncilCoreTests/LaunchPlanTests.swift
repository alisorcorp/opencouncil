import XCTest
@testable import CouncilCore

final class LaunchPlanTests: XCTestCase {
    private let tools = ToolLocations(claude: URL(fileURLWithPath: "/opt/bin/claude"), codex: URL(fileURLWithPath: "/opt/bin/codex"),
                                      pi: URL(fileURLWithPath: "/opt/bin/pi"), kimi: URL(fileURLWithPath: "/opt/bin/kimi"),
                                      council: URL(fileURLWithPath: "/Users/x/.local/bin/council"))

    private func context(resume: String? = nil) -> LaunchContext {
        LaunchContext(sessionDir: URL(fileURLWithPath: "/data/chats/2026-09-10_113600_router"),
                      cwd: URL(fileURLWithPath: "/Users/x/proj"),
                      baseEnvironment: ["PATH": "/opt/bin:/usr/bin", "HOME": "/Users/x", "ANTHROPIC_API_KEY": "sk-leak", "HERDR_ENV": "1", "LANG": ""],
                      tools: tools,
                      claudeSettingsFile: URL(fileURLWithPath: "/data/chats/2026-09-10_113600_router/hooks/claude-claude.json"),
                      piExtension: URL(fileURLWithPath: "/Applications/Council.app/Contents/Resources/Resources/pi-council-events.ts"),
                      resumeSessionId: resume,
                      newSessionId: { "11111111-2222-4333-8444-555555555555" })
    }

    private func specs() throws -> [String: MemberLaunchSpec] {
        let cfg = try ChatConfig.load(from: Fixtures.chatDir)
        var out: [String: MemberLaunchSpec] = [:]
        for (name, m) in cfg.members { out[name] = MemberLaunchSpec(name: name, member: m) }
        return out
    }

    func testClaudePlan() throws {
        let plan = try LaunchPlanner.plan(member: try XCTUnwrap(specs()["claude"]), context: context())
        XCTAssertEqual(plan.executable.path, "/opt/bin/claude")
        XCTAssertEqual(plan.arguments, ["--dangerously-skip-permissions", "--effort", "medium",
                                        "--settings", "/data/chats/2026-09-10_113600_router/hooks/claude-claude.json",
                                        "--add-dir", "/data/chats/2026-09-10_113600_router",
                                        "--allowedTools", "Bash(council *),Bash(council:*)",
                                        "--session-id", "11111111-2222-4333-8444-555555555555"])
        XCTAssertEqual(plan.sessionId, "11111111-2222-4333-8444-555555555555")
        XCTAssertFalse(plan.isResume)
        XCTAssertEqual(plan.environment["COUNCIL_CHAT"], "/data/chats/2026-09-10_113600_router")
        XCTAssertEqual(plan.environment["COUNCIL_AS"], "claude")
        XCTAssertEqual(plan.environment["CLAUDE_CODE_FORCE_SYNC_OUTPUT"], "1")
        XCTAssertEqual(plan.environment["TERM"], "xterm-256color")
        XCTAssertEqual(plan.environment["LANG"], "en_US.UTF-8")
        XCTAssertNil(plan.environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(plan.environment["HERDR_ENV"])
        XCTAssertEqual(plan.currentDirectory.path, "/Users/x/proj")
        XCTAssertTrue(plan.environmentList.contains("COUNCIL_AS=claude"))
    }

    func testClaudeResume() throws {
        let plan = try LaunchPlanner.plan(member: try XCTUnwrap(specs()["claude"]), context: context(resume: "abc-123"))
        XCTAssertEqual(Array(plan.arguments.suffix(2)), ["--resume", "abc-123"])
        XCTAssertFalse(plan.arguments.contains("--session-id"))
        XCTAssertEqual(plan.sessionId, "abc-123")
        XCTAssertTrue(plan.isResume)
    }

    func testCodexPlan() throws {
        let plan = try LaunchPlanner.plan(member: try XCTUnwrap(specs()["codex"]), context: context())
        XCTAssertEqual(plan.executable.path, "/opt/bin/codex")
        XCTAssertEqual(Array(plan.arguments.prefix(3)), ["--yolo", "-c", "model_reasoning_effort=\"medium\""])
        XCTAssertTrue(plan.arguments.contains("hooks.Stop=[{hooks=[{type=\"command\",command=\"/Users/x/.local/bin/council event --backend codex\",timeout=10}]}]"))
        XCTAssertTrue(plan.arguments.contains("projects.\"/Users/x/proj\".trust_level=\"trusted\""))
        XCTAssertTrue(plan.arguments.contains("check_for_update_on_startup=false"))
        XCTAssertTrue(plan.arguments.contains("sandbox_workspace_write.writable_roots=[\"/data/chats/2026-09-10_113600_router\"]"))
        XCTAssertEqual(plan.arguments.last, "--dangerously-bypass-hook-trust", "app-authored hooks must not raise Codex's trust dialog")
        XCTAssertNil(plan.sessionId, "Codex reports its id via SessionStart")
        XCTAssertEqual(plan.environment["COUNCIL_AS"], "codex")
        XCTAssertNil(plan.environment["CLAUDE_CODE_FORCE_SYNC_OUTPUT"])
    }

    func testCodexResume() throws {
        let plan = try LaunchPlanner.plan(member: try XCTUnwrap(specs()["codex"]), context: context(resume: "thread-9"))
        XCTAssertEqual(Array(plan.arguments.prefix(3)), ["resume", "thread-9", "--yolo"])
        XCTAssertEqual(plan.sessionId, "thread-9")
    }

    /// A member answers by running `council post`, which appends to the chat's log — and the chat directory
    /// is not the folder the member works in. Nothing had to say so while every member started with its CLI's
    /// stop-asking flag. Now that they ask, a backend never told about this directory would stop on a
    /// permission prompt before it could say one word, on every reply, for everyone.
    func testEveryAskingBackendIsToldAboutTheChatDirectory() throws {
        let chat = "/data/chats/2026-09-10_113600_router"
        for backend in [CouncilConfig.Backend.claude, .codex, .kimi] {
            let spec = MemberLaunchSpec(name: "m", backend: backend, chatArgs: [])
            let plan = try LaunchPlanner.plan(member: spec, context: context())
            XCTAssertTrue(plan.arguments.joined(separator: " ").contains(chat),
                          "\(backend.rawValue) is never told the chat directory, so posting would need permission")
        }
    }

    func testPiPlanDropsNoSessionAndAddsExtension() throws {
        let plan = try LaunchPlanner.plan(member: try XCTUnwrap(specs()["deepseek"]), context: context())
        XCTAssertEqual(plan.executable.path, "/opt/bin/pi")
        XCTAssertFalse(plan.arguments.contains("--no-session"))
        XCTAssertEqual(Array(plan.arguments.prefix(4)), ["--provider", "openrouter", "--model", "deepseek/deepseek-v4.1-flash"])
        XCTAssertTrue(plan.arguments.contains("--offline"))
        XCTAssertTrue(plan.arguments.contains("--thinking"))
        XCTAssertEqual(Array(plan.arguments.suffix(4)), ["--session-id", "11111111-2222-4333-8444-555555555555",
                                                          "-e", "/Applications/Council.app/Contents/Resources/Resources/pi-council-events.ts"])
        XCTAssertEqual(plan.sessionId, "11111111-2222-4333-8444-555555555555")
    }

    func testPiResumeUsesSameFlag() throws {
        let plan = try LaunchPlanner.plan(member: try XCTUnwrap(specs()["deepseek"]), context: context(resume: "pi-sess"))
        XCTAssertTrue(plan.arguments.contains("pi-sess"))
        XCTAssertEqual(plan.arguments.filter { $0 == "--session-id" }.count, 1)
    }

    func testMissingToolAndUnsupportedBackend() throws {
        var ctx = context()
        ctx.tools.codex = nil
        XCTAssertThrowsError(try LaunchPlanner.plan(member: try XCTUnwrap(specs()["codex"]), context: ctx)) {
            XCTAssertEqual($0 as? LaunchError, .toolMissing(.codex))
        }
        XCTAssertNil(MemberLaunchSpec(name: "gemma", member: ChatConfig.Member(backend: "openai", label: "Gemma")))
        XCTAssertNil(MemberLaunchSpec(name: "x", member: ChatConfig.Member(backend: nil)))
    }

    /// An empty session id is not a session. It reaches here when a hook reported a blank `session_id` and the
    /// app wrote it down, and every CLI reads the empty value differently: Claude Code and Codex are handed a
    /// name nothing answers to, and kimi — whose flag takes an optional id — drops into its interactive session
    /// picker and waits there forever, so the member never reports ready and the briefing is typed into a search
    /// box. Observed: `kimi --session ""` sat at "Sessions (type to search)" until it was killed. Treat a blank
    /// id as no id, for every backend, and let the member start fresh.
    func testAnEmptySessionIdIsNotAResume() throws {
        let backends: [CouncilConfig.Backend] = [.claude, .codex, .pi]
        for backend in backends {
            let name = backend.rawValue
            let spec = MemberLaunchSpec(name: name, backend: backend, chatArgs: [])
            let plan = try LaunchPlanner.plan(member: spec, context: context(resume: ""))
            XCTAssertFalse(plan.isResume, "\(name) treated a blank session id as a resume")
            XCTAssertFalse(plan.arguments.contains(""), "\(name) passed an empty argument: \(plan.arguments)")
            XCTAssertNotEqual(plan.sessionId, "", "\(name) recorded an empty session id")
        }
    }
}
