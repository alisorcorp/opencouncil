import SwiftUI
import CouncilCore

/// Agents (current session's members) above Sessions (history). A plain scrolling column with hand-drawn
/// selection and hover states, like the reference design, rather than a source-list table.
struct SidebarView: View {
    @Environment(SessionsModel.self) private var sessions
    let current: SessionViewModel?
    /// Only for the row actions (start/stop members on a session that is not open).
    let live: LiveSessions?
    @AppStorage("appearance") private var appearance: Appearance = .system
    @State private var newChat = false
    @State private var newVerdict = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image("opencouncil-logo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 18)
                    .offset(x: 5, y: -5)
                    .accessibilityLabel("Open Council")
                Spacer(minLength: 8)
                Button { Task { await sessions.refresh() } } label: { IconView(.refresh, size: 18).foregroundStyle(Palette.mutedIcon) }
                    .buttonStyle(.borderless)
                    .help("Rescan chats and runs")
                // ⌘N lives in the File menu so it works wherever the focus is; these are the same actions.
                Button { newVerdict = true } label: { IconView(.verdict, size: 18).foregroundStyle(Palette.mutedIcon) }
                    .buttonStyle(.borderless)
                    .help("Ask the council (⇧⌘N)")
                Button { newChat = true } label: { IconView(.newSession, size: 18).foregroundStyle(Palette.mutedIcon) }
                    .buttonStyle(.borderless)
                    .help("New chat (⌘N)")
            }
            .padding(.horizontal, 16)
            .padding(.top, 40)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarSectionHeader(icon: .agents, text: "Agents")
                    if let vm = current {
                        ForEach(vm.agents) { agent in
                            AgentRow(agent: agent, isShowingTerminal: vm.detailMode == .terminal(agent.name), vm: vm) {
                                vm.toggleTerminal(for: agent.name)
                            }
                        }
                    } else {
                        Text("Select a session to see its members")
                            .font(Typography.callout).foregroundStyle(Palette.faintText)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }

                    SidebarSectionHeader(icon: .sessions, text: "Sessions")
                        .padding(.top, 16)
                    if sessions.sessions.isEmpty {
                        Text("No chats or verdicts yet").font(Typography.callout).foregroundStyle(Palette.faintText)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    ForEach(sessions.sessions) { s in
                        SessionRow(session: s, unread: sessions.unread[s.id] ?? 0, isSelected: sessions.selectedID == s.id,
                                   live: live, current: current, sessions: sessions) {
                            if sessions.selectedID == s.id {
                                current?.detailMode = .conversation   // already selected: leave the terminal, back to the chat
                            } else {
                                sessions.selectedID = s.id
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }

            HStack {
                Button { appearance = appearance.next } label: {
                    IconView(appearance.icon, size: 18).foregroundStyle(Palette.mutedIcon)
                }
                .buttonStyle(.borderless)
                .help(appearance.help)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(Palette.surface)
        .onReceive(NotificationCenter.default.publisher(for: .councilNewChat)) { _ in newChat = true }
        .onReceive(NotificationCenter.default.publisher(for: .councilNewVerdict)) { _ in newVerdict = true }
        .sheet(isPresented: $newChat) {
            NewChatSheet(paths: sessions.paths, defaultFolder: sessions.lastUsedFolder) { dir in
                Task { await sessions.select(newSessionAt: dir, startImmediately: true) }
            }
        }
        .sheet(isPresented: $newVerdict) {
            NewVerdictSheet(paths: sessions.paths, defaultFolder: sessions.lastUsedFolder) { dir in
                Task { await sessions.select(newSessionAt: dir, startImmediately: true) }
            }
        }
    }
}

struct SidebarSectionHeader: View {
    let icon: Icon
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            IconView(icon, size: 15)
            Text(text)
        }
        .font(Typography.font(11, .bold))
        .textCase(.uppercase)
        .kerning(0.6)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

/// Shared chrome for sidebar rows: rounded highlight for selection, faint highlight on hover. Applied inside the
/// row's Button label so the whole padded area, not just the text, takes the click.
struct SidebarRowStyle: ViewModifier {
    let isSelected: Bool
    let tint: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    // A selected row is tinted, not filled: a solid accent block under a whole session row
                    // shouted louder than the conversation beside it. Same wash as a shown terminal.
                    .fill(isSelected || tint ? AnyShapeStyle(Palette.accent.opacity(0.12))
                          : hovering ? AnyShapeStyle(Palette.hover) : AnyShapeStyle(Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { hovering = $0 }
    }
}
