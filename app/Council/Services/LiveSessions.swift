import Foundation
import Observation
import CouncilCore

/// Registry of sessions whose members run inside the app. Runtimes outlive the detail pane: selecting another
/// session keeps its members running so their posts and badges stay meaningful. Capped so forgotten sessions
/// cannot pile up terminals; a picker replaces the plain refusal in the routing unit.
@Observable
@MainActor
final class LiveSessions {
    enum StartError: LocalizedError {
        case capReached(Int)
        case notAChat
        case notARun
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .capReached(let n): return "\(n) sessions already have members running. Stop one of them first."
            case .notAChat: return "Only chats can run members."
            case .notARun: return "Only verdict runs can be asked."
            case .refused(let why): return why
            }
        }
    }

    /// Something from any live chat that the user might want to know about, wherever they are.
    enum Notice: Equatable {
        case post(session: String, title: String, body: String, isHello: Bool)
        case attention(session: String, title: String, body: String)
        case verdict(session: String, title: String, body: String)

        var session: String {
            switch self {
            case .post(let s, _, _, _), .attention(let s, _, _), .verdict(let s, _, _): return s
            }
        }

        var event: NotificationPolicy.Event {
            switch self {
            case .post(_, _, _, let isHello): return .post(isHello: isHello)
            case .attention: return .card
            case .verdict: return .verdict
            }
        }
    }

    static let cap = 3
    let launchEnvironment: MemberLaunchEnvironment
    private(set) var runtimes: [String: SessionRuntime] = [:]
    /// Verdict runs with members answering right now. They hold a slot under the same cap: a run is three or
    /// four terminals, exactly like a chat.
    private(set) var verdicts: [String: VerdictRuntime] = [:]
    /// Set by the app environment: where notices go.
    var onNotice: ((Notice) -> Void)?
    /// Called when a chat goes live, which is when asking for notification permission makes sense.
    var onSessionStarted: (() -> Void)?

    init(launchEnvironment: MemberLaunchEnvironment) {
        self.launchEnvironment = launchEnvironment
    }

    func runtime(for id: String) -> SessionRuntime? { runtimes[id] }
    func verdict(for id: String) -> VerdictRuntime? { verdicts[id] }
    var count: Int { runtimes.count + verdicts.count }
    var isAtCap: Bool { count >= Self.cap }

    /// The sessions holding a slot, for the picker the user gets when the cap is in the way. Runs hold slots
    /// alongside chats, so the kind travels with each row — the picker has to name what it is offering to stop.
    var running: [(id: String, title: String, members: Int, since: Date?, kind: SessionKind)] {
        let chats = runtimes.values.map { ($0.id, $0.config.title ?? $0.id, $0.members.count, $0.startedAt, SessionKind.chat) }
        let runs = verdicts.values.map { ($0.id, $0.run.config.questionPreview, $0.participants.count, $0.startedAt, SessionKind.verdict) }
        return (chats + runs).sorted { ($0.3 ?? .distantPast) < ($1.3 ?? .distantPast) }
    }

    @discardableResult
    func start(summary: SessionSummary, config: ChatConfig, resume: Bool = false) throws -> SessionRuntime {
        if let existing = runtimes[summary.id] { return existing }
        guard summary.kind == .chat else { throw StartError.notAChat }
        guard count < Self.cap else { throw StartError.capReached(count) }
        let rt = SessionRuntime(id: summary.id, directory: summary.directory, config: config)
        let title = config.title ?? summary.displayTitle
        rt.onPost = { [weak self] member, text, isHello in
            let label = config.members[member]?.label ?? member
            self?.onNotice?(.post(session: summary.id, title: "\(label) · \(title)",
                                  body: String(text.prefix(180)), isHello: isHello))
        }
        rt.onAttention = { [weak self] member, state in
            let label = config.members[member]?.label ?? member
            self?.onNotice?(.attention(session: summary.id, title: "\(label) needs you · \(title)",
                                       body: state.reason ?? "waiting in its terminal"))
        }
        rt.start(environment: launchEnvironment, resume: resume)
        // A session that could not launch anything (locked by the CLI, missing folder) must not be registered:
        // it would look live in the sidebar and hold a slot under the cap.
        guard rt.isRunning else {
            rt.stop()
            throw StartError.refused(rt.problems.first { $0.member == "*" }?.message
                                     ?? rt.problems.first?.message ?? "No members could start.")
        }
        runtimes[summary.id] = rt
        onSessionStarted?()
        return rt
    }

    /// Starts a verdict run: every member gets a hidden terminal, is asked the question and answers with
    /// `council post`. Resuming is the same call — the orchestrator reads what is already on disk and asks
    /// only for what is missing.
    @discardableResult
    func startVerdict(summary: SessionSummary, run: VerdictRun, sessionDirectory: URL,
                      sessionConfig: ChatConfig,
                      mode: VerdictRuntime.StartMode = .resume) throws -> VerdictRuntime {
        if let existing = verdicts[summary.id] { return existing }
        guard summary.kind == .verdict else { throw StartError.notARun }
        guard count < Self.cap else { throw StartError.capReached(count) }
        let rt = VerdictRuntime(id: summary.id, run: run, sessionDirectory: sessionDirectory,
                                sessionConfig: sessionConfig)
        let title = run.config.questionPreview
        rt.onAttention = { [weak self] member, state in
            let label = run.label(member)
            self?.onNotice?(.attention(session: summary.id, title: "\(label) needs you · \(title)",
                                       body: state.reason ?? "waiting in its terminal"))
        }
        rt.onFinished = { [weak self] score, reason in
            let head = score.map { "Verdict ready · consensus \($0)/100" } ?? "Verdict run finished"
            self?.onNotice?(.verdict(session: summary.id, title: head, body: reason ?? title))
            self?.verdicts[summary.id] = nil
        }
        rt.start(environment: launchEnvironment, mode: mode)
        guard rt.isRunning else {
            rt.stop()
            throw StartError.refused(rt.problems.first { $0.member == "*" }?.message
                                     ?? rt.problems.first?.message ?? "No members could start.")
        }
        verdicts[summary.id] = rt
        onSessionStarted?()
        return rt
    }

    func stop(_ id: String) {
        if let rt = runtimes.removeValue(forKey: id) { rt.stop() }
        if let rt = verdicts.removeValue(forKey: id) { rt.stop() }
    }

    func stopAll() {
        for id in Array(runtimes.keys) + Array(verdicts.keys) { stop(id) }
    }
}
