import Foundation

/// `transcript.md` beside `chat.jsonl`: the human-readable copy of a chat, rewritten whenever the log grows.
/// A port of `transcript()` in chat.py, byte-for-byte — members are told to read this file when a chat resumes,
/// and `council log` users expect the same file whether the app or the CLI wrote it.
public enum Transcript {
    public static func render(config: ChatConfig, messages: [Message]) -> String {
        var out = ["# Council chat · \(config.created)", "",
                   "members: " + config.order.map { config.label(for: $0) }.joined(separator: ", "),
                   "cwd: \(config.cwd)"]
        if let resumed = config.resumed, !resumed.isEmpty {
            out.append("resumed: " + resumed.joined(separator: ", "))
        }
        out.append("")
        for m in messages {
            if m.isNote {
                out.append("_\(m.clock) · \(m.text)_\n")
            } else {
                let who = m.isFromUser ? "**you**" : "**\(m.sender)**"
                out.append("\(who) · \(m.clock)\n\n\(m.text)\n")
            }
        }
        return out.joined(separator: "\n")
    }

    public static func write(config: ChatConfig, messages: [Message], to directory: URL) throws {
        try render(config: config, messages: messages)
            .write(to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    }
}
