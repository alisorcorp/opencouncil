import XCTest

final class AppSmokeTests: XCTestCase {
    func testBundleLoads() {
        XCTAssertNotNil(Bundle.main)
    }
}
