import Foundation
import Observation
import CouncilCore

enum AgentStatus: Equatable {
    case notRunning, starting, ready, working(String?), blocked, error, muted

    var label: String {
        switch self {
        case .notRunning: return "not running"
        case .starting: return "starting…"
        case .ready: return "idle"
        case .working(let what): return what ?? "working…"
        case .blocked: return "needs attention"
        case .error: return "error"
        case .muted: return "muted"
        }
    }
}

struct AgentInfo: Identifiable, Equatable {
    let name: String
    let label: String
    let effort: String?
    let backend: String
    let colorIndex: Int
    var status: AgentStatus = .notRunning
    /// Asset name of the member's avatar image, when the catalog has one.
    var avatar: String? = nil

    var id: String { name }
}

enum DetailMode: Equatable {
    case conversation
    case terminal(String)
}

/// One member's answer in a verdict round.
struct VerdictAnswer: Identifiable, Equatable, Sendable {
    let member: String
    let label: String
    let alias: String?
    let text: String
    let done: RunDone?
    var id: String { member }
}

struct VerdictContent: Equatable, Sendable {
    let config: RunConfig
    let question: String
    let rounds: [[VerdictAnswer]]     // index 0 = round 1
    let verdict: String?
    let score: Int?
    let moderatorLabel: String
    /// What the run directory says about itself: complete, part way through, or never started.
    let state: RunState
}

/// Everything the detail pane needs for the selected session. Both kinds are live: a chat tails its bus, and a
/// verdict run re-reads its directory whenever its runtime writes an answer. Member statuses come from the
/// session's runtime when its members run in the app.
@Observable
@MainActor
final class SessionViewModel {
    let summary: SessionSummary
    private(set) var config: ChatConfig?
    private(set) var messages: [Message] = []
    private(set) var verdict: VerdictContent?
    private(set) var loadError: String?
    private(set) var startError: String?
    /// Set when starting was refused only because every live slot is taken; the picker offers to free one.
    var capReached = false
    private var pendingResume = false
    /// What a refused verdict was trying to do, so taking a slot carries on with it rather than guessing.
    private var pendingVerdictMode: VerdictRuntime.StartMode = .resume
    var detailMode: DetailMode = .conversation
    /// What the user has typed but not sent. It lives here, not in the composer, so switching to a member's
    /// terminal and back does not throw the draft away; it is saved with the session's app state too.
    var draft: String = ""

    private var baseAgents: [AgentInfo] = []
    private var tail: BusTail?
    private var appState: SessionAppState
    private let live: LiveSessions?
    /// Needed to start a verdict run: the run's hidden session directory is written from `council.toml`.
    private let paths: CouncilPaths?
    private let councilConfig: CouncilConfig?
    var onRead: ((String) -> Void)?
    /// Discard on an unfinished run: the session list owns deleting.
    var onDiscard: ((SessionSummary) -> Void)?

    init(summary: SessionSummary, live: LiveSessions? = nil, paths: CouncilPaths? = nil,
         councilConfig: CouncilConfig? = nil) {
        self.summary = summary
        self.live = live
        self.paths = paths
        self.councilConfig = councilConfig
        self.appState = SessionAppState.load(from: summary.directory)
    }

    var title: String { summary.displayTitle }
    var cwd: String? { appState.cwdOverride ?? summary.cwd }

    /// The runtime hosting this session's members, while they run in the app.
    var runtime: SessionRuntime? { live?.runtime(for: summary.id) }
    /// The runtime answering this verdict run's question, while it is being asked.
    var verdictRuntime: VerdictRuntime? { live?.verdict(for: summary.id) }
    var isLive: Bool { runtime != nil || verdictRuntime != nil }

    /// Members in order, with the live status when the session is running.
    var agents: [AgentInfo] {
        if let rt = verdictRuntime {
            return baseAgents.map { agent in
                var a = agent
                if let s = rt.statuses[agent.name] { a.status = s }
                return a
            }
        }
        guard let rt = runtime else { return baseAgents }
        return baseAgents.map { agent in
            var a = agent
            if let s = rt.statuses[agent.name] { a.status = s }
            if rt.muted.contains(agent.name) { a.status = .muted }
            return a
        }
    }

    func open() {
        switch summary.kind {
        case .chat: openChat()
        case .verdict: openVerdict()
        }
    }

    func close() {
        saveDraft()
        tail?.stop()
        tail = nil
    }

    /// Drafts are written on the way out rather than on every keystroke.
    func saveDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draft
        guard appState.draft != text else { return }
        updateState { $0.draft = text }
    }

    func toggleTerminal(for member: String) {
        detailMode = detailMode == .terminal(member) ? .conversation : .terminal(member)
    }

    // MARK: members

    /// Launches this chat's members inside the app. Refused past the live-session cap, or when another router
    /// (the CLI, or another window) holds this chat. `resume` continues each member's previous CLI session.
    func startMembers(resume: Bool = false) {
        guard let live, let config, summary.kind == .chat else { return }
        startError = nil
        do {
            try live.start(summary: summary, config: config, resume: resume)
            capReached = false
        } catch LiveSessions.StartError.capReached {
            // Refusing outright is no help when the user cannot see which chats hold the slots: offer them.
            pendingResume = resume
            capReached = true
        } catch {
            startError = error.localizedDescription
        }
    }

    /// True when this chat had members running the last time the app closed, so resuming is the obvious offer:
    /// Claude Code and Codex can pick their own sessions back up and keep the context they had.
    var wasLive: Bool { !isLive && appState.live && !appState.sessionIds.isEmpty }

    /// The live sessions that could make room, for the picker. Chats and runs both hold slots.
    var runningSessions: [(id: String, title: String, members: Int, since: Date?, kind: SessionKind)] {
        live?.running ?? []
    }

    /// Stops another session's members and starts this one in the slot it freed. Chats and runs share the cap
    /// and this sheet, so what gets started has to follow the session — `startMembers` accepts only chats, and
    /// a run that took a slot this way used to stop the other session and then quietly do nothing.
    func takeSlot(from id: String) {
        live?.stop(id)
        capReached = false
        if summary.kind == .verdict {
            startVerdict(mode: pendingVerdictMode)
        } else {
            startMembers(resume: pendingResume)
        }
    }

    /// What the user has to act on, in config order: dialogs in the way, and members that gave up.
    var attention: [(member: String, state: MemberState)] { runtime?.attention ?? verdictRuntime?.attention ?? [] }
    /// The whole-session problems (a missing project folder, a chat another router holds).
    var sessionProblems: [String] {
        ((runtime?.problems ?? []).filter { $0.member == "*" }.map(\.message))
            + ((verdictRuntime?.problems ?? []).filter { $0.member == "*" }.map(\.message))
    }

    func state(of member: String) -> MemberState {
        runtime?.state(of: member) ?? verdictRuntime?.state(of: member) ?? .notRunning
    }
    func isSlow(_ member: String) -> Bool { runtime?.isSlow(member) ?? false }
    func hasDeliveryInFlight(for member: String) -> Bool { runtime?.hasDeliveryInFlight(for: member) ?? false }
    func hint(for member: String) -> String? { runtime?.blockedHints[member] ?? verdictRuntime?.blockedHints[member] }

    // MARK: terminals
    //
    // A verdict's members are real interactive terminals in the app, exactly like a chat's — only the thing
    // driving them differs. The terminal pane used to read `runtime` alone, so a verdict member asking for
    // permission showed "is not running" on the one screen that could have answered it.

    var terminalHosts: [TerminalHost] { runtime?.orderedHosts ?? verdictRuntime?.orderedHosts ?? [] }
    func terminalHost(for member: String) -> TerminalHost? {
        runtime?.host(for: member) ?? verdictRuntime?.host(for: member)
    }
    var lockedMembers: Set<String> { runtime?.lockedMembers ?? verdictRuntime?.lockedMembers ?? [] }
    /// The two runtimes each declare their own `Problem`, so this reads them one at a time rather than
    /// coalescing the arrays.
    func problem(for member: String) -> String? {
        func mine(_ name: String) -> Bool { name == member || name == "*" }
        if let p = runtime?.problems.first(where: { mine($0.member) }) { return p.message }
        if let p = verdictRuntime?.problems.first(where: { mine($0.member) }) { return p.message }
        return nil
    }

    /// Retry on a card: relaunch that member alone.
    func restart(_ member: String) {
        if let rt = verdictRuntime { rt.restart(member); return }
        guard let live, let rt = runtime else { return }
        rt.restart(member, environment: live.launchEnvironment)
    }

    /// Pick folder on a card: the chat runs somewhere else from now on.
    func setProjectFolder(_ url: URL) {
        runtime?.setProjectFolder(url)
        updateState { $0.cwdOverride = url.path }
    }

    func stopMembers() {
        live?.stop(summary.id)
        if case .terminal = detailMode { detailMode = .conversation }
    }

    // MARK: sending

    /// Posts the user's message. Sending is what makes a read-only chat live: members start, get briefed and
    /// then receive the message. If they cannot start (no free slot, missing folder) the message is still
    /// written to the log, so nothing the user typed is lost and the CLI can pick the chat up.
    func send(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, summary.kind == .chat else { return }
        // Resume when there is something to resume. The banner above the composer offers it, but answering the
        // question in the box is the same act — and starting fresh here threw away every member's CLI session
        // without saying so, leaving them to read the chat back before they could answer.
        if !isLive { startMembers(resume: wasLive) }
        do {
            if let rt = runtime {
                try rt.post(message)
            } else {
                try Bus(directory: summary.directory).append(sender: Message.userSender, text: message,
                                                             members: config?.order ?? [])
            }
        } catch {
            startError = error.localizedDescription
        }
    }

    // MARK: routing controls

    /// Replies left in this round and whether the council is wrapping up; nil when the chat is not live.
    var routerStatus: (budgetLeft: Int, budget: Int, wrapping: Bool)? { runtime?.routerStatus }

    func isMuted(_ member: String) -> Bool { runtime?.muted.contains(member) ?? false }

    func setMuted(_ member: String, _ muted: Bool) { runtime?.setMuted(member, muted) }

    /// The chat is not always live; a budget set while it is read-only is picked up when its members start.
    func setBudget(_ n: Int) {
        let n = max(1, n)
        if let rt = runtime {
            rt.setBudget(n)
        } else {
            updateState { $0.budget = n }
        }
    }

    /// `/budget n` typed in the composer. The CLI prints the change; the app records it in the chat, so both
    /// sides of a shared session can see it happened.
    func setBudget(fromCommand n: Int) {
        setBudget(n)
        try? Bus(directory: summary.directory).append(
            sender: Message.systemSender, text: "reply budget set to \(max(n, 1)) per member",
            kind: Message.kindNote, members: config?.order ?? [])
    }

    // MARK: chat

    private func openChat() {
        let dir = summary.directory
        do {
            let cfg = try ChatConfig.load(from: dir)
            config = cfg
            baseAgents = cfg.order.enumerated().map { i, name in
                let m = cfg.members[name]
                let split = ChatConfig.splitEffortSuffix(m?.label ?? name)
                return AgentInfo(name: name, label: split.label, effort: split.effort ?? cfg.effort,
                                 backend: m?.backend ?? "?", colorIndex: i,
                                 avatar: AvatarCatalog.imageName(member: name, backend: m?.backend, model: m?.model))
            }
            messages = try Bus(directory: dir).readAll()
            draft = appState.draft ?? ""
        } catch {
            loadError = error.localizedDescription
            return
        }
        markRead()
        let t = BusTail(bus: Bus(directory: dir)) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        t.start(replayExisting: false)
        tail = t
    }

    /// Re-reads the log and keeps what it gained. By position, not by id: ids are nanosecond timestamps and
    /// two members can post in the same one, which would make a matching-by-id merge drop a reply.
    private func reload() {
        let all = (try? Bus(directory: summary.directory).readAll()) ?? []
        guard all.count > messages.count else { return }
        messages = all
        markRead()
    }

    /// Records one change to this session's `app.json`, keeping whatever the runtime has written to the same
    /// file. Both hold their own copy, so neither may write its copy back whole.
    private func updateState(_ edit: (inout SessionAppState) -> Void) {
        do { appState = try SessionAppState.update(in: summary.directory, edit) }
        catch { edit(&appState) }       // the file could not be written; at least keep this session consistent
    }

    /// The user is looking at this session, so everything in it counts as seen.
    func markRead() {
        guard let last = messages.last?.id, appState.lastSeenId != last else { return }
        updateState { $0.lastSeenId = last }
        onRead?(summary.id)
    }

    // MARK: verdict

    private func openVerdict() {
        reloadVerdict()
        verdictRuntime?.onChanged = { [weak self] in self?.reloadVerdict() }
    }

    private func reloadVerdict() {
        let dir = summary.directory
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Self.loadVerdict(from: dir) }.value
            self?.apply(result)
        }
    }

    /// Asks the council. The same call resumes an interrupted run: the orchestrator reads what is on disk and
    /// asks only for the answers that are missing, so nothing already paid for is asked again.
    func startVerdict(mode: VerdictRuntime.StartMode = .resume) {
        guard let live, let paths, let councilConfig, summary.kind == .verdict else {
            startError = "The council folder is not loaded."
            return
        }
        startError = nil
        pendingVerdictMode = mode
        do {
            let run = try VerdictRun(directory: summary.directory)
            // A run the CLI created has no hidden session directory yet, and one the app created may predate a
            // change to council.toml; writing it here keeps both cases working.
            let sessionDir = try RunFactory(paths: paths, config: councilConfig)
                .prepareSessions(in: summary.directory, cwd: runCwd(for: run))
            let sessionConfig = try ChatConfig.load(from: sessionDir)
            let rt = try live.startVerdict(summary: summary, run: run, sessionDirectory: sessionDir,
                                           sessionConfig: sessionConfig, mode: mode)
            rt.onChanged = { [weak self] in self?.reloadVerdict() }
            capReached = false
            reloadVerdict()
        } catch LiveSessions.StartError.capReached {
            capReached = true
        } catch {
            startError = error.localizedDescription
        }
    }

    /// Where a run's members work. The CLI runs them in the run directory; the app keeps that, so a member
    /// that writes a scratch file leaves it with the run rather than in whatever folder was last used.
    private func runCwd(for run: VerdictRun) -> URL {
        appState.cwdOverride.map { URL(fileURLWithPath: $0) } ?? run.directory
    }

    /// Retry moderator on the verdict card: the answers stay, only the synthesis runs again.
    ///
    /// A moderator that gave up ends the run, which takes its runtime out of the live registry — so by the time
    /// the user presses Retry there is usually nothing live to ask. Starting it again is not enough either: the
    /// failure is recorded on disk, so a fresh orchestrator reads the run back as abandoned and refuses to do
    /// anything. The retry has to say that is what it is.
    func retryModerator() {
        if let rt = verdictRuntime { rt.retryModerator(); return }
        startVerdict(mode: .moderator)
    }

    func stopVerdict() { live?.stop(summary.id) }

    /// Discard on an interrupted run: the whole directory goes, as a session's Delete does.
    func discardRun() {
        live?.stop(summary.id)
        onDiscard?(summary)
    }

    /// What the run directory says about itself, whether or not it is live.
    var runState: RunState? { verdict?.state }

    /// True while this run's members are being asked. `nil` phase means it is not live.
    var runPhase: VerdictOrchestrator.Phase? { verdictRuntime?.phase }

    /// Who the run is waiting on right now, for the card spinner.
    func isWaiting(on member: String) -> Bool { verdictRuntime?.isWaiting(on: member) ?? false }

    /// What the run has said about itself: who was left out, who did not answer.
    var runNotes: [String] { verdictRuntime?.notes ?? [] }

    nonisolated private static func loadVerdict(from dir: URL) -> Result<VerdictContent, Error> {
        do {
            let cfg = try RunConfig.load(from: dir)
            let question = (try? String(contentsOf: dir.appendingPathComponent("question.md"), encoding: .utf8)) ?? ""
            var rounds: [[VerdictAnswer]] = []
            for r in 1...max(cfg.rounds, 1) {
                rounds.append(cfg.order.map { m in
                    let member = cfg.members[m]
                    let label = member?.label ?? m
                    let alias = cfg.anonymous ? member?.alias : nil
                    let text = (try? String(contentsOf: cfg.answerURL(m, round: r, in: dir), encoding: .utf8)) ?? ""
                    return VerdictAnswer(member: m, label: label, alias: alias, text: text,
                                         done: RunDone.load(cfg.doneURL(m, round: r, in: dir)))
                })
            }
            let verdictText = try? String(contentsOf: dir.appendingPathComponent("verdict.md"), encoding: .utf8)
            return .success(VerdictContent(config: cfg, question: question, rounds: rounds, verdict: verdictText,
                                           score: verdictText.flatMap(ConsensusScore.parse),
                                           moderatorLabel: cfg.moderator.label ?? cfg.moderator.name ?? "moderator",
                                           state: RunState.read(VerdictRun(directory: dir, config: cfg))))
        } catch {
            return .failure(error)
        }
    }

    private func apply(_ result: Result<VerdictContent, Error>) {
        switch result {
        case .success(let v):
            verdict = v
            var agents = v.config.order.enumerated().map { i, name in
                let m = v.config.members[name]
                return AgentInfo(name: name, label: m?.label ?? name, effort: nil, backend: m?.backend ?? "?", colorIndex: i,
                                 avatar: AvatarCatalog.imageName(member: name, backend: m?.backend, model: m?.model))
            }
            // The moderator has a terminal of its own when it is not already at the table, and the user should
            // be able to open it like any other.
            if let mod = v.config.moderator.name, !v.config.order.contains(mod) {
                agents.append(AgentInfo(name: mod, label: v.config.moderator.label ?? mod, effort: nil,
                                        backend: v.config.moderator.backend ?? "?", colorIndex: agents.count,
                                        avatar: AvatarCatalog.imageName(member: mod,
                                                                        backend: v.config.moderator.backend,
                                                                        model: v.config.moderator.model)))
            }
            baseAgents = agents
        case .failure(let e):
            loadError = e.localizedDescription
        }
    }
}
