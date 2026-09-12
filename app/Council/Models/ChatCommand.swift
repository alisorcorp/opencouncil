import Foundation

/// A slash command typed in the composer. The CLI has a whole vocabulary (chat.py's `HELP`); the app only
/// parses the ones it has nowhere else to put, and anything unrecognised is sent as an ordinary message —
/// a line that starts with a slash is far more often code than a command.
enum ChatCommand: Equatable {
    /// `/budget 20`: replies each member may send before the user speaks again.
    case budget(Int)

    static func parse(_ text: String) -> ChatCommand? {
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, parts[0] == "/budget",
              let n = Int(parts[1]), (1...999).contains(n) else { return nil }
        return .budget(n)
    }
}
