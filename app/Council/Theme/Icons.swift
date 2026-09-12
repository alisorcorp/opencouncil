import SwiftUI

/// Semantic names for the line-duotone icon set in `Icons.xcassets` (source SVGs in `app/Icons`).
/// All are template images: tint with `foregroundStyle`, size with `frame`. Secondary strokes are drawn at
/// half opacity by the SVGs themselves, so the duotone look survives tinting.
enum Icon: String {
    case chat = "text-chat-4"          // a chat session (bubble with text lines)
    case chatPlain = "chat-3"
    case verdict = "check-chat"        // a verdict run
    case consensus = "medal-star"
    case agents = "chatting"
    case sessions = "inbox"
    case terminal = "code-chat"
    case send = "send"
    case attach = "attachment"
    case refresh = "undo-right-round"
    case back = "undo-left"
    case bell = "bell"
    case bellOff = "bell-off"
    case bellRing = "bell-bing"
    case newSession = "pen"
    case wrapUp = "check-2"
    case question = "talk"
    case exit = "exit"
    case login = "login"
    case maximize = "maximize"
    case minimize = "minimize"
    case reorder = "reorder"
    case unread = "unread-chat"
    // Drawn for this app rather than taken from the packs, which have no sun, moon or half-disc.
    case themeLight = "theme-light"
    case themeDark = "theme-dark"
    case themeSystem = "theme-system"

    var image: Image { Image(rawValue).renderingMode(.template).resizable() }
}

/// An icon at a fixed point size.
struct IconView: View {
    let icon: Icon
    var size: CGFloat = 18

    init(_ icon: Icon, size: CGFloat = 18) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        icon.image
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}
