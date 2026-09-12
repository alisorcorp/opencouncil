import XCTest
import CouncilCore
@testable import Council

final class ConversationLayoutTests: XCTestCase {
    private func msg(_ id: Int64, _ ts: String, _ from: String, kind: String = Message.kindMessage) -> Message {
        Message(id: id, ts: ts, sender: from, kind: kind, text: "t\(id)")
    }

    func testDaySeparatorsNotesAndContinuations() {
        let rows = ConversationLayout.rows(for: [
            msg(1, "2026-09-10T11:36:12", "deepseek"),
            msg(2, "2026-09-10T11:36:14", "claude"),
            msg(3, "2026-09-10T11:36:20", "claude"),          // continuation: same sender, 6 s later
            msg(4, "2026-09-10T11:45:00", "claude"),          // > 5 min: header again
            msg(5, "2026-09-10T11:45:30", "system", kind: Message.kindNote),
            msg(6, "2026-09-10T11:45:40", "claude"),          // after a note: header again
            msg(7, "2026-09-11T09:00:00", "user"),            // next day
        ])
        XCTAssertEqual(rows.count, 9)
        guard case .day = rows[0].kind else { return XCTFail("first row should be a day separator") }
        XCTAssertEqual(rows[1].kind, .message(msg(1, "2026-09-10T11:36:12", "deepseek"), showHeader: true))
        XCTAssertEqual(rows[2].kind, .message(msg(2, "2026-09-10T11:36:14", "claude"), showHeader: true))
        XCTAssertEqual(rows[3].kind, .message(msg(3, "2026-09-10T11:36:20", "claude"), showHeader: false))
        XCTAssertEqual(rows[4].kind, .message(msg(4, "2026-09-10T11:45:00", "claude"), showHeader: true))
        XCTAssertEqual(rows[5].kind, .note(msg(5, "2026-09-10T11:45:30", "system", kind: Message.kindNote)))
        XCTAssertEqual(rows[6].kind, .message(msg(6, "2026-09-10T11:45:40", "claude"), showHeader: true))
        guard case .day = rows[7].kind else { return XCTFail("day separator before the next day") }
        XCTAssertEqual(rows[8].kind, .message(msg(7, "2026-09-11T09:00:00", "user"), showHeader: true))
    }

    func testRowIdsAreStable() {
        let a = ConversationLayout.rows(for: [msg(1, "2026-09-10T11:36:12", "a")])
        let b = ConversationLayout.rows(for: [msg(1, "2026-09-10T11:36:12", "a"), msg(2, "2026-09-10T11:36:13", "a")])
        XCTAssertEqual(a.map(\.id), Array(b.map(\.id).prefix(2)))
    }

    /// Two members posting in the same nanosecond share a message id. Rows keyed by id made `ForEach` draw one
    /// of the two and silently drop the other — from the conversation the user reads, not just from a test.
    func testSimultaneousPostsBothGetARow() {
        let rows = ConversationLayout.rows(for: [
            msg(1789101085693330000, "2026-09-11T00:31:25", "claude"),
            msg(1789101085693330000, "2026-09-11T00:31:25", "codex"),
        ])
        XCTAssertEqual(rows.filter { if case .message = $0.kind { return true } else { return false } }.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "every row needs its own identity")
    }

    func testInitials() {
        XCTAssertEqual(Palette.initials("Claude Fable 5.1"), "CF")
        XCTAssertEqual(Palette.initials("Codex GPT-6 Astra"), "CG")
        XCTAssertEqual(Palette.initials("codex"), "CO")
        XCTAssertEqual(Palette.initials("DeepSeek V4.1 Flash"), "DV")
    }
}
