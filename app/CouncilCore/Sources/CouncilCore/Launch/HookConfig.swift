import Foundation
import CryptoKit

/// Builds the per-launch hook wiring for each backend. The hook command is the same for every member:
/// `council event --backend <x>`; identity comes from `COUNCIL_CHAT` / `COUNCIL_AS` in the member's environment.
public enum HookConfig {
    public static let eventCommandBase = "council event"

    /// Hook events we subscribe to on Claude Code and Codex (same names on both CLIs).
    public static let sharedHookEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd", "PermissionRequest"]
    public static let claudeOnlyEvents = ["PostToolUseFailure", "StopFailure", "Notification"]
    public static let codexOnlyEvents = ["Interrupt"]

    public static func command(backend: String, councilExecutable: String = "council") -> String {
        "\(councilExecutable) event --backend \(backend)"
    }

    // MARK: Claude Code

    /// The `--settings` file for a Claude Code member: the user's own settings with the app's hooks appended
    /// to each event array (whether the flag merges or replaces user settings, behaviour is unchanged).
    /// Existing `council event` entries are removed first so relaunches never double-fire.
    public static func claudeSettings(userSettings: Data?, councilExecutable: String = "council") throws -> Data {
        var root: [String: Any] = [:]
        if let d = userSettings, let parsed = try JSONSerialization.jsonObject(with: d) as? [String: Any] { root = parsed }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let cmd = command(backend: "claude", councilExecutable: councilExecutable)
        for event in sharedHookEvents + claudeOnlyEvents {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isCouncilGroup($0) }
            groups.append(["matcher": "", "hooks": [["type": "command", "command": cmd, "timeout": 10]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func isCouncilGroup(_ group: [String: Any]) -> Bool {
        guard let hs = group["hooks"] as? [[String: Any]] else { return false }
        return hs.contains { ($0["command"] as? String)?.contains("council event") == true }
    }

    /// Writes the settings file into `<sessionDir>/hooks/claude-<member>.json` and returns its path.
    public static func writeClaudeSettings(sessionDir: URL, member: String,
                                           userSettingsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json"),
                                           councilExecutable: String = "council") throws -> URL {
        let dir = sessionDir.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try claudeSettings(userSettings: try? Data(contentsOf: userSettingsURL), councilExecutable: councilExecutable)
        let url = dir.appendingPathComponent("claude-\(member).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Kimi Code

    /// Kimi reads hooks only from `config.toml` in its data directory and has no per-launch flag for them, so
    /// the app does not edit the user's: `KIMI_CODE_HOME` points each member at a directory of its own.
    /// Every event kimi and Claude Code share — the payloads are the same shape, down to `hook_event_name`,
    /// `session_id` and `cwd`.
    public static let kimiEvents = sharedHookEvents + ["Notification", "PostToolUseFailure", "StopFailure", "Interrupt"]

    /// The member's `config.toml`: the user's own, with the council's hooks appended. It is regenerated from
    /// theirs at every launch, so a model or provider they add tomorrow is picked up and this copy cannot
    /// drift. A previous council block is dropped first, so relaunching never doubles the hooks.
    public static func kimiConfig(userConfig: String?, councilExecutable: String = "council") -> String {
        var base = userConfig ?? ""
        if let marker = base.range(of: kimiBlockMarker) { base = String(base[..<marker.lowerBound]) }
        let cmd = command(backend: "kimi", councilExecutable: councilExecutable)
        var out = base.hasSuffix("\n") || base.isEmpty ? base : base + "\n"
        out += kimiBlockMarker
        for event in kimiEvents {
            out += "\n[[hooks]]\nevent = \"\(event)\"\ncommand = \"\(cmd)\"\ntimeout = \(hookTimeout)\n"
        }
        return out
    }

    static let kimiBlockMarker = "\n# --- council: hooks for this member, regenerated at every launch ---\n"
    static let hookTimeout = 10

    /// kimi remembers a trusted folder as a file named `wd_<basename>_<first 12 hex of sha256(path)>`.
    /// Writing it ahead of the launch is what keeps the member off the "Trust this folder?" dialog — which
    /// the app must never answer on the user's behalf, and which would otherwise hold every new chat folder.
    public static func kimiTrustBucketName(for cwd: URL) -> String {
        let path = cwd.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "wd_\(cwd.lastPathComponent)_\(digest.prefix(12))"
    }

    /// Builds `<sessionDir>/kimi/<member>/` and returns it for `KIMI_CODE_HOME`. Credentials, the device id
    /// and the region are **linked** to the user's own: one copy of a secret, in the place kimi put it.
    /// Sessions, logs and caches stay inside the council's directory, so a chat can be thrown away whole.
    @discardableResult
    public static func writeKimiHome(sessionDir: URL, member: String, cwd: URL,
                                     userHome: URL = FileManager.default.homeDirectoryForCurrentUser
                                         .appendingPathComponent(".kimi-code"),
                                     councilExecutable: String = "council") throws -> URL {
        let fm = FileManager.default
        let home = sessionDir.appendingPathComponent("kimi/\(member)", isDirectory: true)
        try fm.createDirectory(at: home.appendingPathComponent("workspace-trust"), withIntermediateDirectories: true)
        for name in ["credentials", "device_id", "region"] {
            let source = userHome.appendingPathComponent(name)
            let link = home.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            if (try? link.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
                || fm.fileExists(atPath: link.path) { try? fm.removeItem(at: link) }
            try fm.createSymbolicLink(at: link, withDestinationURL: source)
        }
        let user = try? String(contentsOf: userHome.appendingPathComponent("config.toml"), encoding: .utf8)
        try kimiConfig(userConfig: user, councilExecutable: councilExecutable)
            .write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let trust = ["root": cwd.standardizedFileURL.path, "trustedAt": Int(Date().timeIntervalSince1970 * 1000)] as [String: Any]
        try JSONSerialization.data(withJSONObject: trust, options: [.sortedKeys])
            .write(to: home.appendingPathComponent("workspace-trust/\(kimiTrustBucketName(for: cwd))"), options: .atomic)
        return home
    }

    // MARK: Codex

    /// `-c` overrides that define the hooks for one launch, one per event, as TOML arrays of inline tables.
    public static func codexOverrides(councilExecutable: String = "council") -> [String] {
        let cmd = command(backend: "codex", councilExecutable: councilExecutable)
        var args: [String] = []
        for event in sharedHookEvents + codexOnlyEvents {
            args += ["-c", "hooks.\(event)=[{hooks=[{type=\"command\",command=\"\(cmd)\",timeout=10}]}]"]
        }
        return args
    }

    /// Fallback when `-c` cannot carry hooks: the block to merge into `~/.codex/hooks.json`. The command is
    /// a no-op outside council because `council event` exits quietly without `COUNCIL_CHAT`.
    public static func codexHooksJSON(existing: Data?, councilExecutable: String = "council") throws -> Data {
        var root: [String: Any] = [:]
        if let d = existing, let parsed = try JSONSerialization.jsonObject(with: d) as? [String: Any] { root = parsed }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let cmd = command(backend: "codex", councilExecutable: councilExecutable)
        for event in sharedHookEvents + codexOnlyEvents {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isCouncilGroup($0) }
            groups.append(["hooks": [["type": "command", "command": cmd, "timeout": 10]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: pi

    public static let piExtensionFileName = "pi-council-events.ts"
}
