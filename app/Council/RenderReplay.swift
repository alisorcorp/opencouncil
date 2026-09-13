import AppKit
import SwiftUI
import CouncilCore

/// Replays a saved conversation through the real chat UI.
/// `Council --render-replay <chat-dir> <output-dir> [--stress] [--live]` writes timings and a screenshot.
///
/// Without `--live` no members run: saved records are appended to a disposable copy and the cost measured is
/// rendering alone. That is worth having and it is not the app people use. Replaying this way never came near
/// a stall — 35 ms at worst against a twenty-second freeze — which is the result that made `--live` necessary.
///
/// `--live` starts the scripted stand-ins (`COUNCIL_FAKE_MEMBERS=1`, no model quota), so the things the plain
/// replay has none of are present: every member's terminal sits in the view hierarchy whether or not anyone is
/// looking at it, the once-a-second ticker reads the screens of members that are answering, and the activity
/// line above the composer changes as they work. It seeds the conversation with the saved user message and
/// lets the real router do the rest. The stall watchdog runs throughout, so a freeze leaves a sampled stack in
/// the output directory rather than only a number.
enum RenderReplayCommand {
    enum ReplayError: Error, CustomStringConvertible {
        case notFake, noUserMessage
        var description: String {
            switch self {
            case .notFake:
                return "--live needs COUNCIL_FAKE_MEMBERS=1; without it this would start the real CLIs and "
                     + "spend the maintainer's subscription"
            case .noUserMessage: return "the source chat has no user message to seed the conversation with"
            }
        }
    }

    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let index = arguments.firstIndex(of: "--render-replay"), arguments.count > index + 2 else { return false }
        let source = URL(fileURLWithPath: arguments[index + 1])
        let output = URL(fileURLWithPath: arguments[index + 2])
        let stress = arguments.contains("--stress")
        let live = arguments.contains("--live")
        Task { @MainActor in
            do {
                if live { try await replayLive(source: source, output: output) }
                else { try await replay(source: source, output: output, stress: stress) }
                exit(0)
            } catch { print("render-replay: \(error)"); exit(1) }
        }
        return true
    }

    // MARK: live

    @MainActor
    private static func replayLive(source: URL, output: URL) async throws {
        let fm = FileManager.default
        let config = try ChatConfig.load(from: source)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let began = ProcessInfo.processInfo.systemUptime
        func log(_ s: String) {
            let stamp = String(format: "%6.2fs", ProcessInfo.processInfo.systemUptime - began)
            FileHandle.standardOutput.write(Data("[\(stamp)] \(s)\n".utf8))
        }

        // The stand-in lives in the repo and its path is built from the council root, so the disposable root
        // has to be able to see it. Everything written stays inside the disposable root.
        let repoRoot = source.deletingLastPathComponent().deletingLastPathComponent()
        let root = fm.temporaryDirectory.appendingPathComponent("council-live-\(UUID().uuidString)")
        let name = "2026-01-01_000000_replay"
        let chat = root.appendingPathComponent("chats/\(name)")
        try fm.createDirectory(at: chat, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("council.py"))
        try Data().write(to: root.appendingPathComponent("council.toml"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("app"),
                                  withDestinationURL: repoRoot.appendingPathComponent("app"))
        try fm.copyItem(at: source.appendingPathComponent("config.json"), to: chat.appendingPathComponent("config.json"))
        let log0 = chat.appendingPathComponent("chat.jsonl")
        try Data().write(to: log0)

        // The stand-ins post what the real members posted, so the app renders the markdown and routes the
        // mentions a real conversation had. Without this they answer in one short line each and the replay
        // measures an empty room.
        let scripted = root.appendingPathComponent("replies.json")
        let counts = try writeScriptedReplies(from: source, to: scripted)
        setenv("FAKE_REPLIES", scripted.path, 1)
        log("scripted replies: " + counts.sorted(by: { $0.key < $1.key })
                .map { "\($0.key) \($0.value)" }.joined(separator: ", "))

        let paths = CouncilPaths(root: root)
        let shell = await Task.detached { ShellEnvironment.resolve() }.value
        let launch = MemberLaunchEnvironment.make(shell: shell, paths: paths)
        guard launch.isFake else { throw ReplayError.notFake }
        let sessions = LiveSessions(launchEnvironment: launch)
        log("members \(config.order.joined(separator: ", ")) · stand-ins · root \(root.lastPathComponent)")

        // The watchdog that caught the real freezes, pointed at this process. Held in a local for the length of
        // the run, which is a real owner; the app has none, which is why it owns itself there.
        let watchdog = StallWatchdog(options: .init(interval: 0.25, threshold: 1.5),
                                     sample: StallWatchdog.spawningSample(into: output, seconds: 3))
        watchdog.start()
        defer { watchdog.stop() }

        let hosting = NSHostingView(rootView:
            MainWindow(paths: paths, live: sessions, initialSelection: name, autoStartMembers: true)
                .environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1400, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.autoresizingMask = [.width, .height]
        window.acceptsMouseMovedEvents = true
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.close() }

        // Main-actor lateness, sampled throughout rather than only around an append: the freeze this is chasing
        // does not wait to be asked.
        var delays: [Double] = []
        func rest(_ seconds: Double) async {
            let start = ProcessInfo.processInfo.systemUptime
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            delays.append(max(0, ProcessInfo.processInfo.systemUptime - start - seconds))
        }
        func records() -> Int { (try? String(contentsOf: log0, encoding: .utf8))?.split(separator: "\n").count ?? 0 }

        for _ in 0..<120 { await rest(0.1) }        // members come up and print their first screen
        log("after start-up: \(records()) records, worst main-actor delay \(ms(delays.max()))")
        let startupWorst = delays.max() ?? 0

        guard let seed = try userMessage(in: source) else { throw ReplayError.noUserMessage }
        let handle = try FileHandle(forWritingTo: log0)
        try handle.seekToEnd()
        try handle.write(contentsOf: seed)
        try handle.close()
        log("seeded the conversation; the router takes it from here")

        // Run until the conversation stops growing, which is what the reaction pass settling looks like.
        var lastCount = records(), quietFor = 0.0, elapsed = 0.0
        while elapsed < 240, quietFor < 20 {
            await rest(0.1)
            elapsed += 0.1
            let now = records()
            if now != lastCount {
                log("\(now) records, worst so far \(ms(delays.max()))")
                lastCount = now
                quietFor = 0
            } else {
                quietFor += 0.1
            }
        }
        sessions.stopAll()
        try? await Task.sleep(for: .milliseconds(500))

        let stacks = ((try? fm.contentsOfDirectory(atPath: output.path)) ?? []).filter { $0.hasPrefix("stall-") }
        let result: [String: Any] = ["mode": "live", "records": lastCount, "elapsed_seconds": elapsed,
                                     "max_main_actor_delay_seconds": delays.max() ?? 0,
                                     "max_startup_delay_seconds": startupWorst,
                                     "stall_reports": stacks,
                                     "delays_seconds": delays]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("timings.json"))
        hosting.layoutSubtreeIfNeeded()
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: output.appendingPathComponent("final.png"))
            }
        }
        log("\(lastCount) records · worst main-actor delay \(ms(delays.max())) · "
            + (stacks.isEmpty ? "no stall reached the watchdog" : "STALLED, stacks: \(stacks.joined(separator: ", "))"))
    }

    private static func ms(_ seconds: Double?) -> String {
        String(format: "%.0fms", (seconds ?? 0) * 1000)
    }

    /// Every message each member posted, in order, so the stand-ins can say the same things. The briefing
    /// reply is dropped: the app asks for that one before any conversation exists, and replaying it would put
    /// a member one answer behind for the rest of the run.
    private static func writeScriptedReplies(from source: URL, to file: URL) throws -> [String: Int] {
        let data = try Data(contentsOf: source.appendingPathComponent("chat.jsonl"))
        var byMember: [String: [String]] = [:]
        for line in data.split(separator: 0x0a) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let from = object["from"] as? String, let text = object["text"] as? String,
                  from != "user", from != Message.systemSender, object["kind"] as? String != Message.kindNote
            else { continue }
            byMember[from, default: []].append(text)
        }
        for (member, texts) in byMember { byMember[member] = Array(texts.dropFirst()) }
        try JSONSerialization.data(withJSONObject: byMember, options: [.sortedKeys]).write(to: file)
        return byMember.mapValues(\.count)
    }

    /// The first thing the maintainer typed, which is what the members answered.
    private static func userMessage(in source: URL) throws -> Data? {
        let data = try Data(contentsOf: source.appendingPathComponent("chat.jsonl"))
        for line in data.split(separator: 0x0a) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["from"] as? String == "user" else { continue }
            return Data(line) + Data([0x0a])
        }
        return nil
    }

    @MainActor
    private static func replay(source: URL, output: URL, stress: Bool) async throws {
        let fm = FileManager.default
        _ = try ChatConfig.load(from: source)
        _ = try Bus(directory: source).readAll()
        let root = fm.temporaryDirectory.appendingPathComponent("council-render-\(UUID().uuidString)")
        let chat = root.appendingPathComponent("chats/2026-01-01_000000_replay")
        try fm.createDirectory(at: chat, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        // Only filenames are needed by the session browser; this harness never invokes the Python helper.
        try Data().write(to: root.appendingPathComponent("council.py"))
        try Data().write(to: root.appendingPathComponent("council.toml"))
        try fm.copyItem(at: source.appendingPathComponent("config.json"), to: chat.appendingPathComponent("config.json"))
        let data = try Data(contentsOf: source.appendingPathComponent("chat.jsonl"))
        let records = data.split(separator: 0x0a).map { Data($0) + Data([0x0a]) }
        guard !records.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let log = chat.appendingPathComponent("chat.jsonl")
        try records[0].write(to: log)

        let hosting = NSHostingView(rootView:
            MainWindow(paths: CouncilPaths(root: root), initialSelection: chat.lastPathComponent)
                .environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1400, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.autoresizingMask = [.width, .height]
        window.acceptsMouseMovedEvents = true
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.close() }
        try await Task.sleep(for: .seconds(2))

        // A deadline on the main actor measures how long rendering prevents it from serving another task.
        // The pause is also long enough to let each bus append reach the view through the real file tail.
        var delays: [Double] = []
        let began = ProcessInfo.processInfo.systemUptime
        let file = try FileHandle(forWritingTo: log)
        defer { try? file.close() }
        try file.seekToEnd()
        for (index, record) in records.dropFirst().enumerated() {
            try file.write(contentsOf: record)
            let start = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .milliseconds(250))
            let late = max(0, ProcessInfo.processInfo.systemUptime - start - 0.25)
            delays.append(late)
            print(String(format: "render-replay: message %d, main-actor delay %.3fs", index + 2, late))
        }
        for _ in 0..<8 {
            let start = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .milliseconds(250))
            delays.append(max(0, ProcessInfo.processInfo.systemUptime - start - 0.25))
        }
        var stressDelays: [Double] = []
        var scrollSteps = 0
        if stress {
            // Exercise anchor conversion as the window reflows, lazy rows enter/leave the viewport, and
            // the pointer crosses text. Events go only to this offscreen window; the real pointer stays put.
            for step in 0..<100 {
                let start = ProcessInfo.processInfo.systemUptime
                window.setContentSize(NSSize(width: 950 + (step % 10) * 50, height: 650 + (step % 7) * 40))
                hosting.layoutSubtreeIfNeeded()
                if let scroll = transcriptScrollView(in: hosting), let document = scroll.documentView {
                    let range = max(0, document.bounds.height - scroll.contentView.bounds.height)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: range * Double(step % 5) / 4))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    scrollSteps += 1
                }
                if let event = NSEvent.mouseEvent(with: .mouseMoved,
                                                 location: NSPoint(x: 500 + step % 200, y: 250 + step % 100),
                                                 modifierFlags: [], timestamp: start,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: step, clickCount: 0, pressure: 0) {
                    window.sendEvent(event)
                }
                try await Task.sleep(for: .milliseconds(50))
                stressDelays.append(max(0, ProcessInfo.processInfo.systemUptime - start - 0.05))
            }
            window.setContentSize(NSSize(width: 1400, height: 900))
            try await Task.sleep(for: .milliseconds(300))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let result: [String: Any] = ["messages": records.count, "elapsed_seconds": elapsed,
                                   "max_main_actor_delay_seconds": delays.max() ?? 0,
                                   "max_stress_delay_seconds": stressDelays.max() ?? 0,
                                   "scroll_steps": scrollSteps,
                                   "stress_delays_seconds": stressDelays,
                                   "delays_seconds": delays]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("timings.json"))
        hosting.layoutSubtreeIfNeeded()
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: output.appendingPathComponent("final.png"))
            }
        }
        print(String(format: "render-replay: %d messages in %.3fs, maximum delay %.3fs", records.count, elapsed, delays.max() ?? 0))
    }

    @MainActor
    private static func transcriptScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView?.bounds.height ?? 0 > 1000 { return scroll }
        return view.subviews.compactMap { transcriptScrollView(in: $0) }.first
    }
}
