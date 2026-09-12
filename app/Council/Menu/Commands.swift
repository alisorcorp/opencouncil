import SwiftUI
import AppKit

/// Menu commands. They travel as notifications rather than through focused values: there is one window, the
/// receivers are deep in the view tree, and a broadcast keeps the menu from having to know about any of them.
extension Notification.Name {
    static let councilNewChat = Notification.Name("council.newChat")
    static let councilNewVerdict = Notification.Name("council.newVerdict")
    static let councilToggleTerminal = Notification.Name("council.toggleTerminal")
    static let councilWrapUp = Notification.Name("council.wrapUp")
    static let councilStopMembers = Notification.Name("council.stopMembers")
}

struct CouncilCommands: Commands {
    let openEnvironment: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat…") { NotificationCenter.default.post(name: .councilNewChat, object: nil) }
                .keyboardShortcut("n", modifiers: .command)
            Button("Ask the Council…") { NotificationCenter.default.post(name: .councilNewVerdict, object: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .appInfo) {
            Button("Environment…", action: openEnvironment)
        }
        CommandMenu("Council") {
            Button("Show Member Terminal") {
                NotificationCenter.default.post(name: .councilToggleTerminal, object: nil)
            }
            .keyboardShortcut("t", modifiers: .command)
            Button("Ask Everyone to Wrap Up") {
                NotificationCenter.default.post(name: .councilWrapUp, object: nil)
            }
            Divider()
            Button("Stop This Chat's Members") {
                NotificationCenter.default.post(name: .councilStopMembers, object: nil)
            }
        }
    }
}

/// Quitting with members running is worth one question: their terminals die with the app, and only the CLIs
/// that keep their own sessions can be picked up again.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the root view once the environment exists.
    var liveSessionCount: () -> Int = { 0 }
    var stopAll: () -> Void = {}

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let live = liveSessionCount()
        guard live > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = live == 1 ? "One chat still has members running"
                                      : "\(live) chats still have members running"
        alert.informativeText = "Their terminals close with the app. Chats that were live are offered a "
            + "Resume when you open them again, and Claude Code and Codex pick up their own sessions."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        stopAll()
        return .terminateNow
    }
}
