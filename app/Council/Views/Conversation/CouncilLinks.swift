import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CouncilCore

/// Every link a session shows goes through here: a path becomes the file it names, resolved against the
/// folder the session's members work in, a web link goes to the browser, and anything else to the system.
/// Before this, a path link reached LaunchServices with no scheme and came back as "The application can't be
/// opened. -50". One alert per screen names what was looked for when nothing is there.
struct CouncilLinks: ViewModifier {
    let folder: URL?
    @State private var problem: String?

    func body(content: Content) -> some View {
        let open: @MainActor @Sendable (URL) -> OpenURLAction.Result = { url in
            LinkOpener.open(url, relativeTo: folder) { problem = $0 }
        }
        content
            // Text that does not install its own handler (the verdict) inherits this one…
            .environment(\.openURL, OpenURLAction { open($0) })
            // …and a message body, which must intercept its mention chips first, calls this after them.
            .environment(\.councilOpenLink, open)
            .alert("Can't open that link", isPresented: Binding(get: { problem != nil },
                                                               set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
    }
}

extension View {
    /// Resolve and open this view's links against `folder`, where the session's members work.
    func councilLinks(folder: URL?) -> some View { modifier(CouncilLinks(folder: folder)) }
}

extension EnvironmentValues {
    @Entry var councilOpenLink: (@MainActor @Sendable (URL) -> OpenURLAction.Result)? = nil
}

@MainActor
enum LinkOpener {
    static func open(_ url: URL, relativeTo folder: URL?, report: (String) -> Void) -> OpenURLAction.Result {
        switch LinkTarget.resolve(url, relativeTo: folder) {
        case .web, .system:
            return .systemAction
        case .missing(let path):
            report("There is no file at \(path).")
            return .handled
        case .file(let file, _):
            openFile(file, report: report)
            return .handled
        }
    }

    /// See `LinkTarget.openMode`: a member wrote this link, so nothing it names is launched by a click.
    private static func openFile(_ url: URL, report: (String) -> Void) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isExecutableKey])
        let mode = LinkTarget.openMode(for: url, isDirectory: values?.isDirectory ?? false,
                                       isPackage: values?.isPackage ?? false,
                                       isExecutable: values?.isExecutable ?? false)
        switch mode {
        case .open:
            if !NSWorkspace.shared.open(url) { report("No app is set to open \(url.lastPathComponent).") }
        case .openAsText:
            if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
                NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
