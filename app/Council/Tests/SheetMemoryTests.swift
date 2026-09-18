import XCTest
import CouncilCore
@testable import Council

/// Re-ticking the same three members before every chat is a small tax charged over and over, so the sheets
/// remember. What they must not do is remember their way into a sheet nobody can use: a roster changes, a CLI
/// gets uninstalled, and a remembered name that no longer resolves has to fall back to `council.toml` rather
/// than opening with nothing ticked and a disabled button.
final class SheetMemoryTests: XCTestCase {
    private var store: UserDefaults!

    /// One fixed name rather than a fresh UUID per run. `removePersistentDomain` empties a domain but leaves
    /// its now-empty plist behind, so the per-run name quietly left ten files in ~/Library/Preferences before
    /// anybody thought to look. tearDown deletes the file too, though cfprefsd usually writes the empty
    /// domain back out after the test process has gone; the fixed name is what bounds the mess at one.
    private static let suite = "council.sheetmemory.tests"

    private static var plist: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/\(suite).plist")
    }

    override func setUp() {
        super.setUp()
        store = UserDefaults(suiteName: Self.suite)
        store.removePersistentDomain(forName: Self.suite)   // a previous run's leftovers are not this run's
    }

    override func tearDown() {
        store.removePersistentDomain(forName: Self.suite)
        store = nil
        try? FileManager.default.removeItem(at: Self.plist)
        super.tearDown()
    }

    private func config(_ members: [(String, CouncilConfig.Backend?)]) -> CouncilConfig {
        var byName: [String: CouncilConfig.Member] = [:]
        for (name, backend) in members {
            byName[name] = CouncilConfig.Member(name: name, backend: backend,
                                                backendName: backend?.rawValue ?? "openai")
        }
        return CouncilConfig(defaults: .init(members: members.map(\.0)),
                             chat: .init(members: members.map(\.0)),
                             members: byName, memberOrder: members.map(\.0))
    }

    func testNothingIsRememberedUntilSomethingIsSaved() {
        XCTAssertNil(SheetMemory.load(SheetMemory.Chat.self, key: SheetMemory.chatKey, from: store))
        XCTAssertNil(SheetMemory.load(SheetMemory.Verdict.self, key: SheetMemory.verdictKey, from: store))
    }

    func testAChoiceComesBackAsItWasLeft() {
        let chat = SheetMemory.Chat(members: ["claude", "kimi"], effort: "high", budget: 30)
        SheetMemory.save(chat, key: SheetMemory.chatKey, to: store)
        XCTAssertEqual(SheetMemory.load(SheetMemory.Chat.self, key: SheetMemory.chatKey, from: store), chat)

        let verdict = SheetMemory.Verdict(members: ["claude", "codex"], moderator: "codex",
                                          rounds: 3, anonymous: true)
        SheetMemory.save(verdict, key: SheetMemory.verdictKey, to: store)
        XCTAssertEqual(SheetMemory.load(SheetMemory.Verdict.self, key: SheetMemory.verdictKey, from: store),
                       verdict)
    }

    /// The two sheets keep separate answers: a verdict roster is not a chat roster.
    func testTheChatAndTheVerdictRememberSeparately() {
        SheetMemory.save(SheetMemory.Chat(members: ["claude"], effort: "low", budget: 5),
                         key: SheetMemory.chatKey, to: store)
        XCTAssertNil(SheetMemory.load(SheetMemory.Verdict.self, key: SheetMemory.verdictKey, from: store))
    }

    func testAMemberTheRosterNoLongerOffersIsDropped() {
        let cfg = config([("claude", .claude), ("codex", .codex)])
        XCTAssertEqual(SheetMemory.stillOffered(["claude", "deepseek", "codex"], in: cfg), ["claude", "codex"])
    }

    /// `openai` members have no terminal, so the app cannot host them however they are spelled in the config.
    func testAMemberWithNoTerminalIsDropped() {
        let cfg = config([("claude", .claude), ("gemma", .openai)])
        XCTAssertEqual(SheetMemory.stillOffered(["gemma", "claude"], in: cfg), ["claude"])
    }

    /// The case that decides whether this feature is safe: everything remembered is gone. Answering with an
    /// empty list is what lets the sheet fall back instead of opening unusable.
    func testARememberedRosterThatIsEntirelyGoneAnswersEmpty() {
        let cfg = config([("claude", .claude)])
        XCTAssertTrue(SheetMemory.stillOffered(["gemini", "deepseek"], in: cfg).isEmpty)
    }
}
