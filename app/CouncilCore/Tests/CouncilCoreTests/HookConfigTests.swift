import XCTest
@testable import CouncilCore

final class HookConfigTests: XCTestCase {
    func testClaudeSettingsMergeKeepsUserSettingsAndAddsOneGroupPerEvent() throws {
        let user = """
        {"model": "opus", "statusLine": {"type": "command", "command": "hud"},
         "mcpServers": {"x": {"command": "x"}},
         "hooks": {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "say done"}]}],
                   "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "council event --backend claude"}]}]}}
        """.data(using: .utf8)!
        let merged = try JSONSerialization.jsonObject(with: try HookConfig.claudeSettings(userSettings: user)) as! [String: Any]
        XCTAssertEqual(merged["model"] as? String, "opus")
        XCTAssertNotNil(merged["statusLine"])
        XCTAssertNotNil(merged["mcpServers"])
        let hooks = merged["hooks"] as! [String: Any]
        let stop = hooks["Stop"] as! [[String: Any]]
        XCTAssertEqual(stop.count, 2, "user's Stop hook kept, app's added")
        XCTAssertEqual(((stop[0]["hooks"] as! [[String: Any]])[0]["command"] as? String), "say done")
        XCTAssertEqual(((stop[1]["hooks"] as! [[String: Any]])[0]["command"] as? String), "council event --backend claude")
        let pre = hooks["PreToolUse"] as! [[String: Any]]
        XCTAssertEqual(pre.count, 1, "a stale council group is replaced, not duplicated")
        for event in HookConfig.sharedHookEvents + HookConfig.claudeOnlyEvents {
            XCTAssertNotNil(hooks[event], event)
        }
        // Idempotent: merging the output again yields the same hook counts.
        let again = try JSONSerialization.jsonObject(with: try HookConfig.claudeSettings(userSettings: try HookConfig.claudeSettings(userSettings: user))) as! [String: Any]
        XCTAssertEqual(((again["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]).count, 2)
    }

    func testClaudeSettingsFromNothing() throws {
        let merged = try JSONSerialization.jsonObject(with: try HookConfig.claudeSettings(userSettings: nil, councilExecutable: "/Users/x/.local/bin/council")) as! [String: Any]
        let hooks = merged["hooks"] as! [String: Any]
        let start = hooks["SessionStart"] as! [[String: Any]]
        XCTAssertEqual(((start[0]["hooks"] as! [[String: Any]])[0]["command"] as? String), "/Users/x/.local/bin/council event --backend claude")
    }

    func testWriteClaudeSettingsIntoSessionDir() throws {
        let dir = try Fixtures.tempDir("hooks")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try HookConfig.writeClaudeSettings(sessionDir: dir, member: "claude", userSettingsURL: dir.appendingPathComponent("nonexistent.json"))
        XCTAssertEqual(url.lastPathComponent, "claude-claude.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCodexOverridesAreValidTomlInlineTables() {
        let args = HookConfig.codexOverrides()
        XCTAssertEqual(args.count, (HookConfig.sharedHookEvents.count + HookConfig.codexOnlyEvents.count) * 2)
        XCTAssertEqual(args[0], "-c")
        XCTAssertTrue(args[1].hasPrefix("hooks.SessionStart=[{hooks=[{type=\"command\",command=\"council event --backend codex\",timeout=10}]}]"), args[1])
        XCTAssertTrue(args.contains { $0.hasPrefix("hooks.Interrupt=") })
        XCTAssertFalse(args.contains { $0.hasPrefix("hooks.Notification=") }, "Notification is a Claude-only event")
    }

    func testCodexHooksJSONMergePreservesExisting() throws {
        let existing = """
        {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "afplay done.aiff"}]}]}}
        """.data(using: .utf8)!
        let merged = try JSONSerialization.jsonObject(with: try HookConfig.codexHooksJSON(existing: existing)) as! [String: Any]
        let stop = (merged["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        XCTAssertEqual(stop.count, 2)
        XCTAssertEqual(((stop[0]["hooks"] as! [[String: Any]])[0]["command"] as? String), "afplay done.aiff")
    }
}
