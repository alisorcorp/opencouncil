import SwiftUI

struct AgentRow: View {
    let agent: AgentInfo
    let isShowingTerminal: Bool
    /// Nil for a session that is not open; the mute action needs a live chat.
    var vm: SessionViewModel? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Avatar(label: agent.label, color: Palette.member(agent.colorIndex), size: 32, image: agent.avatar)
                    .overlay(alignment: .bottomTrailing) { StatusDot(status: agent.status) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.label).font(Typography.font(14, .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(agent.status.label).foregroundStyle(Palette.status(agent.status))
                        if let e = agent.effort { Text("· \(e)").foregroundStyle(Palette.faintText) }
                    }
                    .font(Typography.caption).lineLimit(1)
                }
                Spacer(minLength: 4)
                IconView(.terminal, size: 18)
                    .foregroundStyle(isShowingTerminal ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.tertiary))
                    .help(isShowingTerminal ? "Back to the conversation" : "Show \(agent.label)'s terminal")
            }
            .modifier(SidebarRowStyle(isSelected: false, tint: isShowingTerminal))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(isShowingTerminal ? "Back to the conversation" : "Show terminal", action: action)
            if let vm, vm.isLive {
                Divider()
                if vm.isMuted(agent.name) {
                    Button("Unmute") { vm.setMuted(agent.name, false) }
                } else {
                    Button("Mute") { vm.setMuted(agent.name, true) }
                }
            }
        }
    }
}

struct StatusDot: View {
    let status: AgentStatus

    var body: some View {
        Circle()
            .fill(Palette.status(status))
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(Palette.surface, lineWidth: 2))
            .offset(x: 1, y: 1)
    }
}
