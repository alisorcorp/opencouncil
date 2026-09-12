import Foundation

/// Who gets prompted, and with what. A pure port of `Router.route` / `Router.deliver_loop` in chat.py: the same
/// mention rules, the same reply budget, the same wrap-up behaviour and the same four-second burst coalescing.
/// It owns no I/O and no clock — the caller appends what the bus produced, ticks with the current time and the
/// set of members that can accept a prompt, and carries out the effects it returns.
public struct ChatRouter: Sendable {
    public enum Effect: Equatable, Sendable {
        /// Paste `text` into `member`'s terminal.
        case deliver(member: String, text: String)
        /// Append a dim system note to the bus (visible to the CLI and the transcript too).
        case note(String)
    }

    public let members: [String]
    /// Replies allowed **per member** per user message, as `config.json` `budget`. Each member may have this
    /// many of its own replies routed onward before the user speaks again, so one talkative member cannot
    /// spend everyone else's turns. Changing it starts the count over.
    public var budget: Int {
        didSet { spent = [:]; noticed = [] }
    }
    /// Replies each member has had routed since the last user message.
    private var spent: [String: Int] = [:]
    /// Members already told they are out of replies, so the note is posted once each.
    private var noticed: Set<String> = []
    public private(set) var wrapping = false
    public var muted: Set<String> = []
    /// How long a burst of messages is allowed to gather before it goes out as one delivery.
    public var coalesce: TimeInterval

    /// Every message the router has seen, in bus order (chat.py's `Router.msgs`).
    private(set) var messages: [Message] = []
    /// Per member: how far into `messages` its last delivery went (chat.py's `last`).
    private var cursors: [String: Int] = [:]
    /// Per member: when its pending delivery is due. Set by the first message of a burst and not extended.
    private var due: [String: Date] = [:]
    private var round: ReactionRound?
    /// The "not routed during wrap-up" note is posted once per wrap, not once per late mention.
    private var warnedAboutWrapMentions = false

    /// `members` is the chat's order; `history` is what the bus already holds when the chat opens. It is seeded
    /// into the buffer rather than merely counted: every cursor indexes `messages`, so handing over a count on
    /// its own would leave the cursors measuring the whole log while the buffer held only what arrived next, and
    /// the slice in `tick` would come back empty. Seeded history is context for the reaction pass and a floor for
    /// the cursors; it is never routed, so reopening a chat re-delivers nothing.
    public init(members: [String], budget: Int, history: [Message] = [], coalesce: TimeInterval = 4) {
        self.members = members
        self.budget = budget
        self.coalesce = coalesce
        self.messages = history
        for m in members { cursors[m] = history.count }
    }

    // MARK: bus

    /// Records new bus messages and routes them. Returns the notes to post; deliveries follow from `tick`.
    @discardableResult
    public mutating func append(_ new: [Message], now: Date = Date()) -> [Effect] {
        var effects: [Effect] = []
        for m in new {
            messages.append(m)
            effects += route(m, now: now)
        }
        return effects
    }

    /// chat.py `Router.route`. An unreadable record routes nothing: whatever mentions it carried did not
    /// survive either, and the only text it has is the app's account of failing to read it.
    private mutating func route(_ m: Message, now: Date) -> [Effect] {
        guard !m.isNote, !m.isUnreadable else { return [] }
        var effects: [Effect] = []
        var targets: [String]
        if m.isFromUser {
            wrapping = ChatRouter.isWrapUp(m.text)
            spent = [:]
            noticed = []
            targets = (m.to.isEmpty ? members : m.to).filter { $0 != Message.userSender }
            round = nil
            warnedAboutWrapMentions = false
        } else {
            if wrapping {
                // The council is writing its closing statements; a late @mention would start a new thread.
                let late = m.to.contains { $0 != m.sender && $0 != Message.userSender }
                if late, !warnedAboutWrapMentions {
                    warnedAboutWrapMentions = true
                    return [.note("mentions are not routed during wrap-up")]
                }
                return []
            }
            targets = m.to.filter { $0 != m.sender && $0 != Message.userSender }
            if targets.isEmpty { return [] }
            if spent[m.sender, default: 0] >= budget {
                if noticed.insert(m.sender).inserted {
                    effects.append(.note("reply budget (\(budget)) reached for \(m.sender); say something to continue"))
                }
                return effects
            }
            spent[m.sender, default: 0] += 1
        }
        let delivered = targets.filter { members.contains($0) && !muted.contains($0) }
        for t in delivered where due[t] == nil { due[t] = now.addingTimeInterval(coalesce) }
        if m.isFromUser {
            // A question put to the whole council gets the reaction pass; one addressed to a single member is
            // answered by that member, and nobody is asked to react to the answer.
            round = (!wrapping && delivered.count > 1) ? ReactionRound(messageId: m.id, waiting: Set(delivered)) : nil
        } else if round != nil {
            // A member pulled into the round by a mention is already replying; it does not need a nudge to react.
            for t in delivered { round?.excluded.insert(t) }
        }
        return effects
    }

    // MARK: deliveries

    /// Deliveries whose coalescing window has passed, for members that can take a prompt right now. `ready` keeps
    /// one prompt in flight per member: a member that is working stays queued until it comes back.
    public mutating func tick(now: Date = Date(), ready: Set<String>) -> [Effect] {
        var effects: [Effect] = []
        for member in members {
            guard let deadline = due[member], deadline <= now, ready.contains(member), !muted.contains(member) else { continue }
            let cursor = cursors[member] ?? 0
            let fresh = messages[min(cursor, messages.count)...].filter { $0.sender != member && $0.isContent }
            cursors[member] = messages.count
            due[member] = nil
            guard !fresh.isEmpty else { continue }
            round?.started.insert(member)
            effects.append(.deliver(member: member, text: Briefing.delivery(name: member, messages: Array(fresh),
                                                                           wrapping: wrapping)))
        }
        effects += reactionEffects(now: now, ready: ready)
        return effects
    }

    /// R11a: once every member that received the user's message has had its turn, each of them is asked to read
    /// what the others said and reply only if it has something to add. One pass per user message, never while
    /// wrapping up, and it spends one of that member's replies like any other round.
    private mutating func reactionEffects(now: Date, ready: Set<String>) -> [Effect] {
        // The gate opens only once every member that was going to answer has been prompted and has finished.
        guard let pass = round, pass.started == pass.delivered, pass.waiting.isEmpty, !wrapping else { return [] }
        round = nil
        let candidates = pass.delivered.filter {
            ready.contains($0) && !muted.contains($0) && !pass.excluded.contains($0) && spent[$0, default: 0] < budget
        }
        guard candidates.count > 1 else { return [] }
        var effects: [Effect] = []
        for member in members where candidates.contains(member) {
            let others = messages.filter { $0.id > pass.messageId && $0.sender != member && $0.isContent }
            guard !others.isEmpty else { continue }
            effects.append(.deliver(member: member, text: Briefing.reaction(name: member, messages: others)))
            spent[member, default: 0] += 1
            cursors[member] = messages.count
            due[member] = nil
        }
        return effects
    }

    /// A member's turn ended. The reaction pass waits for all of them before it opens.
    public mutating func memberFinished(_ member: String) {
        guard round?.started.contains(member) == true else { return }
        round?.waiting.remove(member)
    }

    /// A member will not answer this round (it exited, is stuck on a dialog, or was muted mid-round): the pass
    /// closes without it instead of waiting forever.
    public mutating func memberUnavailable(_ member: String) {
        round?.waiting.remove(member)
        round?.delivered.remove(member)
        round?.started.remove(member)
    }

    // MARK: state

    public mutating func mute(_ member: String) {
        muted.insert(member)
        due[member] = nil
        memberUnavailable(member)
    }

    public mutating func unmute(_ member: String) { muted.remove(member) }

    /// Everything the header needs: replies left, wrapping or not. The budget is per member, so what is
    /// reported is the smallest remaining — "at least this many left for everyone".
    public var status: (budgetLeft: Int, budget: Int, wrapping: Bool) {
        let left = members.map { budget - spent[$0, default: 0] }.min() ?? budget
        return (max(left, 0), budget, wrapping)
    }

    /// Replies `member` has left before the user must speak again.
    public func repliesLeft(for member: String) -> Int { max(budget - spent[member, default: 0], 0) }

    /// Whether a delivery is queued or in flight for `member` (the composer shows it as "queued").
    public func hasPendingDelivery(for member: String) -> Bool { due[member] != nil }

    nonisolated(unsafe) private static let wrapRegex = try! NSRegularExpression(
        pattern: #"\bwrap(?:ping)?\s+(?:it|this|things)?\s*up\b|^/wrap\b"#, options: [.caseInsensitive])

    /// chat.py's `WRAP_RE`: "wrap it up", "wrapping up", "/wrap" at the start of the message.
    public static func isWrapUp(_ text: String) -> Bool {
        let ns = text as NSString
        return wrapRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private struct ReactionRound: Sendable {
        let messageId: Int64
        /// Members still to finish their turn on this user message.
        var waiting: Set<String>
        /// Everyone the user's message went to, which is who the pass is offered to.
        var delivered: Set<String>
        /// Members whose delivery has actually gone out; the pass waits for all of them.
        var started: Set<String> = []
        /// Members a peer has already pulled back into the conversation with a mention.
        var excluded: Set<String> = []

        init(messageId: Int64, waiting: Set<String>) {
            self.messageId = messageId
            self.waiting = waiting
            self.delivered = waiting
        }
    }
}
