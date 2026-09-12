import XCTest
@testable import CouncilCore

/// Kimi Code is the one backend the CLI cannot host — `council chat` starts members as herdr agents and herdr
/// has no kimi kind — so everything about it lives in the app. Two things make it work at all: it takes hooks
/// only from the config file in its data directory, and it will not run in an untrusted folder. Both are
/// answered by giving each member a `KIMI_CODE_HOME` of its own.
final class KimiBackendTests: XCTestCase {
    private let cwd = URL(fileURLWithPath: "/private/tmp/council-work")

    private func context(dir: URL, resume: String? = nil, effort: String? = nil) -> LaunchContext {
        LaunchContext(sessionDir: dir, cwd: cwd, baseEnvironment: ["PATH": "/usr/bin"],
                      tools: ToolLocations(kimi: URL(fileURLWithPath: "/opt/kimi/bin/kimi"),
                                           council: URL(fileURLWithPath: "/opt/bin/council")),
                      kimiHome: dir.appendingPathComponent("kimi/k"), effort: effort,
                      resumeSessionId: resume, newSessionId: { "fixed-id" })
    }

    private func spec(_ chatArgs: [String] = ["--auto"], model: String = "kimi-code/k3") -> MemberLaunchSpec {
        MemberLaunchSpec(name: "k", backend: .kimi, chatArgs: chatArgs, model: model)
    }

    // MARK: the launch

    func testTheMemberGetsItsOwnDataDirectoryAndTheModelItIsConfiguredWith() throws {
        let dir = try Fixtures.tempDir("kimi")
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = try LaunchPlanner.plan(member: spec(), context: context(dir: dir, effort: "high"))
        XCTAssertEqual(plan.environment["KIMI_CODE_HOME"], dir.appendingPathComponent("kimi/k").path,
                       "without its own home, hooks could only be added to the user's global config")
        XCTAssertEqual(plan.environment["KIMI_MODEL_EFFORT"], "high")
        XCTAssertEqual(Array(plan.arguments.prefix(3)), ["--auto", "--model", "kimi-code/k3"])
        XCTAssertEqual(Array(plan.arguments.suffix(2)), ["--add-dir", dir.path],
                       "kimi is told where the chat log is, or posting would need permission")
        XCTAssertEqual(plan.environment["COUNCIL_AS"], "k")
        XCTAssertEqual(plan.environment["COUNCIL_CHAT"], dir.path)
    }

    /// A kimi session does not exist until the first message — the id arrives on the SessionStart hook — so
    /// there is nothing to pre-assign, and pretending otherwise would name a session that is never created.
    func testAFreshLaunchPreAssignsNoSessionAndAResumeNamesTheRecordedOne() throws {
        let dir = try Fixtures.tempDir("kimi")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fresh = try LaunchPlanner.plan(member: spec(), context: context(dir: dir))
        XCTAssertNil(fresh.sessionId)
        XCTAssertFalse(fresh.arguments.contains("--session"))
        XCTAssertFalse(fresh.isResume)

        let again = try LaunchPlanner.plan(member: spec(), context: context(dir: dir, resume: "session_abc"))
        XCTAssertEqual(again.arguments.suffix(2), ["--session", "session_abc"])
        XCTAssertEqual(again.sessionId, "session_abc")
        XCTAssertTrue(again.isResume)
    }

    /// `-S, --session [id]` takes an *optional* id: without one, kimi opens its interactive session picker and
    /// waits. Asked to resume a blank id, a member would therefore never start, never fire SessionStart, and be
    /// handed the briefing as if it were the picker's search box. Observed directly — `kimi --session ""` sat at
    /// "Sessions (type to search)" until it was killed — so a blank id has to mean a fresh launch.
    func testABlankSessionIdStartsFreshRatherThanOpeningThePicker() throws {
        let dir = try Fixtures.tempDir("kimi")
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = try LaunchPlanner.plan(member: spec(), context: context(dir: dir, resume: ""))
        XCTAssertFalse(plan.arguments.contains("--session"),
                       "a blank id reached kimi as --session with no value: \(plan.arguments)")
        XCTAssertFalse(plan.isResume)
        XCTAssertNil(plan.sessionId)
    }

    /// The council's efforts are low/medium/high/xhigh/default; kimi's are low/high/max. The two that have no
    /// counterpart must set nothing rather than guess, leaving kimi on its own default for the model.
    func testEffortIsMappedAndTheMiddleIsLeftToKimi() {
        XCTAssertEqual(LaunchPlanner.kimiEffort("low"), "low")
        XCTAssertEqual(LaunchPlanner.kimiEffort("high"), "high")
        XCTAssertEqual(LaunchPlanner.kimiEffort("xhigh"), "max")
        XCTAssertNil(LaunchPlanner.kimiEffort("medium"))
        XCTAssertNil(LaunchPlanner.kimiEffort("default"))
    }

    func testAMissingKimiIsReportedAsAMissingTool() {
        let dir = FileManager.default.temporaryDirectory
        var ctx = context(dir: dir)
        ctx.tools = ToolLocations(council: URL(fileURLWithPath: "/opt/bin/council"))
        XCTAssertThrowsError(try LaunchPlanner.plan(member: spec(), context: ctx)) { error in
            XCTAssertEqual(error as? LaunchError, .toolMissing(.kimi))
        }
    }

    // MARK: the home

    func testTheConfigKeepsTheUsersAndAddsTheCouncilsHooksExactlyOnce() {
        let user = "default_model = \"kimi-code/k3\"\n\n[providers.\"managed:kimi-code\"]\ntype = \"kimi\"\n"
        let once = HookConfig.kimiConfig(userConfig: user, councilExecutable: "/opt/bin/council")
        XCTAssertTrue(once.hasPrefix(user), "the user's own config must survive verbatim")
        XCTAssertTrue(once.contains("event = \"SessionStart\""))
        XCTAssertTrue(once.contains("command = \"/opt/bin/council event --backend kimi\""))
        // Relaunching regenerates from the user's config, so hooks must not accumulate.
        let twice = HookConfig.kimiConfig(userConfig: once, councilExecutable: "/opt/bin/council")
        XCTAssertEqual(twice, once, "a second launch doubled the hooks")
        XCTAssertEqual(twice.components(separatedBy: "event = \"Stop\"").count - 1, 1)
    }

    /// kimi names a remembered folder `wd_<basename>_<first 12 hex of sha256(path)>`. The digests here were
    /// computed outside this code; getting the name wrong means the folder is not trusted and every member
    /// stops on a dialog the app must never answer.
    func testTheTrustBucketIsNamedTheWayKimiNamesIt() {
        XCTAssertEqual(HookConfig.kimiTrustBucketName(for: URL(fileURLWithPath: "/private/tmp/council-work")),
                       "wd_council-work_4874f6b08e2b")
        XCTAssertEqual(HookConfig.kimiTrustBucketName(for: URL(fileURLWithPath: "/Users/you/Code/demo")),
                       "wd_demo_64ace29708a6")
    }

    func testTheHomeIsBuiltWithLinkedCredentialsAPreTrustedFolderAndTheHooks() throws {
        let dir = try Fixtures.tempDir("kimi-home")
        defer { try? FileManager.default.removeItem(at: dir) }
        let userHome = dir.appendingPathComponent("user-kimi")
        try FileManager.default.createDirectory(at: userHome.appendingPathComponent("credentials"),
                                                withIntermediateDirectories: true)
        try "default_model = \"kimi-code/k3\"\n".write(to: userHome.appendingPathComponent("config.toml"),
                                                       atomically: true, encoding: .utf8)
        try "abc".write(to: userHome.appendingPathComponent("device_id"), atomically: true, encoding: .utf8)

        let home = try HookConfig.writeKimiHome(sessionDir: dir, member: "k", cwd: cwd, userHome: userHome,
                                                councilExecutable: "/opt/bin/council")
        let fm = FileManager.default
        let config = try String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(config.contains("default_model"), "the user's config was not carried over")
        XCTAssertTrue(config.contains("--backend kimi"))

        // Linked, not copied: one credential store, in the place kimi put it.
        let credentials = home.appendingPathComponent("credentials")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: credentials.path),
                       userHome.appendingPathComponent("credentials").path)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: home.appendingPathComponent("device_id").path),
                       userHome.appendingPathComponent("device_id").path)
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent("region").path),
                       "a file the user does not have must not be linked")

        let bucket = home.appendingPathComponent("workspace-trust/wd_council-work_4874f6b08e2b")
        let trust = try JSONSerialization.jsonObject(with: Data(contentsOf: bucket)) as? [String: Any]
        XCTAssertEqual(trust?["root"] as? String, cwd.path, "the folder would not be recognised as trusted")

        // A relaunch replaces the link rather than failing on it.
        XCTAssertNoThrow(try HookConfig.writeKimiHome(sessionDir: dir, member: "k", cwd: cwd, userHome: userHome,
                                                      councilExecutable: "/opt/bin/council"))
    }

    // MARK: what kimi says back

    /// Captured from a real launch: kimi speaks the Claude Code hook contract, so it is read the same way.
    func testKimisOwnHookPayloadsNormaliseLikeClaudes() throws {
        let start = try event(#"{"hook_event_name":"SessionStart","session_id":"session_eb9da0a3","cwd":"/w","client_type":"kimi_code_cli","source":"startup","model":"kimi-code/k3","profile":"agent"}"#, hook: "SessionStart")
        XCTAssertEqual(EventNormalizer.normalize(start), [.started(sessionId: "session_eb9da0a3", reason: "startup")])

        let stop = try event(#"{"hook_event_name":"Stop","session_id":"session_eb9da0a3","cwd":"/w","client_type":"kimi_code_cli","session_title":"Reply with exactly: ok","stop_hook_active":false}"#, hook: "Stop")
        XCTAssertEqual(EventNormalizer.normalize(stop), [.turnEnded(lastMessage: nil)])
    }

    private func event(_ payload: String, hook: String) throws -> RawEvent {
        let line = #"{"ts": "2026-09-12T00:00:00", "member": "k", "backend": "kimi", "hook": "HOOK", "payload": PAYLOAD}"#
            .replacingOccurrences(of: "HOOK", with: hook)
            .replacingOccurrences(of: "PAYLOAD", with: payload)
        return try XCTUnwrap(RawEvent.decode(line: line))
    }

    /// Without its trust bucket kimi opens on a menu — and a member sitting on one is exactly what the app
    /// must report rather than answer.
    func testTheTrustDialogIsRecognisedRatherThanAnswered() {
        let screen = ["", " Trust this folder?", " ↑↓ navigate · Enter select · Esc exit", "",
                      "  /private/tmp/council-work", "",
                      "  Project-level MCP servers are disabled until you explicitly choose Trust.", "",
                      "  ❯ Trust this folder", "    Don't trust"]
        let dialog = ScreenHeuristics.blockingDialog(in: screen)
        XCTAssertEqual(dialog?.reason, "folder trust dialog")
        XCTAssertNotNil(dialog?.hint)
    }
}
