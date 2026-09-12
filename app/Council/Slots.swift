import AppKit
import CouncilCore

/// Developer tool: `Council --slots <council-root>`.
///
/// The live cap end to end. Three sessions are started until every slot is held, a fourth asks for one and is
/// offered the picker rather than refused, and then the fourth takes the slot the picker named — which has to
/// stop the session that held it and start the one that asked. Unit tests can reach the dispatch (which branch
/// runs) but not the transfer: nothing is actually running in them, so "the slot was freed and something else
/// took it" is exactly the part they cannot see. Here the members are real processes, and the slot is seen to
/// change hands by asking the kernel what became of them.
///
/// Wants a council folder with three chats to fill the cap and a fourth session to ask for one — a verdict run
/// when there is one, since a run taking a slot is the case that used to stop somebody else's members and then
/// do nothing. With `COUNCIL_FAKE_MEMBERS=1` no model is called.
enum SlotsCommand {
    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let i = arguments.firstIndex(of: "--slots"), arguments.count >= i + 2 else { return false }
        let root = URL(fileURLWithPath: arguments[i + 1]).standardizedFileURL
        Task { @MainActor in exit(await run(root: root)) }
        return true
    }

    @MainActor
    private static func run(root: URL) async -> Int32 {
        let t0 = Date()
        var failures = 0
        func log(_ s: String) {
            let stamp = String(format: "%6.2fs", Date().timeIntervalSince(t0))
            FileHandle.standardOutput.write(Data("[\(stamp)] \(s)\n".utf8))
        }
        func expect(_ condition: Bool, _ what: String) {
            log((condition ? "ok   " : "FAIL ") + what)
            if !condition { failures += 1 }
        }

        let paths = CouncilPaths(root: root)
        guard paths.isValid else { log("slots: \(root.path) is not a council folder"); return 2 }
        let all = SessionStore(paths: paths).scan()
        let chats = all.filter { $0.kind == .chat }
        guard chats.count >= LiveSessions.cap else {
            log("slots: need \(LiveSessions.cap) chats to fill the cap, found \(chats.count)")
            return 2
        }
        let holders = Array(chats.prefix(LiveSessions.cap))
        // A verdict run asks for the slot when the folder has one. Runs hold slots alongside chats, and a run
        // taking one is the case that used to stop somebody else's members and then quietly do nothing — the
        // callback started chats whatever the session was.
        guard let asking = all.first(where: { $0.kind == .verdict })
                ?? (chats.count > LiveSessions.cap ? chats[LiveSessions.cap] : nil) else {
            log("slots: no fourth session to ask for a slot")
            return 2
        }
        log("slot-holders: \(holders.map(\.id).joined(separator: ", "))")
        log("asking for a slot: \(asking.id) (\(asking.kind == .verdict ? "run" : "chat"))")
        let shell = await Task.detached { ShellEnvironment.resolve() }.value
        let live = LiveSessions(launchEnvironment: MemberLaunchEnvironment.make(shell: shell, paths: paths))
        let councilConfig = try? CouncilConfig.load(from: paths.configFile)

        // What the interface does: a chat starts members, a run starts the run. `takeSlot` has to make the same
        // choice for itself once the slot is free, which is the whole point of the exercise.
        func startWhateverItIs(_ vm: SessionViewModel) {
            if vm.summary.kind == .verdict { vm.startVerdict() } else { vm.startMembers() }
        }

        // 1. Fill every slot. These are the sessions the picker will be offering to stop.
        var opened: [SessionViewModel] = []
        for summary in holders {
            let vm = SessionViewModel(summary: summary, live: live, paths: paths, councilConfig: councilConfig)
            vm.open()               // the config is read when the session is opened, and startMembers needs it
            opened.append(vm)
            startWhateverItIs(vm)
            if let problem = vm.startError { log("could not start \(summary.id): \(problem)") }
        }
        expect(live.count == LiveSessions.cap, "\(LiveSessions.cap) sessions hold slots (count \(live.count))")
        let held = holders[0]
        let heldPids = live.runtime(for: held.id).map { rt in rt.members.compactMap { rt.host(for: $0)?.pid } } ?? []
        expect(!heldPids.isEmpty, "the session about to lose its slot has members running (pids \(heldPids))")

        // 2. A fourth asks. Being at the cap is not an error: it is the picker, carrying what was asked for.
        let taker = SessionViewModel(summary: asking, live: live, paths: paths, councilConfig: councilConfig)
        taker.open()
        startWhateverItIs(taker)
        expect(taker.capReached, "the fourth session is offered the picker")
        expect(taker.startError == nil, "and not an error (\(taker.startError ?? "none"))")
        expect(!taker.isLive, "and did not start behind the picker's back")
        let offered = taker.runningSessions
        expect(offered.count == LiveSessions.cap, "the picker offers \(LiveSessions.cap) sessions (got \(offered.count))")
        expect(offered.allSatisfy { !$0.title.isEmpty && $0.members > 0 },
               "each one named with its members: \(offered.map { "\($0.title) (\($0.members))" }.joined(separator: ", "))")

        // 3. Take the slot the picker named. The session that held it stops; the one that asked starts in it.
        log("taking the slot from \(held.id)")
        taker.takeSlot(from: held.id)
        expect(!taker.capReached, "the picker is dismissed")
        expect(live.runtime(for: held.id) == nil, "the session that held the slot is no longer live")
        let stopped = await waitUntil(timeout: 10) { heldPids.allSatisfy { isFinished(pid_t($0)) } }
        expect(stopped, "its members' processes are gone "
               + "(\(heldPids.map { "\($0) \(state(of: pid_t($0)))" }.joined(separator: ", ")))")
        expect(taker.isLive, "the session that asked is live")
        let takerPids = live.runtime(for: asking.id).map { rt in rt.members.compactMap { rt.host(for: $0)?.pid } }
            ?? live.verdict(for: asking.id).map { rt in rt.participants.compactMap { rt.host(for: $0)?.pid } } ?? []
        expect(!takerPids.isEmpty, "with members running (pids \(takerPids))")
        expect(live.count == LiveSessions.cap, "and the cap still holds (count \(live.count))")

        for vm in opened + [taker] { vm.close() }
        live.stopAll()
        try? await Task.sleep(for: .milliseconds(200))
        log(failures == 0 ? "OK" : "FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }

    /// The kernel's view of a pid, which is not the same question as `kill(pid, 0)`. A member stopped with
    /// SIGTERM stays in the process table until its parent reaps it, and its parent is this process — so a pid
    /// that still answers may be a corpse nobody has collected rather than a CLI still running.
    private static func state(of pid: pid_t) -> String {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return "gone" }
        return info.kp_proc.p_stat == SZOMB ? "exited (not yet reaped)" : "still running"
    }

    private static func isFinished(_ pid: pid_t) -> Bool { state(of: pid) != "still running" }

    @MainActor
    private static func waitUntil(timeout: TimeInterval, poll: Duration = .milliseconds(100),
                                  _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: poll)
        }
        return condition()
    }
}
