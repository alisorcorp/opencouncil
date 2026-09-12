import Foundation
import TOMLDecoder

/// The parsed `council.toml`. Read-only: the app never writes this file (see requirements, scope boundaries).
/// Mirrors `load_config()` in council.py: `[defaults]` and `[members]` always exist, `[members]` must not be empty.
public struct CouncilConfig: Sendable, Equatable {
    public struct Defaults: Sendable, Equatable {
        public var members: [String]
        public var moderator: String?
        public var rounds: Int
        public var anonymous: Bool
        public var length: String

        public init(members: [String] = [], moderator: String? = nil, rounds: Int = 1,
                    anonymous: Bool = false, length: String = "about 300-500 words") {
            self.members = members
            self.moderator = moderator
            self.rounds = rounds
            self.anonymous = anonymous
            self.length = length
        }
    }

    public struct Chat: Sendable, Equatable {
        public var members: [String]
        public var budget: Int
        public var effort: String

        public init(members: [String], budget: Int = 20, effort: String = "medium") {
            self.members = members
            self.budget = budget
            self.effort = effort
        }
    }

    public enum Backend: String, Sendable, Equatable, CaseIterable {
        case claude, codex, pi, kimi, openai

        /// Backends the app can host as interactive terminals (R12). `openai` members are direct HTTP
        /// clients without a terminal and are out of scope for the app's first version.
        public var isTerminalBackend: Bool {
            switch self {
            case .claude, .codex, .pi, .kimi: return true
            case .openai: return false
            }
        }

        /// `kimi` is the one backend the CLI cannot host: `council chat` starts members as herdr agents, and
        /// herdr has no kimi kind. The app hosts its own terminals, so it does not need one.
        public var isCLIBackend: Bool { self != .kimi }
    }

    public struct Member: Sendable, Equatable, Identifiable {
        public var name: String
        public var backend: Backend?
        public var backendName: String
        public var label: String
        public var model: String
        public var provider: String?
        public var chatArgs: [String]?

        public var id: String { name }

        /// True when this member can join a chat or verdict run in the app.
        public var isAvailable: Bool { backend?.isTerminalBackend ?? false }

        public init(name: String, backend: Backend?, backendName: String, label: String? = nil,
                    model: String = "", provider: String? = nil, chatArgs: [String]? = nil) {
            self.name = name
            self.backend = backend
            self.backendName = backendName
            self.label = label ?? name
            self.model = model
            self.provider = provider
            self.chatArgs = chatArgs
        }
    }

    public var defaults: Defaults
    public var chat: Chat
    public var members: [String: Member]
    /// Member names in the order they appear in the file.
    public var memberOrder: [String]

    public init(defaults: Defaults, chat: Chat, members: [String: Member], memberOrder: [String]) {
        self.defaults = defaults
        self.chat = chat
        self.members = members
        self.memberOrder = memberOrder
    }

    public var orderedMembers: [Member] { memberOrder.compactMap { members[$0] } }

    public enum LoadError: Error, LocalizedError, Equatable {
        case fileMissing(URL)
        case noMembers(URL)
        case malformed(URL, String)

        public var errorDescription: String? {
            switch self {
            case .fileMissing(let u): return "council.toml not found at \(u.path)"
            case .noMembers(let u): return "no [members.*] configured in \(u.path)"
            case .malformed(let u, let why): return "could not parse \(u.path): \(why)"
            }
        }
    }

    public static func load(from url: URL) throws -> CouncilConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { throw LoadError.fileMissing(url) }
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch { throw LoadError.malformed(url, error.localizedDescription) }
        do { return try parse(text) } catch let e as LoadError {
            switch e {
            case .noMembers: throw LoadError.noMembers(url)
            case .malformed(_, let why): throw LoadError.malformed(url, why)
            case .fileMissing: throw e
            }
        }
    }

    /// Parses TOML text. Exposed for tests; `load(from:)` is the normal entry point.
    public static func parse(_ text: String) throws -> CouncilConfig {
        let raw: RawConfig
        do { raw = try TOMLDecoder().decode(RawConfig.self, from: text) } catch { throw LoadError.malformed(URL(fileURLWithPath: "council.toml"), "\(error)") }
        guard let rawMembers = raw.members, !rawMembers.isEmpty else {
            throw LoadError.noMembers(URL(fileURLWithPath: "council.toml"))
        }
        var members: [String: Member] = [:]
        for (name, m) in rawMembers {
            members[name] = Member(name: name, backend: Backend(rawValue: m.backend ?? ""), backendName: m.backend ?? "",
                                   label: m.label, model: m.model ?? "", provider: m.provider, chatArgs: m.chat_args)
        }
        let order = memberOrder(in: text, known: Set(members.keys))
        let d = raw.defaults
        let defaults = Defaults(members: d?.members ?? [], moderator: d?.moderator, rounds: d?.rounds ?? 1,
                                anonymous: d?.anonymous ?? false, length: d?.length ?? "about 300-500 words")
        // chat.py: chat members default to [chat].members, else [defaults].members; budget 20; effort "medium".
        let c = raw.chat
        let chat = Chat(members: c?.members ?? defaults.members, budget: c?.budget ?? 20, effort: c?.effort ?? "medium")
        return CouncilConfig(defaults: defaults, chat: chat, members: members, memberOrder: order)
    }

    /// TOML tables decode into an unordered dictionary; recover file order from `[members.NAME]` headers.
    static func memberOrder(in text: String, known: Set<String>) -> [String] {
        var order: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("[members."), let close = t.firstIndex(of: "]") else { continue }
            let name = String(t[t.index(t.startIndex, offsetBy: 9)..<close]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if known.contains(name), !order.contains(name) { order.append(name) }
        }
        for name in known.sorted() where !order.contains(name) { order.append(name) }
        return order
    }
}

// Raw Codable mirror of the TOML file. Everything optional so unknown or partial tables never fail decoding.
private struct RawConfig: Decodable {
    struct RawDefaults: Decodable {
        var members: [String]?
        var moderator: String?
        var rounds: Int?
        var anonymous: Bool?
        var length: String?
    }
    struct RawChat: Decodable {
        var members: [String]?
        var budget: Int?
        var effort: String?
    }
    struct RawMember: Decodable {
        var backend: String?
        var label: String?
        var model: String?
        var provider: String?
        var chat_args: [String]?
    }
    var defaults: RawDefaults?
    var chat: RawChat?
    var members: [String: RawMember]?
}
