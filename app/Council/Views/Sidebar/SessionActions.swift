import SwiftUI
import AppKit
import CouncilCore

/// Right-click actions on a session row. Starting and stopping members is otherwise only reachable from inside
/// the session, which is awkward once several chats are live at the same time.
struct SessionActions: View {
    let session: SessionSummary
    let live: LiveSessions?
    /// Set when the sidebar is showing this session, so the action can run against its view model.
    let current: SessionViewModel?
    /// Passed in rather than read from the environment: a context menu is hosted in its own AppKit menu.
    let sessions: SessionsModel

    private var runtime: SessionRuntime? { live?.runtime(for: session.id) }

    var body: some View {
        Group {
            if session.kind == .chat {
                if runtime != nil {
                    Button("Stop members") { live?.stop(session.id) }
                } else {
                    Button("Start members") { start(resume: false) }
                    if hasSomethingToResume {
                        Button("Resume members") { start(resume: true) }
                    }
                }
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([session.directory])
            }
            Button("Copy folder path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.directory.path, forType: .string)
            }
            Divider()
            if session.kind == .chat {
                Button("Rename…") { rename() }
            }
            Button("Delete…", role: .destructive) { confirmDelete() }
        }
    }

    /// Renaming moves the chat's folder as well as its title, so `council session <new name>` finds it. A chat
    /// with members running keeps its name until they stop: their runtime holds the old path.
    private func rename() {
        let alert = NSAlert()
        alert.messageText = "Rename “\(session.displayTitle)”"
        alert.informativeText = runtime == nil
            ? "The chat's folder is renamed too, so `council session` finds it under the new name."
            : "Stop this chat's members first: they are running against its current folder."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = session.displayTitle
        field.placeholderString = "Chat name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        Task { @MainActor in
            if let problem = await sessions.rename(session, to: name, live: live) {
                let failed = NSAlert()
                failed.alertStyle = .warning
                failed.messageText = "“\(session.displayTitle)” could not be renamed"
                failed.informativeText = problem
                failed.runModal()
            }
        }
    }

    /// Deleting throws away the only copy of a transcript, so it asks first and then moves the folder to the
    /// Trash, where the user can still get it back.
    private func confirmDelete() {
        let kind = session.kind == .chat ? "chat" : "verdict"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(session.displayTitle)”?"
        alert.informativeText = runtime == nil
            ? "The whole \(kind) folder moves to the Trash."
            : "Its members stop, and the whole \(kind) folder moves to the Trash."
        let delete = alert.addButton(withTitle: "Move to Trash")
        let cancel = alert.addButton(withTitle: "Cancel")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""          // Return must not be a delete
        cancel.keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            if let problem = await sessions.delete(session, live: live) {
                let failed = NSAlert()
                failed.alertStyle = .warning
                failed.messageText = "“\(session.displayTitle)” could not be deleted"
                failed.informativeText = problem
                failed.runModal()
            }
        }
    }

    /// Only offer a resume when there are CLI session ids to resume from.
    private var hasSomethingToResume: Bool {
        !SessionAppState.load(from: session.directory).sessionIds.isEmpty
    }

    private func start(resume: Bool) {
        guard let live else { return }
        if let vm = current, vm.summary.id == session.id {
            vm.startMembers(resume: resume)
            return
        }
        guard let config = try? ChatConfig.load(from: session.directory) else { return }
        try? live.start(summary: session, config: config, resume: resume)
    }
}
