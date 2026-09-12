import Foundation

/// The append-only `chat.jsonl` shared by the app, the members (`council post`) and the CLI.
/// Append uses the same `flock` discipline as chat.py so writers can interleave safely.
public struct Bus: Sendable, Equatable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory.standardizedFileURL }

    public var logURL: URL { directory.appendingPathComponent("chat.jsonl") }

    public enum BusError: Error, LocalizedError {
        case cannotOpen(String, Int32)
        case shortWrite
        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let p, let e): return "cannot open \(p): \(String(cString: strerror(e)))"
            case .shortWrite: return "short write to chat.jsonl"
            }
        }
    }

    /// Every message in the log. Nothing is skipped: see `decodeLines`.
    public func readAll() throws -> [Message] {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
        let data = try Data(contentsOf: logURL)
        return Bus.decodeLines(data)
    }

    /// Every complete record in `data`, and nothing else.
    ///
    /// **Complete means newline-terminated.** Bytes after the last newline are a write in progress: decoding
    /// them would consume a post before the writer had finished it, and — because every consumer takes new
    /// messages by position — the finished post would then arrive at the same index with the same count and be
    /// read as "nothing new". The answer would be swallowed twice over. `FileTail` has always held a partial
    /// line back until its newline arrives; this is the same rule for whole-file reads.
    ///
    /// A record that crashed mid-write and never got its newline is therefore not read. That is the honest
    /// answer: nothing ever observed a complete record there.
    static func decodeLines(_ data: Data) -> [Message] {
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
        return data[..<lastNewline].split(separator: 0x0A).compactMap { record(Data($0)) }
    }

    /// The one decoding policy, used by every reader of the log — `readAll` and the live tail both come here
    /// and nowhere else. A line the decoder refuses is not the same thing as no line: skipping one silently is
    /// how the app came to tell a user that a member "had nothing to add" while that member's reply sat in the
    /// file. So a complete record is decoded strictly, or repaired, or — failing both — returned as an
    /// attributed `kindUnreadable` message that says what happened to it.
    ///
    /// `nil` means there is nothing there at all: a blank line, or bytes with no sender to attribute them to.
    public static func record(_ line: Data) -> Message? {
        if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { return nil }
        let decoder = JSONDecoder()
        if let m = try? decoder.decode(Message.self, from: line) { return m }
        if let repaired = repairingLoneSurrogates(line),
           let m = try? decoder.decode(Message.self, from: repaired) { return m }
        return placeholder(for: line)
    }

    /// Text that was never valid UTF-8 reaches the log as lone surrogate escapes: Python takes undecodable
    /// argv bytes as surrogates (PEP 383) and writes them without complaint, and every strict decoder rejects
    /// the whole line. The observed cause was a member posting through a double-quoted shell string, where the
    /// shell ate part of a multi-byte character along with its `$`-expansions. Replace the unpaired halves with
    /// U+FFFD so the rest of the message survives; returns nil when there was nothing to repair.
    static func repairingLoneSurrogates(_ line: Data) -> Data? {
        guard let text = String(data: line, encoding: .utf8), text.contains("\\u") else { return nil }
        let chars = Array(text)
        func escape(at j: Int) -> UInt32? {
            guard j + 5 < chars.count, chars[j] == "\\", chars[j + 1] == "u" else { return nil }
            return UInt32(String(chars[(j + 2)...(j + 5)]), radix: 16)
        }
        var out = ""
        var i = 0
        var repaired = false
        while i < chars.count {
            if chars[i] == "\\" {
                if let v = escape(at: i) {
                    let isHigh = (0xD800...0xDBFF).contains(v)
                    let isLow = (0xDC00...0xDFFF).contains(v)
                    // A proper pair is a real character and travels untouched.
                    if isHigh, let next = escape(at: i + 6), (0xDC00...0xDFFF).contains(next) {
                        out += String(chars[i..<(i + 12)])
                        i += 12
                        continue
                    }
                    if isHigh || isLow {
                        out += "\\ufffd"
                        repaired = true
                        i += 6
                        continue
                    }
                }
                // Any other escape — `\\\\` included — travels as a pair, so a literal backslash before a `u`
                // is never mistaken for an escape sequence.
                if i + 1 < chars.count {
                    out.append(chars[i])
                    out.append(chars[i + 1])
                    i += 2
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return repaired ? out.data(using: .utf8) : nil
    }

    /// What an unreadable record says in place of the text nobody could recover.
    public static let unreadableText =
        "(this message could not be read: it reached the log as text that is not valid Unicode)"

    /// How a consumer describes an unreadable record when it has to close something with a reason.
    public static let unreadableReason = "posted a message that could not be read"

    /// Last resort for a line that will not decode even repaired. `id` and `from` are plain scalars written
    /// before the text, so they survive whatever broke it, and the message becomes visible — attributed, in
    /// the right place in the conversation, and saying what happened to it. The kind is the decoder's, not the
    /// line's: whatever this was meant to be, what arrived is a transport failure and must not be mistaken for
    /// something a member said.
    static func placeholder(for line: Data) -> Message? {
        guard let text = String(data: line, encoding: .utf8) ?? String(data: line, encoding: .isoLatin1) else { return nil }
        func value(_ key: String) -> String? {
            guard let r = text.range(of: "\"\(key)\": ") else { return nil }
            let rest = text[r.upperBound...]
            guard rest.first == "\"" else { return String(rest.prefix(while: \.isNumber)) }
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: "\"") else { return nil }
            return String(body[body.startIndex..<end])
        }
        guard let sender = value("from"), let id = value("id").flatMap(Int64.init) else { return nil }
        return Message(id: id, ts: value("ts") ?? "", sender: sender, kind: Message.kindUnreadable,
                       text: Bus.unreadableText)
    }

    /// Appends a message. `members` is the roster used to resolve mentions (config.json `order`).
    @discardableResult
    public func append(sender: String, text: String, kind: String = Message.kindMessage, members: [String],
                       now: Date = Date()) throws -> Message {
        let trimmed = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let msg = Message(id: MessageTime.nowNanoseconds(), ts: MessageTime.format(now), sender: sender, kind: kind,
                          text: trimmed, to: Mentions.extract(from: trimmed, members: members))
        try appendRaw(msg)
        return msg
    }

    public func appendRaw(_ msg: Message) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(msg)
        data.append(0x0A)
        let fd = Darwin.open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw BusError.cannotOpen(logURL.path, errno) }
        defer { Darwin.close(fd) }
        _ = flock(fd, LOCK_EX)
        defer { _ = flock(fd, LOCK_UN) }
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var written = 0
            while written < buf.count {
                let n = Darwin.write(fd, buf.baseAddress!.advanced(by: written), buf.count - written)
                if n <= 0 { throw BusError.shortWrite }
                written += n
            }
        }
    }
}
