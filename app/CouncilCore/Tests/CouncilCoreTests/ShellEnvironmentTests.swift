import XCTest
@testable import CouncilCore

final class ShellEnvironmentTests: XCTestCase {
    func testSentinelParsingIgnoresNoise() {
        let out = """
        Welcome banner from .zshrc
        warning: something
        __COUNCIL_PATH_BEGIN__
        /opt/homebrew/bin:/usr/bin:/bin
        __COUNCIL_PATH_END__
        trailing
        """
        XCTAssertEqual(ShellEnvironment.parseSentinel(out), "/opt/homebrew/bin:/usr/bin:/bin")
        XCTAssertNil(ShellEnvironment.parseSentinel("no markers"))
        XCTAssertNil(ShellEnvironment.parseSentinel("__COUNCIL_PATH_BEGIN__ only"))
    }

    func testMergedAddsToolDirsWithoutDuplicates() {
        let home = URL(fileURLWithPath: "/Users/t")
        let merged = ShellEnvironment.merged(["/usr/bin", "/opt/homebrew/bin", "~/.local/bin"], home: home)
        XCTAssertEqual(merged.prefix(3).map { $0 }, ["/usr/bin", "/opt/homebrew/bin", "/Users/t/.local/bin"])
        XCTAssertEqual(merged.filter { $0 == "/usr/bin" }.count, 1)
        XCTAssertTrue(merged.contains("/bin"))
    }

    func testFallbackPathContainsSystemDirs() {
        let p = ShellEnvironment.fallbackPath(home: URL(fileURLWithPath: "/Users/t"))
        XCTAssertTrue(p.contains("/usr/bin"))
        XCTAssertTrue(p.contains("/Users/t/.local/bin"))
    }

    func testMemberEnvironmentStripsApiKeyAndSetsPath() {
        let env = ShellEnvironment(path: ["/a", "/b"], source: .fallback)
        let base = env.memberBaseEnvironment(from: ["ANTHROPIC_API_KEY": "sk-x", "HOME": "/Users/t", "PATH": "/old"])
        XCTAssertNil(base["ANTHROPIC_API_KEY"])
        XCTAssertEqual(base["PATH"], "/a:/b")
        XCTAssertEqual(base["HOME"], "/Users/t")
    }

    func testWhichFindsExecutables() throws {
        let env = ShellEnvironment(path: ["/nonexistent", "/bin"], source: .fallback)
        XCTAssertEqual(env.which("sh")?.path, "/bin/sh")
        XCTAssertNil(env.which("definitely-not-a-tool"))
    }

    func testResolveFromLoginShellReturnsSomething() {
        let env = ShellEnvironment.resolve(shell: "/bin/zsh", timeout: 15)
        XCTAssertFalse(env.path.isEmpty)
        XCTAssertNotNil(env.which("ls"))
    }
}
