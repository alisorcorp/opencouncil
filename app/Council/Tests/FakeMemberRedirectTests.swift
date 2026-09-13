import XCTest
import CouncilCore
@testable import Council

/// `COUNCIL_FAKE_MEMBERS=1` exists so the whole delivery chain can be exercised without spending anyone's
/// model quota, and it is used by the scenario suite and by every `--drive` run. A backend it forgets does the
/// opposite of what the flag promises: it launches the real CLI and bills the user for a test. kimi was left
/// out from the day it was added, and nothing noticed, because kimi has no scenario of its own.
final class FakeMemberRedirectTests: XCTestCase {
    private func environment(fake: Bool) -> MemberLaunchEnvironment {
        MemberLaunchEnvironment.make(shell: ShellEnvironment(path: ["/usr/bin", "/bin"], source: .fallback),
                                     paths: CouncilPaths(root: URL(fileURLWithPath: "/private/tmp/council-test")),
                                     processEnvironment: fake ? [MemberLaunchEnvironment.fakeFlag: "1"] : [:],
                                     bundle: .main)
    }

    func testEveryBackendTheAppCanHostRunsTheStandIn() {
        let made = environment(fake: true)
        XCTAssertTrue(made.isFake)
        for backend in CouncilConfig.Backend.allCases where backend.isTerminalBackend {
            let executable = made.tools.executable(for: backend)
            XCTAssertEqual(executable?.lastPathComponent, "fake-member.py",
                           "\(backend.rawValue) still launches its real CLI under "
                           + "\(MemberLaunchEnvironment.fakeFlag), so a test that is supposed to be free "
                           + "spends the user's subscription")
        }
    }

    /// The flag has to be opt-in: resolving the real CLIs is what every ordinary launch does.
    func testWithoutTheFlagNothingIsRedirected() {
        let made = environment(fake: false)
        XCTAssertFalse(made.isFake)
        for backend in CouncilConfig.Backend.allCases {
            XCTAssertNotEqual(made.tools.executable(for: backend)?.lastPathComponent, "fake-member.py")
        }
    }
}
