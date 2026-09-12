import SwiftUI
import CouncilCore

/// One message: the sender's avatar and name, then the text itself. No bubble — a member's text carries a
/// light tint of its colour instead, which keeps a long thread readable without boxing every paragraph. The
/// user's own messages mirror the row to the right and stay plain white, so a glance finds what was asked.
struct MessageBubble: View {
    let message: Message
    let showHeader: Bool
    let label: String
    let color: Color
    let members: [String]
    var avatar: String? = nil
    var onMention: ((String) -> Void)?

    private var isUser: Bool { message.isFromUser }
    private var tint: Color { isUser ? Palette.user : color }
    private var name: String { isUser ? "You" : label }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isUser { Spacer(minLength: 40) } else { avatarOrGap }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                // Every message keeps its own name line: without bubbles, two posts in a row from one member
                // would otherwise read as one long message.
                header
                MessageMarkdown(text: message.text, members: members, onMention: onMention)
                    // A record the log could not give up keeps its place and its name, but the words shown are
                    // the app's account of the failure — italic so they do not read as the member's own.
                    .italic(message.isUnreadable)
                    .foregroundStyle(isUser ? Palette.userText : Palette.messageText(tintedBy: tint))
                    .multilineTextAlignment(isUser ? .trailing : .leading)
                    .frame(maxWidth: 760, alignment: isUser ? .trailing : .leading)
                    .contextMenu {
                        Button("Copy text") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        }
                    }
            }
            if isUser { avatarOrGap } else { Spacer(minLength: 0) }
        }
        .padding(.top, showHeader ? 14 : 10)
        .padding(.bottom, 8)
    }

    /// The avatar on the first message of a run, and a gap of the same width on the rest, so every line of a
    /// run keeps the same margin.
    @ViewBuilder
    private var avatarOrGap: some View {
        if showHeader {
            Avatar(label: name, color: isUser ? Palette.user : color, size: 30,
                   isUser: isUser, image: isUser ? AvatarCatalog.imageName(member: "user") : avatar)
        } else {
            Color.clear.frame(width: 30, height: 1)
        }
    }

    /// Name and time, mirrored for the user so the name always sits against the message's own margin.
    private var header: some View {
        HStack(spacing: 8) {
            if isUser { Text(Formatters.clock(message.date)).font(Typography.caption).foregroundStyle(Palette.faintText) }
            Text(name)
                .font(Typography.font(14, .bold))
                .foregroundStyle(isUser ? Palette.userText : color)
            if !isUser { Text(Formatters.clock(message.date)).font(Typography.caption).foregroundStyle(Palette.faintText) }
        }
    }
}

struct NoteRow: View {
    let message: Message

    var body: some View {
        HStack(spacing: 6) {
            Text(Formatters.clock(message.date)).font(Typography.caption2).foregroundStyle(Palette.faintestText)
            Text(message.text).font(Typography.callout).italic().foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

struct DaySeparator: View {
    let date: Date

    var body: some View {
        Text(Formatters.dayLabel(date))
            .font(Typography.captionMedium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(Palette.surface))
            .overlay(Capsule().strokeBorder(Palette.hairline))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }
}
