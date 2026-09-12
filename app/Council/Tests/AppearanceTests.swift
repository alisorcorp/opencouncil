import XCTest
import SwiftUI
@testable import Council

/// The sidebar's one button has to reach every state and come back, and "follow the system" has to stay
/// reachable — a two-state toggle would strand anyone who pressed it once.
final class AppearanceTests: XCTestCase {
    func testCyclingReachesEveryStateAndReturns() {
        var seen: [Appearance] = [.system]
        var state = Appearance.system
        for _ in 1...Appearance.allCases.count {
            state = state.next
            if state != .system { seen.append(state) }
        }
        XCTAssertEqual(Set(seen), Set(Appearance.allCases), "a state the button cannot reach")
        XCTAssertEqual(state, .system, "the cycle does not come back to following the system")
    }

    func testOnlySystemDefersToTheSystem() {
        XCTAssertNil(Appearance.system.colorScheme, "nil is what preferredColorScheme wants for 'the system's'")
        XCTAssertEqual(Appearance.light.colorScheme, .light)
        XCTAssertEqual(Appearance.dark.colorScheme, .dark)
    }

    /// The icons are drawn for this app rather than taken from the packs, so a rebuild of the catalog that
    /// dropped them would otherwise show up only as three blank buttons.
    func testEveryStateHasItsOwnIconAndItIsInTheCatalog() {
        let icons = Appearance.allCases.map(\.icon)
        XCTAssertEqual(Set(icons).count, Appearance.allCases.count, "two states share an icon")
        for icon in icons {
            XCTAssertNotNil(NSImage(named: icon.rawValue), "\(icon.rawValue) is missing from Icons.xcassets")
        }
    }

    func testTheHelpTextNamesTheStateItIsIn() {
        for state in Appearance.allCases {
            XCTAssertTrue(state.help.contains(state == .system ? "system" : state.rawValue),
                          "\(state) does not say which appearance it is on: \(state.help)")
        }
    }
}
