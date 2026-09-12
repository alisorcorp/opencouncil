import SwiftUI
import AppKit

/// The composer's text field. `TextEditor` cannot tell Return from Shift-Return or report the caret, both of
/// which the composer needs, so this wraps an `NSTextView` directly: Return sends, Shift-Return starts a new
/// line, ⌘Return sends from anywhere, and the caret's `@word` is published for the mention popover.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    /// The `@word` being typed at the caret, if any, for the mention list.
    @Binding var mention: MentionQuery?
    /// Set to a member name to replace the `@word` at the caret with it; cleared once applied.
    @Binding var completion: String?
    var minHeight: CGFloat = 21
    var maxHeight: CGFloat = 170
    /// Reports the height the text currently needs, so the composer can grow with it.
    var onHeight: (CGFloat) -> Void = { _ in }
    var onSubmit: () -> Void
    /// Keys the mention list wants first. Return `true` to swallow the key.
    var onNavigationKey: (NavigationKey) -> Bool = { _ in false }

    enum NavigationKey { case up, down, tab, escape, accept }

    struct MentionQuery: Equatable {
        /// What has been typed after the `@`, lowercased.
        let prefix: String
        /// Range of the whole `@word` in the text, for replacement.
        let range: NSRange
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onCommandReturn = { context.coordinator.parent.onSubmit() }
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = Typography.nsFont(14, .regular) ?? .systemFont(ofSize: NSFont.systemFontSize + 1)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        context.coordinator.textView = textView
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            DispatchQueue.main.async { context.coordinator.publishMention() }
        }
        // Inserting a picked name and measuring the text both report back to SwiftUI — the draft, the mention,
        // the height, the cleared request — and this runs *inside* a view update, where writing state is
        // undefined behaviour. AppKit knows the answers now; SwiftUI hears them once this update has finished.
        if let name = completion { context.coordinator.completeAfterUpdate(with: name) }
        DispatchQueue.main.async { context.coordinator.reportHeight() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?

        init(_ parent: ComposerTextView) { self.parent = parent }

        /// Puts the caret back in the composer (after a mention was picked with the mouse, say).
        func focus() {
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            setText(textView.string)
            publishMention()
            reportHeight()
        }

        func textViewDidChangeSelection(_ notification: Notification) { publishMention() }

        /// Height of the laid-out text, clamped to the composer's limits.
        /// The last height SwiftUI was told about. Re-reporting the same number is still a state write, and one
        /// per update is what "tried to update multiple times per frame" was counting.
        private var reportedHeight: CGFloat?

        func reportHeight() {
            guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + textView.textContainerInset.height * 2
            let height = min(max(used, parent.minHeight), parent.maxHeight)
            guard height != reportedHeight else { return }
            reportedHeight = height
            parent.onHeight(height)
        }

        /// Same rule for the draft. `complete` reports the text the delegate has already reported for the very
        /// same edit, which is one write of a string SwiftUI is already holding.
        private func setText(_ value: String) {
            guard parent.text != value else { return }
            parent.text = value
        }

        /// Same rule for the mention: the caret moves constantly and is usually not in an `@word`, so most of
        /// these are `nil` over `nil`.
        private func setMention(_ query: ComposerTextView.MentionQuery?) {
            guard parent.mention != query else { return }
            parent.mention = query
        }

        /// The `@word` the caret sits in, if the caret is inside one.
        func publishMention() {
            guard let textView else { return }
            let text = textView.string as NSString
            let caret = textView.selectedRange().location
            guard caret <= text.length else { setMention(nil); return }
            var start = caret
            while start > 0 {
                let c = text.character(at: start - 1)
                if c == UInt16(UnicodeScalar("@").value) {
                    // "a@b" is an address, not a mention.
                    if start - 1 > 0, !isSeparator(text.character(at: start - 2)) { setMention(nil); return }
                    let range = NSRange(location: start - 1, length: caret - start + 1)
                    let prefix = text.substring(with: NSRange(location: start, length: caret - start))
                    setMention(MentionQuery(prefix: prefix.lowercased(), range: range))
                    return
                }
                if isSeparator(c) { break }
                start -= 1
            }
            setMention(nil)
        }

        private func isSeparator(_ c: unichar) -> Bool {
            guard let scalar = UnicodeScalar(c) else { return true }
            return CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.punctuationCharacters.contains(scalar)
        }

        /// Applies a name picked from the mention list, once the view update that asked for it has ended.
        /// Everything the edit touches is SwiftUI state — the draft, the closed mention, the new height, the
        /// cleared request — and it is asked for from inside a view update, where none of that may be written.
        /// SwiftUI may run the update more than once before this gets its turn, and the request is still set on
        /// every one of them: the first edit clears it, and the rest find nothing to do.
        func completeAfterUpdate(with name: String) {
            DispatchQueue.main.async { [weak self] in
                guard let self, parent.completion != nil else { return }
                complete(with: name)
                parent.completion = nil
            }
        }

        /// Replaces the `@word` at the caret with `@name `, as one undoable edit.
        func complete(with name: String) {
            guard let textView, let mention = parent.mention else { return }
            let replacement = "@\(name) "
            if textView.shouldChangeText(in: mention.range, replacementString: replacement) {
                textView.replaceCharacters(in: mention.range, with: replacement)
                textView.didChangeText()
            }
            setText(textView.string)
            setMention(nil)
            focus()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if parent.onNavigationKey(.accept) { return true }
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                parent.onSubmit()
                return true
            case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case #selector(NSResponder.moveUp(_:)): return parent.onNavigationKey(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onNavigationKey(.down)
            case #selector(NSResponder.insertTab(_:)): return parent.onNavigationKey(.tab)
            case #selector(NSResponder.cancelOperation(_:)): return parent.onNavigationKey(.escape)
            default: return false
            }
        }
    }
}

/// ⌘Return is not bound to any action by default, so it never reaches the delegate; catching it here makes the
/// documented shortcut work from anywhere in the field.
final class ComposerNSTextView: NSTextView {
    var onCommandReturn: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
