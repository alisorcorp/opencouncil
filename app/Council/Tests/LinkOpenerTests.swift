import XCTest
import CouncilCore
@testable import Council

/// The app half of link handling: `LinkTarget` decides, `LinkOpener` acts. Only the paths with no side effect
/// are driven here — nothing in a test should open a file or a browser.
final class LinkOpenerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("council-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// The replacement for LaunchServices' "-50": a path with nothing at it is reported, not handed on.
    @MainActor
    func testALinkToNothingIsReported() {
        var reported: String?
        let url = URL(string: "gone/nowhere.swift:12")!
        _ = LinkOpener.open(url, relativeTo: root) { reported = $0 }
        XCTAssertEqual(reported, "There is no file at \(root.appendingPathComponent("gone/nowhere.swift").standardizedFileURL.path).")
    }

    @MainActor
    func testAWebLinkIsLeftToTheSystem() {
        var reported: String?
        _ = LinkOpener.open(URL(string: "https://example.com")!, relativeTo: root) { reported = $0 }
        XCTAssertNil(reported)
    }
}
