import Foundation

/// What a member's CLI told us through its hook / extension channel, normalised across backends.
public enum MemberEvent: Sendable, Equatable {
    /// The CLI is up and has a session (Claude Code / Codex `SessionStart`, pi `session_start`).
    case started(sessionId: String?, reason: String?)
    /// A prompt was accepted and the model is working (`UserPromptSubmit`, pi `agent_start`).
    case turnStarted
    /// A tool call began; `activity` is a short human phrase such as "reading chat.py".
    case toolStarted(tool: String, activity: String)
    case toolEnded(tool: String, failed: Bool)
    /// The turn finished (`Stop`, pi `agent_end`). `lastMessage` when the backend provides it.
    case turnEnded(lastMessage: String?)
    /// The CLI is waiting on a human: permission prompt, trust prompt, login, elicitation.
    case blocked(reason: String)
    /// The dialog was answered (auth succeeded, elicitation completed).
    case unblocked
    /// The turn failed on the CLI side (Claude Code `StopFailure`).
    case failed(message: String)
    /// The CLI session ended (`SessionEnd`, pi `session_shutdown`).
    case ended(reason: String?)

    public var isTerminalForTurn: Bool {
        switch self {
        case .turnEnded, .failed, .ended: return true
        default: return false
        }
    }
}

/// One line of `events.jsonl`, as written by `council event` or the pi extension.
public struct RawEvent: Codable, Sendable, Equatable {
    public var ts: String
    public var member: String
    public var backend: String
    public var hook: String
    public var payload: JSONValue

    public init(ts: String, member: String, backend: String, hook: String, payload: JSONValue) {
        self.ts = ts; self.member = member; self.backend = backend; self.hook = hook; self.payload = payload
    }

    public static func decode(line: String) -> RawEvent? {
        guard let d = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RawEvent.self, from: d)
    }
}

/// Minimal JSON tree, because hook payloads differ per backend and version and we only read a few keys.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// Dotted lookup: `value["tool_input.file_path"]`.
    public func path(_ dotted: String) -> JSONValue? {
        var cur: JSONValue? = self
        for part in dotted.split(separator: ".") {
            cur = cur?[String(part)]
            if cur == nil { return nil }
        }
        return cur
    }
}
