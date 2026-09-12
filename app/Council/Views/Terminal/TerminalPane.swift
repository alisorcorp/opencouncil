import SwiftUI
import CouncilCore

/// The detail pane while an agent row is selected: that member's terminal, or why there is none yet.
struct TerminalPane: View {
    let vm: SessionViewModel
    let member: String

    private var agent: AgentInfo? { vm.agents.first { $0.name == member } }
    private var label: String { agent?.label ?? member }

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(vm: vm, subtitle: subtitle)
            if let rt = vm.runtime, rt.host(for: member) != nil {
                TerminalContainerView(runtime: rt, selected: member)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(alignment: .bottom) {
                        if rt.lockedMembers.contains(member) { DeliveryLockBadge() }
                    }
            } else {
                notRunning
            }
        }
    }

    private var subtitle: String {
        var s = "\(label) · terminal"
        if let status = agent?.status, status != .notRunning { s += " · \(status.label)" }
        if let hint = vm.runtime?.blockedHints[member] { s += " · \(hint)" }
        return s
    }

    private var problem: String? {
        vm.runtime?.problems.first { $0.member == member || $0.member == "*" }?.message
    }

    private var notRunning: some View {
        VStack(spacing: 10) {
            IconView(.terminal, size: 56).foregroundStyle(.tertiary)
            Text("\(label) is not running").font(Typography.title3)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            if vm.summary.kind == .chat, vm.runtime == nil {
                Button("Start members") { vm.startMembers() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 6)
            }
            if let e = vm.startError { Text(e).font(Typography.callout).foregroundStyle(Palette.vermilion) }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
    }

    private var detail: String {
        if let problem { return problem }
        if vm.runtime != nil { return "This member cannot run in the app." }
        if vm.summary.kind == .chat { return "Start the members to open a terminal for each of them here." }
        return "Verdict members run in hidden sessions once verdicts move into the app."
    }
}


/// Shown over a terminal while the app is pasting a delivery into it: keystrokes are dropped, not queued.
struct DeliveryLockBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Delivering · keyboard input paused").font(Typography.callout)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Palette.hairline))
        .padding(.bottom, 14)
    }
}
