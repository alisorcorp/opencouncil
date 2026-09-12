import SwiftUI
import AppKit

extension Color {
    /// `Color(hex: 0x7678ED)` — the palette is written the way the design tool writes it.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// The brand palette: indigo #3D348B, periwinkle #7678ED, amber #F7B801, orange #F18701, vermilion #F35B04.
/// Everything the app tints comes from here. In the dark the whole window is one flat near-black (#0B0B0F) and
/// separation comes from the palette and hairline borders, not from stacked greys.
enum Palette {
    // MARK: brand

    static let indigo = Color(hex: 0x3D348B)
    static let periwinkle = Color(hex: 0x7678ED)
    static let amber = Color(hex: 0xF7B801)
    static let orange = Color(hex: 0xF18701)
    static let vermilion = Color(hex: 0xF35B04)

    /// The accent also lives in the asset catalog so AppKit tints system controls with it.
    static let accent = Color("AccentColor")

    // MARK: members
    // Eight slots so a large roster still reads; the palette first, then tints of it. Index = position in the
    // session's member order, as the CLI does it.
    static let members: [Color] = [
        periwinkle,
        orange,
        Color(hex: 0x4FC3C7),        // teal, a cool counterweight to the warm half
        amber,
        Color(hex: 0xB07BE8),        // violet, between the indigo and the warm end
        vermilion,
        Color(hex: 0x9BA2F5),        // pale periwinkle
        Color(hex: 0x5B54A6),        // deep indigo, lifted enough to read on the canvas
    ]

    static func member(_ index: Int) -> Color { members[max(index, 0) % members.count] }

    // MARK: surfaces

    static let user = accent
    /// The canvas: #0B0B0F everywhere in the dark, a cool off-white in the light.
    static let canvas = dynamic(light: Color(hex: 0xF6F7FA), dark: Color(hex: 0x0B0B0F))
    /// Sidebar, header and composer. The same near-black as the canvas in the dark, so the window is one field.
    static let surface = dynamic(light: .white, dark: Color(hex: 0x0B0B0F))
    /// A message bubble, lifted just enough to read as a block of text.
    static let bubble = dynamic(light: .white, dark: Color(hex: 0x16161D))
    /// Hairlines and bubble borders.
    static let hairline = dynamic(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.09))
    /// Row hover and other faint fills.
    static let hover = dynamic(light: Color.black.opacity(0.05), dark: Color.white.opacity(0.06))
    /// Message text: mostly neutral, carrying just enough of the sender's colour to tell a thread apart at a
    /// glance now that the bubbles are gone.
    static func messageText(tintedBy color: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let base = NSColor(isDark ? Color(hex: 0xE6E6EC) : Color(hex: 0x17171E))
            let tint = NSColor(color).usingColorSpace(.sRGB) ?? .white
            return base.usingColorSpace(.sRGB)?.blended(withFraction: isDark ? 0.22 : 0.16, of: tint) ?? base
        })
    }

    /// A member's state, as both the dot and the words beside it.
    static func status(_ status: AgentStatus) -> Color {
        switch status {
        case .notRunning: return mutedIcon
        case .starting: return indigo
        case .ready: return periwinkle
        case .working: return orange
        case .blocked: return amber
        case .error: return vermilion
        case .muted: return mutedIcon.opacity(0.5)
        }
    }

    /// The user's own messages: plain white on the dark canvas, with no member tint — they are the questions a
    /// thread is answering, not another voice in it. White would vanish on the light canvas, so it inverts.
    static let userText = dynamic(light: Color(hex: 0x101014), dark: .white)

    /// Icons that are not the subject: the sidebar collapse control, inactive glyphs.
    static let mutedIcon = dynamic(light: Color.black.opacity(0.45), dark: Color.white.opacity(0.45))

    /// The quiet text: timestamps, the composer's placeholder, a member's effort, the sidebar's counts.
    /// AppKit's `.tertiary` is about a quarter opacity, which against this canvas reads as nearly absent, so
    /// these are named rather than borrowed — a notch brighter, and still clearly below `.secondary`.
    /// Dark carries slightly more: white on a near-black ground reads dimmer than black on white at the same
    /// opacity.
    static let faintText = dynamic(light: Color.black.opacity(0.42), dark: Color.white.opacity(0.44))
    /// A step quieter still, for the clock on a system note where the note itself is the point.
    static let faintestText = dynamic(light: Color.black.opacity(0.30), dark: Color.white.opacity(0.32))

    /// Unread counts and anything that means "look here".
    static let attention = vermilion

    static func dynamic(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }

    /// "Claude Fable 5.1" → "CF", "codex" → "CO".
    static func initials(_ label: String) -> String {
        let words = label.split(whereSeparator: { $0 == " " || $0 == "·" }).filter { !$0.isEmpty }
        if words.count >= 2, let a = words[0].first, let b = words[1].first, b.isLetter {
            return String([a, b]).uppercased()
        }
        return String(label.prefix(2)).uppercased()
    }

    /// Consensus as a heat ramp through the warm half of the palette.
    static func scoreColor(_ score: Int) -> Color {
        score >= 70 ? amber : score >= 40 ? orange : vermilion
    }
}

/// The avatar images in `Icons.xcassets` (`avatar-<name>`), generated from `app/Icons/avatars`.
enum AvatarCatalog {
    static let user = "avatar-user"

    /// The image for a member: by member name first (claude, codex, deepseek, gemini), then by the model it runs,
    /// then by backend. Nil when no image exists, so the caller falls back to initials — which is what a kimi
    /// member gets until an `avatar-kimi` image is dropped into `Icons.xcassets`.
    static func imageName(member: String?, backend: String? = nil, model: String? = nil) -> String? {
        var candidates: [String] = []
        if let member { candidates.append(member.lowercased()) }
        if let model = model?.lowercased() {
            for known in ["deepseek", "gemini", "claude", "codex", "gpt", "kimi"] where model.contains(known) {
                candidates.append(known == "gpt" ? "codex" : known)
            }
        }
        if let backend = backend?.lowercased(), ["claude", "codex", "kimi"].contains(backend) { candidates.append(backend) }
        return candidates.lazy.map { "avatar-\($0)" }.first { exists($0) }
    }

    nonisolated(unsafe) private static var cache: [String: Bool] = [:]
    private static func exists(_ name: String) -> Bool {
        if let hit = cache[name] { return hit }
        let found = NSImage(named: name) != nil
        cache[name] = found
        return found
    }
}

/// A round avatar: the member's image when the catalog has one, otherwise initials on the member colour; the
/// user gets their image or the accent colour with a person glyph.
struct Avatar: View {
    let label: String
    let color: Color
    var size: CGFloat = 34
    var isUser = false
    var image: String? = nil

    var body: some View {
        ZStack {
            if let image {
                Image(image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle().fill(color)
                if isUser {
                    Image(systemName: "person.fill").font(Typography.font(size * 0.45, .semibold)).foregroundStyle(.white)
                } else {
                    Text(Palette.initials(label))
                        .font(Typography.font(size * 0.38, .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(label)
    }
}

enum Formatters {
    /// "2m", "3h", "Yesterday", "Sep 8", "Mar 2, 2025"
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let s = now.timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400, Calendar.current.isDateInToday(date) { return "\(Int(s / 3600))h" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(date, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        return f.string(from: date)
    }

    /// "Today, Sep 10" / "Yesterday, Sep 9" / "Tue, Sep 2"
    static func dayLabel(_ date: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        if Calendar.current.isDateInToday(date) { return "Today, " + f.string(from: date) }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday, " + f.string(from: date) }
        f.dateFormat = Calendar.current.isDate(date, equalTo: now, toGranularity: .year) ? "EEE, MMM d" : "EEE, MMM d, yyyy"
        return f.string(from: date)
    }

    static func clock(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
