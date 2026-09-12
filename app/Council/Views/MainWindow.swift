import SwiftUI
import CouncilCore

/// The two-column window: sidebar (Agents + Sessions) and the detail pane (conversation, verdict, or a terminal).
struct MainWindow: View {
    /// Optional on purpose: the snapshot tool builds this window with no app environment around it.
    @Environment(AppEnvironment.self) private var env: AppEnvironment?
    @State private var sessions: SessionsModel
    @State private var current: SessionViewModel?
    @State private var columns: NavigationSplitViewVisibility = .all
    private let live: LiveSessions?
    private let initialSelection: String?
    private let autoStartMembers: Bool
    private let initialDetail: DetailMode?

    /// `initialSelection`, `autoStartMembers` and `initialDetail` serve the offscreen snapshot tool, which
    /// opens a given session (optionally with its members started and one terminal showing) and captures it.
    init(paths: CouncilPaths, live: LiveSessions? = nil, initialSelection: String? = nil,
         autoStartMembers: Bool = false, initialDetail: DetailMode? = nil) {
        _sessions = State(initialValue: SessionsModel(paths: paths))
        self.live = live
        self.initialSelection = initialSelection
        self.autoStartMembers = autoStartMembers
        self.initialDetail = initialDetail
    }

    var body: some View {
        split.withSidebarToggle(toggleButton)
            .font(Typography.body)
        .background(Palette.canvas)
        .task {
            if let initialSelection {
                await sessions.refresh()
                sessions.selectedID = initialSelection
            }
            sessions.start()
            env?.notifier.onOpenSession = { id in sessions.selectedID = id }
        }
        .onDisappear { sessions.stop() }
        .onChange(of: sessions.selectedID) { _, id in
            select(id)
            env?.visibleSessionID = id
        }
        .onChange(of: sessions.sessions) { _, _ in
            // A session selected before the scan listed it (a sheet just made it, or the CLI did) has no view
            // model yet. Resolve it as soon as it appears, rather than leaving an empty pane the user has to
            // click away from and back to.
            if current == nil, let id = sessions.selectedID { select(id) }
        }
        .onChange(of: sessions.unread) { _, counts in
            env?.notifier.setBadge(counts.values.reduce(0, +))
        }
        .onReceive(NotificationCenter.default.publisher(for: .councilToggleTerminal)) { _ in
            guard let vm = current else { return }
            if case .terminal = vm.detailMode {
                vm.detailMode = .conversation
            } else if let first = vm.agents.first {
                vm.toggleTerminal(for: first.name)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .councilWrapUp)) { _ in
            current?.send("Let's wrap it up. Final conclusions, please.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .councilStopMembers)) { _ in
            current?.stopMembers()
            current?.stopVerdict()
        }
    }

    private var split: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(current: current, live: live)
                .environment(sessions)
                // The system toggle has to be removed on the sidebar column itself, not on the split view, and
                // before the width is set: the toolbar modifier otherwise swallows the column width.
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 420)
        } detail: {
            DetailView(current: current)
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// Our own collapse control: the glyph alone, in the same muted grey as the other secondary icons.
    private var toggleButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                columns = columns == .detailOnly ? .all : .detailOnly
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(Typography.font(15, .regular))
                .foregroundStyle(Palette.mutedIcon)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Hide or show the sidebar")
    }

    private func select(_ id: String?) {
        current?.close()
        guard let summary = sessions.summary(for: id) else { current = nil; return }
        let vm = SessionViewModel(summary: summary, live: live, paths: sessions.paths,
                                  councilConfig: env?.config)
        vm.onRead = { [sessions] id in sessions.markRead(id) }
        vm.onDiscard = { [sessions, live] summary in
            Task { await sessions.delete(summary, live: live) }
        }
        vm.open()
        current = vm
        if summary.id == initialSelection {
            if let initialDetail { vm.detailMode = initialDetail }
            // Starting members mutates observable state; do it after this view update, like a button click would.
            if autoStartMembers { Task { @MainActor in vm.startMembers() } }
        }
        // A session created from a sheet starts straight away: the sheet is the deliberate act, and stopping
        // to press a second button in an empty view is not a decision anybody is making. For a chat it means
        // the members connect and introduce themselves while you are still deciding what to type, rather than
        // after your first message — which read as though they had ignored it.
        if sessions.takeAutoStart(for: summary.id) {
            Task { @MainActor in
                if summary.kind == .verdict { vm.startVerdict() } else { vm.startMembers() }
            }
        }
    }
}

extension View {
    /// Puts `button` in the titlebar where the system sidebar toggle used to sit. On macOS 26 a toolbar item is
    /// drawn inside a glass capsule unless the shared background is hidden, which is the circle we do not want.
    @ViewBuilder
    func withSidebarToggle(_ button: some View) -> some View {
        if #available(macOS 26.0, *) {
            self.toolbar {
                ToolbarItem(id: "sidebar-toggle", placement: .navigation) { button }
                    .sharedBackgroundVisibility(.hidden)
            }
        } else {
            self.toolbar { ToolbarItem(placement: .navigation) { button } }
        }
    }
}

struct DetailView: View {
    let current: SessionViewModel?

    var body: some View {
        if let vm = current {
            switch vm.detailMode {
            case .terminal(let member):
                TerminalPane(vm: vm, member: member)
            case .conversation:
                switch vm.summary.kind {
                case .chat: ConversationView(vm: vm)
                case .verdict: VerdictView(vm: vm)
                }
            }
        } else {
            EmptyState(title: "No session selected",
                       detail: "Pick a chat or a verdict from the sidebar, or start a new chat with ⌘N.",
                       icon: .agents)
        }
    }
}
