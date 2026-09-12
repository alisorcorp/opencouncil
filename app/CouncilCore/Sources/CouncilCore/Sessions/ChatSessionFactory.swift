import Foundation

/// Creates a new chat directory. The layout and `config.json` shape are the CLI's (`prepare_chat` and
/// `build_members` in chat.py), so a chat started in the app can be opened with `council session <name>`
/// and vice versa. The one omission is the herdr `agent` field, which only means something to the CLI's
/// pane manager; the CLI fills it in itself when it resumes a chat.
public struct ChatSessionFactory: Sendable {
    public let paths: CouncilPaths
    public let config: CouncilConfig

    public init(paths: CouncilPaths, config: CouncilConfig) {
        self.paths = paths
        self.config = config
    }

    public enum CreateError: Error, LocalizedError, Equatable {
        case noMembers
        case unknownMember(String)
        case reservedName(String)
        case unavailable(String)
        case folderMissing(URL)
        case directoryExists(URL)

        public var errorDescription: String? {
            switch self {
            case .noMembers: return "Pick at least one member."
            case .unknownMember(let n): return "\(n) is not in council.toml."
            case .reservedName(let n): return "\"\(n)\" is a reserved name."
            case .unavailable(let n): return "\(n) cannot run in the app (its backend has no terminal)."
            case .folderMissing(let u): return "The project folder does not exist: \(u.path)"
            case .directoryExists(let u): return "A chat already exists at \(u.lastPathComponent)."
            }
        }
    }

    /// Reserved senders, as chat.py rejects them.
    static let reserved: Set<String> = [Message.userSender, Message.systemSender, "all", "everyone"]

    /// Creates `chats/<stamp>_<slug>/` with `config.json`, an empty `chat.jsonl`, `inbox/` and `status/`,
    /// and repoints `chats/current` at it. Returns the new directory.
    @discardableResult
    public func create(title: String, members: [String], cwd: URL, budget: Int? = nil, effort: String? = nil,
                       now: Date = Date()) throws -> URL {
        guard !members.isEmpty else { throw CreateError.noMembers }
        for name in members {
            guard let member = config.members[name] else { throw CreateError.unknownMember(name) }
            if Self.reserved.contains(name) { throw CreateError.reservedName(name) }
            guard member.isAvailable else { throw CreateError.unavailable(name) }
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir), isDir.boolValue else {
            throw CreateError.folderMissing(cwd)
        }
        let effort = effort ?? config.chat.effort
        let stamp = Self.stamp(now)
        let dir = paths.chats.appendingPathComponent("\(stamp)_\(Self.slugify(title, 24))")
        guard !FileManager.default.fileExists(atPath: dir.path) else { throw CreateError.directoryExists(dir) }

        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("inbox"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("status"), withIntermediateDirectories: true)
        let chat = ChatConfig(created: MessageTime.format(now), cwd: cwd.path, title: title,
                              members: buildMembers(members, effort: effort),
                              order: members, budget: budget ?? config.chat.budget, effort: effort)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(chat).write(to: dir.appendingPathComponent("config.json"), options: .atomic)
        fm.createFile(atPath: dir.appendingPathComponent("chat.jsonl").path, contents: Data())
        pointCurrent(at: dir)
        return dir
    }

    /// chat.py `build_members`: the launch arguments are baked into `chat_args` at creation, so a chat keeps
    /// running the models it was started with even if council.toml changes later.
    func buildMembers(_ names: [String], effort: String) -> [String: ChatConfig.Member] {
        var out: [String: ChatConfig.Member] = [:]
        for name in names {
            guard let m = config.members[name], let backend = m.backend else { continue }
            var args = m.chatArgs ?? Self.defaultChatArgs[backend] ?? []
            if backend == .pi {
                var model: [String] = []
                if let p = m.provider, !p.isEmpty { model += ["--provider", p] }
                if !m.model.isEmpty { model += ["--model", m.model] }
                args = model + args
                // The CLI runs pi without a session; the app strips this again when it launches so that
                // members can be resumed (see LaunchPlanner). Kept here so `council session` behaves as before.
                if !args.contains("--no-session") { args.insert("--no-session", at: 0) }
            }
            var label = m.label
            if effort != "default", let flags = Self.effortArgs[backend] {
                args += flags(effort)
                label = "\(label) · \(effort)"
            }
            out[name] = ChatConfig.Member(name: name, backend: backend.rawValue, label: label,
                                          model: m.model.isEmpty ? nil : m.model, provider: m.provider,
                                          chatArgs: args, chatKind: backend.isTerminalBackend ? "herdr" : "openai")
        }
        return out
    }

    /// `chats/current` is how `council post` and `council log` find the chat when no `--chat` is given.
    private func pointCurrent(at dir: URL) {
        let link = paths.chats.appendingPathComponent("current")
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
    }

    // MARK: name rules

    /// chat.py `DEFAULT_CHAT_ARGS`, and `ChatArgsParityTests` holds the two files to the same answer.
    ///
    /// A member is given file and shell tools in the chat's working folder, so what it may do without asking
    /// is a product decision, not a detail: these ask before anything risky. Claude Code takes its edits and
    /// asks about the rest, and is *allowed* to bypass — from inside the session, if the user chooses — but
    /// does not start there. Codex keeps writes inside the folder and asks on request. kimi's `--yolo` is its
    /// asking mode, not its unattended one; `--auto` is the unattended one. Whatever asks must also be
    /// visible: a member waiting on an answer reports `PermissionRequest`, which reaches the user as a
    /// `needs attention` card rather than a chat that has quietly stopped.
    static let defaultChatArgs: [CouncilConfig.Backend: [String]] = [
        .claude: ["--permission-mode", "acceptEdits", "--allow-dangerously-skip-permissions"],
        .codex: ["--sandbox", "workspace-write", "-a", "on-request"],
        .kimi: ["--yolo"],
        .pi: ["--no-session", "--offline"],
    ]

    /// chat.py `EFFORT_ARGS`.
    static let effortArgs: [CouncilConfig.Backend: @Sendable (String) -> [String]] = [
        .claude: { ["--effort", $0] },
        .codex: { ["-c", "model_reasoning_effort=\"\($0)\""] },
        .pi: { ["--thinking", $0] },
    ]

    /// council.py `slugify`: lowercase, non-alphanumerics to `-`, trimmed, truncated.
    public static func slugify(_ s: String, _ limit: Int = 40) -> String {
        var out = ""
        var lastWasDash = false
        for ch in s.lowercased() {
            if ch.isLetter && ch.isASCII || ch.isNumber && ch.isASCII {
                out.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        out = String(out.prefix(limit))
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "question" : out
    }

    /// `%Y-%m-%d_%H%M%S`, the directory prefix both tools sort by.
    public static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: date)
    }
}
