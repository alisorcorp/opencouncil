import XCTest
import CouncilCore
@testable import Council

/// Adding a backend meant editing three lists: the enum, `council event`'s argparse choices, and this one.
/// The first two announce themselves — a member will not launch, or every hook fails. This one does not: the
/// app works and the CLI is simply missing from the Environment window, which is where someone looks when a
/// member will not start. So it is derived rather than written out, and this test says so.
final class ToolsListTests: XCTestCase {
    // On the method, never the class: XCTest instantiates cases off the main thread.
    @MainActor
    func testEveryBackendTheAppCanHostIsListedAsATool() {
        for backend in CouncilConfig.Backend.allCases where backend.isTerminalBackend {
            XCTAssertTrue(AppEnvironment.tools.contains(backend.rawValue),
                          "\(backend.rawValue) can be launched but is not listed under Tools")
        }
        XCTAssertFalse(AppEnvironment.tools.contains(CouncilConfig.Backend.openai.rawValue),
                       "openai members have no CLI to find")
        XCTAssertTrue(AppEnvironment.tools.contains("council"), "the members' hooks run it")
    }
}
