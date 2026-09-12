import XCTest
@testable import Council

/// `/budget n` is the one CLI command the app parses. Everything else has to reach the council as text: a
/// message that opens with a slash is usually a path or a regex.
final class ChatCommandTests: XCTestCase {
    func testBudgetTakesACount() {
        XCTAssertEqual(ChatCommand.parse("/budget 20"), .budget(20))
        XCTAssertEqual(ChatCommand.parse("/budget   7"), .budget(7))
    }

    func testBudgetNeedsAPlausibleNumber() {
        XCTAssertNil(ChatCommand.parse("/budget"))
        XCTAssertNil(ChatCommand.parse("/budget 0"))
        XCTAssertNil(ChatCommand.parse("/budget -3"))
        XCTAssertNil(ChatCommand.parse("/budget 1000"))
        XCTAssertNil(ChatCommand.parse("/budget twenty"))
        XCTAssertNil(ChatCommand.parse("/budget 20 please"))
    }

    func testOrdinaryTextIsNotACommand() {
        XCTAssertNil(ChatCommand.parse("what is the /budget for this?"))
        XCTAssertNil(ChatCommand.parse("/wrap"))
        XCTAssertNil(ChatCommand.parse("/Users/you/Code 20"))
    }
}
