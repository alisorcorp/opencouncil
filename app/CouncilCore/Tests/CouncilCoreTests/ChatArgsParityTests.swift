import XCTest
@testable import CouncilCore

/// What a member may do without asking is a product decision, not a detail — it decides whether a stranger's
/// first conversation can rewrite their files unprompted. It is written down in three places: the roster in
/// `council.toml`, `DEFAULT_CHAT_ARGS` in chat.py for the CLI, and `ChatSessionFactory.defaultChatArgs` for
/// the app. The first only applies to members that name `chat_args`, so the other two are what a fresh
/// install actually gets, and nothing stopped them drifting apart.
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

    /// Each CLI's own way of saying "stop asking me". kimi names these the other way round to everyone else —
    /// its `--yolo` is the mode that still asks about anything risky, and `--auto` is the unattended one — so
    /// a single list of flag names would either miss kimi or condemn it for the wrong flag.
    private static let unattended: [CouncilConfig.Backend: [String]] = [
        .claude: ["--dangerously-skip-permissions", "bypassPermissions"],
        .codex: ["--yolo", "--full-auto", "--dangerously-bypass-approvals-and-sandbox", "danger-full-access"],
        .kimi: ["--auto"],
    ]

    func testNoMemberStartsUnattended() {
        for (backend, args) in ChatSessionFactory.defaultChatArgs {
            let line = args.joined(separator: " ")
            for flag in Self.unattended[backend] ?? [] {
                XCTAssertFalse(line.contains(flag),
                               "\(backend.rawValue) starts with \(flag), so it changes files and runs commands "
                               + "without asking anyone")
            }
        }
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
    /// be a fourth place to disagree.
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
