import Foundation

/// What a run directory says about itself. Derived from the files alone, so a run the app was in the middle
/// of when it quit — or one the CLI started — reads the same on the next launch: nothing about a run's
/// progress lives only in memory.
public struct RunState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Nothing has been recorded: the run directory exists and no member has been asked yet.
        case notStarted
        /// This round still has members to hear from.
        case answering(round: Int)
        /// Every member's final round is decided and the moderator has not produced a verdict.
        case awaitingModerator
        /// `verdict.md` holds the CLI's moderator-failure marker.
        case moderatorFailed(String)
        /// Fewer than two members answered, so there is nothing to synthesize (council.py `cmd_moderate`).
        case tooFewAnswers
        case complete
    }

    /// One member's round that has not been decided yet — what a resume would ask again.
    public struct Pending: Sendable, Equatable {
        public let member: String
        public let round: Int
        public init(member: String, round: Int) { self.member = member; self.round = round }
    }

    public var phase: Phase
    /// Members and rounds with no `.done` file, in run order.
    public var pending: [Pending]
    /// Members with an answer in the final round, which is what the moderator needs two of.
    public var answered: [String]
    public var score: Int?

    /// The CLI writes this into `verdict.md` when the moderator itself failed.
    public static let moderatorFailurePrefix = "(moderator failed:"

    public var isComplete: Bool { phase == .complete }

    /// True when work was started and stopped part way: the app was quit, or the CLI's run was abandoned.
    /// A run that has not been touched at all is not interrupted, it is simply new.
    public var isInterrupted: Bool {
        switch phase {
        case .notStarted, .complete, .tooFewAnswers: return false
        case .moderatorFailed: return true
        case .answering: return !answered.isEmpty || pending.count < expected
        case .awaitingModerator: return true
        }
    }

    /// How many member-rounds the run expects in total; used only to tell a fresh run from a half-done one.
    private var expected: Int

    public init(phase: Phase, pending: [Pending], answered: [String], score: Int? = nil, expected: Int = 0) {
        self.phase = phase
        self.pending = pending
        self.answered = answered
        self.score = score
        self.expected = expected
    }

    /// Reads the state off disk.
    public static func read(_ run: VerdictRun) -> RunState {
        if let verdict = run.verdict {
            let trimmed = verdict.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(moderatorFailurePrefix) {
                let reason = trimmed.dropFirst(moderatorFailurePrefix.count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " )\n"))
                return RunState(phase: .moderatorFailed(reason.isEmpty ? "the moderator failed" : reason),
                                pending: [], answered: answeredIn(run, round: run.rounds), expected: run.order.count)
            }
            return RunState(phase: .complete, pending: [], answered: answeredIn(run, round: run.rounds),
                            score: ConsensusScore.parse(verdict), expected: run.order.count)
        }

        var expected = 0
        var recorded = 0
        for round in 1...run.rounds {
            let due = participants(run, round: round)
            expected += due.count
            let missing = due.filter { run.done($0, round: round) == nil }
            recorded += due.count - missing.count
            if !missing.isEmpty {
                let pending = missing.map { Pending(member: $0, round: round) }
                let phase: Phase = (recorded == 0 && round == 1) ? .notStarted : .answering(round: round)
                return RunState(phase: phase, pending: pending, answered: answeredIn(run, round: round),
                                expected: expected)
            }
        }
        let answered = answeredIn(run, round: run.rounds)
        return RunState(phase: answered.count >= minimumAnswers ? .awaitingModerator : .tooFewAnswers,
                        pending: [], answered: answered, expected: expected)
    }

    /// council.py `cmd_moderate`: under two answers there is nothing to synthesize.
    public static let minimumAnswers = 2

    /// Who is asked in a round. Everyone in round 1; after that, only members that produced an answer in the
    /// previous round — a member that never replied has nothing to critique with, and its peers are told it
    /// produced nothing rather than being made to wait for it again.
    public static func participants(_ run: VerdictRun, round: Int) -> [String] {
        guard round > 1 else { return run.order }
        return run.order.filter { run.done($0, round: round - 1)?.isOK == true }
    }

    /// Members with a usable answer in `round`, in run order.
    public static func answeredIn(_ run: VerdictRun, round: Int) -> [String] {
        run.order.filter { run.done($0, round: round)?.isOK == true && !run.answer($0, round: round).isEmpty }
    }
}
