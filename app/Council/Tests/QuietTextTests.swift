import XCTest
import SwiftUI
import AppKit
@testable import Council

/// The app has three levels of quiet text and the order between them is the design: a note's clock is quieter
/// than a message's, which is quieter than the words themselves. Nudging one level is how that order gets
/// inverted by accident, and an inverted one is not obviously wrong on screen — it just reads oddly.
final class QuietTextTests: XCTestCase {
    private func opacity(of color: Color, dark: Bool) -> CGFloat {
        var alpha: CGFloat = -1
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            alpha = (NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)).alphaComponent
        }
        return alpha
    }

    func testTheQuietTextLevelsKeepTheirOrderInBothAppearances() {
        for dark in [false, true] {
            let faint = opacity(of: Palette.faintText, dark: dark)
            let faintest = opacity(of: Palette.faintestText, dark: dark)
            let where_ = dark ? "dark" : "light"
            XCTAssertGreaterThan(faint, faintest, "faintText is not brighter than faintestText in \(where_)")
            XCTAssertGreaterThan(faintest, 0.2, "faintestText has gone too dim to read in \(where_): \(faintest)")
            XCTAssertLessThan(faint, 0.5, "faintText has reached secondary in \(where_): \(faint)")
        }
    }

    /// The dark side carries a little more, because white on a near-black ground reads dimmer than black on
    /// white at the same opacity. If that ever reverses it was an accident.
    func testDarkIsNotQuieterThanLight() {
        XCTAssertGreaterThanOrEqual(opacity(of: Palette.faintText, dark: true),
                                    opacity(of: Palette.faintText, dark: false))
        XCTAssertGreaterThanOrEqual(opacity(of: Palette.faintestText, dark: true),
                                    opacity(of: Palette.faintestText, dark: false))
    }
}
