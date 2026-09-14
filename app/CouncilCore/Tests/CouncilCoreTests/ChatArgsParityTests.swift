import XCTest
@testable import CouncilCore

/// What a member may do without asking is a product decision, not a detail — it decides whether a stranger's
/// first conversation can rewrite their files unprompted. It is written down in four places: the roster in
/// `council.toml`, the copy of that roster council.py writes when `council.toml` is missing,
/// `DEFAULT_CHAT_ARGS` in chat.py for the CLI, and `ChatSessionFactory.defaultChatArgs` for the app. The
/// first two only apply to members that name `chat_args`, so the last two are what a fresh install actually
/// gets, and nothing stopped any of them drifting apart.
final class ChatArgsParityTests: XCTestCase {
    /// The repo root, from this file's own path.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)      // …/app/CouncilCore/Tests/CouncilCoreTests/ChatArgsParityTests.swift
            .deletingLastPathComponent()     // CouncilCoreTests
            .deletingLastPathComponent()     // Tests
            .deletingLastPathComponent()     // CouncilCore
            .deletingLastPathComponent()     // app
            .deletingLastPathComponent()     // repo root
    }

    func testTheAppAndTheCLIAgreeOnHowAMemberStarts() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent("chat.py"), encoding: .utf8)
        let fromPython = try Self.parseDefaultChatArgs(source)
        var fromSwift: [String: [String]] = [:]
        for (backend, args) in ChatSessionFactory.defaultChatArgs { fromSwift[backend.rawValue] = args }
        XCTAssertEqual(fromPython, fromSwift,
                       "chat.py and ChatSessionFactory disagree about what a member starts with")
    }

    // MARK: what each backend does when a member reaches for something risky

    /// Flag names differ per CLI, and kimi names its the other way round to everyone else — `--yolo` still
    /// asks, `--auto` does not — so one flat list of dangerous-looking flags would either miss kimi or
    /// condemn it for the wrong one. The cases that are not `asksUnless` are the point of this type: they
    /// are findings, not gaps, and writing them down is what stops a backend that cannot ask from being
    /// waved through by a test that only knows how to look for flags.
    enum PermissionModel {
        /// The CLI asks before anything risky, and these are the flags that stop it asking.
        case asksUnless([String])
        /// The CLI has file and shell tools and no way to gate them. pi says so in its own README and
        /// recommends a container instead; council's pi extension only reports what pi already did, so a pi
        /// member cannot be made to ask and cannot be shown as waiting.
        case noGate
        /// No tools to gate. `openai` members are a plain HTTP client.
        case noTools
    }

    static let permissions: [CouncilConfig.Backend: PermissionModel] = [
        .claude: .asksUnless(["--dangerously-skip-permissions", "bypassPermissions"]),
        .codex: .asksUnless(["--yolo", "--full-auto", "--dangerously-bypass-approvals-and-sandbox",
                             "danger-full-access"]),
        .kimi: .asksUnless(["--auto"]),
        .pi: .noGate,
        .openai: .noTools,
    ]

    /// A new backend touches several lists and most of them stay quiet about it. This one does not: an
    /// unclassified backend is one nobody has asked the permission question about yet, and until somebody
    /// does, `testTheShippedRostersOnlyStartMembersThatCanAsk` has no opinion on it.
    func testEveryBackendHasARecordedPermissionModel() {
        for backend in CouncilConfig.Backend.allCases {
            XCTAssertNotNil(Self.permissions[backend],
                            "\(backend.rawValue) is not in the permission table, so nothing here knows "
                            + "whether a member on it can be made to ask")
        }
    }

    func testNoMemberStartsUnattended() {
        for (backend, args) in ChatSessionFactory.defaultChatArgs {
            guard case .asksUnless(let flags) = Self.permissions[backend] else { continue }
            let line = args.joined(separator: " ")
            for flag in flags {
                XCTAssertFalse(line.contains(flag),
                               "\(backend.rawValue) starts with \(flag), so it changes files and runs commands "
                               + "without asking anyone")
            }
        }
    }

    /// Codex has been able to search the web without asking all along — `--sandbox workspace-write -a
    /// on-request` covers its `webrun` — and Claude Code could not, so a verdict on anything factual stopped
    /// Claude on a WebSearch prompt in the critique round while codex went and checked. That is the round
    /// where a member goes back over the numbers it flagged as unverified, so it is the worst place to stall.
    /// Reading a page edits nothing and runs nothing: it is not one of the gates the README promises, and
    /// allowing it is not a hole in them.
    func testClaudeCanReadTheWebWithoutAsking() {
        let args = ChatSessionFactory.defaultChatArgs[.claude] ?? []
        guard let allowed = args.firstIndex(of: "--allowedTools") else {
            return XCTFail("claude starts with no --allowedTools, so WebSearch stops it mid-round to ask")
        }
        for tool in ["WebSearch", "WebFetch"] {
            XCTAssertTrue(args[allowed...].contains(tool), "\(tool) is not allowed, so it asks")
        }
    }

    /// The README promises that the shipped defaults ask before anything risky. A member on a backend with
    /// no gate keeps that promise only by not being in the roster: it stays defined in `council.toml`, so
    /// the app still offers it in the new-chat sheet, and ticking it is the user's decision rather than
    /// ours. Both rosters are checked because the app builds verdict runs from the same terminals and the
    /// same `chat_args` it builds chats from; only `council ask` from the terminal runs pi with `--no-tools`.
    func testTheShippedRostersOnlyStartMembersThatCanAsk() throws {
        let config = try CouncilConfig.load(from: repoRoot.appendingPathComponent("council.toml"))
        for (roster, names) in [("[chat] members", config.chat.members),
                                ("[defaults] members", config.defaults.members)] {
            for name in names {
                guard let backend = config.members[name]?.backend else {
                    XCTFail("\(roster) names \(name), which council.toml does not define")
                    continue
                }
                if case .noGate = Self.permissions[backend] {
                    XCTFail("\(roster) ships \(name) on \(backend.rawValue), which has no permission system, "
                            + "so a first conversation edits files and runs commands with no way to ask and "
                            + "no way to show that it is waiting")
                }
            }
        }
    }

    /// council.py writes `DEFAULT_CONFIG` when `council.toml` is missing, which makes it a second copy of
    /// the shipped roster. It spent a release holding `--dangerously-skip-permissions` and `--yolo` after
    /// the tracked file had moved off them, so deleting your config regenerated the posture the README says
    /// was retired. Byte equality is the cheapest way to keep one from wandering off from the other.
    func testCouncilPyShipsTheConfigItDocuments() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent("council.py"), encoding: .utf8)
        let shipped = try String(contentsOf: repoRoot.appendingPathComponent("council.toml"), encoding: .utf8)
        let opening = "DEFAULT_CONFIG = \"\"\"\\\n"
        guard let start = source.range(of: opening),
              let end = source.range(of: "\n\"\"\"", range: start.upperBound..<source.endIndex) else {
            return XCTFail("council.py has no DEFAULT_CONFIG literal in the shape this test reads")
        }
        XCTAssertEqual(String(source[start.upperBound..<end.lowerBound]) + "\n", shipped,
                       "council.py's DEFAULT_CONFIG is not the council.toml this repo ships")
    }

    /// A member that asks is only safe if the asking is visible, and the app learns about it from the
    /// `PermissionRequest` hook. Dropping that subscription would turn every question into a silent stall.
    func testEveryBackendIsSubscribedToPermissionRequests() {
        XCTAssertTrue(HookConfig.sharedHookEvents.contains("PermissionRequest"))
        XCTAssertTrue(HookConfig.kimiEvents.contains("PermissionRequest"))
    }

    // MARK: reading chat.py

    enum ParseError: Error, CustomStringConvertible {
        case notFound, empty
        var description: String {
            switch self {
            case .notFound: return "chat.py has no DEFAULT_CHAT_ARGS assignment"
            case .empty: return "DEFAULT_CHAT_ARGS parsed to nothing — the shape of the literal changed"
            }
        }
    }

    /// Reads `DEFAULT_CHAT_ARGS = { … }` out of chat.py, rather than keeping a copy of it here: a copy would
    /// be a fifth place to disagree.
    static func parseDefaultChatArgs(_ source: String) throws -> [String: [String]] {
        guard let start = source.range(of: "DEFAULT_CHAT_ARGS = {"),
              let end = source.range(of: "}", range: start.upperBound..<source.endIndex) else {
            throw ParseError.notFound
        }
        let body = String(source[start.upperBound..<end.lowerBound]) as NSString
        let re = try NSRegularExpression(pattern: "\"([a-z]+)\"\\s*:\\s*\\[([^\\]]*)\\]")
        var out: [String: [String]] = [:]
        for m in re.matches(in: body as String, range: NSRange(location: 0, length: body.length)) {
            let key = body.substring(with: m.range(at: 1))
            out[key] = body.substring(with: m.range(at: 2))
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \n\"")) }
                .filter { !$0.isEmpty }
        }
        guard !out.isEmpty else { throw ParseError.empty }
        return out
    }
}
