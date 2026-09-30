import AppKit
import UniformTypeIdentifiers
import CouncilCore

/// "Export as HTML": a session as one self-contained page — every message of a chat, or a run's question,
/// rounds and verdict — saved where the user chooses and opened in their browser. The page is built from the
/// files on disk, not from what the window happens to have loaded, so it is the whole history.
@MainActor
enum SessionExport {
    static func export(_ session: SessionSummary) {
        let panel = NSSavePanel()
        panel.title = "Export as HTML"
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = fileName(for: session.displayTitle)
        if panel.directoryURL == nil {
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(try page(for: session).utf8).write(to: url, options: .atomic)
            NSWorkspace.shared.open(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not export \u{201C}\(session.displayTitle)\u{201D}"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    static func page(for session: SessionSummary, exportedAt: Date = Date()) throws -> String {
        let style = SessionHTML.Style(palette: Palette.memberHex.map(Palette.css),
                                      accentLight: Palette.css(Palette.accentHex.light),
                                      accentDark: Palette.css(Palette.accentHex.dark))
        // The same folder links resolve against in the window (SessionViewModel.linkFolder).
        let override = SessionAppState.load(from: session.directory).cwdOverride
        let folder = (override ?? session.cwd).map { URL(fileURLWithPath: $0) } ?? session.directory
        switch session.kind {
        case .chat:
            let config = try? ChatConfig.load(from: session.directory)
            let messages = try Bus(directory: session.directory).readAll()
            let order = config?.order ?? session.memberOrder
            return SessionHTML.chat(title: session.displayTitle, config: config, messages: messages, style: style,
                                    folder: folder, exportedAt: exportedAt,
                                    prepare: { MentionMarkup.apply(to: $0, members: order) })
        case .verdict:
            let run = try VerdictRun(directory: session.directory)
            return SessionHTML.run(run, title: session.displayTitle, style: style, folder: folder,
                                   exportedAt: exportedAt,
                                   prepare: { MentionMarkup.apply(to: $0, members: run.order) })
        }
    }

    /// A title as a file name: path separators and control characters out, length bounded.
    static func fileName(for title: String) -> String {
        let cleaned = title.unicodeScalars
            .map { "/:\\".unicodeScalars.contains($0) || CharacterSet.controlCharacters.contains($0) ? "-" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "Council session" : String(cleaned.prefix(120))) + ".html"
    }
}
