import Foundation

/// App-owned state for one session, stored as `app.json` next to `config.json`. Kept separate because
/// the CLI rewrites `config.json` when it resumes a chat and would drop anything the app added.
public struct SessionAppState: Codable, Sendable, Equatable {
    /// CLI session ids per member (Claude Code / pi: pre-assigned; Codex: from its SessionStart hook).
    public var sessionIds: [String: String]
    /// Project folder to use instead of config.json `cwd` (set when the original folder moved).
    public var cwdOverride: String?
    /// Highest message id the user has seen; unread = messages above it from non-user senders.
    public var lastSeenId: Int64?
    /// True while the app has members running for this session.
    public var live: Bool
    /// Members the user muted: they stay in the chat but are not prompted.
    public var muted: [String]
    /// Replies allowed per member per user message, when the user changed it from the chat's `config.json` value.
    public var budget: Int?
    /// A message typed but not sent. Kept so leaving the chat — for a member's terminal, another session, or a
    /// restart — never throws away what the user wrote.
    public var draft: String?

    public static let fileName = "app.json"

    public init(sessionIds: [String: String] = [:], cwdOverride: String? = nil, lastSeenId: Int64? = nil,
                live: Bool = false, muted: [String] = [], budget: Int? = nil, draft: String? = nil) {
        self.sessionIds = sessionIds
        self.cwdOverride = cwdOverride
        self.lastSeenId = lastSeenId
        self.live = live
        self.muted = muted
        self.budget = budget
        self.draft = draft
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionIds = try c.decodeIfPresent([String: String].self, forKey: .sessionIds) ?? [:]
        cwdOverride = try c.decodeIfPresent(String.self, forKey: .cwdOverride)
        lastSeenId = try c.decodeIfPresent(Int64.self, forKey: .lastSeenId)
        live = try c.decodeIfPresent(Bool.self, forKey: .live) ?? false
        muted = try c.decodeIfPresent([String].self, forKey: .muted) ?? []
        budget = try c.decodeIfPresent(Int.self, forKey: .budget)
        draft = try c.decodeIfPresent(String.self, forKey: .draft)
    }

    public static func load(from directory: URL) -> SessionAppState {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(SessionAppState.self, from: data) else {
            return SessionAppState()
        }
        return s
    }

    /// Applies `edit` to whatever `app.json` holds right now, writes the result back, and returns it.
    ///
    /// This file has two owners inside the app — the view model (the draft, the read position) and the runtime
    /// (session ids, live, mutes) — and each keeps its own copy. Writing a copy back whole would undo every
    /// change the other had made since that copy was loaded, which is why a change is *described* here rather
    /// than pasted, and why there is no public whole-struct write. Callers take the returned value as their
    /// new copy so they do not go stale either.
    @discardableResult
    public static func update(in directory: URL, _ edit: (inout SessionAppState) -> Void) throws -> SessionAppState {
        var state = load(from: directory)
        edit(&state)
        try state.write(to: directory)
        return state
    }

    private func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(SessionAppState.fileName), options: .atomic)
    }

    /// Messages the user has not seen: newer than `lastSeenId`, not their own, not notes.
    public func unreadCount(in messages: [Message]) -> Int {
        let floor = lastSeenId ?? Int64.min
        return messages.filter { $0.id > floor && !$0.isFromUser && !$0.isNote }.count
    }
}
