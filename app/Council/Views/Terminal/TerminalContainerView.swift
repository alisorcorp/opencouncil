import SwiftUI
import AppKit

/// Shows the selected member's terminal. Every host of the session is a subview with the container's frame,
/// hidden except the selected one, so all grids stay the same size and hidden terminals keep rendering the
/// output they receive.
struct TerminalContainerView: NSViewRepresentable {
    /// The hosts themselves rather than the runtime holding them: a chat and a verdict run both host real
    /// terminals, and this view has never needed to know which.
    let hosts: [TerminalHost]
    let selected: String

    func makeNSView(context: Context) -> TerminalStackView { TerminalStackView() }

    func updateNSView(_ view: TerminalStackView, context: Context) {
        view.show(hosts: hosts, selected: selected)
    }
}

final class TerminalStackView: NSView {
    private weak var focusPending: TerminalHost?

    func show(hosts: [TerminalHost], selected: String) {
        for host in hosts where host.superview !== self {
            host.removeFromSuperview()
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
        }
        for stale in subviews.compactMap({ $0 as? TerminalHost }) where !hosts.contains(stale) {
            stale.removeFromSuperview()
        }
        var focus: TerminalHost?
        for host in hosts {
            let visible = host.member == selected
            host.isHidden = !visible
            if visible { focus = host }
        }
        guard let focus else { return }
        if let window { window.makeFirstResponder(focus) } else { focusPending = focus }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let focusPending, let window {
            window.makeFirstResponder(focusPending)
            self.focusPending = nil
        }
    }

    override func layout() {
        super.layout()
        for s in subviews { s.frame = bounds }
    }
}
