import Foundation

/// Runs a verdict: who is asked what, in which round, and what becomes of the answers. Pure by construction,
/// like `ChatRouter` and `MemberSupervisor` — it holds no files and reads no clock of its own, so every rule
/// below is a unit test and the app layer only carries out effects.
///
/// The division of labour with `MemberSupervisor` is that a verdict member is a member with one delivery and
/// one expected post per round: the supervisor gets the prompt into the terminal and says when the turn ended;
/// this decides what the prompt says and what the answer means.
public struct VerdictOrchestrator: Sendable {
    public struct Timings: Sendable, Equatable {
        /// council.py's `wait_for_done` gives up on a member after half an hour.
        public var answerTimeout: TimeInterval = 1800
        public var moderatorTimeout: TimeInterval = 1800
        public init() {}
    }

    public struct Answer: Sendable, Equatable {
        public var text: String
        public var done: RunDone
        public init(text: String, done: RunDone) { self.text = text; self.done = done }
        public var isOK: Bool { done.isOK && !text.isEmpty }
    }

    public enum Phase: Sendable, Equatable {
        /// Nothing has been asked yet.
        case idle
        case asking(round: Int)
        case moderating
        case complete(score: Int?)
        /// The run stopped without a verdict; the string is why.
        case abandoned(String)
    }

    public enum Effect: Equatable, Sendable {
        /// Paste this whole prompt into the member's terminal and expect one post back.
        case ask(member: String, round: Int, text: String)
        /// Write `r<round>/<member>.md` and `r<round>/<member>.done`.
        case record(member: String, round: Int, answer: String, done: RunDone)
        /// This participant has nothing further to do in the run; its terminal can be stopped.
        case release(member: String)
        case moderate(member: String, text: String)
        /// The moderator answered: write `verdict.md` (with the reveal footer) and the transcript.
        case finish(verdict: String, score: Int?)
        /// The run ends with no verdict. `moderatorFailed` means the CLI's `(moderator failed: …)` marker goes
        /// into verdict.md, which is how a later reader tells a moderator that gave up from one never asked.
        case abandon(reason: String, moderatorFailed: Bool)
        /// A dim line for the user, worded as the CLI words it.
        case note(String)
    }

    public static let tooFewAnswers = "fewer than two members answered; there is nothing to synthesize"

    public let question: String
    public let order: [String]
    public let rounds: Int
    public let length: String
    public let moderator: String
    /// The name each member is shown under in prompts: its alias in an anonymous run.
    public let displays: [String: String]
    public var timings: Timings

    public private(set) var phase: Phase = .idle
    /// Members this round is still waiting on.
    public private(set) var outstanding: Set<String> = []
    private var answers: [Int: [String: Answer]] = [:]
    private var askedAt: [String: Date] = [:]
    private var moderatorAskedAt: Date?

    public init(question: String, order: [String], rounds: Int, length: String, moderator: String,
                displays: [String: String] = [:], answers: [Int: [String: Answer]] = [:],
                timings: Timings = Timings()) {
        self.question = question
        self.order = order
        self.rounds = max(rounds, 1)
        self.length = length
        self.moderator = moderator
        self.displays = displays
        self.answers = answers
        self.timings = timings
    }

    /// Convenience: seed from a run directory that already holds some answers (a resume).
    public init(run: VerdictRun, timings: Timings = Timings()) {
        var seeded: [Int: [String: Answer]] = [:]
        for round in 1...max(run.rounds, 1) {
            for member in run.order {
                guard let done = run.done(member, round: round) else { continue }
                seeded[round, default: [:]][member] = Answer(text: run.answer(member, round: round), done: done)
            }
        }
        var displays: [String: String] = [:]
        for member in run.order { displays[member] = run.display(member) }
        self.init(question: run.question, order: run.order, rounds: run.rounds, length: run.length,
                  moderator: run.moderatorName, displays: displays, answers: seeded, timings: timings)
        // A run that already ended does not begin again. Without this a completed directory would be read as
        // "every answer is in", and the moderator would be asked to synthesize a verdict it already wrote.
        switch RunState.read(run).phase {
        case .complete:
            phase = .complete(score: run.verdict.flatMap(ConsensusScore.parse))
        case .moderatorFailed(let reason):
            phase = .abandoned(reason)
        case .tooFewAnswers:
            phase = .abandoned(Self.tooFewAnswers)
        case .notStarted, .answering, .awaitingModerator:
            break
        }
    }

    // MARK: queries

    public func answer(_ member: String, round: Int) -> Answer? { answers[round]?[member] }

    /// Members with a usable answer in the final round: what the moderator gets, and what it needs two of.
    public var answeredMembers: [String] { okMembers(in: rounds) }

    public var isFinished: Bool {
        switch phase {
        case .complete, .abandoned: return true
        default: return false
        }
    }

    /// Whether this participant is being waited on right now, which is what the UI draws as "working".
    public func isWaiting(on member: String) -> Bool {
        if case .moderating = phase, member == moderator { return true }
        return outstanding.contains(member)
    }

    /// Who is asked in `round`: everyone in round 1, and after that only members that answered the round
    /// before — a member that produced nothing has nothing to critique with, so it is left out and said so.
    public func participants(in round: Int) -> [String] {
        round <= 1 ? order : okMembers(in: round - 1)
    }

    // MARK: the machine

    /// Picks up wherever the answers on disk left off: the first round with anything missing, else the
    /// moderator. Safe to call on a fresh run and on a resumed one.
    public mutating func begin(now: Date) -> [Effect] {
        guard case .idle = phase else { return [] }
        for round in 1...rounds {
            let due = participants(in: round).filter { answers[round]?[$0] == nil }
            guard due.isEmpty else { return startRound(round, asking: due, now: now) }
        }
        return closeRound(rounds, now: now)
    }

    /// The prompt actually reached the member's terminal. A member is asked as soon as the round opens, but a
    /// CLI that has not drawn its prompt yet cannot be pasted into for tens of seconds, and counting that as
    /// thinking time makes `elapsed` mean something different from the CLI's (which times the model call) and
    /// eats into the answer timeout.
    public mutating func delivered(_ member: String, now: Date) {
        if case .moderating = phase, member == moderator { moderatorAskedAt = now; return }
        guard outstanding.contains(member) else { return }
        askedAt[member] = now
    }

    /// A post arrived from a participant, as the log gave it up.
    ///
    /// A record nobody could read is a transport failure, not an answer. Its text is the app's own diagnostic,
    /// and because that text is not empty it used to be recorded as an `ok` answer: it could count toward the
    /// minimum for synthesis, be shown to the moderator as the member's position, and — from the moderator —
    /// complete the run as the verdict itself. It closes the turn as an error instead, which keeps the answer
    /// out of the run's files and keeps Retry available.
    public mutating func received(_ message: Message, now: Date) -> [Effect] {
        guard !message.isUnreadable else { return failed(message.sender, reason: Bus.unreadableReason, now: now) }
        return answered(message.sender, text: message.text, now: now)
    }

    /// A member posted its answer.
    public mutating func answered(_ member: String, text: String, now: Date) -> [Effect] {
        if case .moderating = phase, member == moderator { return moderated(text, now: now) }
        guard case .asking(let round) = phase, outstanding.contains(member) else { return [] }
        let elapsed = now.timeIntervalSince(askedAt[member] ?? now)
        let body = text.rstripped()
        guard !body.isEmpty else {
            return failed(member, reason: "posted an empty answer", now: now)
        }
        let done = RunDone(status: "ok", error: nil, elapsed: (elapsed * 10).rounded() / 10,
                           words: VerdictRun.words(body), finished: MessageTime.format(now))
        return finish(member, round: round, answer: body, done: done, now: now)
    }

    /// A member will not answer this round: its terminal died, it gave up, or it said nothing.
    public mutating func failed(_ member: String, reason: String, now: Date) -> [Effect] {
        if case .moderating = phase, member == moderator { return moderatorFailed(reason, now: now) }
        guard case .asking(let round) = phase, outstanding.contains(member) else { return [] }
        let elapsed = now.timeIntervalSince(askedAt[member] ?? now)
        let done = RunDone(status: "error", error: reason, elapsed: (elapsed * 10).rounded() / 10, words: 0,
                           finished: MessageTime.format(now))
        var effects: [Effect] = [.note("\(display(member)) did not answer: \(reason)")]
        effects += finish(member, round: round, answer: "", done: done, now: now)
        return effects
    }

    /// The moderator posted the verdict.
    public mutating func moderated(_ text: String, now: Date) -> [Effect] {
        guard case .moderating = phase else { return [] }
        let verdict = text.rstripped()
        guard !verdict.isEmpty else { return moderatorFailed("posted an empty verdict", now: now) }
        let score = ConsensusScore.parse(verdict)
        phase = .complete(score: score)
        moderatorAskedAt = nil
        return [.release(member: moderator), .finish(verdict: verdict, score: score)]
    }

    public mutating func moderatorFailed(_ reason: String, now: Date) -> [Effect] {
        guard case .moderating = phase else { return [] }
        phase = .abandoned(reason)
        moderatorAskedAt = nil
        return [.release(member: moderator), .abandon(reason: reason, moderatorFailed: true)]
    }

    /// Retry moderator on the verdict card: the answers are kept, only the synthesis runs again. A run that
    /// already has a verdict is not re-moderated — that would overwrite a good one with a second opinion
    /// nobody asked for.
    public mutating func retryModerator(now: Date) -> [Effect] {
        switch phase {
        case .abandoned, .moderating: break
        case .idle, .asking, .complete: return []
        }
        guard answeredMembers.count >= RunState.minimumAnswers else { return [] }
        return startModerator(now: now)
    }

    /// The timeouts. A member that has been asked and has said nothing for half an hour is recorded as having
    /// failed, exactly as the CLI stops waiting for it, so the moderator is not held up for ever by one member.
    public mutating func tick(now: Date) -> [Effect] {
        var effects: [Effect] = []
        if case .moderating = phase, let asked = moderatorAskedAt,
           now.timeIntervalSince(asked) >= timings.moderatorTimeout {
            return moderatorFailed(Self.timedOut(after: timings.moderatorTimeout), now: now)
        }
        guard case .asking = phase else { return [] }
        for member in order where outstanding.contains(member) {
            guard let asked = askedAt[member], now.timeIntervalSince(asked) >= timings.answerTimeout else { continue }
            effects += failed(member, reason: Self.timedOut(after: timings.answerTimeout), now: now)
            if isFinished { break }
        }
        return effects
    }

    public static func timedOut(after seconds: TimeInterval) -> String {
        "no answer in \(Int((seconds / 60).rounded())) minutes"
    }

    // MARK: rounds

    private mutating func startRound(_ round: Int, asking due: [String], now: Date) -> [Effect] {
        phase = .asking(round: round)
        outstanding = Set(due)
        var effects: [Effect] = []
        if round > 1 {
            for member in order where !participants(in: round).contains(member) {
                effects.append(.note("\(display(member)) is left out of round \(round): it did not answer round \(round - 1)"))
                effects.append(.release(member: member))
            }
        }
        for member in due {
            askedAt[member] = now
            effects.append(.ask(member: member, round: round, text: prompt(for: member, round: round)))
        }
        return effects
    }

    /// Records one member's round and, when it was the last the round was waiting for, moves the run on.
    private mutating func finish(_ member: String, round: Int, answer: String, done: RunDone,
                                 now: Date) -> [Effect] {
        answers[round, default: [:]][member] = Answer(text: answer, done: done)
        outstanding.remove(member)
        askedAt[member] = nil
        var effects: [Effect] = [.record(member: member, round: round, answer: answer, done: done)]
        guard outstanding.isEmpty else { return effects }
        effects += closeRound(round, now: now)
        return effects
    }

    /// A round is complete: either the next one starts, or the moderator does.
    private mutating func closeRound(_ round: Int, now: Date) -> [Effect] {
        if round < rounds {
            let next = participants(in: round + 1)
            if next.count >= RunState.minimumAnswers {
                return startRound(round + 1, asking: next, now: now)
            }
            // One member left cannot critique anybody: go straight to the verdict with what there is.
            var effects: [Effect] = [.note("not enough answers for round \(round + 1); going to the verdict")]
            effects += releaseEveryone()
            effects += moderateOrAbandon(now: now)
            return effects
        }
        var effects = releaseEveryone()
        effects += moderateOrAbandon(now: now)
        return effects
    }

    private mutating func moderateOrAbandon(now: Date) -> [Effect] {
        guard answeredMembers.count >= RunState.minimumAnswers else {
            phase = .abandoned(Self.tooFewAnswers)
            return [.abandon(reason: Self.tooFewAnswers, moderatorFailed: false)]
        }
        return startModerator(now: now)
    }

    private mutating func startModerator(now: Date) -> [Effect] {
        phase = .moderating
        outstanding = []
        moderatorAskedAt = now
        return [.moderate(member: moderator, text: moderatorPrompt())]
    }

    /// Every member is finished; the moderator is not released here even when it is also a member.
    private func releaseEveryone() -> [Effect] {
        order.filter { $0 != moderator }.map { .release(member: $0) }
    }

    // MARK: prompts

    private func prompt(for member: String, round: Int) -> String {
        var peers: [String] = []
        if round > 1 {
            let others = order.filter { $0 != member }
            // The order peers appear in is fixed per member per round (see `VerdictPrompts.peerOrder`); an
            // absent peer is shown as producing nothing rather than dropped, as council.py does.
            for peer in VerdictPrompts.peerOrder(others, for: member, round: round) {
                peers.append(answers[round - 1]?[peer]?.text ?? "")
            }
        }
        return VerdictPrompts.memberPaste(name: member, round: round, rounds: rounds, length: length,
                                          question: question, peerAnswers: peers,
                                          ownPrevious: answers[round - 1]?[member]?.text)
    }

    private func moderatorPrompt() -> String {
        let entries = order.map { member -> (label: String, answer: String?, error: String?) in
            let a = answers[rounds]?[member]
            guard let a, a.isOK else {
                return (display(member), nil, a?.done.error ?? "member did not finish")
            }
            return (display(member), a.text, nil)
        }
        return VerdictPrompts.moderatorPaste(name: moderator, question: question, rounds: rounds, answers: entries)
    }

    private func display(_ member: String) -> String { displays[member] ?? member }

    private func okMembers(in round: Int) -> [String] {
        order.filter { answers[round]?[$0]?.isOK == true }
    }
}
