import Foundation

/// `config.json` of a verdict run directory, written by council.py `create_run`.
public struct RunConfig: Codable, Sendable, Equatable {
    public struct Member: Codable, Sendable, Equatable {
        public var name: String?
        public var backend: String?
        public var label: String?
        public var alias: String?
        public var model: String?
        public var provider: String?

        public init(name: String? = nil, backend: String? = nil, label: String? = nil, alias: String? = nil,
                    model: String? = nil, provider: String? = nil) {
            self.name = name
            self.backend = backend
            self.label = label
            self.alias = alias
            self.model = model
            self.provider = provider
        }
    }

    public var created: String
    public var questionPreview: String
    public var members: [String: Member]
    public var order: [String]
    public var moderator: Member
    public var rounds: Int
    public var anonymous: Bool
    public var length: String?
    public var attachments: [String]?

    enum CodingKeys: String, CodingKey {
        case created, members, order, moderator, rounds, anonymous, length, attachments
        case questionPreview = "question_preview"
    }

    public init(created: String, questionPreview: String, members: [String: Member], order: [String],
                moderator: Member, rounds: Int, anonymous: Bool, length: String? = nil,
                attachments: [String]? = nil) {
        self.created = created
        self.questionPreview = questionPreview
        self.members = members
        self.order = order
        self.moderator = moderator
        self.rounds = rounds
        self.anonymous = anonymous
        self.length = length
        self.attachments = attachments
    }

    public static func load(from directory: URL) throws -> RunConfig {
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        return try JSONDecoder().decode(RunConfig.self, from: data)
    }
}

/// `r<N>/<member>.done`, written by council.py `cmd_member` when a member finishes a round.
public struct RunDone: Codable, Sendable, Equatable {
    public var status: String
    public var error: String?
    public var elapsed: Double?
    public var words: Int?
    public var finished: String?

    public var isOK: Bool { status == "ok" }

    public init(status: String, error: String? = nil, elapsed: Double? = nil, words: Int? = nil, finished: String? = nil) {
        self.status = status; self.error = error; self.elapsed = elapsed; self.words = words; self.finished = finished
    }

    public static func load(_ url: URL) -> RunDone? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RunDone.self, from: d)
    }
}

public extension RunConfig {
    func answerURL(_ member: String, round: Int, in directory: URL) -> URL {
        directory.appendingPathComponent("r\(round)/\(member).md")
    }
    func doneURL(_ member: String, round: Int, in directory: URL) -> URL {
        directory.appendingPathComponent("r\(round)/\(member).done")
    }

    /// Every `.done` record present, keyed by round then member.
    func doneRecords(in directory: URL) -> [Int: [String: RunDone]] {
        var out: [Int: [String: RunDone]] = [:]
        for r in 1...max(rounds, 1) {
            for m in order {
                if let d = RunDone.load(doneURL(m, round: r, in: directory)) { out[r, default: [:]][m] = d }
            }
        }
        return out
    }

    /// The latest `finished` timestamp across all rounds, or nil when nothing finished yet.
    func latestFinished(in directory: URL) -> Date? {
        doneRecords(in: directory).values.flatMap { $0.values }.compactMap { $0.finished.flatMap(MessageTime.parse) }.max()
    }
}
