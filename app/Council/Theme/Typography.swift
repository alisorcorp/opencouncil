import SwiftUI
import AppKit

/// Figtree is the app's only typeface. It ships in `Resources/Fonts` (SIL OFL 1.1, licence beside it) and is
/// registered by `ATSApplicationFontsPath`, so nothing needs installing. Every text style in the app comes from
/// here rather than from SwiftUI's defaults; the sizes follow macOS's own scale so the switch did not reflow the
/// UI. The one exception is the terminal and fenced code, which have to stay monospaced.
enum Typography {
    static let family = "Figtree"

    /// Figtree's weight axis runs 300–900.
    enum Weight {
        case light, regular, medium, semibold, bold, extraBold, black

        var axis: Double {
            switch self {
            case .light: return 300
            case .regular: return 400
            case .medium: return 500
            case .semibold: return 600
            case .bold: return 700
            case .extraBold: return 800
            case .black: return 900
            }
        }

        var system: Font.Weight {
            switch self {
            case .light: return .light
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            case .extraBold: return .heavy
            case .black: return .black
            }
        }
    }

    // MARK: the app's text styles

    static let largeTitle = font(26, .bold)
    static let title = font(22, .bold)
    static let title2 = font(17, .semibold)
    static let title3 = font(15, .semibold)
    static let headline = font(13, .semibold)
    static let body = font(13)
    static let bodyMedium = font(13, .medium)
    static let callout = font(12)
    static let calloutMedium = font(12, .medium)
    static let calloutSemibold = font(12, .semibold)
    static let subheadline = font(11)
    static let subheadlineSemibold = font(11, .semibold)
    static let caption = font(10)
    static let captionMedium = font(10, .medium)
    static let captionSemibold = font(10, .semibold)
    static let caption2 = font(9)
    static let caption2Semibold = font(9, .semibold)
    static let caption2Bold = font(9, .bold)

    /// Digits that do not jitter as they change (scores, counters, budgets).
    static func tabular(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        font(size, weight, tabularFigures: true)
    }

    static func font(_ size: CGFloat, _ weight: Weight = .regular, tabularFigures: Bool = false) -> Font {
        if let font = nsFont(size, weight, tabularFigures: tabularFigures) { return Font(font) }
        return .system(size: size, weight: weight.system)
    }

    /// `true` once the bundled font is registered; false in a plain SwiftPM context or if the file is missing.
    static var isAvailable: Bool { NSFont(name: family, size: 12) != nil }

    /// The variable-font instance for a weight. Setting the `wght` axis directly avoids depending on CoreText
    /// exposing each named instance as its own face (Figtree's default instance is Light, not Regular).
    static func nsFont(_ size: CGFloat, _ weight: Weight, tabularFigures: Bool = false) -> NSFont? {
        guard isAvailable else { return nil }
        let key = Key(size: size, axis: weight.axis, tabular: tabularFigures)
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        if let hit { return hit }
        var attributes: [NSFontDescriptor.AttributeName: Any] = [
            .family: family,
            NSFontDescriptor.AttributeName(kCTFontVariationAttribute as String):
                [NSNumber(value: wghtTag): NSNumber(value: weight.axis)],
        ]
        if tabularFigures {
            attributes[.featureSettings] = [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]]
        }
        guard let font = NSFont(descriptor: NSFontDescriptor(fontAttributes: attributes), size: size) else { return nil }
        lock.lock()
        cache[key] = font
        lock.unlock()
        return font
    }

    private struct Key: Hashable { let size: CGFloat; let axis: Double; let tabular: Bool }
    /// Descriptor resolution is not free and these run inside view bodies. NSFont is not Sendable, so the
    /// cache is guarded by a lock rather than held in an actor.
    nonisolated(unsafe) private static var cache: [Key: NSFont] = [:]
    private static let lock = NSLock()
    /// FourCharCode for `wght`.
    private static let wghtTag: UInt32 = 0x7767_6874
}

extension View {
    /// Figtree at an explicit size, e.g. `.appFont(17, .bold)`.
    func appFont(_ size: CGFloat, _ weight: Typography.Weight = .regular) -> some View {
        font(Typography.font(size, weight))
    }
}
