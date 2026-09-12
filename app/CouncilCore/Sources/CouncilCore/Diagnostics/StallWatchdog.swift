import Foundation

/// Notices that the main actor has stopped answering, and takes a stack sample while it is still stuck.
///
/// The "while" is the whole design. The obvious shape is to send a ping, await it, and complain about how
/// long the round trip took, but that complaint can only be made after the main thread has come back, and a
/// sample taken then is a sample of an app that is working again. This one never waits for the ping. It
/// records when one went out, and the clock decides when to sample, so the report is written during the
/// beachball rather than after it.
///
/// Off unless `COUNCIL_WATCHDOG` is set. It spawns `/usr/bin/sample` against a process that is already in
/// trouble, which is the right trade while chasing a stall and the wrong one for everybody else.
///
/// `Council --stall <seconds>` blocks the main thread on purpose and checks that a report lands before the
/// block ends, which is the only way to tell this apart from a watchdog that merely reports late.
public final class StallWatchdog: @unchecked Sendable {
    /// Asks the main actor to call back. Nothing waits for it: the callback arriving is the only signal, and
    /// its absence is the thing being measured.
    public typealias Ping = @Sendable (@escaping @Sendable () -> Void) -> Void
    /// Takes the stack. Called from the watchdog's own queue, never the main actor, which is what lets it run
    /// at all while the main thread is blocked.
    public typealias Sampler = @Sendable () -> Void

    public struct Options: Sendable {
        /// How often a ping goes out while the main actor is keeping up.
        public var interval: TimeInterval
        /// How long a ping may go unanswered before this counts as a stall. Below roughly a second the
        /// ordinary hitches of a launch or a big paste start reporting themselves.
        public var threshold: TimeInterval

        public init(interval: TimeInterval = 0.25, threshold: TimeInterval = 1.5) {
            self.interval = interval
            self.threshold = threshold
        }
    }

    private let options: Options
    private let clock: @Sendable () -> TimeInterval
    private let ping: Ping
    private let sample: Sampler
    private let queue: DispatchQueue

    private let lock = NSLock()
    /// When the outstanding ping went out, or nil when the main actor is up to date.
    private var sentAt: TimeInterval?
    /// One report per stall. A twenty-second freeze is one event, not eighty.
    private var sampledThisStall = false
    private var started = false
    private var stopped = false

    public init(options: Options = Options(),
                clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
                ping: @escaping Ping = StallWatchdog.pingTheMainActor,
                sample: @escaping Sampler) {
        self.options = options
        self.clock = clock
        self.ping = ping
        self.sample = sample
        self.queue = DispatchQueue(label: "me.opencouncil.stall-watchdog", qos: .utility)
    }

    // MARK: running

    public func start() {
        lock.lock()
        guard !started, !stopped else { return lock.unlock() }
        started = true
        lock.unlock()
        queue.async { [weak self] in
            self?.tick()
            self?.schedule()
        }
    }

    public func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func schedule() {
        queue.asyncAfter(deadline: .now() + options.interval) { [weak self] in
            guard let self, !self.isStopped else { return }
            self.tick()
            self.schedule()
        }
    }

    /// One turn of the loop. Internal so a test can drive it with a clock of its own and watch the order of
    /// events, rather than sleeping and hoping.
    func tick() {
        let now = clock()
        lock.lock()
        guard let sent = sentAt else {
            // The main actor answered the last one, so ask again and start the clock over.
            sentAt = now
            sampledThisStall = false
            lock.unlock()
            ping { [weak self] in self?.answered() }
            return
        }
        let due = now - sent >= options.threshold && !sampledThisStall
        if due { sampledThisStall = true }
        lock.unlock()
        // Deliberately outside the lock and outside any wait on the ping: the main thread is stuck right now,
        // and right now is the only time the stack is worth having.
        if due { sample() }
    }

    private func answered() {
        lock.lock(); sentAt = nil; lock.unlock()
    }

    // MARK: the real ends

    public static let pingTheMainActor: Ping = { answer in
        Task { @MainActor in answer() }
    }

    /// `~/Library/Logs/Council`, which is where Console looks and where a beta tester can find a report
    /// without being told a path twice.
    public static var defaultReports: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library.appendingPathComponent("Logs/Council", isDirectory: true)
    }

    /// Spawns `/usr/bin/sample` at this process. It can attach to a locally-signed build only because the
    /// app is built with `com.apple.security.get-task-allow`; a hardened runtime without it refuses, and the
    /// failure is silent apart from a missing report.
    public static func spawningSample(into reports: URL, seconds: Int = 3) -> Sampler {
        {
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sample") else { return }
            try? FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            let file = reports.appendingPathComponent("stall-\(ChatSessionFactory.stamp(Date())).txt")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [String(ProcessInfo.processInfo.processIdentifier), String(seconds),
                                 "-file", file.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            // Blocks this queue for the length of the sample, which is what keeps two reports from overlapping.
            process.waitUntilExit()
        }
    }

    /// `COUNCIL_WATCHDOG=1`. Anything falsey, and absence, leaves the app with no watchdog at all.
    @discardableResult
    public static func startIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment,
                                        reports: URL = StallWatchdog.defaultReports) -> StallWatchdog? {
        let asked = environment["COUNCIL_WATCHDOG"] ?? ""
        guard ["1", "true", "yes", "on"].contains(asked.lowercased()) else { return nil }
        let watchdog = StallWatchdog(sample: spawningSample(into: reports))
        watchdog.start()
        return watchdog
    }
}
