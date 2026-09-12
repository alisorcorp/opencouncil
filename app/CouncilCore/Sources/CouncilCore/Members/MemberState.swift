import Foundation

/// Where one member is, as the supervisor sees it. The states are the ones in the plan's diagram; the app maps
/// them to a dot, an activity line and — for the last two — a card with something the user can do about it.
public enum MemberState: Equatable, Sendable {
    /// No process, or one that exited cleanly.
    case notRunning
    /// Launched; its CLI has not reported a session yet.
    case starting
    /// A dialog is in the way before the CLI ever reached its prompt: folder trust, hook review, login.
    case blockedBeforeStart(reason: String)
    /// Idle at the prompt. The only state a delivery may be handed to.
    case prompted(attempts: Int)
    /// Sitting at the prompt with nothing in flight.
    case ready
    /// A turn is under way; `activity` is the current tool phrase when the CLI reports one.
    case working(activity: String?)
    /// A dialog is in the way mid-turn: a permission prompt, an elicitation.
    case blocked(reason: String)
    /// Gave up: the prompt was never accepted, the CLI failed, the process died, or an API error outlasted
    /// its retries. The user has to do something — the card offers what.
    case error(reason: String)

    /// True while the member cannot be given anything new.
    public var isBusy: Bool {
        switch self {
        case .prompted, .working, .blocked, .blockedBeforeStart, .starting: return true
        case .ready, .notRunning, .error: return false
        }
    }

    /// True when the member gave up. Its process may still be alive: an API error that outlasted its retries,
    /// or a prompt it never acknowledged, leaves the CLI sitting at its own prompt with nobody listening.
    public var hasGivenUp: Bool {
        if case .error = self { return true }
        return false
    }

    /// True when the user has to intervene; the app draws a card for these.
    public var needsAttention: Bool {
        switch self {
        case .blocked, .blockedBeforeStart, .error: return true
        default: return false
        }
    }

    public var reason: String? {
        switch self {
        case .blocked(let r), .blockedBeforeStart(let r), .error(let r): return r
        default: return nil
        }
    }
}
