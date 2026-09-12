import AppKit
import CouncilCore

/// Developer tool: `Council --ask <run-dir> [--timeout <s>] [--cwd <dir>] [--retry-moderator]`.
/// Runs a verdict the way the app does — hidden terminals, the question pasted, answers collected from
/// `council post`, the moderator last — and prints what each round produced. Exits 0 when the run reached a
/// verdict. With `COUNCIL_FAKE_MEMBERS=1` this exercises the whole chain without model calls.
enum AskCommand {
    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let i = arguments.firstIndex(of: "--ask"), arguments.count >= i + 2 else { return false }
        let dir = URL(fileURLWithPath: arguments[i + 1]).standardizedFileURL
        var rest = Array(arguments[(i + 2)...])
        var timeout: TimeInterval = 120
        var cwd: URL?
        var mode: VerdictRuntime.StartMode = .resume
        while !rest.isEmpty {
            let a = rest.removeFirst()
            switch a {
            case "--timeout":
                if let v = rest.first.flatMap(Double.init) { timeout = v; rest.removeFirst() }
            case "--cwd":
                if let v = rest.first { cwd = URL(fileURLWithPath: v).standardizedFileURL; rest.removeFirst() }
            case "--retry-moderator":
                // A run whose moderator gave up reads back as finished, so an ordinary start declines it.
                mode = .moderator
            default:
                break
            }
        }
        Task { @MainActor in exit(await run(dir: dir, timeout: timeout, cwd: cwd, mode: mode)) }
        return true
    }

    @MainActor
    private static func run(dir: URL, timeout: TimeInterval, cwd: URL?,
                            mode: VerdictRuntime.StartMode = .resume) async -> Int32 {
        let t0 = Date()
        func log(_ s: String) {
            FileHandle.standardOutput.write(Data("[\(String(format: "%6.2fs", Date().timeIntervalSince(t0)))] \(s)\n".utf8))
        }
        let paths = CouncilPaths(root: dir.deletingLastPathComponent().deletingLastPathComponent())
        guard paths.isValid else { log("ask: \(dir.path) is not inside a council folder"); return 2 }
        let run: VerdictRun
        let sessionDir: URL
        let sessionConfig: ChatConfig
        do {
            let config = try CouncilConfig.load(from: paths.configFile)
            run = try VerdictRun(directory: dir)
            // Where the members work: `--cwd`, else what the sheet recorded in app.json, else the run itself.
            let workingDir = cwd ?? SessionAppState.load(from: dir).cwdOverride.map { URL(fileURLWithPath: $0) } ?? dir
            sessionDir = try RunFactory(paths: paths, config: config).prepareSessions(in: dir, cwd: workingDir)
            sessionConfig = try ChatConfig.load(from: sessionDir)
        } catch {
            log("ask: \(error.localizedDescription)")
            return 2
        }
        let shell = await Task.detached { ShellEnvironment.resolve() }.value
        let env = MemberLaunchEnvironment.make(shell: shell, paths: paths)
        log("cwd \(sessionConfig.cwd)")
        log("run \(dir.lastPathComponent) · members \(run.order.joined(separator: ", ")) · moderator "
            + "\(run.moderatorName) · \(run.rounds) round(s)\(run.anonymous ? " · anonymous" : "") · fake=\(env.isFake)")

        let rt = VerdictRuntime(id: dir.lastPathComponent, run: run, sessionDirectory: sessionDir,
                                sessionConfig: sessionConfig)
        var finishedScore: Int??
        var finishedReason: String?
        rt.onFinished = { score, reason in
            finishedScore = .some(score)
            finishedReason = reason
        }
        rt.onChanged = { }
        rt.start(environment: env, mode: mode)
        for p in rt.problems { log("problem \(p.member): \(p.message)") }
        guard rt.isRunning || rt.isFinished else { log("FAILED: nothing launched"); return 1 }
        log("launched \(rt.participants.filter { rt.host(for: $0) != nil }.joined(separator: ", "))")

        var lastPhase: VerdictOrchestrator.Phase?
        let done = await waitUntil(timeout: timeout) {
            if rt.phase != lastPhase { lastPhase = rt.phase; log("phase \(rt.phase)") }
            return finishedScore != nil
        }
        try? await Task.sleep(for: .milliseconds(300))
        rt.stop()

        for note in rt.notes { log("note: \(note)") }
        let state = RunState.read(run)
        for round in 1...run.rounds {
            for member in run.order {
                let d = run.done(member, round: round)
                let words = run.answer(member, round: round).split(whereSeparator: \.isWhitespace).count
                log("r\(round) \(member): \(d.map { "\($0.status)\($0.error.map { " (\($0))" } ?? "")" } ?? "—") · \(words) words")
            }
        }
        log("state \(state.phase) · score \(state.score.map(String.init) ?? "none")"
            + (finishedReason.map { " · \($0)" } ?? ""))
        let transcript = dir.appendingPathComponent("transcript.md")
        log("transcript \(FileManager.default.fileExists(atPath: transcript.path) ? "written" : "MISSING")")
        let ok = done && state.phase == .complete
        log(ok ? "OK" : "FAILED")
        return ok ? 0 : 1
    }

    @MainActor
    private static func waitUntil(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return condition()
    }
}
