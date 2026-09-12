import AppKit
import Foundation
import Observation
import CouncilCore

/// App-wide state that everything else hangs off: where the council folder is, the parsed config,
/// the resolved shell environment (PATH and tool locations), and the registry of live sessions.
/// Loaded once at launch.
@Observable
@MainActor
final class AppEnvironment {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var paths: CouncilPaths?
    private(set) var config: CouncilConfig?
    private(set) var shell: ShellEnvironment?
    private(set) var toolLocations: [String: URL?] = [:]
    /// Sessions with members running in the app. Nil until bootstrap succeeds.
    private(set) var live: LiveSessions?
    /// Notifications and the dock badge.
    let notifier = Notifier()
    /// The session the user is looking at, so a reply they can already see does not also buzz.
    var visibleSessionID: String?

    static let rootDefaultsKey = "councilRoot"
    /// Every CLI the app looks for, derived from the backends themselves so that adding one cannot leave this
    /// list — or the Environment window that reads it — behind. `council` is not a backend but is what the
    /// members' hooks run, so a missing one is worth seeing here too.
    static let tools = CouncilConfig.Backend.allCases.filter(\.isTerminalBackend).map(\.rawValue) + ["council"]

    /// True inside the XCTest host. The host must not touch the user's council folder: a Debug build is ad-hoc
    /// signed, so every rebuild re-triggers the Documents privacy prompt, and `open()` then blocks the main
    /// thread until someone clicks Allow, which the test runner reports as "hung before establishing connection".
    nonisolated static let isTestHost = ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XCTest") }
        || NSClassFromString("XCTestCase") != nil

    func bootstrap() async {
        guard !Self.isTestHost else {
            phase = .failed("Test host: the app does not load a council folder while tests run.")
            return
        }
        let preferred = UserDefaults.standard.url(forKey: Self.rootDefaultsKey)
        guard let paths = CouncilPaths.discoverRoot(preferred: preferred) else {
            phase = .failed("Could not find the council folder. Run install.sh in it, or pick it in Settings.")
            return
        }
        self.paths = paths
        do {
            config = try CouncilConfig.load(from: paths.configFile)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        let shell = await Task.detached(priority: .userInitiated) { ShellEnvironment.resolve() }.value
        self.shell = shell
        var found: [String: URL?] = [:]
        for tool in Self.tools { found[tool] = shell.which(tool) }
        toolLocations = found
        let sessions = LiveSessions(launchEnvironment: MemberLaunchEnvironment.make(shell: shell, paths: paths))
        sessions.onNotice = { [weak self] notice in self?.deliver(notice) }
        sessions.onSessionStarted = { [weak self] in self?.notifier.requestAuthorizationIfNeeded() }
        live = sessions
        phase = .ready
    }

    /// Sends a notice on if the user cannot already see it (`NotificationPolicy`).
    private func deliver(_ notice: LiveSessions.Notice) {
        let context = NotificationPolicy.Context(appIsActive: NSApplication.shared.isActive,
                                                 sessionIsVisible: visibleSessionID == notice.session)
        guard NotificationPolicy.shouldNotify(notice.event, context) else { return }
        switch notice {
        case .post(let session, let title, let body, _), .attention(let session, let title, let body),
             .verdict(let session, let title, let body):
            notifier.notify(title: title, body: body, sessionId: session)
        }
    }

    /// Lets the user point the app at a different council checkout. Members of the old one are stopped.
    func setRoot(_ url: URL) async {
        live?.stopAll()
        live = nil
        UserDefaults.standard.set(url, forKey: Self.rootDefaultsKey)
        phase = .loading
        await bootstrap()
    }
}
