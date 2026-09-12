import XCTest
import CouncilCore
@testable import Council

/// Typing into a chat that was live when the app closed must resume it, not start it over.
///
/// The banner above the composer offers "Resume members", and the CLI sessions it resumes are the whole point:
/// each member keeps the context it had. But sending a message also starts a chat that is not running, and that
/// path asked for a fresh start — so a user who answered the question in the box instead of pressing the button
/// silently lost every member's session. It is invisible while it happens: the members reconnect, say hello and
/// answer, having read the log back with `council log`. The evidence is in the hook records, where every member
/// reports a new session id with `source=startup`.
///
/// Nothing launches here. The tools are absent from `ToolLocations`, so every member fails with "tool missing"
/// after the runtime has already written the note that says which way it started.
final class ResumeOnSendTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("council-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chats"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A chat with two members. `wasLive` is written only when the caller asks for it.
    @discardableResult
    private func makeChat(wasLive: Bool) throws -> URL {
        let dir = root.appendingPathComponent("chats/2026-01-01_000000_a-chat")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "created": "2026-01-01T00:00:00", "title": "a chat", "cwd": root.path,
            "order": ["claude", "codex"], "budget": 20,
            "members": ["claude": ["name": "claude", "backend": "claude", "label": "Claude"],
                        "codex": ["name": "codex", "backend": "codex", "label": "Codex"]],
        ]
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("config.json"))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("chat.jsonl").path, contents: Data())
        if wasLive {
            let state: [String: Any] = ["live": true,
                                        "sessionIds": ["claude": "69ab278f", "codex": "01a0940a"]]
            try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
                .write(to: dir.appendingPathComponent("app.json"))
        }
        return dir
    }

    @MainActor
    private func viewModel() throws -> SessionViewModel {
        let paths = CouncilPaths(root: root)
        let summary = try XCTUnwrap(SessionStore(paths: paths).scan().first, "no session was scanned")
        // No executables: every launch fails, and it fails after the runtime has said how it started.
        let environment = MemberLaunchEnvironment(tools: ToolLocations(), baseEnvironment: [:],
                                                  piExtension: nil, isFake: false)
        let vm = SessionViewModel(summary: summary, live: LiveSessions(launchEnvironment: environment), paths: paths)
        vm.open()          // as selecting the session does; without it the chat's config is never loaded
        addTeardownBlock { Task { @MainActor in vm.close() } }
        return vm
    }

    private func notes(in dir: URL) throws -> [String] {
        try Bus(directory: dir).readAll().filter(\.isNote).map(\.text)
    }

    @MainActor
    func testSendingToAChatThatWasLiveResumesIt() throws {
        let dir = try makeChat(wasLive: true)
        let vm = try viewModel()
        XCTAssertTrue(vm.wasLive, "the fixture is meant to be a chat that was live when the app closed")

        vm.send("what did we decide about the monitor?")

        let notes = try notes(in: dir)
        XCTAssertTrue(notes.contains { $0.hasPrefix("chat resumed") },
                      "sending started the members fresh, throwing away the sessions app.json recorded: \(notes)")
        let texts = try Bus(directory: dir).readAll().map(\.text)
        XCTAssertTrue(texts.contains("what did we decide about the monitor?"),
                      "the message itself must reach the log whatever happened to the members")
    }

    @MainActor
    func testSendingToAChatThatWasNeverLiveStartsFresh() throws {
        let dir = try makeChat(wasLive: false)
        let vm = try viewModel()
        XCTAssertFalse(vm.wasLive, "nothing has ever run in this chat")

        vm.send("hello")

        XCTAssertFalse(try notes(in: dir).contains { $0.hasPrefix("chat resumed") },
                       "there was no session to resume, so the chat must not claim it resumed one")
    }
}
