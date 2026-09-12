import Foundation

/// `config.json` of a chat directory, written by chat.py `prepare_chat`. The app reads it and never writes it (R20);
/// app-owned state goes to `app.json` (see `SessionAppState`).
public struct ChatConfig: Codable, Sendable, Equatable {
    public struct Member: Codable, Sendable, Equatable {
        public var name: String?
        public var backend: String?
        public var label: String?
        public var model: String?
        public var provider: String?
        public var chatArgs: [String]?
        public var chatKind: String?
        public var agent: String?

        enum CodingKeys: String, CodingKey {
            case name, backend, label, model, provider, agent
            case chatArgs = "chat_args"
            case chatKind = "chat_kind"
        }

        public init(name: String? = nil, backend: String? = nil, label: String? = nil, model: String? = nil,
                    provider: String? = nil, chatArgs: [String]? = nil, chatKind: String? = nil, agent: String? = nil) {
            self.name = name; self.backend = backend; self.label = label; self.model = model
            self.provider = provider; self.chatArgs = chatArgs; self.chatKind = chatKind; self.agent = agent
        }
    }

    public var created: String
    public var cwd: String
    public var title: String?
    public var members: [String: Member]
    public var order: [String]
    public var budget: Int?
    public var effort: String?
    public var resumed: [String]?

    public init(created: String, cwd: String, title: String?, members: [String: Member], order: [String],
                budget: Int? = 20, effort: String? = "medium", resumed: [String]? = nil) {
        self.created = created; self.cwd = cwd; self.title = title; self.members = members
        self.order = order; self.budget = budget; self.effort = effort; self.resumed = resumed
    }

    public static func load(from directory: URL) throws -> ChatConfig {
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        return try JSONDecoder().decode(ChatConfig.self, from: data)
    }

    /// Display name for a sender, like `Bus.label` in chat.py: "you" for the user, the member label, else the name.
    public func label(for sender: String) -> String {
        if sender == Message.userSender { return "you" }
        return members[sender]?.label ?? sender
    }

    /// chat.py appends ` · <effort>` to labels at chat creation; the app shows the plain label and keeps the suffix as detail.
    public static func splitEffortSuffix(_ label: String) -> (label: String, effort: String?) {
        guard let r = label.range(of: " · ", options: .backwards) else { return (label, nil) }
        let suffix = String(label[r.upperBound...])
        let known = ["low", "medium", "high", "xhigh", "max", "minimal", "default"]
        return known.contains(suffix) ? (String(label[..<r.lowerBound]), suffix) : (label, nil)
    }
}
