import SwiftUI
import CouncilCore

struct ConversationView: View {
    let vm: SessionViewModel

    private var subtitle: String {
        if let e = vm.loadError { return e }
        let n = vm.agents.count
        return "\(n) member\(n == 1 ? "" : "s") · " + (vm.isLive ? "live" : "members not running")
    }

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(vm: vm, subtitle: subtitle)
            if !vm.isLive, vm.loadError == nil { MembersBanner(vm: vm) }
            MemberCards(vm: vm)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ConversationRows(vm: vm)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
                .background(Palette.canvas)
                // The transcript is lazy, so the rows above the fold are estimated rather than measured, and
                // `scrollTo` on appear lands on an estimate that goes stale the moment the real heights arrive
                // — which left a chat opened from the terminal view stuck part way up, its newest message
                // behind the composer. `defaultScrollAnchor` is maintained by the scroll view itself across
                // relayouts, including the activity line appearing and collapsing underneath it.
                .defaultScrollAnchor(.bottom)
                .onChange(of: vm.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            ActivityLine(vm: vm)
            ComposerView(vm: vm)
        }
        .background(Palette.canvas)
        .sheet(isPresented: Binding(get: { vm.capReached }, set: { vm.capReached = $0 })) {
            LiveCapSheet(title: vm.title, sessions: vm.runningSessions,
                         onTake: { vm.takeSlot(from: $0) }) { vm.capReached = false }
        }
    }

}

/// The message rows of a chat, without a scroll container (shared by the live view and the snapshot tool).
struct ConversationRows: View {
    let vm: SessionViewModel

    var body: some View {
        ForEach(ConversationLayout.rows(for: vm.messages)) { row in
            switch row.kind {
            case .day(let d):
                DaySeparator(date: d)
            case .note(let m):
                NoteRow(message: m)
            case .message(let m, let showHeader):
                MessageBubble(message: m, showHeader: showHeader,
                              label: vm.config?.label(for: m.sender).replacingEffortSuffix ?? m.sender,
                              color: color(for: m.sender), members: vm.config?.order ?? [],
                              avatar: vm.agents.first { $0.name == m.sender }?.avatar,
                              onMention: { name in
                                  if vm.agents.contains(where: { $0.name == name }) { vm.toggleTerminal(for: name) }
                              })
            }
        }
    }

    private func color(for sender: String) -> Color {
        if sender == Message.userSender { return Palette.user }
        if let i = vm.agents.firstIndex(where: { $0.name == sender }) { return Palette.member(i) }
        return .gray
    }
}

/// "Members not running" bar under the header with the action that launches them. Sessions open read-only on
/// purpose: browsing history must never start CLIs.
struct MembersBanner: View {
    let vm: SessionViewModel

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                IconView(.agents, size: 16).foregroundStyle(.secondary)
                Text(vm.wasLive ? "This chat was live when the app last closed"
                                : "Members are not running in the app")
                    .font(Typography.callout).foregroundStyle(.secondary)
                Spacer()
                if vm.wasLive {
                    Button("Start fresh") { vm.startMembers() }
                        .controlSize(.small)
                    Button("Resume members") { vm.startMembers(resume: true) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Each member picks up its own CLI session, keeping the context it had")
                } else {
                    Button("Start members") { vm.startMembers() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            if let e = vm.startError {
                Text(e).font(Typography.caption).foregroundStyle(Palette.vermilion).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Palette.accent.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private extension String {
    var replacingEffortSuffix: String { ChatConfig.splitEffortSuffix(self).label }
}
