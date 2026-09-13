import AppKit
import SwiftUI
import XCTest
@testable import Council
@testable import Textual

/// Exercises the actual selection overlay and its rendered highlight. A model-only test would still pass
/// if the geometry fix disconnected the view from changes to the selected range.
final class TextSelectionRenderingTests: XCTestCase {
    @MainActor
    func testSelectionPaintsAndClearsAfterReflow() async throws {
        let text = "Selection must stay visible when this message wraps onto several lines after the window becomes narrower."
        let host = NSHostingView(rootView:
            MessageMarkdown(text: text, members: [], onMention: { _ in })
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.white))
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 600, height: 250),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        try await settle(host)

        let interaction = try XCTUnwrap(selectionView(in: host))
        let plain = try pixels(of: host)
        interaction.selectAll(nil)
        try await settle(host)
        let range = try XCTUnwrap(interaction.model.selectedRange)
        XCTAssertEqual(interaction.model.text(in: range), text)
        XCTAssertFalse(interaction.model.selectionRects(for: range).isEmpty)
        XCTAssertNotEqual(try pixels(of: host), plain, "selecting must paint a highlight")

        window.setContentSize(NSSize(width: 320, height: 250))
        try await settle(host)
        let reflowed = try XCTUnwrap(interaction.model.selectedRange)
        XCTAssertEqual(interaction.model.text(in: reflowed), text, "reflow must preserve the selected text")
        let selected = try pixels(of: host)
        interaction.model.selectedRange = nil
        try await settle(host)
        XCTAssertNotEqual(try pixels(of: host), selected, "clearing must remove the reflowed highlight")
    }

    @MainActor
    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        view.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func selectionView(in view: NSView) -> NSTextInteractionView? {
        if let selection = view as? NSTextInteractionView { return selection }
        return view.subviews.compactMap { selectionView(in: $0) }.first
    }

    @MainActor
    private func pixels(of view: NSView) throws -> Data {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
