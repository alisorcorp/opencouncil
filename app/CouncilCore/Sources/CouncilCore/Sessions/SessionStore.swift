import Foundation

public enum SessionKind: String, Sendable, Codable, CaseIterable {
    case chat, verdict
}

/// One row of the Sessions list.
public struct SessionSummary: Sendable, Equatable, Identifiable, Hashable {
    public let id: String            // directory name
    public let directory: URL
    public let kind: SessionKind
    public let title: String
    public let created: Date?
    public let lastActivity: Date?
    public let memberOrder: [String]
    public let memberLabels: [String: String]
    public let messageCount: Int     // chat: messages in chat.jsonl; verdict: 0
    public let score: Int?           // verdict: consensus score when verdict.md exists
    public let hasVerdict: Bool
    public let cwd: String?

    public var displayTitle: String { title.isEmpty ? id : title }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (a: SessionSummary, b: SessionSummary) -> Bool {
        a.id == b.id && a.lastActivity == b.lastActivity && a.messageCount == b.messageCount && a.score == b.score && a.title == b.title
    }
}

/// Enumerates `chats/` and `runs/`. Read-only; the CLI keeps creating directories in the same layout (R20).
public struct SessionStore: Sendable {
    public let paths: CouncilPaths

    public init(paths: CouncilPaths) { self.paths = paths }

    /// Every session, newest activity first. Directories without a readable config.json are skipped.
    public func scan(fileManager: FileManager = .default) -> [SessionSummary] {
        var out: [SessionSummary] = []
        for dir in subdirectories(of: paths.chats, fileManager: fileManager) {
            if let s = Self.chatSummary(directory: dir, fileManager: fileManager) { out.append(s) }
        }
        for dir in subdirectories(of: paths.runs, fileManager: fileManager) {
            if let s = Self.runSummary(directory: dir, fileManager: fileManager) { out.append(s) }
        }
        return out.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    private func subdirectories(of url: URL, fileManager: FileManager) -> [URL] {
        guard let items = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { item in
            // Skip the CLI's `chats/current` symlink and anything that is not a real directory.
            guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    public static func chatSummary(directory: URL, fileManager: FileManager = .default) -> SessionSummary? {
        guard let cfg = try? ChatConfig.load(from: directory) else { return nil }
        let messages = (try? Bus(directory: directory).readAll()) ?? []
        let created = MessageTime.parse(cfg.created)
        let last = messages.last.flatMap { $0.date } ?? created   // data, not mtimes: copies and syncs must not reorder the list
        var labels: [String: String] = [:]
        for (name, m) in cfg.members { labels[name] = ChatConfig.splitEffortSuffix(m.label ?? name).label }
        return SessionSummary(id: directory.lastPathComponent, directory: directory, kind: .chat,
                              title: cfg.title ?? titleFromDirectoryName(directory.lastPathComponent),
                              created: created, lastActivity: last, memberOrder: cfg.order, memberLabels: labels,
                              messageCount: messages.count, score: nil, hasVerdict: false, cwd: cfg.cwd)
    }

    public static func runSummary(directory: URL, fileManager: FileManager = .default) -> SessionSummary? {
        guard let cfg = try? RunConfig.load(from: directory) else { return nil }
        let created = MessageTime.parse(cfg.created)
        let verdictURL = directory.appendingPathComponent("verdict.md")
        let verdict = try? String(contentsOf: verdictURL, encoding: .utf8)
        let last = cfg.latestFinished(in: directory) ?? created
        var labels: [String: String] = [:]
        for (name, m) in cfg.members { labels[name] = m.label ?? name }
        return SessionSummary(id: directory.lastPathComponent, directory: directory, kind: .verdict,
                              title: cfg.questionPreview, created: created, lastActivity: last,
                              memberOrder: cfg.order, memberLabels: labels, messageCount: 0,
                              score: verdict.flatMap(ConsensusScore.parse), hasVerdict: verdict != nil, cwd: nil)
    }

    /// `2026-09-10_113600_nfl` → `nfl` (older chats may predate the `title` field).
    static func titleFromDirectoryName(_ name: String) -> String {
        let parts = name.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
        return parts.count == 3 ? String(parts[2]) : name
    }
}
