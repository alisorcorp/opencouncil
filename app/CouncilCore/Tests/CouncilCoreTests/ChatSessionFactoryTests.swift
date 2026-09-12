import XCTest
@testable import CouncilCore

/// A chat the app creates has to be one the CLI can open: same directory name, same `config.json` keys, same
/// baked-in launch arguments. The interop test at the end proves it with the real `council` command.
final class ChatSessionFactoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try Fixtures.tempDir("factory")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chats"), withIntermediateDirectories: true)
        try "".write(to: root.appendingPathComponent("council.toml"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("council.py"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func factory(effort: String = "medium") throws -> ChatSessionFactory {
        let toml = """
        [chat]
        members = ["claude", "codex", "deepseek"]
        budget = 9
        effort = "\(effort)"

        [members.claude]
        backend = "claude"
        label = "Claude Fable 5.1"

        [members.codex]
        backend = "codex"
        label = "Codex GPT-6 Astra"

        [members.deepseek]
        backend = "pi"
        label = "DeepSeek V4.1 Flash"
        provider = "openrouter"
        model = "deepseek/deepseek-v4.1-flash"

        [members.gemini]
        backend = "openai"
        label = "Gemini"
        """
        return ChatSessionFactory(paths: CouncilPaths(root: root), config: try CouncilConfig.parse(toml))
    }

    private func create(_ f: ChatSessionFactory, title: String = "Router design",
                        members: [String] = ["claude", "codex", "deepseek"]) throws -> URL {
        try f.create(title: title, members: members, cwd: root,
                     now: DateComponents(calendar: .current, timeZone: .current, year: 2026, month: 9, day: 10,
                                         hour: 22, minute: 30, second: 0).date!)
    }

    // MARK: layout

    func testTheDirectoryIsNamedTheWayTheCLINamesIt() throws {
        let dir = try create(try factory())
        XCTAssertEqual(dir.lastPathComponent, "2026-09-10_223000_router-design")
        XCTAssertEqual(dir.deletingLastPathComponent().lastPathComponent, "chats")
    }

    func testTheChatHasTheFilesTheCLIExpects() throws {
        let dir = try create(try factory())
        for path in ["config.json", "chat.jsonl", "inbox", "status"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path), path)
        }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("chat.jsonl")).count, 0)
    }

    func testCurrentPointsAtTheNewChat() throws {
        let f = try factory()
        _ = try create(f, title: "First")
        let second = try f.create(title: "Second", members: ["claude"], cwd: root)
        let link = root.appendingPathComponent("chats/current")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), second.path)
    }

    // MARK: config.json

    func testConfigCarriesTheChatSettingsAndMemberOrder() throws {
        let config = try ChatConfig.load(from: try create(try factory()))
        XCTAssertEqual(config.order, ["claude", "codex", "deepseek"])
        XCTAssertEqual(config.budget, 9)
        XCTAssertEqual(config.effort, "medium")
        XCTAssertEqual(config.cwd, root.path)
        XCTAssertEqual(config.title, "Router design")
        XCTAssertEqual(config.created, "2026-09-10T22:30:00")
    }

    func testLaunchArgumentsAreBakedInPerBackend() throws {
        let config = try ChatConfig.load(from: try create(try factory()))
        XCTAssertEqual(config.members["claude"]?.chatArgs,
                       ["--permission-mode", "acceptEdits", "--allow-dangerously-skip-permissions",
                        "--effort", "medium"])
        XCTAssertEqual(config.members["codex"]?.chatArgs,
                       ["--sandbox", "workspace-write", "-a", "on-request", "-c", "model_reasoning_effort=\"medium\""])
        XCTAssertEqual(config.members["deepseek"]?.chatArgs,
                       ["--provider", "openrouter", "--model", "deepseek/deepseek-v4.1-flash",
                        "--no-session", "--offline", "--thinking", "medium"])
    }

    func testTheEffortIsAppendedToLabelsAsTheCLIDoes() throws {
        let config = try ChatConfig.load(from: try create(try factory(effort: "high")))
        XCTAssertEqual(config.members["claude"]?.label, "Claude Fable 5.1 · high")
        XCTAssertEqual(ChatConfig.splitEffortSuffix(config.members["claude"]!.label!).effort, "high")
    }

    func testDefaultEffortLeavesTheLabelsAndArgumentsAlone() throws {
        let config = try ChatConfig.load(from: try create(try factory(effort: "default")))
        XCTAssertEqual(config.members["claude"]?.label, "Claude Fable 5.1")
        XCTAssertEqual(config.members["claude"]?.chatArgs,
                       ["--permission-mode", "acceptEdits", "--allow-dangerously-skip-permissions"])
    }

    func testEveryMemberInTheNewChatCanActuallyBeLaunched() throws {
        let config = try ChatConfig.load(from: try create(try factory()))
        for name in config.order {
            XCTAssertNotNil(MemberLaunchSpec(name: name, member: config.members[name]!), name)
        }
    }

    // MARK: refusals

    func testMembersWithoutATerminalAreRefused() throws {
        XCTAssertThrowsError(try factory().create(title: "t", members: ["gemini"], cwd: root)) {
            XCTAssertEqual($0 as? ChatSessionFactory.CreateError, .unavailable("gemini"))
        }
    }

    func testUnknownMembersEmptyRostersAndMissingFoldersAreRefused() throws {
        let f = try factory()
        XCTAssertThrowsError(try f.create(title: "t", members: ["nobody"], cwd: root)) {
            XCTAssertEqual($0 as? ChatSessionFactory.CreateError, .unknownMember("nobody"))
        }
        XCTAssertThrowsError(try f.create(title: "t", members: [], cwd: root)) {
            XCTAssertEqual($0 as? ChatSessionFactory.CreateError, .noMembers)
        }
        let missing = root.appendingPathComponent("nope")
        XCTAssertThrowsError(try f.create(title: "t", members: ["claude"], cwd: missing)) {
            XCTAssertEqual($0 as? ChatSessionFactory.CreateError, .folderMissing(missing))
        }
    }

    func testASecondChatWithTheSameTitleInTheSameSecondIsRefusedRatherThanOverwriting() throws {
        let f = try factory()
        _ = try create(f)
        XCTAssertThrowsError(try create(f))
    }

    // MARK: slugs

    func testSlugsMatchThePythonRules() {
        XCTAssertEqual(ChatSessionFactory.slugify("Router design"), "router-design")
        XCTAssertEqual(ChatSessionFactory.slugify("Is it worth adding type hints to a 5k line app?", 24),
                       "is-it-worth-adding-type")
        XCTAssertEqual(ChatSessionFactory.slugify("  ¡Hola!  "), "hola")
        XCTAssertEqual(ChatSessionFactory.slugify(""), "question")
        XCTAssertEqual(ChatSessionFactory.slugify("---"), "question")
    }

    // MARK: interop

    /// The CLI has to accept a chat the app made: `council log` reads it and `council post` appends to it.
    func testTheCLIAcceptsAChatTheAppCreated() throws {
        guard let cli = Fixtures.councilCLI else { throw XCTSkip("council CLI not installed") }
        let dir = try create(try factory())
        var env = ProcessInfo.processInfo.environment
        env["COUNCIL_CHAT"] = dir.path
        env.removeValue(forKey: "COUNCIL_AS")

        let post = Process()
        post.executableURL = cli
        post.arguments = ["post", "--chat", dir.path, "--as", "claude", "hello from the app"]
        post.environment = env
        post.standardOutput = FileHandle.nullDevice
        post.standardError = FileHandle.nullDevice
        try post.run()
        post.waitUntilExit()
        XCTAssertEqual(post.terminationStatus, 0, "council post refused the app's chat")

        let log = Process()
        log.executableURL = cli
        log.arguments = ["log", "--chat", dir.path]
        log.environment = env
        let pipe = Pipe()
        log.standardOutput = pipe
        log.standardError = FileHandle.nullDevice
        try log.run()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        log.waitUntilExit()
        XCTAssertEqual(log.terminationStatus, 0)
        XCTAssertTrue(out.contains("hello from the app"), out)
    }
}
