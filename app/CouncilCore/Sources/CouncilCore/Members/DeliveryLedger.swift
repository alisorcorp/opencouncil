import Foundation

/// What became of one delivery. R14: a routed message ends in a reply, a "nothing to add" note, or a card —
/// never silently.
public enum DeliveryOutcome: String, Codable, Sendable, Equatable {
    /// The member posted an answer of its own during the turn.
    case posted
    /// The turn ended without a post: the member read the others and had nothing to say.
    case nothingToAdd
    /// The member never took the prompt, its CLI failed, or it exited mid-turn.
    case failed
    /// The app stopped (or crashed) while the delivery was open. Written when the chat is opened again.
    case interrupted
}

/// One prompt handed to one member, and what came of it.
public struct Delivery: Codable, Sendable, Equatable {
    public var id: String
    public var member: String
    public var opened: String
    public var closed: String?
    /// The highest bus id the delivery carried, so a post from an earlier turn cannot be mistaken for this
    /// delivery's answer.
    public var upToMessageId: Int64
    /// How many times the text was pasted, counting the first.
    public var attempts: Int
    public var outcome: DeliveryOutcome?
    public var postId: Int64?
    /// What was pasted. Kept so a delivery interrupted by a restart can be sent again exactly as it was.
    /// Optional because ledgers written before this existed decode without it.
    public var text: String?

    public init(id: String = UUID().uuidString, member: String, opened: String, upToMessageId: Int64,
                attempts: Int = 1, closed: String? = nil, outcome: DeliveryOutcome? = nil, postId: Int64? = nil,
                text: String? = nil) {
        self.id = id
        self.member = member
        self.opened = opened
        self.upToMessageId = upToMessageId
        self.attempts = attempts
        self.closed = closed
        self.outcome = outcome
        self.postId = postId
        self.text = text
    }

    public var isOpen: Bool { outcome == nil }
}

/// `deliveries.jsonl` beside `chat.jsonl`: an append-only record of every prompt the app handed to a member.
/// Append-only rather than rewritten in place so a delivery that was in flight when the app died is still on
/// disk — reopening the chat closes it as `interrupted` instead of losing it.
public struct DeliveryLedger: Sendable {
    public static let fileName = "deliveries.jsonl"

    public let directory: URL
    public var url: URL { directory.appendingPathComponent(Self.fileName) }

    public init(directory: URL) { self.directory = directory }

    public func open(_ delivery: Delivery) throws { try append(delivery) }

    public func close(id: String, outcome: DeliveryOutcome, postId: Int64?, at time: String) throws {
        guard var d = all().first(where: { $0.id == id }) else { return }
        d.outcome = outcome
        d.postId = postId
        d.closed = time
        try append(d)
    }

    /// Records another attempt at the same delivery (a re-paste after no acknowledgement).
    public func attempt(id: String, attempts: Int) throws {
        guard var d = all().first(where: { $0.id == id }) else { return }
        d.attempts = attempts
        try append(d)
    }

    /// Every delivery, folded to its latest state, in the order they were opened.
    public func all() -> [Delivery] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var order: [String] = []
        var latest: [String: Delivery] = [:]
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = try? decoder.decode(Delivery.self, from: Data(line.utf8)) else { continue }
            if latest[d.id] == nil { order.append(d.id) }
            latest[d.id] = d
        }
        return order.compactMap { latest[$0] }
    }

    public func all(for member: String) -> [Delivery] { all().filter { $0.member == member } }

    public func open() -> [Delivery] { all().filter(\.isOpen) }

    /// Closes everything an earlier process left open. Called when a chat is opened, so a delivery that was in
    /// flight when the app quit is reported rather than forgotten.
    @discardableResult
    public func closeOrphans(at time: String) throws -> [Delivery] {
        let orphans = open()
        for var d in orphans {
            d.outcome = .interrupted
            d.closed = time
            try append(d)
        }
        return orphans
    }

    private func append(_ delivery: Delivery) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(delivery)
        data.append(0x0A)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
