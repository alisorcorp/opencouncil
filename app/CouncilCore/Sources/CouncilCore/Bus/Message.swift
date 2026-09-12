import Foundation

/// One line of `chat.jsonl`. The shape is owned by chat.py's `Bus.post` and must round-trip exactly:
/// `{"id": time_ns, "ts": "YYYY-MM-DDTHH:MM:SS", "from": sender, "kind": "msg"|"note", "text": ..., "to": [mentions]}`.
public struct Message: Codable, Sendable, Equatable, Identifiable, Hashable {
    public static let userSender = "user"
    public static let systemSender = "system"
    public static let kindMessage = "msg"
    public static let kindNote = "note"
    /// Never written to the log: the decoder's own word for a complete record it could not read.
    /// It keeps the sender and the position, so the message is still visible and still attributed,
    /// while a consumer deciding whether an answer arrived can tell it apart from one.
    public static let kindUnreadable = "unreadable"

    public var id: Int64
    public var ts: String
    public var sender: String
    public var kind: String
    public var text: String
    public var to: [String]

    enum CodingKeys: String, CodingKey {
        case id, ts, kind, text, to
        case sender = "from"
    }

    public init(id: Int64, ts: String, sender: String, kind: String = Message.kindMessage, text: String, to: [String] = []) {
        self.id = id
        self.ts = ts
        self.sender = sender
        self.kind = kind
        self.text = text
        self.to = to
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        ts = try c.decodeIfPresent(String.self, forKey: .ts) ?? ""
        sender = try c.decode(String.self, forKey: .sender)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? Message.kindMessage
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        to = try c.decodeIfPresent([String].self, forKey: .to) ?? []
    }

    public var isNote: Bool { kind == Message.kindNote }
    public var isUnreadable: Bool { kind == Message.kindUnreadable }
    /// Something a participant actually said, and so the only thing worth quoting to another one. A note is the
    /// app talking; an unreadable record is the app reporting that it could not read what was said.
    public var isContent: Bool { !isNote && !isUnreadable }
    public var isFromUser: Bool { sender == Message.userSender }
    public var isFromSystem: Bool { sender == Message.systemSender }

    /// `ts` parsed as local time (Python writes `datetime.now().isoformat(timespec="seconds")`, no offset).
    public var date: Date? { MessageTime.parse(ts) }

    /// `HH:MM:SS`, as the CLI transcript shows it.
    public var clock: String { ts.count >= 19 ? String(ts.dropFirst(11).prefix(8)) : ts }
}

public enum MessageTime {
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = .current
        return f
    }()
    private static let lock = NSLock()

    public static func parse(_ s: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return formatter.date(from: String(s.prefix(19)))
    }

    public static func format(_ d: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return formatter.string(from: d)
    }

    /// Python's `time.time_ns()`.
    public static func nowNanoseconds() -> Int64 {
        Int64(bitPattern: clock_gettime_nsec_np(CLOCK_REALTIME))
    }
}
