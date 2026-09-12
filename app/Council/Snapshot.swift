import AppKit
import SwiftUI
import CouncilCore

/// Developer tool: `Council --snapshot <session-dir> <out.png> [width height] [--live] [--terminal <member>]`
/// opens the real main window offscreen with that session selected, lets SwiftUI settle, captures the window's
/// layer tree to a PNG and exits. No screen-recording permission is needed because nothing is read from the
/// display. `--live` starts the session's members first (pair it with `COUNCIL_FAKE_MEMBERS=1`), `--terminal`
/// shows that member's terminal instead of the conversation, `--dark` renders in dark mode, and `--chrome`
/// gives the window a real titlebar and captures the frame view, so the toolbar (the sidebar collapse control)
/// is in the picture. Used to eyeball the UI from a terminal and to produce README images.
enum SnapshotCommand {
    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let i = arguments.firstIndex(of: "--snapshot"), arguments.count >= i + 3 else { return false }
        let dir = URL(fileURLWithPath: arguments[i + 1]).standardizedFileURL
        let out = URL(fileURLWithPath: arguments[i + 2])
        var rest = Array(arguments[(i + 3)...])
        var width = 1180.0, height = 760.0
        if let w = rest.first.flatMap(Double.init) { width = w; rest.removeFirst() }
        if let h = rest.first.flatMap(Double.init) { height = h; rest.removeFirst() }
        var live = false
        var terminal: String?
        var settle = 1.5
        var dark = false
        var chrome = false
        var view: String?
        while !rest.isEmpty {
            let a = rest.removeFirst()
            switch a {
            case "--live": live = true
            case "--dark": dark = true
            case "--chrome": chrome = true
            case "--view":
                view = rest.first
                if !rest.isEmpty { rest.removeFirst() }
            case "--terminal":
                terminal = rest.first
                if !rest.isEmpty { rest.removeFirst() }
                live = true
            case "--settle":
                if let s = rest.first.flatMap(Double.init) { settle = s; rest.removeFirst() }
            default: break
            }
        }
        Task { @MainActor in
            let code = await render(sessionDir: dir, to: out, size: CGSize(width: width, height: height),
                                    live: live, terminal: terminal, settle: settle, dark: dark, view: view,
                                    chrome: chrome)
            exit(code)
        }
        return true
    }

    @MainActor
    private static func render(sessionDir: URL, to out: URL, size: CGSize, live: Bool, terminal: String?,
                               settle: Double, dark: Bool = false, view: String? = nil,
                               chrome: Bool = false) async -> Int32 {
        let paths = CouncilPaths(root: sessionDir.deletingLastPathComponent().deletingLastPathComponent())
        guard paths.isValid else {
            FileHandle.standardError.write(Data("snapshot: \(sessionDir.path) is not inside a council folder\n".utf8))
            return 2
        }
        var sessions: LiveSessions?
        if live {
            let shell = await Task.detached { ShellEnvironment.resolve() }.value
            sessions = LiveSessions(launchEnvironment: MemberLaunchEnvironment.make(shell: shell, paths: paths))
        }
        // `--view new-chat` / `new-verdict` capture a sheet on its own; sheets open in their own window and
        // never appear in the main window's layer tree.
        let content: AnyView
        switch view {
        case "new-chat":
            content = AnyView(NewChatSheet(paths: paths,
                                           defaultFolder: URL(fileURLWithPath: "/Users/you/Code/app")) { _ in })
        case "new-verdict":
            content = AnyView(NewVerdictSheet(paths: paths) { _ in })
        case "live-cap":
            // Three plausible slot-holders — two chats and a run, one of them with a single member — so the
            // wording, the icons and the pluralisation can be read rather than reasoned about.
            let now = Date()
            content = AnyView(LiveCapSheet(
                title: "Should the router coalesce bursts?",
                sessions: [(id: "a", title: "Ledger shapes", members: 3, since: now.addingTimeInterval(-2_400), kind: .chat),
                           (id: "b", title: "Is a per-member reply budget better than one shared pool?",
                            members: 3, since: now.addingTimeInterval(-600), kind: .verdict),
                           (id: "c", title: "Icon grid", members: 1, since: now.addingTimeInterval(-75), kind: .chat)],
                onTake: { _ in }) { })
        default:
            content = AnyView(MainWindow(paths: paths, live: sessions, initialSelection: sessionDir.lastPathComponent,
                                         autoStartMembers: live, initialDetail: terminal.map { .terminal($0) }))
        }
        let root = content
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        // The appearance has to be set on the app and the view, not only the window: a hosting view resolves
        // dynamic colours against its own effective appearance, which otherwise follows the system setting.
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        hosting.appearance = appearance
        // A window far off any screen: SwiftUI lays out and animates as in a real one, nothing is shown, and no
        // focus is stolen. Borderless by default; `--chrome` asks for the same titled, transparent-titlebar
        // window the app itself opens, which is the only way the toolbar exists at all.
        let window = NSWindow(contentRect: CGRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
                              styleMask: chrome ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                                                : [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if chrome {
            window.titlebarAppearsTransparent = true   // `.windowStyle(.hiddenTitleBar)`, as CouncilApp asks for
            window.titleVisibility = .hidden
            window.toolbar = NSToolbar()               // SwiftUI fills an existing toolbar; it installs none itself
            window.toolbarStyle = .unified
        }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        window.makeKey()          // active-window colours for selection highlights

        // Let the session store scan, the selection open, Textual measure, and the scroll settle.
        for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(100)) }
        if live { try? await Task.sleep(for: .seconds(settle)) }   // members print their first screen
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))

        // With a titlebar the picture has to come from the frame view — the titlebar and the toolbar are drawn
        // outside the content view, which is why no earlier snapshot could show the collapse control.
        let target: NSView = chrome ? (window.contentView?.superview ?? hosting) : hosting
        if chrome {
            let items = window.toolbar?.items ?? []
            print("snapshot: toolbar has \(items.count) item(s): "
                  + items.map { $0.itemIdentifier.rawValue }.joined(separator: ", "))
        }
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return 3 }
        target.cacheDisplay(in: target.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return 3 }
        do { try png.write(to: out) } catch {
            FileHandle.standardError.write(Data("snapshot: \(error.localizedDescription)\n".utf8))
            return 4
        }
        print("snapshot: wrote \(out.path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
        sessions?.stopAll()
        window.close()
        return 0
    }
}
