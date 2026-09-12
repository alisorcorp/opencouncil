import Foundation

/// Creates a verdict run directory, the same shape council.py's `create_run` writes, so `council runs`,
/// `council show` and a resumed `council ask` all read an app-made run without knowing where it came from.
///
/// One deliberate narrowing: only members the app can host as terminals go into a run it creates. An `openai`
/// member is a direct HTTP client whose credentials live in `council.toml` under keys the app does not model,
/// and copying half of them into a run would produce a directory the CLI could not finish either.
public struct RunFactory: Sendable {
    public enum CreateError: LocalizedError, Equatable {
        case unknownMember(String)
        case tooFewMembers
        case notHostable(String)
        case emptyQuestion
        case attachmentUnreadable(String, String)
        case directoryExists(URL)

        public var errorDescription: String? {
            switch self {
            case .unknownMember(let n): return "\(n) is not in council.toml."
            case .tooFewMembers: return "A council needs at least two members."
            case .notHostable(let n): return "\(n) cannot run in the app: only Claude Code, Codex and pi members can."
            case .emptyQuestion: return "The question is empty."
            case .attachmentUnreadable(let f, let why): return "Cannot read attachment \(f): \(why)"
            case .directoryExists(let u): return "A run already exists at \(u.lastPathComponent)."
            }
        }
    }

    public let paths: CouncilPaths
    public let config: CouncilConfig

    public init(paths: CouncilPaths, config: CouncilConfig) {
        self.paths = paths
        self.config = config
    }

    /// `runs/<stamp>_<slug>/` with `question.md`, `config.json` and an empty `r1…rN`. Returns the directory.
    @discardableResult
    public func create(question: String, members: [String], moderator: String, rounds: Int = 1,
                       anonymous: Bool = false, attachments: [URL] = [], now: Date = Date(),
                       shuffle: ([String]) -> [String] = { $0.shuffled() }) throws -> URL {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw CreateError.emptyQuestion }
        guard members.count >= 2 else { throw CreateError.tooFewMembers }
        for name in members + [moderator] {
            guard let member = config.members[name] else { throw CreateError.unknownMember(name) }
            guard member.backend?.isTerminalBackend == true else { throw CreateError.notHostable(name) }
        }

        let stamp = ChatSessionFactory.stamp(now)
        let dir = paths.runs.appendingPathComponent("\(stamp)_\(ChatSessionFactory.slugify(question))")
        guard !FileManager.default.fileExists(atPath: dir.path) else { throw CreateError.directoryExists(dir) }

        // Attachments are read before anything is created, so a bad path leaves no half-made run behind.
        var body = question + "\n"
        for url in attachments {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw CreateError.attachmentUnreadable(url.lastPathComponent, "not readable as text")
            }
            // A fence has to be longer than any fence inside the file, or the attachment ends the block early.
            let fence = text.contains("```") ? "````" : "```"
            let trimmed = text.replacingOccurrences(of: "[ \t\n]+$", with: "", options: .regularExpression)
            body += "\n\n## Attached file: \(url.lastPathComponent)\n\n\(fence)\n\(trimmed)\n\(fence)\n"
        }

        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            for round in 1...max(rounds, 1) {
                try fm.createDirectory(at: dir.appendingPathComponent("r\(round)"), withIntermediateDirectories: true)
            }
            try body.write(to: dir.appendingPathComponent("question.md"), atomically: true, encoding: .utf8)

            // Anonymous runs present members as "Model A", "Model B"… in a shuffled order, and `order` is that
            // shuffle: the aliases must not give the roster away by position.
            let order = anonymous ? shuffle(members) : members
            var aliases: [String: String] = [:]
            if anonymous {
                for (i, name) in order.enumerated() {
                    aliases[name] = "Model \(String(UnicodeScalar(UInt8(65 + i % 26))))"
                }
            }
            var entries: [String: RunConfig.Member] = [:]
            for name in members {
                let m = config.members[name]!
                entries[name] = RunConfig.Member(name: name, backend: m.backendName, label: m.label,
                                                 alias: aliases[name] ?? m.label,
                                                 model: m.model.isEmpty ? nil : m.model, provider: m.provider)
            }
            let mod = config.members[moderator]!
            let run = RunConfig(created: MessageTime.format(now),
                                questionPreview: String(question.split(separator: "\n", omittingEmptySubsequences: false)
                                    .first.map(String.init)?.prefix(120) ?? ""),
                                members: entries, order: order,
                                moderator: RunConfig.Member(name: moderator, backend: mod.backendName,
                                                            label: mod.label,
                                                            model: mod.model.isEmpty ? nil : mod.model,
                                                            provider: mod.provider),
                                rounds: max(rounds, 1), anonymous: anonymous,
                                length: config.defaults.length,
                                attachments: attachments.map(\.lastPathComponent))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(run).write(to: dir.appendingPathComponent("config.json"), options: .atomic)
        } catch {
            try? fm.removeItem(at: dir)     // never leave a run the CLI would list but could not read
            throw error
        }
        return dir
    }

    /// The app's own corner of a run directory. A verdict member is an interactive terminal, so it answers with
    /// `council post`, which needs a chat-shaped `config.json` naming every sender it will accept — and the
    /// moderator is not in a run's `order`, so the run's own config.json cannot be that file. This writes one
    /// beside it, in a dotted directory the CLI's view of the run never sees, and it is also where the members'
    /// events and the delivery ledger land.
    ///
    /// `chat_args` come from the same builder a chat uses, so a member runs the model and effort it would in a
    /// chat rather than whatever `council.toml` happens to say when the run is resumed.
    @discardableResult
    public func prepareSessions(in runDirectory: URL, cwd: URL, effort: String? = nil,
                                now: Date = Date()) throws -> URL {
        let run = try RunConfig.load(from: runDirectory)
        let dir = runDirectory.appendingPathComponent(Self.sessionsDirectoryName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let effort = effort ?? config.chat.effort
        var participants = run.order
        if let moderator = run.moderator.name, !participants.contains(moderator) { participants.append(moderator) }
        let chats = ChatSessionFactory(paths: paths, config: config)
        let chat = ChatConfig(created: run.created, cwd: cwd.path, title: run.questionPreview,
                              members: chats.buildMembers(participants, effort: effort),
                              order: participants, budget: 1, effort: effort)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(chat).write(to: dir.appendingPathComponent("config.json"), options: .atomic)
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("chat.jsonl").path) {
            FileManager.default.createFile(atPath: dir.appendingPathComponent("chat.jsonl").path, contents: Data())
        }
        return dir
    }

    /// Where `prepareSessions` writes. Dotted so `SessionStore` and `council runs` both skip it.
    public static let sessionsDirectoryName = ".app"

    /// The app's session directory for a run, whether or not it has been prepared yet.
    public static func sessionsDirectory(of runDirectory: URL) -> URL {
        runDirectory.appendingPathComponent(sessionsDirectoryName)
    }
}
