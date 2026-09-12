import Foundation
import Observation
import CouncilCore

/// A live verdict run. The members are the same interactive terminals a chat uses — the app has no
/// non-interactive channel to Claude Code or Codex — so each one is asked its question by paste and answers
/// with `council post`. Two pure engines decide everything: `VerdictOrchestrator` (which round, who is asked,
/// what an answer means) and `MemberSupervisor` (getting one prompt into one terminal and knowing when the
/// turn ended). This type performs their effects and owns the I/O.
///
/// Everything a member writes lands in the run's hidden `.app/` directory, so `runs/<run>/` itself holds only
/// what the CLI put there: `question.md`, `config.json`, `r<N>/…`, `verdict.md`, `transcript.md`.
@Observable
@MainActor
final class VerdictRuntime {
    struct Problem: Equatable {
        let member: String    // "*" for the whole run
        let message: String
    }

    let id: String
    /// The run directory the CLI also reads.
    let directory: URL
    /// `<run>/.app`: the members' bus, their events, the hook settings and the delivery ledger.
    let sessionDirectory: URL
    private(set) var run: VerdictRun
    /// The chat-shaped config the members' `council post` resolves against.
    private let sessionConfig: ChatConfig
    /// Members plus the moderator, in the order they are launched.
    let participants: [String]
    private(set) var hosts: [String: TerminalHost] = [:]
    private(set) var statuses: [String: AgentStatus] = [:]
    private(set) var problems: [Problem] = []
    private(set) var lockedMembers: Set<String> = []
    private(set) var blockedHints: [String: String] = [:]
    private(set) var startedAt: Date?
    /// What the run has said about itself, newest last: who was left out, who did not answer.
    private(set) var notes: [String] = []

    /// Something was written into the run directory: the view re-reads it.
    var onChanged: (@MainActor () -> Void)?
    /// The run reached its end, with a verdict or without one.
    var onFinished: (@MainActor (_ score: Int?, _ reason: String?) -> Void)?
    /// A participant is waiting on the user: a dialog in the way, or an error it cannot get past.
    var onAttention: (@MainActor (_ member: String, _ state: MemberState) -> Void)?

    private var orchestrator: VerdictOrchestrator
    private var supervisor: MemberSupervisor
    private let screens = ScreenWatcher()
    private var ledger: DeliveryLedger { DeliveryLedger(directory: sessionDirectory) }
    private var eventTail: EventTail?
    private var busTail: BusTail?
    private var messages: [Message] = []
    private var launchedAt: [String: Date] = [:]
    private var launchEnvironment: MemberLaunchEnvironment?
    private var ticker: Task<Void, Never>?
    /// Prompts waiting for their participant to be ready. A terminal cannot be pasted into until its CLI has
    /// drawn a prompt, and members reach that at their own pace.
    private var pendingAsk: [String: String] = [:]
    /// Which member each open ledger entry belongs to, so a delivery that closed without a post can be told
    /// back to the orchestrator as that member's missing answer.
    private var deliveryOwner: [String: String] = [:]
    private var announced: Set<String> = []
    private var cwd: URL

    init(id: String, run: VerdictRun, sessionDirectory: URL, sessionConfig: ChatConfig) {
        self.id = id
        self.directory = run.directory
        self.run = run
        self.sessionDirectory = sessionDirectory
        self.sessionConfig = sessionConfig
        self.cwd = URL(fileURLWithPath: sessionConfig.cwd)
        self.participants = sessionConfig.order.filter { name in
            sessionConfig.members[name].flatMap { MemberLaunchSpec(name: name, member: $0) } != nil
        }
        self.orchestrator = VerdictOrchestrator(run: run)
        self.supervisor = MemberSupervisor(members: participants)
        for name in participants { statuses[name] = .notRunning }
    }

    var isRunning: Bool { hosts.values.contains { $0.isRunning } }
    var isFinished: Bool { orchestrator.isFinished }
    var phase: VerdictOrchestrator.Phase { orchestrator.phase }
    func host(for member: String) -> TerminalHost? { hosts[member] }
    var orderedHosts: [TerminalHost] { participants.compactMap { hosts[$0] } }
    func state(of member: String) -> MemberState { supervisor.state(of: member) }
    func isWaiting(on member: String) -> Bool { orchestrator.isWaiting(on: member) }

    /// What the user has to act on, in launch order.
    var attention: [(member: String, state: MemberState)] {
        participants.compactMap { m in
            let s = supervisor.state(of: m)
            return s.needsAttention ? (m, s) : nil
        }
    }

    // MARK: running

    /// How a run is picked up. `.resume` continues wherever the files left off; `.moderator` re-runs the
    /// synthesis for a run whose moderator gave up, keeping every answer already paid for. The distinction
    /// matters because an abandoned run reads back as finished, and a finished run is not started again.
    enum StartMode { case resume, moderator }

    /// Launches every participant and picks the run up wherever its files left off. A run whose answers are
    /// all in resumes straight into the moderator; one that never started asks everybody round one.
    func start(environment: MemberLaunchEnvironment, mode: StartMode = .resume) {
        guard hosts.isEmpty else { return }
        if mode == .resume, orchestrator.isFinished { return }
        let now = Date()
        startedAt = now
        problems = []
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir), isDir.boolValue else {
            problems.append(Problem(member: "*", message: "Working folder is missing: \(cwd.path)"))
            return
        }
        launchEnvironment = environment
        startEventTail(since: now)
        startBusTail()
        switch mode {
        case .resume:
            // Only the participants the run still needs get a terminal: `begin` asks for exactly those, and
            // performing its effects launches them. A member that answered before the app was quit is left alone.
            perform(orchestrator.begin(now: now))
        case .moderator:
            // A written verdict is never overwritten, however the retry was reached.
            if case .complete = orchestrator.phase {
                problems.append(Problem(member: "*", message: "This run already has a verdict."))
                return
            }
            perform(orchestrator.retryModerator(now: now))
        }
        startTicker()
    }

    private func launch(_ name: String, environment: MemberLaunchEnvironment) {
        guard hosts[name] == nil else { return }
        guard let spec = sessionConfig.members[name].flatMap({ MemberLaunchSpec(name: name, member: $0) }) else {
            // The run names somebody council.toml no longer has, or whose backend has no terminal. Saying so
            // now is far better than a round that waits half an hour for a member nothing will ever start.
            let why = "\(name) cannot run in the app any more; check council.toml"
            problems.append(Problem(member: name, message: why))
            statuses[name] = .error
            pendingAsk[name] = nil
            perform(orchestrator.failed(name, reason: why, now: Date()))
            return
        }
        do {
            var ctx = LaunchContext(sessionDir: sessionDirectory, cwd: cwd,
                                    baseEnvironment: environment.baseEnvironment, tools: environment.tools,
                                    piExtension: environment.piExtension, effort: sessionConfig.effort)
            if spec.backend == .claude {
                ctx.claudeSettingsFile = try HookConfig.writeClaudeSettings(
                    sessionDir: sessionDirectory, member: name, councilExecutable: environment.tools.councilCommand)
            }
            if spec.backend == .kimi {
                ctx.kimiHome = try HookConfig.writeKimiHome(
                    sessionDir: sessionDirectory, member: name, cwd: cwd,
                    councilExecutable: environment.tools.councilCommand)
            }
            let plan = try LaunchPlanner.plan(member: spec, context: ctx)
            let host = TerminalHost(member: name)
            host.onExit = { [weak self] host, status in self?.hostExited(host, status: status) }
            hosts[name] = host
            supervisor.launched(name, now: Date())
            statuses[name] = .starting
            launchedAt[name] = Date()
            host.launch(plan)
        } catch {
            problems.append(Problem(member: name, message: error.localizedDescription))
            statuses[name] = .error
            perform(orchestrator.failed(name, reason: error.localizedDescription, now: Date()))
        }
    }

    /// Retry on a card: this participant alone starts again and is asked its question afresh.
    func restart(_ member: String) {
        guard let environment = launchEnvironment, participants.contains(member) else { return }
        if let old = hosts[member] { old.onExit = nil; old.stop() }
        hosts[member] = nil
        unlock(member)
        screens.forget(member)
        blockedHints[member] = nil
        problems.removeAll { $0.member == member }
        launch(member, environment: environment)   // `launched` resets this member's state machine
    }

    /// Retry moderator on the verdict card: the answers are kept, only the synthesis runs again.
    func retryModerator() {
        let effects = orchestrator.retryModerator(now: Date())
        guard !effects.isEmpty else { return }
        perform(effects)
        if let environment = launchEnvironment, hosts[orchestrator.moderator]?.isRunning != true {
            hosts[orchestrator.moderator] = nil
            launch(orchestrator.moderator, environment: environment)
        }
        deliverPending()
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        screens.forgetAll()
        blockedHints = [:]
        pendingAsk = [:]
        for host in orderedHosts { host.onExit = nil; host.stop() }
        eventTail?.stop(); eventTail = nil
        busTail?.stop(); busTail = nil
        hosts = [:]
        lockedMembers = []
        for name in participants { statuses[name] = .notRunning }
    }

    // MARK: delivery

    private func deliverPending(now: Date = Date()) {
        for name in participants {
            guard let text = pendingAsk[name], supervisor.isReady(name), !lockedMembers.contains(name),
                  hosts[name]?.isRunning == true else { continue }
            pendingAsk[name] = nil
            orchestrator.delivered(name, now: now)   // the clock starts when the terminal takes the prompt
            performSupervisor(supervisor.send(text, to: name, upTo: messages.last?.id ?? 0, now: now))
        }
    }

    private func unlock(_ name: String) {
        hosts[name]?.inputLocked = false
        lockedMembers.remove(name)
    }

    // MARK: the bus

    private func startBusTail() {
        messages = (try? Bus(directory: sessionDirectory).readAll()) ?? []
        let tail = BusTail(bus: Bus(directory: sessionDirectory)) { [weak self] _ in
            Task { @MainActor in self?.received() }
        }
        tail.start(replayExisting: false)
        busTail = tail
    }

    /// New posts, taken by position rather than by id — ids are nanosecond timestamps and two participants can
    /// share one, which a matching-by-id merge would silently drop.
    private func received() {
        let all = (try? Bus(directory: sessionDirectory).readAll()) ?? []
        guard all.count > messages.count else { return }
        let fresh = Array(all[messages.count...])
        messages = all
        for m in fresh where !m.isNote && !m.isFromUser && !m.isFromSystem {
            supervisor.posted(member: m.sender, messageId: m.id, now: Date())
            // `received`, not `answered`: a record the log could not give up is not this member's answer, and
            // from the moderator it is not the verdict. The orchestrator decides which of the two it is.
            perform(orchestrator.received(m, now: Date()))
        }
        deliverPending()
    }

    private func postNote(_ text: String) {
        try? Bus(directory: sessionDirectory).append(sender: Message.systemSender, text: text,
                                                    kind: Message.kindNote, members: sessionConfig.order)
        busTail?.poll()
    }

    // MARK: events

    private func startEventTail(since start: Date) {
        let cutoff = start.addingTimeInterval(-1)
        let tail = EventTail(directory: sessionDirectory) { [weak self] member, raw, events in
            if let date = raw.date, date < cutoff { return }
            Task { @MainActor in self?.handle(member: member, events: events) }
        }
        tail.start(replayExisting: true)
        eventTail = tail
    }

    private func handle(member: String, events: [MemberEvent]) {
        for event in events {
            if screens.hookSpoke(for: member) { blockedHints[member] = nil }
            if case .turnEnded = event { received() }   // its own answer may still be unread
            performSupervisor(supervisor.apply(event, to: member, now: Date()))
        }
        deliverPending()
    }

    private func hostExited(_ host: TerminalHost, status: Int32?) {
        let member = host.member
        unlock(member)
        pendingAsk[member] = nil
        performSupervisor(supervisor.exited(member, status: status, now: Date()))
    }

    // MARK: the clock

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let now = Date()
        performSupervisor(supervisor.tick(now: now))
        for (name, host) in hosts where host.isRunning {
            let signals = screens.poll(member: name, host: host, state: supervisor.state(of: name),
                                       hasDeliveryInFlight: supervisor.hasDeliveryInFlight(for: name),
                                       launchedAt: launchedAt[name] ?? now, now: now)
            for signal in signals {
                switch signal {
                case .event(let event):
                    performSupervisor(supervisor.apply(event, to: name, now: now))
                case .apiError(let line):
                    performSupervisor(supervisor.sawApiError(line, for: name, now: now))
                }
            }
            if let hint = screens.blockedHints[name] { blockedHints[name] = hint }
        }
        perform(orchestrator.tick(now: now))
        deliverPending(now: now)
    }

    // MARK: effects

    private func perform(_ effects: [VerdictOrchestrator.Effect]) {
        for effect in effects {
            switch effect {
            case .ask(let member, _, let text):
                pendingAsk[member] = text
                if hosts[member] == nil, let environment = launchEnvironment { launch(member, environment: environment) }
            case .record(let member, let round, let answer, let done):
                do {
                    try run.record(member, round: round, answer: answer, done: done)
                } catch {
                    problems.append(Problem(member: member, message: error.localizedDescription))
                }
                onChanged?()
            case .release(let member):
                pendingAsk[member] = nil
                release(member)
            case .moderate(let member, let text):
                pendingAsk[member] = text
                if hosts[member] == nil, let environment = launchEnvironment { launch(member, environment: environment) }
            case .finish(let verdict, let score):
                write(verdict: verdict, score: score)
            case .abandon(let reason, let moderatorFailed):
                abandon(reason: reason, moderatorFailed: moderatorFailed)
            case .note(let text):
                notes.append(text)
                postNote(text)
            }
        }
        deliverPending()
    }

    /// A participant has nothing further to do: its terminal closes rather than sitting on the user's machine
    /// with a model session open.
    private func release(_ member: String) {
        guard let host = hosts[member] else { return }
        host.onExit = nil
        host.stop()
        hosts[member] = nil
        unlock(member)
        screens.forget(member)
        blockedHints[member] = nil
        statuses[member] = .notRunning
    }

    private func write(verdict: String, score: Int?) {
        do {
            try run.writeVerdict(verdict)
            try run.writeTranscript(verdict: verdict)
        } catch {
            problems.append(Problem(member: "*", message: error.localizedDescription))
        }
        finishUp()
        onChanged?()
        onFinished?(score, nil)
    }

    /// No verdict. A moderator that gave up leaves the CLI's marker behind, which is what tells a later reader
    /// — `council show`, or the app's own Retry — that the answers are sound and only the synthesis is missing.
    private func abandon(reason: String, moderatorFailed: Bool) {
        do {
            if moderatorFailed {
                try "(moderator failed: \(reason))\n"
                    .write(to: directory.appendingPathComponent("verdict.md"), atomically: true, encoding: .utf8)
            }
            try run.writeTranscript(verdict: "")
        } catch {
            problems.append(Problem(member: "*", message: error.localizedDescription))
        }
        finishUp()
        onChanged?()
        onFinished?(nil, reason)
    }

    private func finishUp() {
        ticker?.cancel()
        ticker = nil
        pendingAsk = [:]
        for name in participants { release(name) }
        eventTail?.stop(); eventTail = nil
        busTail?.stop(); busTail = nil
    }

    private func performSupervisor(_ effects: [MemberSupervisor.Effect]) {
        for effect in effects {
            switch effect {
            case .paste(let member, let text):
                Task { await deliver(text, to: member) }
            case .unlock(let member):
                unlock(member)
            case .note(let text):
                postNote(text)
            case .open(let delivery):
                deliveryOwner[delivery.id] = delivery.member
                try? ledger.open(delivery)
            case .attempt(let id, let attempts):
                try? ledger.attempt(id: id, attempts: attempts)
            case .close(let id, let outcome, let postId):
                try? ledger.close(id: id, outcome: outcome, postId: postId, at: MessageTime.format(Date()))
                // A turn that ended without a post is this member's answer: there is not one.
                if outcome == .nothingToAdd, let member = deliveryOwner.removeValue(forKey: id) {
                    perform(orchestrator.failed(member, reason: "finished without posting an answer", now: Date()))
                } else {
                    deliveryOwner[id] = nil
                }
            case .finished:
                break
            case .unavailable(let member):
                // Blocked is not failure: a dialog is something the user can clear, and the run waits. Only a
                // member that has given up or gone away is recorded as having produced nothing.
                if case .error(let reason) = supervisor.state(of: member) {
                    perform(orchestrator.failed(member, reason: reason, now: Date()))
                }
            }
        }
        syncStatuses()
    }

    private func deliver(_ text: String, to member: String) async {
        guard let host = hosts[member], host.isRunning else { return }
        host.inputLocked = true
        lockedMembers.insert(member)
        await host.paste(text)
    }

    private func syncStatuses() {
        for member in participants {
            let state = supervisor.state(of: member)
            let status: AgentStatus
            switch state {
            case .notRunning: status = .notRunning
            case .starting: status = .starting
            case .blockedBeforeStart, .blocked: status = .blocked
            case .ready: status = orchestrator.isWaiting(on: member) ? .working("reading the question") : .ready
            case .prompted: status = .working("reading the question")
            case .working(let activity): status = .working(activity ?? "thinking")
            case .error: status = .error
            }
            if statuses[member] != status { statuses[member] = status }
            if let reason = state.reason, state.needsAttention {
                if blockedHints[member] != reason { blockedHints[member] = reason }
                if announced.insert(member).inserted { onAttention?(member, state) }
            } else {
                announced.remove(member)
            }
        }
    }
}

