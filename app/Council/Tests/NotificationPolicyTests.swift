import XCTest
@testable import Council

/// R13: a card has to reach the user wherever they are, a reply only when they cannot already see it, and the
/// chatter around them — hellos, budget notes — never should.
final class NotificationPolicyTests: XCTestCase {
    private let watching = NotificationPolicy.Context(appIsActive: true, sessionIsVisible: true)
    private let elsewhere = NotificationPolicy.Context(appIsActive: true, sessionIsVisible: false)
    private let away = NotificationPolicy.Context(appIsActive: false, sessionIsVisible: true)

    func testAReplyInTheSessionOnScreenIsNotWorthInterrupting() {
        XCTAssertFalse(NotificationPolicy.shouldNotify(.post(isHello: false), watching))
    }

    func testAReplyElsewhereOrWhileAwayIsNotified() {
        XCTAssertTrue(NotificationPolicy.shouldNotify(.post(isHello: false), elsewhere))
        XCTAssertTrue(NotificationPolicy.shouldNotify(.post(isHello: false), away))
    }

    func testAMembersHelloIsNeverNews() {
        for context in [watching, elsewhere, away] {
            XCTAssertFalse(NotificationPolicy.shouldNotify(.post(isHello: true), context))
        }
    }

    func testACardInterruptsWhereverTheUserIs() {
        for context in [watching, elsewhere, away] {
            XCTAssertTrue(NotificationPolicy.shouldNotify(.card, context))
            XCTAssertTrue(NotificationPolicy.shouldNotify(.verdict, context))
        }
    }

    func testNotesStayInTheChat() {
        for context in [watching, elsewhere, away] {
            XCTAssertFalse(NotificationPolicy.shouldNotify(.note, context))
        }
    }
}
