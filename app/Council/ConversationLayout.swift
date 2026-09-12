import Foundation
import CouncilCore

/// Turns the flat message log into rows for the conversation view: day separators, notes, and bubbles that
/// hide their sender header when they continue the previous bubble from the same sender within a few minutes.
enum ConversationLayout {
    struct Row: Equatable, Identifiable {
        enum Kind: Equatable {
            case day(Date)
            case note(Message)
            case message(Message, showHeader: Bool)
        }

        let kind: Kind
        /// Position in the log. A message id is a nanosecond timestamp and two members posting at the same
        /// moment share one; keying rows by id made `ForEach` draw one of the two and drop the other.
        let position: Int

        var id: Int { position }
    }

    static let continuationWindow: TimeInterval = 5 * 60

    static func rows(for messages: [Message], calendar: Calendar = .current) -> [Row] {
        var out: [Row] = []
        var lastDay: Date?
        var lastBubble: Message?
        func append(_ kind: Row.Kind) { out.append(Row(kind: kind, position: out.count)) }
        for m in messages {
            if let d = m.date {
                let day = calendar.startOfDay(for: d)
                if lastDay != day {
                    append(.day(day))
                    lastDay = day
                    lastBubble = nil
                }
            }
            if m.isNote {
                append(.note(m))
                lastBubble = nil
                continue
            }
            var continues = false
            if let prev = lastBubble, prev.sender == m.sender, let a = prev.date, let b = m.date,
               b.timeIntervalSince(a) < continuationWindow, b >= a {
                continues = true
            }
            append(.message(m, showHeader: !continues))
            lastBubble = m
        }
        return out
    }
}
