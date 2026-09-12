import XCTest
@testable import Council

/// A session going live asks for notification permission. Reaching the notification centre is XPC to
/// `usernoted`, and the first reach for a freshly installed bundle is slow — which, on the main actor at the
/// moment the members start, is a spinning cursor through the first round. Whatever the centre does, starting
/// a session must not wait for it.
final class NotifierTests: XCTestCase {
    @MainActor
    func testAskingForPermissionDoesNotMakeTheSessionWaitForTheNotificationCentre() {
        let reached = expectation(description: "the centre was reached")
        let notifier = Notifier(authorize: {
            reached.fulfill()
            try? await Task.sleep(for: .seconds(3))     // a slow usernoted, as observed
            return (true, nil)
        })
        let started = Date()
        notifier.requestAuthorizationIfNeeded()
        let blocked = Date().timeIntervalSince(started)
        XCTAssertLessThan(blocked, 0.5, "starting a session waited \(blocked)s for the notification centre")
        XCTAssertFalse(notifier.isAuthorized, "the answer cannot be known yet, and must not be guessed")
        wait(for: [reached], timeout: 3)
    }

    /// From a clean state the dialog is a real question, and "Don't Allow" is a real answer. Saying no is not a
    /// malfunction: the badge keeps working and the app must not put up a complaint about a choice the user
    /// just made deliberately. Only an actual failure — a bundle the system will not talk to — is reported.
    ///
    /// This machine can no longer reach that state by itself: `me.opencouncil.app` was granted permission on
    /// 2026-09-11 and every later ask is answered from the system's cache in single-digit milliseconds. Only the
    /// first ask waits for a person, and the wait is the person, not the XPC.
    @MainActor
    func testDecliningPermissionIsNotReportedAsAProblem() async {
        let notifier = Notifier(authorize: { (false, nil) })
        notifier.requestAuthorizationIfNeeded()
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(notifier.isAuthorized)
        XCTAssertNil(notifier.unavailableReason, "the user declined; nothing is broken and nothing should say so")

        let broken = Notifier(authorize: { (false, "this build has no bundle identifier") })
        broken.requestAuthorizationIfNeeded()
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(broken.unavailableReason, "this build has no bundle identifier",
                       "a real failure is still reported once")
    }

    @MainActor
    func testTheCentreIsReachedOnlyOnce() {
        let reached = expectation(description: "reached")
        reached.expectedFulfillmentCount = 1
        reached.assertForOverFulfill = true
        let notifier = Notifier(authorize: { reached.fulfill(); return (true, nil) })
        notifier.requestAuthorizationIfNeeded()
        notifier.requestAuthorizationIfNeeded()
        notifier.requestAuthorizationIfNeeded()
        wait(for: [reached], timeout: 3)
    }
}
