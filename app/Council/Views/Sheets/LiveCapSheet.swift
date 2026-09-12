import SwiftUI
import CouncilCore

/// Three sessions may have members running at once — enough terminals to follow, few enough that forgotten
/// ones cannot pile up. When a fourth is asked for, this says which hold the slots and offers to free one,
/// rather than refusing and leaving the user to find them. Verdict runs count against the same cap as chats,
/// so this list holds both and has to say which is which.
///
/// It takes the rows rather than the view model: everything it needs is a title and a list, and a sheet that
/// depends on nothing live can be rendered on its own by the snapshot harness.
struct LiveCapSheet: View {
    typealias Row = (id: String, title: String, members: Int, since: Date?, kind: SessionKind)

    let title: String
    let sessions: [Row]
    let onTake: (String) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(LiveSessions.cap) sessions already have members running")
                    .font(Typography.headline)
                Text("Stop one of them to start “\(title)”. Stopping members changes nothing the session "
                     + "has already written.")
                    .font(Typography.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 14)

            VStack(spacing: 6) {
                ForEach(sessions, id: \.id) { session in
                    HStack(spacing: 10) {
                        IconView(session.kind == .verdict ? .verdict : .chat, size: 18)
                            .foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title).font(Typography.calloutSemibold).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(session.kind == .verdict ? "Run" : "Chat") · \(session.members) "
                                 + "member\(session.members == 1 ? "" : "s") · running "
                                 + "\(Formatters.relative(session.since))")
                                .font(Typography.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Stop and take the slot") { onTake(session.id); dismiss() }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.hover))
                }
            }
            .padding(.horizontal, 20)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
        }
        .frame(width: 460)
        .background(Palette.surface)
    }
}
