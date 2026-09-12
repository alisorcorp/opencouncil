import Foundation
import CouncilCore

/// Reads members' terminals for the things their hooks never say. A CLI sitting in a pre-session dialog
/// (folder trust, hook review, login) reports nothing at all; Codex only reports SessionStart with its first
/// prompt, so a member that has drawn its prompt and gone quiet has to be recognised by eye; and a member
/// stuck on an API error line mid-delivery will sit there until somebody nudges it.
///
/// Kept apart from the runtimes because both a chat and a verdict run need exactly this, and these heuristics
/// are the most delicate code in the app: one copy, one place to fix them.
@MainActor
final class ScreenWatcher {
    /// What the screen showed for a blocked member, for the sidebar and the terminal pane.
    private(set) var blockedHints: [String: String] = [:]
    /// Members whose blocked state came from the screen rather than from a hook.
    private(set) var blocked: Set<String> = []
    /// Each member's last visible screen and when it last changed for real.
    private var screens: [String: (lines: [String], since: Date)] = [:]

    /// A screen that has not changed for this long is quiescent enough to be read for an API error, as
    /// chat.py's `wait_quiet` does before it nudges a member.
    static let apiErrorQuietFor: TimeInterval = 20
    /// How much of the screen is read. Enough for a dialog and its prompt, not so much that an old error line
    /// scrolls back into view.
    static let visibleLines = 40

    enum Signal: Equatable {
        case event(MemberEvent)
        case apiError(String)
    }

    /// Seconds the member's visible screen has been unchanged, as last measured (diagnostics).
    func stableSeconds(for member: String, now: Date = Date()) -> TimeInterval? {
        screens[member].map { now.timeIntervalSince($0.since) }
    }

    /// Everything about this member is forgotten: it is being relaunched, or it has stopped.
    func forget(_ member: String) {
        screens[member] = nil
        blocked.remove(member)
        blockedHints[member] = nil
    }

    func forgetAll() {
        screens = [:]
        blocked = []
        blockedHints = [:]
    }

    /// A hook spoke, which is better evidence than any screen: drop a block this watcher inferred.
    @discardableResult
    func hookSpoke(for member: String) -> Bool {
        guard blocked.remove(member) != nil else { return false }
        blockedHints[member] = nil
        return true
    }

    /// One member's screen, once. Returns what to tell its supervisor.
    func poll(member: String, host: TerminalHost, state: MemberState, hasDeliveryInFlight: Bool,
              launchedAt: Date, now: Date) -> [Signal] {
        // Two screens are worth reading: one that has not reached its prompt yet, and one that is meant to be
        // answering right now. Anything else is a member working, and its output is nobody's business.
        let launching = state == .starting || (blocked.contains(member) && state.needsAttention)
        let answering = hasDeliveryInFlight && state.isWorking
        guard launching || answering else { screens[member] = nil; return [] }

        let lines = host.recentLines(Self.visibleLines)
        // Compare words only: decoration animations (Codex's twinkling braille, spinners, block cursors) must
        // not keep a member "starting" for ever; a remaining one- or two-character wobble is cosmetic too.
        let words = ScreenHeuristics.normalized(lines)
        if let previous = screens[member] {
            if previous.lines != words {
                let since = ScreenHeuristics.isCosmeticChange(from: previous.lines, to: words) ? previous.since : now
                screens[member] = (words, since)
            }
        } else {
            screens[member] = (words, now)
        }
        let stableFor = now.timeIntervalSince(screens[member]?.since ?? now)

        if answering {
            guard stableFor >= Self.apiErrorQuietFor, let error = ScreenHeuristics.trailingError(in: lines) else {
                return []
            }
            screens[member] = nil      // the nudge redraws the screen; start the clock again
            return [.apiError(error)]
        }
        if let dialog = ScreenHeuristics.blockingDialog(in: lines) {
            blockedHints[member] = "\(dialog.reason): \(dialog.hint)"
            return blocked.insert(member).inserted ? [.event(.blocked(reason: dialog.reason))] : []
        }
        var signals: [Signal] = []
        if blocked.remove(member) != nil {
            blockedHints[member] = nil
            signals.append(.event(.unblocked))
        }
        if ScreenHeuristics.looksReady(lines: lines, outputBytes: host.outputBytes, screenStableFor: stableFor,
                                       launchedAt: launchedAt, now: now) {
            screens[member] = nil
            signals.append(.event(.started(sessionId: nil, reason: "settled screen")))
        }
        return signals
    }
}

extension MemberState {
    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}
