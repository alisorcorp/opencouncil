import XCTest
import SwiftUI
import AppKit
@testable import Council

/// The composer's text view reports back to SwiftUI: the height the text needs, the `@word` at the caret, the
/// draft itself, and whether a picked name is still waiting to be inserted. All of it is SwiftUI state, and
/// `updateNSView` — where it used to be written — runs inside a view update, where writing state is undefined
/// behaviour. Rendering one chat window logged "Modifying state during view update" once or twice every time,
/// and 207 of them came out of a 35-minute session; the height was the bulk of it, because it was written on
/// every update whether it had changed or not, and picking a name from the mention list was five at once.
///
/// Deferring the write is half the fix. The other half is this: a report that repeats the value SwiftUI already
/// holds is still a write, and a deferred storm of them is no better than an immediate one. These tests hold
/// that line — the runtime issue itself is not something XCTest can observe.
final class ComposerStateWritesTests: XCTestCase {
    /// Everything the coordinator writes back to SwiftUI, in the order it arrives. The bindings both read from
    /// and write to this, so a write that merely repeats what SwiftUI already holds still lands here — which is
    /// exactly what these tests are counting.
    private final class Writes {
        var text: String
        var mention: ComposerTextView.MentionQuery?
        var completion: String?
        var heights: [CGFloat] = []
        var texts = 0
        var mentions = 0
        var completions = 0
        /// Every state write, of any kind. A view update is allowed none of them.
        var all: Int { texts + mentions + completions + heights.count }

        init(text: String = "", completion: String? = nil) {
            self.text = text
            self.completion = completion
        }
    }

    /// A coordinator wired to a real text view, as `makeNSView` builds it — delegate included, because the edit
    /// a completion makes reaches SwiftUI through `textDidChange`.
    @MainActor
    private func coordinator(_ writes: Writes) -> ComposerTextView.Coordinator {
        let view = ComposerTextView(
            text: Binding(get: { writes.text }, set: { writes.text = $0; writes.texts += 1 }),
            mention: Binding(get: { writes.mention }, set: { writes.mention = $0; writes.mentions += 1 }),
            completion: Binding(get: { writes.completion }, set: { writes.completion = $0; writes.completions += 1 }),
            onHeight: { writes.heights.append($0) },
            onSubmit: {})
        let coordinator = ComposerTextView.Coordinator(view)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        textView.isVerticallyResizable = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.string = writes.text
        textView.delegate = coordinator
        coordinator.textView = textView
        return coordinator
    }

    /// Runs whatever the view update deferred. The main queue is FIFO, so anything enqueued before this call
    /// has run by the time it returns.
    @MainActor
    private func drain(function: String = #function) {
        let done = expectation(description: "deferred work ran for \(function)")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    @MainActor
    func testTheHeightIsReportedOnlyWhenItChanges() throws {
        let writes = Writes(text: "one line")
        let c = coordinator(writes)

        c.reportHeight()
        c.reportHeight()
        c.reportHeight()
        XCTAssertEqual(writes.heights.count, 1, "the same height was written to SwiftUI \(writes.heights.count) times")

        c.textView?.string = "one line\ntwo lines\nthree lines\nfour lines"
        c.reportHeight()
        XCTAssertEqual(writes.heights.count, 2, "a height that genuinely changed must still be reported")
        XCTAssertGreaterThan(try XCTUnwrap(writes.heights.last), try XCTUnwrap(writes.heights.first))
    }

    @MainActor
    func testTheMentionIsWrittenOnlyWhenItChanges() throws {
        let writes = Writes(text: "no mention here")
        let c = coordinator(writes)

        // The caret moves constantly and is usually not inside an `@word`, so most reports are nil over nil.
        c.textView?.setSelectedRange(NSRange(location: 3, length: 0))
        c.publishMention()
        c.publishMention()
        c.publishMention()
        XCTAssertEqual(writes.mentions, 0, "nil was written over nil \(writes.mentions) times")

        c.textView?.string = "hello @cla"
        c.textView?.setSelectedRange(NSRange(location: 10, length: 0))
        c.publishMention()
        XCTAssertEqual(writes.mentions, 1, "a real mention must reach SwiftUI")
        c.publishMention()
        XCTAssertEqual(writes.mentions, 1, "and must not be written again unchanged")
    }

    /// Picking a name from the mention list sets the `completion` binding, and SwiftUI answers it with a view
    /// update. Applying the edit there wrote the draft twice, the closed mention, the new height and the
    /// cleared request straight back into the update that asked for it — five faults per pick on a live build,
    /// which is why the first fix, which only moved the height and the mention, did not end them.
    @MainActor
    func testPickingAMentionWritesNothingUntilTheViewUpdateIsOver() throws {
        let writes = Writes(text: "hello @cla", completion: "claude")
        let c = coordinator(writes)
        c.textView?.setSelectedRange(NSRange(location: 10, length: 0))
        c.publishMention()
        XCTAssertNotNil(writes.mention, "there must be an `@word` to complete")
        let duringUpdate = writes.all

        c.completeAfterUpdate(with: "claude")
        XCTAssertEqual(writes.all, duringUpdate,
                       "\(writes.all - duringUpdate) state writes happened inside the view update")

        drain()
        XCTAssertEqual(writes.text, "hello @claude ", "the name goes in, with the caret after it")
        XCTAssertEqual(c.textView?.string, "hello @claude ", "and the text view and SwiftUI agree")
        XCTAssertNil(writes.mention, "the list closes once the name is in")
        XCTAssertNil(writes.completion, "and the request is cleared, or the next update would apply it again")
    }

    /// SwiftUI runs `updateNSView` as often as it likes, and the request is still set on every one of them
    /// until the deferred edit clears it. Asking twice must not insert the name twice.
    @MainActor
    func testAMentionPickedOnceIsInsertedOnce() throws {
        let writes = Writes(text: "hello @cla", completion: "claude")
        let c = coordinator(writes)
        c.textView?.setSelectedRange(NSRange(location: 10, length: 0))
        c.publishMention()

        c.completeAfterUpdate(with: "claude")
        c.completeAfterUpdate(with: "claude")
        c.completeAfterUpdate(with: "claude")
        drain()
        XCTAssertEqual(writes.text, "hello @claude ")
    }
}
