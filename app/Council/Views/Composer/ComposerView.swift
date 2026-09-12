import SwiftUI
import CouncilCore

/// The message box. Typing is never blocked (R11): a chat whose members are not running starts them when the
/// first message is sent, and a message is written to the log even if the members cannot start, so nothing the
/// user typed is ever lost.
struct ComposerView: View {
    @Bindable var vm: SessionViewModel
    @State private var mention: ComposerTextView.MentionQuery?
    @State private var completion: String?
    @State private var highlighted = 0
    @State private var height: CGFloat = 21
    @State private var showingBudget = false

    /// Members whose name or label matches what has been typed after the `@`.
    private var suggestions: [AgentInfo] {
        guard let mention else { return [] }
        guard !mention.prefix.isEmpty else { return vm.agents }
        return vm.agents.filter {
            $0.name.hasPrefix(mention.prefix) || $0.label.lowercased().hasPrefix(mention.prefix)
        }
    }

    private var canSend: Bool { !vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !suggestions.isEmpty { MentionList(agents: suggestions, highlighted: highlighted, pick: complete) }
            VStack(spacing: 8) {
                HStack(alignment: .bottom, spacing: 10) {
                    ComposerTextView(text: $vm.draft, mention: $mention, completion: $completion,
                                     onHeight: { height = $0 }, onSubmit: send, onNavigationKey: navigate)
                        .frame(height: height)
                        .overlay(alignment: .topLeading) {
                            if vm.draft.isEmpty {
                                Text(placeholder).foregroundStyle(Palette.faintText).allowsHitTesting(false)
                            }
                        }
                    Button(action: send) { IconView(.send, size: 20) }
                        .buttonStyle(.plain)
                        .foregroundStyle(canSend ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.quaternary))
                        .disabled(!canSend)
                        .help("Send (↩) · Shift ↩ for a new line")
                }
                ComposerToolbar(vm: vm, showingBudget: $showingBudget, onWrapUp: wrapUp)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline))
        }
        .padding(.horizontal, 20).padding(.bottom, 16).padding(.top, 6)
        .background(Palette.canvas)
    }

    private var placeholder: String {
        if vm.isLive { return "Message the council · @name to address one" }
        return "Message the council · sending starts the members"
    }

    private func send() {
        let message = vm.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        switch ChatCommand.parse(message) {
        case .budget(let n): vm.setBudget(fromCommand: n)
        case nil: vm.send(message)
        }
        vm.draft = ""
        vm.saveDraft()
        mention = nil
        height = 21
    }

    private func wrapUp() {
        vm.send("Let's wrap it up. Final conclusions, please.")
    }

    /// The text view owns the edit so it stays undoable and the caret lands after the name.
    private func complete(_ agent: AgentInfo) { completion = agent.name }

    /// Keys the mention list claims while it is open.
    private func navigate(_ key: ComposerTextView.NavigationKey) -> Bool {
        guard !suggestions.isEmpty else { return false }
        switch key {
        case .up: highlighted = max(0, highlighted - 1); return true
        case .down: highlighted = min(suggestions.count - 1, highlighted + 1); return true
        case .tab, .accept:
            complete(suggestions[min(highlighted, suggestions.count - 1)])
            highlighted = 0
            return true
        case .escape: mention = nil; return true
        }
    }
}

/// Wrap-up, reply budget and the muted members, in the CLI's bottom-toolbar spirit.
struct ComposerToolbar: View {
    let vm: SessionViewModel
    @Binding var showingBudget: Bool
    let onWrapUp: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onWrapUp) {
                HStack(spacing: 5) { IconView(.wrapUp, size: 13); Text("Wrap up") }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Ask everyone for a final conclusion")

            if let status = vm.routerStatus {
                Button { showingBudget.toggle() } label: {
                    Text("\(status.budgetLeft)/\(status.budget) replies each")
                        .monospacedDigit()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Replies each member may send before you speak again · /budget 20 to change it")
                .popover(isPresented: $showingBudget, arrowEdge: .top) { BudgetPopover(vm: vm) }
                if status.wrapping {
                    Text("wrapping up").foregroundStyle(Palette.orange)
                }
            }

            Spacer()

            ForEach(vm.agents.filter { vm.isMuted($0.name) }) { agent in
                Button { vm.setMuted(agent.name, false) } label: {
                    HStack(spacing: 4) {
                        IconView(.bellOff, size: 12)
                        Text(agent.label).lineLimit(1)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Unmute \(agent.label)")
            }
        }
        .font(Typography.caption)
    }
}

struct BudgetPopover: View {
    let vm: SessionViewModel
    @State private var value = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Replies per member").font(Typography.calloutSemibold)
            Text("How many times each member may answer the others before you speak again. Typing "
                 + "/budget 20 in the chat does the same thing.")
                .font(Typography.caption).foregroundStyle(.secondary).frame(width: 240, alignment: .leading)
            Stepper("\(value)", value: $value, in: 1...99)
                .onChange(of: value) { _, n in vm.setBudget(n) }
        }
        .padding(14)
        .onAppear { value = vm.routerStatus?.budget ?? 20 }
    }
}

/// The `@name` picker above the composer.
struct MentionList: View {
    let agents: [AgentInfo]
    let highlighted: Int
    let pick: (AgentInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(agents.enumerated()), id: \.element.id) { i, agent in
                Button { pick(agent) } label: {
                    HStack(spacing: 8) {
                        Avatar(label: agent.label, color: Palette.member(agent.colorIndex), size: 20, image: agent.avatar)
                        Text(agent.name).font(Typography.calloutMedium)
                        Text(agent.label).font(Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(agent.status.label).font(Typography.caption2).foregroundStyle(Palette.faintText)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(i == highlighted ? Palette.accent.opacity(0.15) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.bottom, 6)
    }
}
