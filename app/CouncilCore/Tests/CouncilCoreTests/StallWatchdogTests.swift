import XCTest
@testable import CouncilCore

/// The watchdog exists to capture a stack from an app that is stuck, so the only interesting question is
/// *when* it samples. A monitor that sends a ping, waits for the answer, and then measures the round trip
/// would pass every test about durations and still be useless, because by the time the answer arrives the
/// main thread is working again and the stack is of an app with nothing wrong with it. These drive the loop
/// with a clock of their own so the order of events is decided rather than raced.
final class StallWatchdogTests: XCTestCase {
    /// Both ends of the loop: a main actor that answers only when the test says so, and a sampler that
    /// records whether a ping was still outstanding at the moment it was asked for a stack.
    private final class Ends: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: (@Sendable () -> Void)?
        private(set) var pings = 0
        private(set) var samples = 0
        /// The failure this whole class is built to catch: a sample taken after the main thread recovered.
        private(set) var everSampledWithNothingOutstanding = false

        var isOutstanding: Bool {
            lock.lock(); defer { lock.unlock() }
            return answer != nil
        }

        /// Stores the callback and does not call it. The main actor is busy.
        func ping(_ done: @escaping @Sendable () -> Void) {
            lock.lock(); pings += 1; answer = done; lock.unlock()
        }

        /// The main thread comes back and drains its queue.
        func comeBack() {
            lock.lock(); let done = answer; answer = nil; lock.unlock()
            done?()
        }

        func sample() {
            lock.lock()
            samples += 1
            if answer == nil { everSampledWithNothingOutstanding = true }
            lock.unlock()
        }
    }

    private func makeWatchdog(_ ends: Ends, now: @escaping @Sendable () -> TimeInterval) -> StallWatchdog {
        StallWatchdog(options: .init(interval: 0.25, threshold: 1.5),
                      clock: now,
                      ping: { done in ends.ping(done) },
                      sample: { ends.sample() })
    }

    /// A box the closures and the test can both reach, since the clock closure has to be `@Sendable`.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0
        var now: TimeInterval {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    func testAnAppThatKeepsAnsweringIsNeverReported() {
        let ends = Ends(), clock = Clock()
        let watchdog = makeWatchdog(ends, now: { clock.now })
        for step in 0..<20 {
            clock.now = Double(step) * 10          // far longer than the threshold, between every ping
            watchdog.tick()
            ends.comeBack()
        }
        XCTAssertEqual(ends.samples, 0, "a healthy app was reported as stuck")
        XCTAssertEqual(ends.pings, 20, "the loop stopped pinging")
    }

    func testItSamplesWhileThePingIsStillUnanswered() {
        let ends = Ends(), clock = Clock()
        let watchdog = makeWatchdog(ends, now: { clock.now })

        watchdog.tick()                            // a ping goes out at 0 and is never answered
        XCTAssertTrue(ends.isOutstanding)

        clock.now = 1.4
        watchdog.tick()
        XCTAssertEqual(ends.samples, 0, "reported before the threshold")

        clock.now = 1.6
        watchdog.tick()
        XCTAssertEqual(ends.samples, 1, "the stall was not reported")
        XCTAssertTrue(ends.isOutstanding, "the main actor answered, so this was not a stall at all")
        XCTAssertFalse(ends.everSampledWithNothingOutstanding,
                       "the sample was taken after the main thread came back, which is the one thing this "
                       + "watchdog must never do")

        // Recovery is the moment the wrong design gives itself away: a watchdog that waited for the round
        // trip would do its sampling here, with the app already working again.
        ends.comeBack()
        XCTAssertEqual(ends.samples, 1, "a sample was taken as the app recovered")
        XCTAssertFalse(ends.everSampledWithNothingOutstanding)
    }

    func testALongStallIsOneReport() {
        let ends = Ends(), clock = Clock()
        let watchdog = makeWatchdog(ends, now: { clock.now })
        watchdog.tick()
        for step in stride(from: 1.6, through: 20.0, by: 0.25) {
            clock.now = step
            watchdog.tick()
        }
        XCTAssertEqual(ends.samples, 1, "a twenty-second freeze is one event, not eighty")
        XCTAssertEqual(ends.pings, 1, "a new ping went out while the old one was still unanswered")
    }

    func testTheNextStallGetsItsOwnReport() {
        let ends = Ends(), clock = Clock()
        let watchdog = makeWatchdog(ends, now: { clock.now })
        watchdog.tick()
        clock.now = 2.0
        watchdog.tick()
        XCTAssertEqual(ends.samples, 1)

        ends.comeBack()                            // the app recovers
        clock.now = 2.5
        watchdog.tick()                            // and is asked again
        XCTAssertEqual(ends.samples, 1, "recovering was reported as a second stall")

        clock.now = 4.5
        watchdog.tick()
        XCTAssertEqual(ends.samples, 2, "the second stall went unreported")
        XCTAssertFalse(ends.everSampledWithNothingOutstanding)
    }

    /// The app starts the watchdog and throws the reference away, which is the only thing it can sensibly do
    /// from `CouncilApp.init()`. Every closure in the loop holds `self` weakly, so unless something owns it for
    /// the life of the process the whole thing deallocates the moment the call returns and the app watches
    /// nothing. `--stall` cannot see this: it keeps its own instance in a local for the length of the test.
    func testItStaysAliveAfterTheCallerLetsGo() {
        let reports = Self.scratch()
        weak var afterTheCallReturns: StallWatchdog?
        do {
            let started = StallWatchdog.startIfRequested(environment: ["COUNCIL_WATCHDOG": "1"], reports: reports)
            XCTAssertNotNil(started)
            afterTheCallReturns = started
        }                                          // exactly what `_ = StallWatchdog.startIfRequested()` does
        XCTAssertNotNil(afterTheCallReturns,
                        "nothing owns the watchdog, so the app starts one and it deallocates immediately")
        XCTAssertNotNil(StallWatchdog.running, "the process has no watchdog to reach")
        StallWatchdog.running?.stop()
        XCTAssertNil(StallWatchdog.running, "stopping it left the process holding a dead watchdog")
    }

    /// Two of them sampling the same process would each report the other.
    func testAskingTwiceGivesTheSameWatchdog() {
        let reports = Self.scratch()
        let first = StallWatchdog.startIfRequested(environment: ["COUNCIL_WATCHDOG": "1"], reports: reports)
        let second = StallWatchdog.startIfRequested(environment: ["COUNCIL_WATCHDOG": "1"], reports: reports)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "a second call started a second watchdog")
        first?.stop()
    }

    private static func scratch() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("council-watchdog-\(UUID().uuidString)")
    }

    /// Spawning `sample` at a process in trouble is the right trade while chasing a stall and the wrong one
    /// for everybody else, so absence and every falsey spelling have to mean off.
    func testItOnlyRunsWhenAskedFor() throws {
        let reports = Self.scratch()
        for environment in [[:], ["COUNCIL_WATCHDOG": ""], ["COUNCIL_WATCHDOG": "0"],
                            ["COUNCIL_WATCHDOG": "no"], ["SOMETHING_ELSE": "1"]] as [[String: String]] {
            XCTAssertNil(StallWatchdog.startIfRequested(environment: environment, reports: reports),
                         "started with \(environment)")
        }
        let watchdog = StallWatchdog.startIfRequested(environment: ["COUNCIL_WATCHDOG": "1"], reports: reports)
        XCTAssertNotNil(watchdog)
        watchdog?.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: reports.path),
                       "starting the watchdog wrote something before anything had stalled")
    }
}
