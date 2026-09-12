import SwiftUI
import CouncilCore

/// What the council is doing right now, in one line above the composer: who is working and on what, who has a
/// prompt waiting, and which turn has gone quiet for long enough to be worth mentioning. Empty — and invisible
/// — when everybody is idle.
struct ActivityLine: View {
    let vm: SessionViewModel

    private struct Item: Identifiable {
        let id: String
        let label: String
        let detail: String
        let color: Color
        let slow: Bool
    }

    private var items: [Item] {
        vm.agents.enumerated().compactMap { i, agent in
            let state = vm.state(of: agent.name)
            switch state {
            case .working(let activity):
                return Item(id: agent.name, label: agent.label, detail: activity ?? "thinking",
                            color: Palette.member(i), slow: vm.isSlow(agent.name))
            case .prompted:
                return Item(id: agent.name, label: agent.label, detail: "reading the prompt",
                            color: Palette.member(i), slow: false)
            default:
                return vm.hasDeliveryInFlight(for: agent.name)
                    ? Item(id: agent.name, label: agent.label, detail: "queued", color: Palette.member(i), slow: false)
                    : nil
            }
        }
    }

    var body: some View {
        let items = items
        if !items.isEmpty {
            HStack(spacing: 12) {
                ForEach(items) { item in
                    HStack(spacing: 5) {
                        Circle().fill(item.color).frame(width: 5, height: 5)
                        Text(item.label).foregroundStyle(item.color)
                        Text(item.slow ? "\(item.detail) · quiet for a while" : item.detail)
                            .foregroundStyle(item.slow ? AnyShapeStyle(Palette.amber) : AnyShapeStyle(Palette.faintText))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(Typography.caption)
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .transition(.opacity)
        }
    }
}
