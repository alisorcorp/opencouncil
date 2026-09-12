import SwiftUI

/// What the window follows, remembered across launches. Three states rather than two: a Mac app that quietly
/// stops following the system setting is the odd one out, and a plain light/dark toggle has no way back to it.
/// The sidebar's button cycles system → light → dark → system, and says which it is on.
enum Appearance: String, CaseIterable {
    case system, light, dark

    var next: Appearance {
        switch self {
        case .system: return .light
        case .light: return .dark
        case .dark: return .system
        }
    }

    /// `nil` means "whatever the system says", which is what `preferredColorScheme` wants for it.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var icon: Icon {
        switch self {
        case .system: return .themeSystem
        case .light: return .themeLight
        case .dark: return .themeDark
        }
    }

    var help: String {
        switch self {
        case .system: return "Appearance: following the system — click for light"
        case .light: return "Appearance: light — click for dark"
        case .dark: return "Appearance: dark — click to follow the system"
        }
    }
}
