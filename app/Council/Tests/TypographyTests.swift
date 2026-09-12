import XCTest
import AppKit
@testable import Council

/// The app's typeface is bundled, not installed, so nothing warns when the resource or the
/// `ATSApplicationFontsPath` entry goes missing: the app just renders in the system font. These tests fail instead.
final class TypographyTests: XCTestCase {
    func testBundledDisplayFontIsRegistered() {
        XCTAssertTrue(Typography.isAvailable, "Figtree is not registered; check Resources/Fonts and ATSApplicationFontsPath")
    }

    func testWeightsResolveToDistinctFaces() {
        guard Typography.isAvailable else { return XCTFail("font missing") }
        let regular = Typography.nsFont(20, .regular)
        let bold = Typography.nsFont(20, .black)
        XCTAssertNotNil(regular)
        XCTAssertNotNil(bold)
        // A variable font that ignored the axis would draw both weights identically.
        XCTAssertGreaterThan(width("Council", in: bold), width("Council", in: regular))
    }

    private func width(_ text: String, in font: NSFont?) -> CGFloat {
        guard let font else { return 0 }
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// Every weight has to resolve to the bundled face; a typo in the family name would silently fall back to
    /// the system font, which is exactly the regression these tests exist to catch.
    func testEveryWeightResolvesToTheBundledFace() {
        for weight in [Typography.Weight.light, .regular, .medium, .semibold, .bold, .extraBold, .black] {
            XCTAssertEqual(Typography.nsFont(13, weight)?.familyName, Typography.family, "\(weight)")
        }
    }

    func testTabularDigitsAreAvailableForCountersAndScores() {
        guard let font = Typography.nsFont(13, .regular, tabularFigures: true) else { return XCTFail("font missing") }
        XCTAssertEqual(width("111", in: font), width("000", in: font), accuracy: 0.01)
    }

    func testLicenceShipsWithTheFont() {
        XCTAssertNotNil(Bundle.main.url(forResource: "OFL", withExtension: "txt", subdirectory: "Resources/Fonts"),
                        "SIL OFL requires the licence to travel with the font")
    }
}
