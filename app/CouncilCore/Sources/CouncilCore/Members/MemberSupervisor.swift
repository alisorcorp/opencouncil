import Foundation

/// One state machine per member, driven by hook events, bus posts and a clock. It decides when a prompt is
/// pasted, when it is pasted again, when a member has said all it is going to say, and when to give up — so
/// R14 holds: every delivery ends in a post, a "nothing to add" note, or a card.
///
/// Pure by construction: it performs no I/O and reads no clock of its own. The caller hands it events with a
/// time and carries out the effects it returns, which makes every arrow of the diagram a unit test.
public struct MemberSupervisor: Sendable {
    public struct Timings: Sendable, Equatable {
        /// A launched member that says nothing at all for this long is an error, as in the CLI.
        public var readyTimeout: TimeInterval = 300
        /// How long to wait for the CLI to acknowledge a pasted prompt before pasting it again.
        public var pasteAck: TimeInterval = 15
        /// A turn longer than this is reported as slow. It is not cancelled: long turns are legitimate.
        public var slowTurn: TimeInterval = 900
        /// Attempts at one delivery, counting the first.
        public var pasteAttempts = 3
        /// Retries after an API error appears on screen, as in chat.py's `wait_quiet`.
        public var apiErrorRetries = 2

        public init() {}
    }

    public enum Effect: Equatable, Sendable {
        /// Paste this text into the member's terminal and lock its input.
        case paste(member: String, text: String)
        /// The terminal may be typed into again.
        case unlock(member: String)
        /// A dim note for the bus, worded as the CLI words it.
        case note(String)
        /// Ledger: a delivery began.
        case open(Delivery)
        /// Ledger: another attempt at the same delivery.
        case attempt(id: String, attempts: Int)
        /// Ledger: how the delivery ended.
        case close(id: String, outcome: DeliveryOutcome, postId: Int64?)
        /// The member's turn is over (the router's reaction pass waits for this).
        case finished(member: String)
        /// The member will not answer this round.
        case unavailable(member: String)
    }

    public static let noSignOfLife = "no sign of life five minutes after launch"
    public static let didNotAcceptPrompt = "did not accept the prompt"
    public static let apiErrorGaveUp = "kept failing with an API error"

    public let members: [String]
    public var timings: Timings

    private var states: [String: MemberState] = [:]
    /// When the current state began, for the timeouts.
    private var since: [String: Date] = [:]
    private var pending: [String: Pending] = [:]

    private struct Pending: Sendable {
        var delivery: Delivery
        var text: String
        var sentAt: Date
        var acknowledged = false
        var apiErrorRetries = 0
        var postId: Int64?
    }

    public init(members: [String], timings: Timings = Timings()) {
        self.members = members
        self.timings = timings
        for m in members { states[m] = .notRunning }
    }

    public func state(of member: String) -> MemberState { states[member] ?? .notRunning }

    /// Everything the delivery loop needs: a member that is running, idle and not mid-paste.
    public func isReady(_ member: String) -> Bool { state(of: member) == .ready }

    /// True when a turn has been running long enough to be worth mentioning. Not an error.
    public func isSlow(_ member: String, now: Date) -> Bool {
        guard case .working = state(of: member), let start = since[member] else { return false }
        return now.timeIntervalSince(start) >= timings.slowTurn
    }

    /// Whether a delivery is in flight for this member (the composer shows it as queued).
    public func hasDeliveryInFlight(for member: String) -> Bool { pending[member] != nil }

    // MARK: the machine

    /// The process has been launched (or relaunched after an error).
    public mutating func launched(_ member: String, now: Date) {
        set(member, .starting, now: now)
        pending[member] = nil
    }

    /// Hands `text` to a member and opens a ledger entry for it. `upTo` is the highest bus id the text carries,
    /// so a post from an earlier turn cannot be mistaken for the answer to this one.
    public mutating func send(_ text: String, to member: String, upTo messageId: Int64, now: Date) -> [Effect] {
        let delivery = Delivery(member: member, opened: MessageTime.format(now), upToMessageId: messageId,
                                text: text)
        pending[member] = Pending(delivery: delivery, text: text, sentAt: now)
        set(member, .prompted(attempts: 1), now: now)
        return [.open(delivery), .paste(member: member, text: text)]
    }

    /// A member posted to the bus. Only a post newer than the delivery counts as its answer.
    public mutating func posted(member: String, messageId: Int64, now: Date) {
        guard var p = pending[member], messageId > p.delivery.upToMessageId else { return }
        p.postId = messageId
        pending[member] = p
    }

    public mutating func apply(_ event: MemberEvent, to member: String, now: Date) -> [Effect] {
        switch event {
        case .started:
            if case .working = state(of: member) { return [] }   // a mid-turn session event changes nothing
            if state(of: member) != .ready { set(member, .ready, now: now) }
            return []

        case .turnStarted:
            if var p = pending[member] {
                p.acknowledged = true       // the prompt landed; no more re-pastes for this delivery
                pending[member] = p
            }
            // The state changes here, so the clock `isSlow` reads measures the turn and not the paste.
            set(member, .working(activity: nil), now: now)
            return [.unlock(member: member)]

        case .toolStarted(_, let activity):
            if case .working = state(of: member) { states[member] = .working(activity: activity) }
            return []

        case .toolEnded:
            if case .working = state(of: member) { states[member] = .working(activity: nil) }
            return []

        case .turnEnded:
            var effects: [Effect] = []
            effects += closePending(member, at: now)
            set(member, .ready, now: now)
            effects.append(.finished(member: member))
            return effects

        case .blocked(let reason):
            let blocked: MemberState = hasStarted(member) ? .blocked(reason: reason)
                                                          : .blockedBeforeStart(reason: reason)
            set(member, blocked, now: now)
            return [.unavailable(member: member)]

        case .unblocked:
            switch state(of: member) {
            case .blockedBeforeStart: set(member, .starting, now: now)
            case .blocked: set(member, .working(activity: nil), now: now)
            default: break
            }
            return []

        case .failed(let message):
            var effects = close(member, outcome: .failed, at: now)
            set(member, .error(reason: message), now: now)
            effects.append(.unavailable(member: member))
            return effects

        case .ended:
            return []   // the process exit that follows decides between not running and error
        }
    }

    /// The process is gone. A clean exit is not an error; anything else is, and an open delivery died with it.
    public mutating func exited(_ member: String, status: Int32?, now: Date) -> [Effect] {
        var effects = close(member, outcome: .failed, at: now)
        if let status, status != 0 {
            set(member, .error(reason: "exited with status \(status)"), now: now)
        } else {
            set(member, .notRunning, now: now)
        }
        effects.append(.unavailable(member: member))
        return effects
    }

    /// The member's screen ends on an API error line (chat.py's `trailing_error`). Nudge it to try again, twice,
    /// and then give up — an agent stuck behind a 529 will otherwise sit there until the user notices.
    public mutating func sawApiError(_ line: String, for member: String, now: Date) -> [Effect] {
        guard var p = pending[member] else { return [] }
        guard p.apiErrorRetries < timings.apiErrorRetries else {
            var effects = close(member, outcome: .failed, at: now)
            set(member, .error(reason: Self.apiErrorGaveUp), now: now)
            effects.append(.unlock(member: member))
            effects.append(.unavailable(member: member))
            return effects
        }
        p.apiErrorRetries += 1
        p.sentAt = now
        pending[member] = p
        return [.note("\(member) hit an API error (\(line.prefix(80))); retrying"),
                .paste(member: member, text: Briefing.retryPrompt(name: member))]
    }

    /// The timeouts: a member that never spoke, and a prompt that was never acknowledged.
    public mutating func tick(now: Date) -> [Effect] {
        var effects: [Effect] = []
        for member in members {
            switch state(of: member) {
            case .starting:
                if let start = since[member], now.timeIntervalSince(start) >= timings.readyTimeout {
                    set(member, .error(reason: Self.noSignOfLife), now: now)
                    effects.append(.unavailable(member: member))
                }
            case .prompted(let attempts):
                guard var p = pending[member], !p.acknowledged,
                      now.timeIntervalSince(p.sentAt) >= timings.pasteAck else { continue }
                if attempts < timings.pasteAttempts {
                    p.sentAt = now
                    p.delivery.attempts = attempts + 1
                    pending[member] = p
                    states[member] = .prompted(attempts: attempts + 1)
                    effects.append(.attempt(id: p.delivery.id, attempts: attempts + 1))
                    effects.append(.paste(member: member, text: p.text))
                } else {
                    effects += close(member, outcome: .failed, at: now)
                    effects.append(.note("\(member) \(Self.didNotAcceptPrompt)"))
                    set(member, .error(reason: Self.didNotAcceptPrompt), now: now)
                    effects.append(.unlock(member: member))
                    effects.append(.unavailable(member: member))
                }
            default:
                continue
            }
        }
        return effects
    }

    // MARK: helpers

    /// True once the member has reached its prompt at least once, which is what separates a dialog in the way
    /// of the launch from one in the way of a turn.
    private func hasStarted(_ member: String) -> Bool {
        switch state(of: member) {
        case .starting, .notRunning, .blockedBeforeStart: return false
        default: return true
        }
    }

    private mutating func set(_ member: String, _ state: MemberState, now: Date) {
        guard states[member] != state else { return }
        states[member] = state
        since[member] = now
    }

    /// Ends an open delivery with the outcome the turn earned: a post, or a note saying there was none.
    private mutating func closePending(_ member: String, at now: Date) -> [Effect] {
        guard let p = pending[member] else { return [] }
        pending[member] = nil
        if let postId = p.postId {
            return [.close(id: p.delivery.id, outcome: .posted, postId: postId)]
        }
        return [.close(id: p.delivery.id, outcome: .nothingToAdd, postId: nil),
                .note("\(member) had nothing to add")]
    }

    /// Ends an open delivery without a verdict on what the member said — it failed, or it went away.
    private mutating func close(_ member: String, outcome: DeliveryOutcome, at now: Date) -> [Effect] {
        guard let p = pending[member] else { return [] }
        pending[member] = nil
        return [.close(id: p.delivery.id, outcome: outcome, postId: p.postId)]
    }
}
