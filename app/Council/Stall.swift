import AppKit
import CouncilCore

/// Developer tool: `Council --stall [seconds]`.
///
/// The watchdog's one claim is that it samples *during* a stall. A unit test can only check the order its own
/// closures ran in, which is worth having and is not the same claim. This blocks the real main thread of a
/// running app for real seconds and then asks the question a late report cannot pass: was the file already on
/// disk before the main thread came back, and does the stack in it show the main thread inside the block?
///
/// Run it with `app/build.sh` output directly, e.g.
/// `DEVELOPER_DIR=… .build/Build/Products/Debug/Council.app/Contents/MacOS/Council --stall 6`.
enum StallCommand {
    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let i = arguments.firstIndex(of: "--stall") else { return false }
        let seconds = arguments.count > i + 1 ? (Double(arguments[i + 1]) ?? 6) : 6
        // Deliberately not run from `init()`: before the run loop starts nothing drains the main queue, so a
        // ping would go unanswered whether the main thread was stuck or idle, and the test would pass without
        // ever having measured anything.
        Task { @MainActor in exit(await run(seconds: max(seconds, 3))) }
        return true
    }

    @MainActor
    private static func run(seconds: Double) async -> Int32 {
        var failures = 0
        func log(_ s: String) { FileHandle.standardOutput.write(Data("\(s)\n".utf8)) }
        func expect(_ condition: Bool, _ what: String) {
            log((condition ? "ok   " : "FAIL ") + what)
            if !condition { failures += 1 }
        }

        let reports = StallWatchdog.defaultReports
        try? FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let before = names(in: reports)
        let sampleSeconds = 2
        let threshold = 1.0
        let watchdog = StallWatchdog(options: .init(interval: 0.25, threshold: threshold),
                                     sample: StallWatchdog.spawningSample(into: reports, seconds: sampleSeconds))
        watchdog.start()
        log("reports: \(reports.path)")
        log("threshold \(threshold)s, sample \(sampleSeconds)s, blocking for \(seconds)s")

        // A watchdog that fires on a healthy app is worse than none, so the quiet case goes first. The main
        // actor is free for longer than the threshold here, and every ping comes straight back.
        try? await Task.sleep(for: .seconds(threshold + 1))
        expect(names(in: reports).subtracting(before).isEmpty, "nothing is reported while the app is answering")

        let blockedFrom = Date()
        block(for: seconds)                             // this is what a beachball is
        let wokeAt = Date()
        watchdog.stop()
        expect(wokeAt.timeIntervalSince(blockedFrom) >= seconds,
               "the main thread was blocked for \(String(format: "%.1f", wokeAt.timeIntervalSince(blockedFrom)))s")

        let fresh = names(in: reports).subtracting(before)
        expect(fresh.count == 1, "one report was written (got \(fresh.count))")
        guard let name = fresh.sorted().last else {
            log("FAILED (\(failures + 1))")
            return 1
        }
        let file = reports.appendingPathComponent(name)

        // The whole point. A watchdog that waited for the round trip to finish would spawn `sample` after
        // this moment, and the file's timestamp would fall on the other side of it.
        let written = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        if let written {
            let margin = wokeAt.timeIntervalSince(written)
            expect(margin > 0, "the report was written \(String(format: "%.1f", margin))s "
                   + "\(margin > 0 ? "before" : "after") the main thread came back")
        } else {
            expect(false, "the report has a modification date")
        }

        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let stack = mainThread(of: text)
        expect(stack.contains("sleepForTimeInterval") || stack.contains("__semwait_signal"),
               "the sampled stack shows the main thread inside the block")
        log("report: \(file.path) (\(text.count) bytes)")
        for line in stack.split(separator: "\n").suffix(3) { log("  \(line.trimmingCharacters(in: .whitespaces))") }

        log(failures == 0 ? "OK" : "FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }

    /// `sample` writes one indented block per thread, each headed by `NNN Thread_<id>`, and the main one
    /// says so by name. Scoping the search to that block is what makes this a claim about the main thread
    /// rather than about any thread in the process that happens to be waiting on something.
    private static func mainThread(of report: String) -> String {
        let lines = report.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.contains("com.apple.main-thread") }) else { return "" }
        let rest = lines[lines.index(after: start)...]
        let end = rest.firstIndex { $0.range(of: "^ *[0-9]+ Thread_", options: .regularExpression) != nil }
        return lines[start..<(end ?? lines.endIndex)].joined(separator: "\n")
    }

    /// `Thread.sleep` is marked unavailable from async contexts, for the good reason that blocking a thread
    /// is almost never what an async function wants. Here it is exactly what is wanted, and a synchronous
    /// call is how you say so.
    @MainActor
    private static func block(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private static func names(in directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }
}
