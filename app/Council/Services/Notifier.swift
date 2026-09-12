import AppKit
import UserNotifications
import Observation

/// When something that happened in a session is worth interrupting the user for. Pure, so the rules are a test
/// rather than something only observable by leaving the app running in the background.
enum NotificationPolicy {
    enum Event: Equatable {
        /// A member posted an answer. `isHello` marks its reply to the briefing, which is not news.
        case post(isHello: Bool)
        /// A member is blocked or gave up: the chat cannot continue without the user.
        case card
        /// A verdict run finished.
        case verdict
        /// A dim system note (budget reached, nothing to add). Never worth a notification.
        case note
    }

    struct Context: Equatable {
        /// The app is frontmost.
        var appIsActive: Bool
        /// The session in question is the one on screen.
        var sessionIsVisible: Bool

        init(appIsActive: Bool, sessionIsVisible: Bool) {
            self.appIsActive = appIsActive
            self.sessionIsVisible = sessionIsVisible
        }
    }

    /// A card always interrupts: nothing else in the chat will move until it is dealt with. A post interrupts
    /// only when the user cannot already see it. Hellos and notes never do.
    static func shouldNotify(_ event: Event, _ context: Context) -> Bool {
        switch event {
        case .card, .verdict: return true
        case .note: return false
        case .post(let isHello):
            if isHello { return false }
            return !(context.appIsActive && context.sessionIsVisible)
        }
    }
}

/// macOS notifications, with the dock badge as the fallback. A development build is ad-hoc signed and may not
/// be allowed to post notifications at all; that is not worth a crash or a second complaint, so it is reported
/// once and the badge carries the unread count on its own.
@Observable
@MainActor
final class Notifier: NSObject {
    /// Called with a session id when the user clicks a notification.
    var onOpenSession: ((String) -> Void)?
    private(set) var isAuthorized = false
    private(set) var unavailableReason: String?
    private var didAsk = false

    /// What actually talks to `usernoted`, injected so a test can prove the caller is never made to wait for
    /// it. The default reaches `UNUserNotificationCenter`, which is XPC, and the first reach for a freshly
    /// installed bundle can take many seconds.
    private nonisolated let authorize: @Sendable () async -> (granted: Bool, failure: String?)

    init(authorize: @escaping @Sendable () async -> (granted: Bool, failure: String?) = Notifier.askTheSystem) {
        self.authorize = authorize
        super.init()
    }

    nonisolated static let sessionKey = "session"

    private var center: UNUserNotificationCenter? {
        // Reading the centre of a bundle the system does not recognise throws an exception rather than
        // returning nil, so anything unexpected here means "no notifications", not "crash".
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// Asked the first time a session goes live, rather than at launch: a permission dialog makes more sense
    /// next to the thing that needs it.
    ///
    /// None of it happens on the main actor. Reaching the notification centre is XPC to `usernoted`, and the
    /// first reach for a newly installed bundle is slow — on the main actor, at the moment the members start,
    /// that is a spinning cursor through the first round of a chat. Nothing here has to finish before a
    /// session can run: the badge works unauthorised, and a notification is only offered once `isAuthorized`
    /// says so. If it is ever slow again it says so in the log, so the next person does not have to guess.
    func requestAuthorizationIfNeeded() {
        guard !didAsk else { return }
        didAsk = true
        guard Bundle.main.bundleIdentifier != nil else { report("this build has no bundle identifier"); return }
        let authorize = self.authorize
        Task.detached(priority: .utility) { [weak self] in
            let started = Date()
            let (granted, failure) = await authorize()
            let took = Date().timeIntervalSince(started)
            await MainActor.run {
                guard let self else { return }
                if took > 1 { NSLog("Council: the notification centre took %.1fs to answer", took) }
                self.isAuthorized = granted
                if let failure { self.report(failure) }
                // Safe on the main actor now: the centre is warm, so this is a property set rather than a
                // first connection.
                if granted { self.center?.delegate = self }
            }
        }
    }

    /// The real thing. `nonisolated` and `async` so it can only be reached off the main actor.
    nonisolated static let askTheSystem: @Sendable () async -> (granted: Bool, failure: String?) = {
        let center = UNUserNotificationCenter.current()
        do {
            return (try await center.requestAuthorization(options: [.alert, .sound]), nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func notify(title: String, body: String, sessionId: String) {
        guard isAuthorized, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [Self.sessionKey: sessionId]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// The dock badge always works, authorised or not.
    func setBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    private func report(_ reason: String) {
        guard unavailableReason == nil else { return }
        unavailableReason = reason
        NSLog("Council: notifications unavailable (\(reason)); using the dock badge instead")
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo[Self.sessionKey] as? String
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            if let id { onOpenSession?(id) }
        }
    }

    /// Without this a notification from the frontmost app is swallowed; the policy already decided it is worth
    /// showing, so show it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
