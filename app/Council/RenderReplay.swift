import AppKit
import SwiftUI
import CouncilCore

/// Replays a saved conversation through the real chat UI, without launching members or changing the source.
/// `Council --render-replay <chat-dir> <output-dir> [--stress]` writes timings and a final screenshot.
/// Stress adds window reflow and programmatic scrolling; it does not simulate a live member runtime.
enum RenderReplayCommand {
    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let index = arguments.firstIndex(of: "--render-replay"), arguments.count > index + 2 else { return false }
        let source = URL(fileURLWithPath: arguments[index + 1])
        let output = URL(fileURLWithPath: arguments[index + 2])
        let stress = arguments.contains("--stress")
        Task { @MainActor in
            do { try await replay(source: source, output: output, stress: stress); exit(0) }
            catch { print("render-replay: \(error)"); exit(1) }
        }
        return true
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
