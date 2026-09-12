import SwiftUI
import CouncilCore

/// Top bar of the detail pane: title, member avatars, and the live/not-running state.
struct SessionHeader: View {
    let vm: SessionViewModel
    var subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Palette.accent)
                IconView(vm.summary.kind == .chat ? .chat : .verdict, size: 24)
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.title).font(Typography.font(17, .bold)).lineLimit(1)
                Text(subtitle).font(Typography.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: -8) {
                ForEach(vm.agents) { a in
                    Avatar(label: a.label, color: Palette.member(a.colorIndex), size: 28, image: a.avatar)
                        .overlay(Circle().stroke(Palette.surface, lineWidth: 2))
                        .help("\(a.label) · \(a.status.label)")
                }
            }
            if vm.isLive {
                Button("Stop members") { vm.stopMembers() }
                    .buttonStyle(.bordered)
                    .help("Terminate this session's members")
            }
            if vm.detailMode != .conversation {
                Button { vm.detailMode = .conversation } label: {
                    HStack(spacing: 6) { IconView(.back, size: 16); Text("Back to chat") }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Palette.surface)
        .overlay(alignment: .bottom) { Divider() }
    }
}
