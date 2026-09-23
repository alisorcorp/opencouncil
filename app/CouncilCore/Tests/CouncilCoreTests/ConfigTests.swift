import XCTest
@testable import CouncilCore

final class ConfigTests: XCTestCase {
    func fixture(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        return try XCTUnwrap(url, "missing fixture \(name)")
    }

    func testParsesRealCouncilToml() throws {
        let cfg = try CouncilConfig.load(from: fixture("council.toml"))
        XCTAssertEqual(cfg.chat.members, ["claude", "codex", "deepseek"])
        XCTAssertEqual(cfg.chat.budget, 12)
        XCTAssertEqual(cfg.chat.effort, "medium")
        XCTAssertEqual(cfg.defaults.moderator, "claude")
        XCTAssertEqual(cfg.defaults.rounds, 1)
        XCTAssertEqual(cfg.defaults.length, "about 300-500 words")

        let deepseek = try XCTUnwrap(cfg.members["deepseek"])
        XCTAssertEqual(deepseek.backend, .pi)
        XCTAssertEqual(deepseek.provider, "openrouter")
        XCTAssertEqual(deepseek.model, "deepseek/deepseek-v4.1-flash")
        XCTAssertEqual(deepseek.chatArgs, [])
        XCTAssertEqual(deepseek.label, "DeepSeek V4.1 Flash")

        let claude = try XCTUnwrap(cfg.members["claude"])
        XCTAssertEqual(claude.chatArgs, ["--dangerously-skip-permissions"])
        XCTAssertEqual(claude.model, "")

        // Optional Gemini member is present; commented-out blocks are not.
        XCTAssertNotNil(cfg.members["gemini"])
        XCTAssertNil(cfg.members["gemini-api"])
        XCTAssertNil(cfg.members["gemma"])
        XCTAssertEqual(cfg.memberOrder, ["claude", "claude-opus", "codex", "deepseek", "gemini"])
    }

    func testChatFallsBackToDefaults() throws {
        let cfg = try CouncilConfig.parse("""
        [defaults]
        members = ["a", "b"]
        [members.a]
        backend = "claude"
        [members.b]
        backend = "codex"
        label = "B"
        """)
        XCTAssertEqual(cfg.chat.members, ["a", "b"])
        XCTAssertEqual(cfg.chat.budget, 20, "chat.py's default, per member")
        XCTAssertEqual(cfg.chat.effort, "medium")
        XCTAssertEqual(cfg.members["a"]?.label, "a")
        XCTAssertEqual(cfg.members["b"]?.label, "B")
    }

    func testOpenAIBackendIsDecodedButUnavailable() throws {
        let cfg = try CouncilConfig.parse("""
        [members.local]
        backend = "openai"
        label = "Gemma (local)"
        base_url = "http://localhost:1234/v1"
        model = "gemma"
        [members.weird]
        backend = "carrier-pigeon"
        """)
        let local = try XCTUnwrap(cfg.members["local"])
        XCTAssertEqual(local.backend, .openai)
        XCTAssertFalse(local.isAvailable)
        let weird = try XCTUnwrap(cfg.members["weird"])
        XCTAssertNil(weird.backend)
        XCTAssertEqual(weird.backendName, "carrier-pigeon")
        XCTAssertFalse(weird.isAvailable)
    }

    func testNoMembersIsAnError() {
        XCTAssertThrowsError(try CouncilConfig.parse("[defaults]\nrounds = 2\n")) { error in
            guard case CouncilConfig.LoadError.noMembers = error else { return XCTFail("\(error)") }
        }
    }

    func testMissingFileIsAnError() {
        let url = URL(fileURLWithPath: "/nonexistent/council.toml")
        XCTAssertThrowsError(try CouncilConfig.load(from: url)) { error in
            XCTAssertEqual(error as? CouncilConfig.LoadError, .fileMissing(url))
        }
    }

    func testRootFromWrapper() {
        let text = "#!/bin/sh\nexec \"/usr/bin/python3\" \"/Users/x/Documents/AI/council/council.py\" \"$@\"\n"
        XCTAssertEqual(CouncilPaths.rootFromWrapper(text)?.path, "/Users/x/Documents/AI/council")
        let bare = "#!/bin/sh\nexec python3 /opt/council/council.py \"$@\"\n"
        XCTAssertEqual(CouncilPaths.rootFromWrapper(bare)?.path, "/opt/council")
        XCTAssertNil(CouncilPaths.rootFromWrapper("echo hi"))
    }

    func testExposesCouncilRoot() {
        let paths = CouncilPaths(root: URL(fileURLWithPath: "/Users/x/Documents/AI/council"))
        // The root itself, and anything above it, put members' tools over council.toml and council.py.
        XCTAssertTrue(paths.exposesCouncilRoot(URL(fileURLWithPath: "/Users/x/Documents/AI/council")))
        XCTAssertTrue(paths.exposesCouncilRoot(URL(fileURLWithPath: "/Users/x/Documents/AI")))
        XCTAssertTrue(paths.exposesCouncilRoot(URL(fileURLWithPath: "/Users/x")))
        XCTAssertTrue(paths.exposesCouncilRoot(URL(fileURLWithPath: "/")))
        XCTAssertTrue(paths.exposesCouncilRoot(URL(fileURLWithPath: "/Users/x/Documents/AI/council/../council")))
        // A folder beside or below the root is fine: reaching up to the config is outside the working folder.
        XCTAssertFalse(paths.exposesCouncilRoot(URL(fileURLWithPath: "/Users/x/Documents/AI/council/sub")))
        XCTAssertFalse(paths.exposesCouncilRoot(URL(fileURLWithPath: "/Users/x/Documents/AI/council-notes")))
        XCTAssertFalse(paths.exposesCouncilRoot(URL(fileURLWithPath: "/Users/x/Code/project")))
    }

    func testHoldsConfig() throws {
        let dir = try Fixtures.tempDir("holds-config")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(CouncilPaths.holdsConfig(dir), "an ordinary folder is not a council checkout")
        try Data().write(to: dir.appendingPathComponent("council.toml"))
        XCTAssertTrue(CouncilPaths.holdsConfig(dir), "a folder with a council.toml is a second checkout")
    }
}
