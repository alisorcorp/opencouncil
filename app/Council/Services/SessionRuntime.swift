import Foundation
import Observation
import CouncilCore

/// A live chat: one `TerminalHost` per launchable member, the `events.jsonl` tail, the bus tail, and the two
/// pure engines that decide everything — `ChatRouter` (who is prompted, with what) and `MemberSupervisor`
/// (what became of each prompt). This type owns no rules; it performs their effects and holds the I/O.
@Observable
@MainActor
final class SessionRuntime {
    struct Problem: Equatable {
        let member: String    // "*" for the whole session
        let message: String
    }

    let id: String
    let directory: URL
    let config: ChatConfig
    /// Members in config order that can run in the app (terminal backends with a launch spec).
    let members: [String]
    private(set) var hosts: [String: TerminalHost] = [:]
    private(set) var statuses: [String: AgentStatus] = [:]
    private(set) var problems: [Problem] = []
    /// Members whose terminal is currently locked for a delivery (mirrors `TerminalHost.inputLocked`, observable).
    private(set) var lockedMembers: Set<String> = []
    private(set) var appState: SessionAppState
    private(set) var startedAt: Date?
    /// Every normalised event, in file order; used by diagnostics and the drive harness.
    var onEvent: (@MainActor (_ member: String, _ raw: RawEvent, _ events: [MemberEvent]) -> Void)?
    var onExit: (@MainActor (_ member: String, _ status: Int32?) -> Void)?
    /// A member posted. `isHello` marks its answer to the briefing, which is not worth telling anyone about.
    var onPost: (@MainActor (_ member: String, _ text: String, _ isHello: Bool) -> Void)?
    /// A member started needing the user: a dialog in the way, or an error it cannot get past on its own.
    var onAttention: (@MainActor (_ member: String, _ state: MemberState) -> Void)?
    /// Posts seen per member, so the first one (the hello) can be told apart from an answer.
    private var postsSeen: [String: Int] = [:]
    /// Members whose card has already been announced, so one dialog raises one notification.
    private var announced: Set<String> = []

    private var eventTail: EventTail?
    private var busTail: BusTail?
    /// Per-member state machine: acknowledgement retries, timeouts, outcomes (pure; see `MemberSupervisor`).
    private var supervisor: MemberSupervisor
    /// `deliveries.jsonl`: what was handed to whom, and how it ended.
    private var ledger: DeliveryLedger { DeliveryLedger(directory: directory) }
    /// Routing state: who gets prompted with what (pure; see `ChatRouter`).
    private var router: ChatRouter
    /// Every message in the log, as the router sees it; also what the transcript is rendered from.
    private(set) var messages: [Message] = []
    /// Members that have been launched but not yet briefed. Nothing is delivered to them until they are.
    private(set) var awaitingBriefing: Set<String> = []
    /// Set when this session was started with `resume`, so the briefing points at the transcript.
    private var resuming = false
    /// Held for as long as this session is live, so the CLI does not route the same chat at the same time.
    private var lock: RouterLock { RouterLock(directory: directory) }
    private var ticker: Task<Void, Never>?
    private var launchedAt: [String: Date] = [:]
    /// Members launched with `--resume` that have not proved the resume worked yet.
    private var resumeAttempt: Set<String> = []
    /// Deliveries an earlier process left open, waiting for their member to be briefed and ready again.
    private var interrupted: [String: Delivery] = [:]
    /// Kept so one member can be relaunched on its own (Retry, or a resume that did not take).
    private var launchEnvironment: MemberLaunchEnvironment?
    /// What the members' terminals say that their hooks do not (see `ScreenWatcher`).
    private let screens = ScreenWatcher()
    /// What the screen showed for a blocked member, for the sidebar and the terminal pane.
    private(set) var blockedHints: [String: String] = [:]

    /// A resume that dies inside this window never really started: fall back to a fresh launch.
    static let resumeFailureWindow: TimeInterval = 25

    init(id: String, directory: URL, config: ChatConfig) {
        self.id = id
        self.directory = directory
        self.config = config
        self.members = config.order.filter { name in
            config.members[name].flatMap { MemberLaunchSpec(name: name, member: $0) } != nil
        }
        self.appState = SessionAppState.load(from: directory)
        self.router = ChatRouter(members: members, budget: config.budget ?? 20)
        self.supervisor = MemberSupervisor(members: members)
        for m in config.order { statuses[m] = .notRunning }
    }

    var isRunning: Bool { hosts.values.contains { $0.isRunning } }
    /// Seconds the member's visible screen has been unchanged, as last measured by the ticker (diagnostics).
    func screenStableSeconds(for member: String, now: Date = Date()) -> TimeInterval? {
        screens.stableSeconds(for: member, now: now)
    }
    var orderedHosts: [TerminalHost] { members.compactMap { hosts[$0] } }
    func host(for member: String) -> TerminalHost? { hosts[member] }
    var cwd: URL { URL(fileURLWithPath: appState.cwdOverride ?? config.cwd) }

    /// Launches every launchable member. A member whose tool is missing gets a problem instead of a host.
    /// `only` restricts the launch to some members (diagnostics); nil launches every launchable member.
    func start(environment: MemberLaunchEnvironment, resume: Bool = false, only: Set<String>? = nil) {
        guard hosts.isEmpty else { return }
        let now = Date()
        startedAt = now
        problems = []
        let cwd = self.cwd
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir), isDir.boolValue else {
            problems.append(Problem(member: "*", message: "Project folder is missing: \(cwd.path)"))
            return
        }
        do {
            try lock.acquire()
        } catch {
            problems.append(Problem(member: "*", message: error.localizedDescription))
            return
        }
        launchEnvironment = environment
        resuming = resume
        if resume {
            postNote("chat resumed \(MessageTime.format(now)) · members: \(members.joined(separator: ", "))")
        }
        reportInterruptedDeliveries(now: now)
        startEventTail(since: now)
        startBusTail()
        for name in members where only?.contains(name) ?? true {
            launch(name, environment: environment, cwd: cwd, resume: resume)
        }
        appState.live = !hosts.isEmpty
        saveState()
        startTicker()
    }

    /// Starts one member's terminal. Shared by the initial launch and by Retry on an error card.
    private func launch(_ name: String, environment: MemberLaunchEnvironment, cwd: URL, resume: Bool) {
        guard let spec = config.members[name].flatMap({ MemberLaunchSpec(name: name, member: $0) }) else { return }
        do {
            var ctx = LaunchContext(sessionDir: directory, cwd: cwd, baseEnvironment: environment.baseEnvironment,
                                    tools: environment.tools, piExtension: environment.piExtension,
                                    effort: config.effort,
                                    resumeSessionId: resume ? appState.sessionIds[name] : nil)
            if spec.backend == .claude {
                ctx.claudeSettingsFile = try HookConfig.writeClaudeSettings(
                    sessionDir: directory, member: name, councilExecutable: environment.tools.councilCommand)
            }
            if spec.backend == .kimi {
                ctx.kimiHome = try HookConfig.writeKimiHome(
                    sessionDir: directory, member: name, cwd: cwd,
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
            awaitingBriefing.insert(name)
            if plan.isResume { resumeAttempt.insert(name) } else { resumeAttempt.remove(name) }
            if let sid = plan.sessionId { appState.sessionIds[name] = sid }
        } catch {
            problems.append(Problem(member: name, message: error.localizedDescription))
            statuses[name] = .error
        }
    }

    /// Relaunches one member after an error without disturbing the others. It is briefed again as soon as it
    /// is ready, and `resume` continues its previous CLI session so it keeps its own context.
    func restart(_ member: String, environment: MemberLaunchEnvironment, resume: Bool = true) {
        // A member can give up with its process still alive — an API error that outlasted its retries, a prompt
        // it never acknowledged, no sign of life at all. Retry on those cards has to replace the terminal, not
        // decline because something is still running inside it.
        let gaveUp = supervisor.state(of: member).hasGivenUp
        guard members.contains(member), gaveUp || hosts[member]?.isRunning != true else { return }
        if let old = hosts[member] { old.onExit = nil; old.stop() }
        hosts[member] = nil
        unlock(member)
        screens.forget(member)
        blockedHints[member] = nil
        problems.removeAll { $0.member == member }
        // Reopening the terminal is not enough: the question it gave up on would be abandoned in the ledger
        // with nobody ever answering it. It goes out again, marked as a repeat, once the member is back.
        if gaveUp, interrupted[member] == nil, let dropped = lastFailedDelivery(for: member) {
            interrupted[member] = dropped
        }
        launch(member, environment: environment, cwd: cwd, resume: resume && appState.sessionIds[member] != nil)
        saveState()
    }

    /// The question a member gave up on, for Retry to ask again. Only its most recent delivery counts —
    /// anything older was either answered or already superseded by what came after it.
    private func lastFailedDelivery(for member: String) -> Delivery? {
        guard let last = ledger.all(for: member).last, last.outcome == .failed,
              last.text?.isEmpty == false else { return nil }
        return last
    }

    /// Points this chat at a different project folder, for when the original moved or was deleted.
    func setProjectFolder(_ url: URL) {
        appState.cwdOverride = url.path
        saveState()
        problems.removeAll { $0.member == "*" }
    }

    /// Terminates every member and stops tailing events.
    func stop() {
        ticker?.cancel()
        ticker = nil
        screens.forgetAll()
        blockedHints = [:]
        for host in orderedHosts { host.onExit = nil; host.stop() }
        eventTail?.stop()
        eventTail = nil
        busTail?.stop()
        busTail = nil
        awaitingBriefing = []
        hosts = [:]
        lockedMembers = []
        // Whatever was in flight did not finish; say so on the bus rather than leaving it open for ever.
        performSupervisor(members.flatMap { supervisor.exited($0, status: 0, now: Date()) })
        for m in config.order { statuses[m] = .notRunning }
        appState.live = false
        saveState()
        lock.release()
    }

    /// Pastes `text` into each recipient's terminal and submits it, locking its input until the member's CLI
    /// reports the prompt. The supervisor decides when to paste again and when to give up, so nothing here
    /// schedules a timeout of its own.
    func deliver(_ text: String, to recipients: [String]) async {
        for name in recipients {
            guard let host = hosts[name], host.isRunning else { continue }
            host.inputLocked = true
            lockedMembers.insert(name)
            await host.paste(text)
        }
    }

    /// Hands a delivery to a member through the supervisor, which opens a ledger entry for it first.
    private func send(_ text: String, to member: String, now: Date = Date()) {
        performSupervisor(supervisor.send(text, to: member, upTo: messages.last?.id ?? 0, now: now))
    }

    private func unlock(_ name: String) {
        hosts[name]?.inputLocked = false
        lockedMembers.remove(name)
    }

    // MARK: chat

    /// Posts the user's message to the bus. The tail picks it up like any other post, so the CLI and the app
    /// route identically and the transcript stays in step.
    func post(_ text: String, as sender: String = Message.userSender) throws {
        try Bus(directory: directory).append(sender: sender, text: text, members: config.order)
        busTail?.poll()
    }

    /// Follows `chat.jsonl` for the router. The view model tails it separately for display; both are cheap and
    /// keeping them apart means routing survives the detail pane being closed.
    private func startBusTail() {
        messages = (try? Bus(directory: directory).readAll()) ?? []
        router = ChatRouter(members: members, budget: appState.budget ?? config.budget ?? 20, history: messages)
        router.muted = Set(appState.muted)
        let tail = BusTail(bus: Bus(directory: directory)) { [weak self] _ in
            Task { @MainActor in self?.received() }
        }
        tail.start(replayExisting: false)
        busTail = tail
    }

    /// Takes whatever the log has gained since the last look. Called by the tail, and directly before a turn is
    /// judged: a member's post and the `Stop` hook that follows it arrive on different channels, and without a
    /// read here the turn could be called "nothing to add" while its own answer sits unread in the file.
    ///
    /// New messages are taken by **position**, never by id. A message id is a nanosecond timestamp, and two
    /// members posting in the same instant get the same one — matching on ids silently drops one of the two
    /// replies. chat.py counts as well, for the same reason.
    private func received() {
        let all = (try? Bus(directory: directory).readAll()) ?? []
        guard all.count > messages.count else { return }
        let fresh = Array(all[messages.count...])
        messages = all
        for m in fresh where !m.isNote && !m.isFromUser && !m.isFromSystem {
            supervisor.posted(member: m.sender, messageId: m.id, now: Date())
            let seen = postsSeen[m.sender, default: 0]
            postsSeen[m.sender] = seen + 1
            onPost?(m.sender, m.text, seen == 0)
        }
        for effect in router.append(fresh) { perform(effect) }
        try? Transcript.write(config: config, messages: messages, to: directory)
        runRouter()
    }

    /// Members that can take a prompt right now: running, briefed, idle and with nothing in flight.
    private var readyForDelivery: Set<String> {
        Set(members.filter { name in
            guard let host = hosts[name], host.isRunning else { return false }
            return supervisor.isReady(name) && !lockedMembers.contains(name) && !awaitingBriefing.contains(name)
        })
    }

    /// One pass of the delivery loop: brief whoever is newly ready, then hand out whatever the router has due.
    private func runRouter(now: Date = Date()) {
        for name in members where awaitingBriefing.contains(name) {
            guard supervisor.isReady(name), !lockedMembers.contains(name), hosts[name]?.isRunning == true else { continue }
            awaitingBriefing.remove(name)
            let text = Briefing.briefing(name: name, members: config.order, cwd: cwd.path,
                                         resumeDirectory: resuming ? directory : nil)
            send(text, to: name, now: now)
        }
        for name in members where interrupted[name] != nil {
            guard supervisor.isReady(name), !awaitingBriefing.contains(name), !lockedMembers.contains(name),
                  hosts[name]?.isRunning == true else { continue }
            guard let delivery = interrupted.removeValue(forKey: name), let text = delivery.text else { continue }
            send(Briefing.interruptedNote + text, to: name, now: now)
        }
        for effect in router.tick(now: now, ready: readyForDelivery) { perform(effect) }
    }

    private func perform(_ effect: ChatRouter.Effect) {
        switch effect {
        case .deliver(let member, let text):
            send(text, to: member)
        case .note(let text):
            try? Bus(directory: directory).append(sender: Message.systemSender, text: text,
                                                 kind: Message.kindNote, members: config.order)
            busTail?.poll()
        }
    }

    // MARK: mute and budget

    var muted: Set<String> { router.muted }
    /// Replies left before the council has to be prompted again, and whether it is writing its closing statements.
    var routerStatus: (budgetLeft: Int, budget: Int, wrapping: Bool) { router.status }

    func setMuted(_ member: String, _ muted: Bool) {
        if muted { router.mute(member) } else { router.unmute(member) }
        appState.muted = router.muted.sorted()
        saveState()
    }

    func setBudget(_ n: Int) {
        router.budget = max(1, n)
        appState.budget = router.budget
        saveState()
    }

    // MARK: screen fallbacks

    /// Once a second: run the supervisor's own timeouts, then read the screens it cannot see. A CLI sitting in
    /// a pre-session dialog (folder trust, hook review, login) is blocked; one that drew its prompt and went
    /// quiet is ready (Codex only reports SessionStart with the first prompt); one that has been sitting on an
    /// error line mid-delivery gets nudged. Hooks take over as soon as they speak.
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.tick()
                self.runRouter()
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
    }

    // MARK: events

    private func startEventTail(since start: Date) {
        // Replaying the file with a cutoff closes the gap between opening the tail and the first launch:
        // nothing a member writes in that window is lost, and old runs' events are skipped.
        let cutoff = start.addingTimeInterval(-1)
        let tail = EventTail(directory: directory) { [weak self] member, raw, events in
            if let date = raw.date, date < cutoff { return }
            Task { @MainActor in self?.handle(member: member, raw: raw, events: events) }
        }
        tail.start(replayExisting: true)
        eventTail = tail
    }

    private func handle(member: String, raw: RawEvent, events: [MemberEvent]) {
        for event in events { apply(event, to: member) }
        onEvent?(member, raw, events)
    }

    private func apply(_ event: MemberEvent, to member: String) {
        if screens.hookSpoke(for: member) { blockedHints[member] = nil }
        if case .turnEnded = event { received() }     // its own answer may still be unread
        // Codex and kimi report the id they chose; Claude Code and pi echo the pre-assigned one. An empty id
        // is not one of them: written down, it would come back as a resume that no CLI can honour.
        if case .started(let sessionId, _) = event, let sid = sessionId, !sid.isEmpty,
           appState.sessionIds[member] != sid {
            appState.sessionIds[member] = sid
            saveState()
        }
        performSupervisor(supervisor.apply(event, to: member, now: Date()))
    }

    private func hostExited(_ host: TerminalHost, status: Int32?) {
        let member = host.member
        unlock(member)
        awaitingBriefing.remove(member)
        performSupervisor(supervisor.exited(member, status: status, now: Date()))
        onExit?(member, status)
        if resumeFailed(member) { return }
        if !isRunning {
            appState.live = false
            saveState()
        }
    }

    // MARK: supervisor

    /// Carries out what the supervisor decided, and mirrors its states into the statuses the UI reads.
    private func performSupervisor(_ effects: [MemberSupervisor.Effect]) {
        for effect in effects {
            switch effect {
            case .paste(let member, let text):
                Task { await deliver(text, to: [member]) }
            case .unlock(let member):
                unlock(member)
            case .note(let text):
                postNote(text)
            case .open(let delivery):
                try? ledger.open(delivery)
            case .attempt(let id, let attempts):
                try? ledger.attempt(id: id, attempts: attempts)
            case .close(let id, let outcome, let postId):
                try? ledger.close(id: id, outcome: outcome, postId: postId, at: MessageTime.format(Date()))
            case .finished(let member):
                router.memberFinished(member)
            case .unavailable(let member):
                router.memberUnavailable(member)
            }
        }
        syncStatuses()
    }

    /// `MemberState` is the truth; `AgentStatus` is what the sidebar and the header draw.
    private func syncStatuses() {
        for member in members {
            let state = supervisor.state(of: member)
            let status: AgentStatus
            switch state {
            case .notRunning: status = .notRunning
            case .starting: status = .starting
            case .blockedBeforeStart, .blocked: status = .blocked
            case .ready: status = .ready
            case .prompted: status = .working("reading the prompt")
            case .working(let activity): status = .working(activity)
            case .error: status = .error
            }
            if statuses[member] != status { statuses[member] = status }
            if let reason = state.reason, state.needsAttention {
                if blockedHints[member] != reason { blockedHints[member] = reason }
                if !announced.contains(member) {
                    announced.insert(member)
                    onAttention?(member, state)
                }
            } else if blockedHints[member] != nil, !screens.blocked.contains(member) {
                blockedHints[member] = nil
            }
            if !state.needsAttention { announced.remove(member) }
        }
    }

    /// What the user has to do something about, in config order: the blocked and error cards.
    var attention: [(member: String, state: MemberState)] {
        members.compactMap { m in
            let s = supervisor.state(of: m)
            return s.needsAttention ? (m, s) : nil
        }
    }

    func state(of member: String) -> MemberState { supervisor.state(of: member) }
    func isSlow(_ member: String, now: Date = Date()) -> Bool { supervisor.isSlow(member, now: now) }
    func hasDeliveryInFlight(for member: String) -> Bool { supervisor.hasDeliveryInFlight(for: member) }

    private func postNote(_ text: String) {
        try? Bus(directory: directory).append(sender: Message.systemSender, text: text,
                                              kind: Message.kindNote, members: config.order)
        busTail?.poll()
    }

    /// Deliveries an earlier process left open never reached anybody. They are closed as interrupted, and the
    /// ones whose text was recorded are queued to go out again as soon as their member is briefed and idle —
    /// R14 does not stop applying because the app was quit.
    private func reportInterruptedDeliveries(now: Date) {
        guard let orphans = try? ledger.closeOrphans(at: MessageTime.format(now)), !orphans.isEmpty else { return }
        for delivery in orphans where members.contains(delivery.member) {
            if delivery.text != nil {
                interrupted[delivery.member] = delivery      // the most recent one wins
            } else {
                postNote("\(delivery.member) was mid-reply when the chat last closed; it was not asked again")
            }
        }
        for member in members where interrupted[member] != nil {
            postNote("\(member) was mid-reply when the chat last closed; it will be asked again")
        }
    }

    /// A CLI asked to resume a session it no longer has exits at once. Rather than leaving an error card for
    /// something the app can fix, the member starts fresh and is briefed with the transcript instead — which is
    /// what the CLI does when a pane is gone.
    private func resumeFailed(_ member: String) -> Bool {
        guard resumeAttempt.remove(member) != nil,
              let started = launchedAt[member], Date().timeIntervalSince(started) < Self.resumeFailureWindow,
              let environment = launchEnvironment else { return false }
        appState.sessionIds[member] = nil
        resuming = true          // the briefing points at transcript.md, as a resumed chat's does
        postNote("\(member) could not resume its previous session; it starts fresh and reads the transcript")
        hosts[member] = nil
        launch(member, environment: environment, cwd: cwd, resume: false)
        saveState()
        return true
    }

    /// Writes back the fields this runtime owns, keeping whatever the view model has put in the same file. It
    /// holds its own copy for the draft and the read position, and a whole-struct write from here would undo
    /// whichever of those had changed since this copy was loaded.
    private func saveState() {
        do {
            appState = try SessionAppState.update(in: directory) {
                $0.sessionIds = appState.sessionIds
                $0.live = appState.live
                $0.muted = appState.muted
                $0.budget = appState.budget
                $0.cwdOverride = appState.cwdOverride
            }
        } catch {
            problems.append(Problem(member: "*", message: "Could not save app.json: \(error.localizedDescription)"))
        }
    }
}

extension RawEvent {
    /// `ts` as written by `council event` (local time, seconds) or by the pi extension (ISO 8601).
    var date: Date? {
        if let d = MessageTime.parse(ts) { return d }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: ts) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: ts)
    }
}
