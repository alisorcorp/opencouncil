import SwiftUI
import CouncilCore

struct SessionRow: View {
    let session: SessionSummary
    let unread: Int
    let isSelected: Bool
    var live: LiveSessions? = nil
    var current: SessionViewModel? = nil
    let sessions: SessionsModel
    let action: () -> Void

    private var subtitle: String {
        switch session.kind {
        case .chat:
            let n = session.messageCount
            return "\(session.memberOrder.count) members · \(n) message\(n == 1 ? "" : "s")"
        case .verdict:
            if let s = session.score { return "Consensus \(s)/100 · \(session.memberOrder.count) members" }
            return session.hasVerdict ? "Verdict · \(session.memberOrder.count) members" : "No verdict yet"
        }
    }

    /// Members of this chat are running in the app right now.
    private var isLive: Bool { live?.runtime(for: session.id) != nil }
    /// The same grey as a message timestamp. The selected row is tinted rather than filled, so nothing here
    /// has to invert to stay legible on it.
    private var secondary: Color { Palette.faintText }
    private var glyphTint: Color { session.kind == .chat ? Palette.accent : Palette.orange }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(glyphTint.opacity(0.14))
                    IconView(session.kind == .chat ? .chat : .verdict, size: 20)
                        .foregroundStyle(glyphTint)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if isLive {
                            Circle().fill(Palette.periwinkle).frame(width: 5, height: 5)
                                .help("Members are running in this chat")
                        }
                        Text(session.displayTitle).font(Typography.font(14, .semibold)).lineLimit(1)
                    }
                    Text(subtitle).font(Typography.caption).foregroundStyle(secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(Formatters.relative(session.lastActivity)).font(Typography.caption2).foregroundStyle(secondary)
                    if unread > 0 {
                        Text("\(unread)")
                            .font(Typography.caption2Bold)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Palette.attention))
                            .foregroundStyle(.white)
                    } else if let s = session.score {
                        Text("\(s)")
                            .font(Typography.tabular(9, .bold))
                            .foregroundStyle(Palette.scoreColor(s))
                    }
                }
            }
            .modifier(SidebarRowStyle(isSelected: isSelected, tint: false))
        }
        .buttonStyle(.plain)
        .contextMenu { SessionActions(session: session, live: live, current: current, sessions: sessions) }
    }
}
