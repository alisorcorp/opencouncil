import SwiftUI
import AppKit
import CouncilCore

/// R14 in the interface: when a member cannot answer, the chat says so and offers the way out, rather than
/// leaving a message that quietly went nowhere. One card per member that needs a human, plus one for the
/// problems that belong to the whole session.
struct MemberCards: View {
    let vm: SessionViewModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(vm.sessionProblems, id: \.self) { problem in
                SessionProblemCard(vm: vm, message: problem)
            }
            ForEach(vm.attention, id: \.member) { item in
                MemberCard(vm: vm, member: item.member, state: item.state)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }
}

struct MemberCard: View {
    let vm: SessionViewModel
    let member: String
    let state: MemberState

    private var label: String { vm.agents.first { $0.name == member }?.label ?? member }
    private var isBlocked: Bool { if case .error = state { return false } else { return true } }

    private var title: String {
        isBlocked ? "\(label) is waiting for you" : "\(label) stopped"
    }

    /// The screen hint is better than the event's reason when we have one — it says which button to press.
    private var detail: String { vm.hint(for: member) ?? state.reason ?? "" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconView(isBlocked ? .bellRing : .exit, size: 18)
                .foregroundStyle(isBlocked ? Palette.amber : Palette.vermilion)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Typography.calloutSemibold)
                if !detail.isEmpty {
                    Text(detail).font(Typography.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button("Open terminal") { vm.toggleTerminal(for: member) }
                if !isBlocked {
                    Button("Retry") { vm.restart(member) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill((isBlocked ? Palette.amber : Palette.vermilion).opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder((isBlocked ? Palette.amber : Palette.vermilion).opacity(0.35)))
    }
}

/// A problem that belongs to the session rather than to one member: the project folder moved, or another
/// router holds the chat.
struct SessionProblemCard: View {
    let vm: SessionViewModel
    let message: String

    private var isMissingFolder: Bool { message.hasPrefix("Project folder is missing") }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconView(.question, size: 18).foregroundStyle(Palette.vermilion).padding(.top, 1)
            Text(message).font(Typography.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if isMissingFolder {
                Button("Pick folder…") { pickFolder() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.vermilion.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Palette.vermilion.opacity(0.35)))
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use this folder"
        if panel.runModal() == .OK, let url = panel.url { vm.setProjectFolder(url) }
    }
}
