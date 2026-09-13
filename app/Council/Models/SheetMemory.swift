import Foundation
import CouncilCore

/// What the new-chat and new-verdict sheets were last set to.
///
/// `council.toml` says what a fresh install should open with, and it stays the answer until somebody makes a
/// choice of their own. After that the sheet opens where the last one left off, because a roster is a decision
/// people make once and then repeat, and re-ticking the same three members before every chat is a small tax
/// charged over and over.
///
/// Kept in `UserDefaults` rather than in `council.toml`: it is a preference about this Mac and this person,
/// and the config file is shared with the CLI and shipped in the repo. The working folder is not stored here
/// because `SessionsModel.lastUsedFolder` already answers that from the sessions themselves.
enum SheetMemory {
    struct Chat: Codable, Equatable {
        var members: [String]
        var effort: String
        var budget: Int
    }

    struct Verdict: Codable, Equatable {
        var members: [String]
        var moderator: String
        var rounds: Int
        var anonymous: Bool
    }

    static let chatKey = "lastChatSetup"
    static let verdictKey = "lastVerdictSetup"

    static func load<T: Decodable>(_ type: T.Type, key: String, from store: UserDefaults = .standard) -> T? {
        guard let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save(_ value: some Encodable, key: String, to store: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        store.set(data, forKey: key)
    }

    /// Remembered members, minus any the roster no longer offers: a member renamed in `council.toml`, one
    /// removed from it, or one whose CLI is no longer installed. An empty result means the remembered choice
    /// is gone entirely, and the caller keeps council.toml's answer rather than opening a sheet with nothing
    /// ticked and a disabled button.
    static func stillOffered(_ remembered: [String], in config: CouncilConfig) -> [String] {
        remembered.filter { config.members[$0]?.isAvailable ?? false }
    }
}
