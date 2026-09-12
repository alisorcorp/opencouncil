import AppKit
import CouncilCore

/// Developer tool: `Council --drive <chat-dir> "<message>" [--timeout <s>] [--settle <s>] [--members a,b] [--to a,b] [--resume] [--paste] [--retry-failed] [--trace-screen]`.
/// Starts the chat's members in hidden terminals, waits for their briefings, posts the message to the bus as
/// the user and lets the router deliver it — the same path the composer takes — then waits for each member to
/// finish its turn (Stop) and prints what happened: hooks seen, posts made, final statuses, and whether the
/// reaction pass went out. `--paste` skips the bus and pastes straight into the terminals (the pre-router
/// path). `--retry-failed` presses Retry on every member that gave up and waits for it to come back, which is
/// the card's path rather than a fresh start. Exits 0 when every recipient finished. With
/// `COUNCIL_FAKE_MEMBERS=1` this exercises the whole delivery chain without model calls. `--trace-screen`
/// reports each member's readiness signals once a second from launch until it is ready, printing the screen
/// lines that changed — for working out why a CLI draws its prompt long before it will accept one.
enum DriveCommand {
    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let i = arguments.firstIndex(of: "--drive"), arguments.count >= i + 3 else { return false }
        let dir = URL(fileURLWithPath: arguments[i + 1]).standardizedFileURL
        let message = arguments[i + 2]
        var rest = Array(arguments[(i + 3)...])
        var timeout: TimeInterval = 60
        var settle: TimeInterval = 0.3       // pause between SessionStart and the paste; real TUIs need a few seconds to draw
        var to: [String]?
        var members: Set<String>?
        var resume = false
        var paste = false
        var retryFailed = false
        var traceScreen = false
        while !rest.isEmpty {
            let a = rest.removeFirst()
            switch a {
            case "--timeout":
                if let v = rest.first.flatMap(Double.init) { timeout = v; rest.removeFirst() }
            case "--settle":
                if let v = rest.first.flatMap(Double.init) { settle = v; rest.removeFirst() }
            case "--to":
                if let v = rest.first { to = v.split(separator: ",").map(String.init); rest.removeFirst() }
            case "--members":
                if let v = rest.first { members = Set(v.split(separator: ",").map(String.init)); rest.removeFirst() }
            case "--resume":
                resume = true
            case "--paste":
                paste = true
            case "--retry-failed":
                retryFailed = true
            case "--trace-screen":
                traceScreen = true
            default:
                break
            }
        }
        Task { @MainActor in
            let code = await run(dir: dir, message: message, recipients: to, members: members, timeout: timeout,
                                 settle: settle, resume: resume, paste: paste, retryFailed: retryFailed,
                                 traceScreen: traceScreen)
            exit(code)
        }
        return true
    }

    @MainActor
    private static func run(dir: URL, message: String, recipients: [String]?, members: Set<String>?, timeout: TimeInterval,
                            settle: TimeInterval, resume: Bool, paste: Bool, retryFailed: Bool = false,
                            traceScreen: Bool = false) async -> Int32 {
        let t0 = Date()
        func log(_ s: String) {
            let stamp = String(format: "%6.2fs", Date().timeIntervalSince(t0))
            FileHandle.standardOutput.write(Data("[\(stamp)] \(s)\n".utf8))
        }
        let paths = CouncilPaths(root: dir.deletingLastPathComponent().deletingLastPathComponent())
        guard paths.isValid else { log("drive: \(dir.path) is not inside a council folder"); return 2 }
        let config: ChatConfig
        do { config = try ChatConfig.load(from: dir) } catch { log("drive: \(error.localizedDescription)"); return 2 }
        let shell = await Task.detached { ShellEnvironment.resolve() }.value
        let env = MemberLaunchEnvironment.make(shell: shell, paths: paths)
        log("chat \(dir.lastPathComponent) · members \(config.order.joined(separator: ", ")) · fake=\(env.isFake) · cwd \(config.cwd)")

        let rt = SessionRuntime(id: dir.lastPathComponent, directory: dir, config: config)
        var hooksSeen: [String: [String]] = [:]
        var turns: [String: Int] = [:]          // completed turns per member; the briefing is turn 1
        var exited = Set<String>()
        rt.onEvent = { member, raw, events in
            for e in events {
                hooksSeen[member, default: []].append(raw.hook)
                log("\(member): \(raw.hook) → \(e)")
                if e.isTerminalForTurn { turns[member, default: 0] += 1 }
                // A member that announces a session is running, whatever an earlier process did: the app
                // relaunches one whose resume was refused, and the run must follow it rather than the corpse.
                if case .started = e, exited.remove(member) != nil {
                    log("\(member): relaunched after exiting")
                    turns[member] = 0
                }
            }
        }
        // Terminal rows can contain NULs and other control bytes; keep the log plain text (grep treats NULs as binary).
        func clean(_ line: String) -> String {
            String(line.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : Character($0) })
        }
        func dumpScreen(_ member: String) {
            guard let host = rt.host(for: member) else { return }
            for l in host.recentLines(14) { log("   │ \(clean(l))") }
        }
        // The card the chat raises, at the moment it is raised. A member that never starts because it is holding
        // a dialog open leaves no other trace: the app simply does not brief it, which looks identical to the
        // app pasting into the dialog and losing the reply. Naming the dialog is the difference.
        rt.onAttention = { member, state in
            log("attention \(member): \(state.reason ?? "needs you")" + (rt.blockedHints[member].map { " — \($0)" } ?? ""))
        }
        rt.onExit = { member, status in
            log("\(member): exited (\(status.map(String.init) ?? "?"))")
            dumpScreen(member)
            exited.insert(member)
        }
        rt.start(environment: env, resume: resume, only: members)
        for p in rt.problems { log("problem \(p.member): \(p.message)") }
        let launched = rt.members.filter { rt.host(for: $0) != nil }
        guard !launched.isEmpty else { log("FAILED: nothing launched"); return 1 }
        log("launched \(launched.joined(separator: ", ")) (pids \(launched.compactMap { rt.host(for: $0)?.pid }.map(String.init).joined(separator: ", ")))")

        // 0b. Readiness trace: the signals looksReady actually consults, once a second, with the normalized
        //     screen lines that changed since the last sample. Codex draws its prompt within a few seconds but
        //     does not accept one for about twenty, and the difference has to be visible from inside the app —
        //     a pty probe outside it reads an empty screen, because the TUI redraws through the alternate
        //     buffer. Whatever flips at the twenty-second mark should show up here.
        var tracer: Task<Void, Never>?
        if traceScreen {
            let launchedAt = Date()
            tracer = Task { @MainActor in
                var previous: [String: [String]] = [:]
                var changedAt: [String: Date] = [:]
                var announced = Set<String>()
                while !Task.isCancelled {
                    let now = Date()
                    for m in launched {
                        guard let host = rt.host(for: m), host.isRunning else { continue }
                        let raw = host.recentLines(host.getTerminal().rows)
                        let lines = ScreenHeuristics.normalized(raw)
                        let before = previous[m]
                        if before != lines {
                            changedAt[m] = now
                            previous[m] = lines
                        }
                        // Stability is measured from what this loop has seen, not from the runtime's own poll:
                        // reading one and sampling the other gives a screen that just changed a long stable
                        // time, and looksReady then says ready seconds before the app agrees.
                        let stable = now.timeIntervalSince(changedAt[m] ?? now)
                        let ready = ScreenHeuristics.looksReady(lines: raw, outputBytes: host.outputBytes,
                                                                screenStableFor: stable, launchedAt: launchedAt, now: now)
                        let age = host.lastOutputAt.map { String(format: "%.1f", now.timeIntervalSince($0)) } ?? "never"
                        let dialog = ScreenHeuristics.blockingDialog(in: raw)?.reason ?? "-"
                        log("trace \(m): state=\(rt.state(of: m)) looksReady=\(ready) bytes=\(host.outputBytes) "
                            + "stable=\(String(format: "%.1f", stable))s lastOutput=\(age)s dialog=\(dialog) lines=\(lines.count)")
                        if let before, before != lines {
                            for l in lines.filter({ !before.contains($0) }).prefix(4) { log("   + \(clean(l))") }
                            for l in before.filter({ !lines.contains($0) }).prefix(4) { log("   - \(clean(l))") }
                        }
                        if ready, announced.insert(m).inserted {
                            log("trace \(m): looksReady first true at \(String(format: "%.1f", now.timeIntervalSince(launchedAt)))s")
                        }
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }

        // 1. Every launched member reports SessionStart (status leaves .starting) or dies.
        let startedAll = await waitUntil(timeout: min(timeout, 300)) {
            launched.allSatisfy { rt.statuses[$0] != .starting || exited.contains($0) }
        }
        if startedAll {
            log("all members started")
        } else {
            let late = launched.filter { rt.statuses[$0] == .starting }
            log("timeout waiting for SessionStart from \(late.joined(separator: ", "))")
            for m in late {
                guard let host = rt.host(for: m) else { continue }
                let age = host.lastOutputAt.map { String(format: "%.1f", Date().timeIntervalSince($0)) } ?? "never"
                let stable = rt.screenStableSeconds(for: m).map { String(format: "%.1f", $0) } ?? "?"
                let term = host.getTerminal()
                log("\(m) screen \(term.cols)×\(term.rows) (last output \(age) s ago, text stable \(stable) s), full screen:")
                let before = host.recentLines(term.rows)
                for (i, l) in before.enumerated() { log("   │\(String(format: "%2d", i)) \(clean(l))") }
                try? await Task.sleep(for: .seconds(1))
                let after = host.recentLines(term.rows)
                let changed = zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }
                log("\(m): \(changed.count) line(s) changed within 1 s" + (before.count != after.count ? " (line count \(before.count) → \(after.count))" : ""))
                for (i, pair) in changed.prefix(6) { log("   │\(String(format: "%2d", i)) was: \(clean(pair.0))"); log("   │\(String(format: "%2d", i)) now: \(clean(pair.1))") }
            }
        }
        tracer?.cancel()
        try? await Task.sleep(for: .seconds(settle))   // let the TUI draw its prompt

        let bus = Bus(directory: dir)
        var seen = Set(((try? bus.readAll()) ?? []).map(\.id))
        func newPosts() -> [Message] {
            let fresh = ((try? bus.readAll()) ?? []).filter { !seen.contains($0.id) }
            for m in fresh { seen.insert(m.id) }
            return fresh
        }
        let targets = (recipients ?? launched).filter { launched.contains($0) && !exited.contains($0) }

        // 2. The briefing goes out on its own (the runtime sends it as soon as a member is ready); wait for the
        //    hellos so the message that follows is not pasted into a CLI that is still reading its instructions.
        if !paste {
            let briefed = await waitUntil(timeout: min(timeout, 300)) {
                rt.awaitingBriefing.isEmpty && launched.allSatisfy { turns[$0, default: 0] >= 1 || exited.contains($0) }
            }
            log(briefed ? "all members briefed" : "timeout waiting for the briefing turn")
            for m in newPosts() { log("hello \(m.sender): \(m.text.prefix(100))") }
            if !briefed {
                for m in launched where turns[m, default: 0] < 1 && !exited.contains(m) { dumpScreen(m) }
            }
        }

        // 3. Send: through the bus and the router (what the composer does), or straight into the terminals.
        let roundBefore = turns
        if paste {
            log("pasting to \(targets.joined(separator: ", ")): \(message.prefix(80))")
            await rt.deliver(message, to: targets)
        } else {
            log("posting as user: \(message.prefix(80))")
            do { try rt.post(message) } catch { log("post failed: \(error.localizedDescription)"); return 1 }
        }

        // 4. Each target finishes the turn this message started.
        var finished = await waitUntil(timeout: timeout) {
            targets.allSatisfy { turns[$0, default: 0] > roundBefore[$0, default: 0] || exited.contains($0) }
        }
        try? await Task.sleep(for: .milliseconds(300))   // trailing post / events
        let replies = newPosts()
        for m in replies { log("post \(m.sender): \(m.text.prefix(120))") }

        // 4b. Retry, as the card does it: a member that gave up is relaunched and asked again for whatever it
        //     dropped. Its process may well still be alive — giving up does not kill it — which is exactly the
        //     case the card has to handle.
        if retryFailed {
            let gaveUp = targets.filter { rt.state(of: $0).hasGivenUp }
            if gaveUp.isEmpty {
                log("retry: nobody gave up")
            } else {
                let before = turns
                for m in gaveUp {
                    let alive = rt.host(for: m)?.isRunning == true
                    log("retry \(m) (state \(rt.statuses[m]?.label ?? "?"), process \(alive ? "still alive" : "gone"))")
                    rt.restart(m, environment: env)
                }
                let back = await waitUntil(timeout: timeout) {
                    gaveUp.allSatisfy { turns[$0, default: 0] > before[$0, default: 0] }
                }
                try? await Task.sleep(for: .milliseconds(300))
                for m in newPosts() { log("after retry \(m.sender): \(m.text.prefix(120))") }
                log(back ? "retried members finished a turn" : "timeout waiting for a retried member")
                for m in gaveUp where !back { dumpScreen(m) }
                // A member that only answered after being retried still counts as having answered.
                finished = targets.allSatisfy { turns[$0, default: 0] > roundBefore[$0, default: 0] || exited.contains($0) }
            }
        }

        // 5. The reaction pass, when the message went to more than one member (R11a).
        var reacted: [String] = []
        if !paste, targets.count > 1 {
            let passBefore = turns
            let passed = await waitUntil(timeout: min(timeout, 60)) {
                targets.allSatisfy { turns[$0, default: 0] > passBefore[$0, default: 0] || exited.contains($0) }
            }
            try? await Task.sleep(for: .milliseconds(300))
            reacted = targets.filter { turns[$0, default: 0] > passBefore[$0, default: 0] }
            log(passed ? "reaction pass: \(reacted.joined(separator: ", "))"
                       : "reaction pass reached \(reacted.joined(separator: ", ").isEmpty ? "nobody" : reacted.joined(separator: ", "))")
            for m in newPosts() { log("reaction post \(m.sender): \(m.text.prefix(120))") }
        }
        let after = replies

        var ok = finished
        for m in targets {
            let posted = after.contains { $0.sender == m }
            let ended = turns[m, default: 0] > roundBefore[m, default: 0]
            let lock = rt.host(for: m).map { " locked=\($0.inputLocked)" } ?? ""
            log("\(m): hooks=[\(hooksSeen[m]?.joined(separator: ",") ?? "")] posted=\(posted) turnEnded=\(ended) "
                + "reacted=\(reacted.contains(m)) status=\(rt.statuses[m]?.label ?? "?")\(lock)")
            if !ended {
                ok = false
                if !exited.contains(m) { dumpScreen(m) }
            }
        }
        rt.stop()
        try? await Task.sleep(for: .milliseconds(200))
        log(ok ? "OK" : "FAILED")
        return ok ? 0 : 1
    }

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
