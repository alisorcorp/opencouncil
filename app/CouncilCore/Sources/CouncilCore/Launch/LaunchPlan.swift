import Foundation

/// Absolute paths of the CLIs the app drives, resolved once from the user's shell PATH.
public struct ToolLocations: Sendable, Equatable {
    public var claude: URL?
    public var codex: URL?
    public var pi: URL?
    public var kimi: URL?
    public var council: URL?

    public init(claude: URL? = nil, codex: URL? = nil, pi: URL? = nil, kimi: URL? = nil, council: URL? = nil) {
        self.claude = claude; self.codex = codex; self.pi = pi; self.kimi = kimi; self.council = council
    }

    public init(shell: ShellEnvironment) {
        // kimi installs to ~/.kimi-code/bin and puts itself on PATH from `.zshrc`, which only an *interactive*
        // shell reads — `ShellEnvironment` tries an interactive login shell first for exactly this reason.
        self.init(claude: shell.which("claude"), codex: shell.which("codex"), pi: shell.which("pi"),
                  kimi: shell.which("kimi"), council: shell.which("council"))
    }

    public func executable(for backend: CouncilConfig.Backend) -> URL? {
        switch backend {
        case .claude: return claude
        case .codex: return codex
        case .pi: return pi
        case .kimi: return kimi
        case .openai: return nil
        }
    }

    /// Path used in hook commands. Falls back to the bare name so a developer PATH still works.
    public var councilCommand: String { council?.path ?? "council" }
}

/// What the app needs to know about one member to launch it: the chat's config.json entry.
public struct MemberLaunchSpec: Sendable, Equatable {
    public var name: String
    public var backend: CouncilConfig.Backend
    public var chatArgs: [String]
    /// The model id from `council.toml`, for backends the app names it on the command line (kimi). Empty
    /// means "whatever the CLI is configured to use".
    public var model: String

    public init(name: String, backend: CouncilConfig.Backend, chatArgs: [String], model: String = "") {
        self.name = name; self.backend = backend; self.chatArgs = chatArgs; self.model = model
    }

    /// From a chat's `config.json` member entry, as chat.py `build_members` wrote it (`chat_args` already
    /// include the effort flags and, for pi, `--provider/--model`).
    public init?(name: String, member: ChatConfig.Member) {
        guard let b = member.backend.flatMap(CouncilConfig.Backend.init(rawValue:)), b.isTerminalBackend else { return nil }
        self.init(name: name, backend: b, chatArgs: member.chatArgs ?? [], model: member.model ?? "")
    }
}

public struct LaunchContext: Sendable {
    public var sessionDir: URL
    public var cwd: URL
    public var baseEnvironment: [String: String]
    public var tools: ToolLocations
    /// Claude Code: the merged settings file with the app's hooks (see `HookConfig.writeClaudeSettings`).
    public var claudeSettingsFile: URL?
    /// pi: the bundled extension that reports events.
    public var piExtension: URL?
    /// kimi: the member's own `KIMI_CODE_HOME` (see `HookConfig.writeKimiHome`). kimi reads hooks only from
    /// its global config file, so each member is given a home of its own rather than editing the user's.
    public var kimiHome: URL?
    /// The chat's reasoning effort. chat.py bakes effort into `chat_args` for the backends that take a flag;
    /// kimi takes an environment variable instead, so the value has to reach the launch.
    public var effort: String?
    /// Resume this CLI session instead of starting a new one.
    public var resumeSessionId: String?
    /// Injected for tests; the app passes nothing and gets a fresh UUID.
    public var newSessionId: @Sendable () -> String

    public init(sessionDir: URL, cwd: URL, baseEnvironment: [String: String], tools: ToolLocations,
                claudeSettingsFile: URL? = nil, piExtension: URL? = nil, kimiHome: URL? = nil,
                effort: String? = nil, resumeSessionId: String? = nil,
                newSessionId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
        self.sessionDir = sessionDir; self.cwd = cwd; self.baseEnvironment = baseEnvironment; self.tools = tools
        self.claudeSettingsFile = claudeSettingsFile; self.piExtension = piExtension
        self.kimiHome = kimiHome; self.effort = effort
        self.resumeSessionId = resumeSessionId; self.newSessionId = newSessionId
    }
}

/// Everything needed to spawn one member on a pty.
public struct LaunchPlan: Sendable, Equatable {
    public var backend: CouncilConfig.Backend
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: URL
    /// The CLI session id this launch uses (pre-assigned for Claude Code and pi; Codex reports its own).
    public var sessionId: String?
    public var isResume: Bool

    public init(backend: CouncilConfig.Backend, executable: URL, arguments: [String], environment: [String: String],
                currentDirectory: URL, sessionId: String? = nil, isResume: Bool = false) {
        self.backend = backend; self.executable = executable; self.arguments = arguments; self.environment = environment
        self.currentDirectory = currentDirectory; self.sessionId = sessionId; self.isResume = isResume
    }

    /// Environment as SwiftTerm / posix_spawn want it.
    public var environmentList: [String] { environment.keys.sorted().map { "\($0)=\(environment[$0]!)" } }
}

public enum LaunchError: Error, LocalizedError, Equatable {
    case toolMissing(CouncilConfig.Backend)
    case unsupportedBackend(String)

    public var errorDescription: String? {
        switch self {
        case .toolMissing(let b): return "\(b.rawValue) is not installed or not on your PATH"
        case .unsupportedBackend(let b): return "\(b) members cannot run in the app"
        }
    }
}

/// Builds `LaunchPlan`s. Mirrors what herdr ran (chat.py `build_members` / `start_member`) plus the hook,
/// session, trust and terminal flags the app needs. Pure and fully unit-tested.
public enum LaunchPlanner {
    public static let hookTimeoutSeconds = 10

    /// The council's efforts are low/medium/high/xhigh/default; kimi's k3 takes low/high/max. `medium` and
    /// `default` set nothing, which leaves kimi on the default effort for whichever model is configured.
    public static func kimiEffort(_ effort: String) -> String? {
        switch effort {
        case "low": return "low"
        case "high": return "high"
        case "xhigh": return "max"
        default: return nil
        }
    }

    public static func plan(member: MemberLaunchSpec, context: LaunchContext) throws -> LaunchPlan {
        guard let exe = context.tools.executable(for: member.backend) else { throw LaunchError.toolMissing(member.backend) }
        var env = context.baseEnvironment
        env["COUNCIL_CHAT"] = context.sessionDir.path
        env["COUNCIL_AS"] = member.name
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil || env["LANG"]?.isEmpty == true { env["LANG"] = "en_US.UTF-8" }
        for k in env.keys where k.hasPrefix("HERDR_") { env.removeValue(forKey: k) }
        env.removeValue(forKey: "ANTHROPIC_API_KEY")

        var args: [String] = []
        // A blank id is not a session. It reaches here when a hook reported an empty `session_id` and the app
        // wrote it down, and no CLI reads it as "start fresh": Claude Code and Codex are handed a name nothing
        // answers to, and kimi — whose `--session` takes an *optional* id — opens its interactive session picker
        // and waits there, so the member never starts and the briefing is typed into a search box.
        let resumeId = context.resumeSessionId.flatMap { $0.isEmpty ? nil : $0 }
        var sessionId: String? = resumeId
        let isResume = resumeId != nil
        switch member.backend {
        case .claude:
            env["CLAUDE_CODE_FORCE_SYNC_OUTPUT"] = "1"
            args = member.chatArgs
            if let settings = context.claudeSettingsFile { args += ["--settings", settings.path] }
            // A member answers by running `council post`, and that writes into the chat directory — which is
            // not the folder it works in. Since members no longer start with their CLI's stop-asking flag,
            // without these two the very first reply would stop on a permission prompt, every time, for
            // everyone. What is granted here is the app's own plumbing, not the user's files: the chat's
            // directory, and the one command the briefing asks for.
            // Both spellings of the same rule: Claude Code's own help documents `Bash(git *)`, and its binary
            // also carries the `Bash(find:*)` form. Granting both costs nothing and means the posting command
            // is allowed whichever one this version parses.
            args += ["--add-dir", context.sessionDir.path,
                     "--allowedTools", "Bash(council *),Bash(council:*)"]
            if let id = resumeId {
                args += ["--resume", id]
            } else {
                let id = context.newSessionId()
                sessionId = id
                args += ["--session-id", id]
            }
        case .codex:
            var flags = member.chatArgs
            flags += HookConfig.codexOverrides(councilExecutable: context.tools.councilCommand)
            // The trust override does **not** suppress Codex's "Do you trust the contents of this directory?"
            // dialog — measured against codex-cli 0.154.0 on a folder no config trusted, with `--yolo` and
            // with `--sandbox`/`-a` alike: it stops there, emits no hook, and never starts. Trust appears to
            // be read from the config file on disk rather than from the effective config, which is a sensible
            // thing for a trust gate to do. It is left here because it costs nothing and a later version may
            // honour it; what actually carries the user through is the card the app raises, which names the
            // dialog and says to answer it in the member's terminal.
            flags += ["-c", "projects.\"\(context.cwd.path)\".trust_level=\"trusted\"",
                      "-c", "check_for_update_on_startup=false"]
            // Same reason as Claude Code above: `council post` writes to the chat directory, which a
            // workspace-write sandbox would refuse because it is outside the working folder. Naming it as a
            // writable root buys posting and nothing else.
            flags += ["-c", "sandbox_workspace_write.writable_roots=[\"\(context.sessionDir.path)\"]"]
            // The hooks above are the app's own; without this Codex stops at a "Hooks need review" dialog on every launch.
            flags += ["--dangerously-bypass-hook-trust"]
            if let id = resumeId {
                args = ["resume", id] + flags
            } else {
                args = flags
            }
        case .pi:
            args = member.chatArgs.filter { $0 != "--no-session" }
            let id = resumeId ?? context.newSessionId()
            sessionId = id
            args += ["--session-id", id]
            if let ext = context.piExtension { args += ["-e", ext.path] }
        case .kimi:
            // kimi takes its hooks only from the config file in its data directory, so the member gets a
            // directory of its own: the user's config regenerated with the council's hooks, their credentials
            // linked rather than copied, and the working folder pre-trusted so no trust dialog is ever raised.
            if let home = context.kimiHome { env["KIMI_CODE_HOME"] = home.path }
            if let effort = context.effort, let level = kimiEffort(effort) { env["KIMI_MODEL_EFFORT"] = level }
            args = member.chatArgs
            if !member.model.isEmpty { args += ["--model", member.model] }
            // As above: the chat directory is where a reply is written, and it is not the working folder.
            args += ["--add-dir", context.sessionDir.path]
            // A session does not exist until the first message — the id arrives on the SessionStart hook —
            // so there is nothing to pre-assign, and a resume names the id the app recorded from that hook.
            if let id = resumeId {
                args += ["--session", id]
                sessionId = id
            } else {
                sessionId = nil
            }
        case .openai:
            throw LaunchError.unsupportedBackend(member.backend.rawValue)
        }
        return LaunchPlan(backend: member.backend, executable: exe, arguments: args, environment: env,
                          currentDirectory: context.cwd, sessionId: sessionId, isResume: isResume)
    }
}
