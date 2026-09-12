import Foundation

/// `@name` extraction, identical to `Bus.mentions` in chat.py: `@([a-z][a-z0-9_-]*)`, case-insensitive,
/// `@all` / `@everyone` expand to every member, `@user` is allowed, unknown names are ignored, order kept, no duplicates.
public enum Mentions {
    nonisolated(unsafe) private static let regex = try! NSRegularExpression(pattern: "@([a-z][a-z0-9_-]*)", options: [.caseInsensitive])

    public static func extract(from text: String, members: [String]) -> [String] {
        var found: [String] = []
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            if name == "all" || name == "everyone" {
                for x in members where !found.contains(x) { found.append(x) }
            } else if (members.contains(name) || name == Message.userSender), !found.contains(name) {
                found.append(name)
            }
        }
        return found
    }

    /// Ranges of every `@word` in `text`, for rendering chips. Includes unknown names; callers filter.
    public static func ranges(in text: String) -> [Range<String.Index>] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { Range($0.range, in: text) }
    }
}
