import Foundation
import Observation
import CouncilCore

/// The Sessions list: scans `chats/` and `runs/`, keeps unread counts, and re-scans when the directories
/// change or on a slow timer (message activity inside a directory does not fire the directory watcher).
@Observable
@MainActor
final class SessionsModel {
    let paths: CouncilPaths
    private(set) var sessions: [SessionSummary] = []
    private(set) var unread: [String: Int] = [:]
    var selectedID: String?

    private let store: SessionStore
    private var watchers: [DirectoryWatcher] = []
    private var refreshTask: Task<Void, Never>?
    private var refreshing = false
    /// A session just created from a sheet that should start as soon as its view exists.
    private var autoStart: String?

    init(paths: CouncilPaths) {
        self.paths = paths
        self.store = SessionStore(paths: paths)
    }

    func start() {
        guard watchers.isEmpty else { return }
        for dir in [paths.chats, paths.runs] {
            let w = DirectoryWatcher(url: dir) { [weak self] in
                Task { @MainActor in await self?.refresh() }
            }
            w.start()
            watchers.append(w)
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stop() {
        watchers.forEach { $0.stop() }
        watchers = []
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        if refreshing { return }
        refreshing = true
        defer { refreshing = false }
        let store = self.store
        let result = await Task.detached(priority: .utility) { () -> ([SessionSummary], [String: Int]) in
            let list = store.scan()
            var counts: [String: Int] = [:]
            for s in list where s.kind == .chat {
                let msgs = (try? Bus(directory: s.directory).readAll()) ?? []
                counts[s.id] = SessionAppState.load(from: s.directory).unreadCount(in: msgs)
            }
            return (list, counts)
        }.value
        sessions = result.0
        unread = result.1
        if let sel = selectedID, !sessions.contains(where: { $0.id == sel }) { selectedID = nil }
    }

    func summary(for id: String?) -> SessionSummary? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    func markRead(_ id: String) { unread[id] = 0 }

    /// Where the last chat was working, as the default for the next one.
    var lastUsedFolder: URL? {
        sessions.first { $0.kind == .chat && $0.cwd != nil }.flatMap { $0.cwd.map { URL(fileURLWithPath: $0) } }
    }

    /// Rescans and selects a session that was just created — a chat or a run — so the user lands in it.
    ///
    /// It waits for the scan to actually list it rather than refreshing once: the directory watcher fires on
    /// the new folder too, and `refresh` skips a scan while one is already running, so a single await could
    /// return before the session exists and leave the detail pane on "No session selected".
    func select(newSessionAt directory: URL, startImmediately: Bool = false) async {
        let id = directory.lastPathComponent
        if startImmediately { autoStart = id }
        for _ in 0..<40 {
            await refresh()
            if sessions.contains(where: { $0.id == id }) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        selectedID = id
    }

    /// True once, for a session created with `startImmediately`: the view asks as soon as it opens it.
    func takeAutoStart(for id: String) -> Bool {
        guard autoStart == id else { return false }
        autoStart = nil
        return true
    }

    /// Moves a session's whole folder to the Trash, stopping its members first. Returns a message when it
    /// could not be done. The Trash rather than an unlink: a chat is the only copy of its own transcript.
    @discardableResult
    func delete(_ session: SessionSummary, live: LiveSessions?) async -> String? {
        live?.stop(session.id)
        do {
            try FileManager.default.trashItem(at: session.directory, resultingItemURL: nil)
        } catch {
            return error.localizedDescription
        }
        if session.kind == .chat { repointCurrent(after: session.directory) }
        if selectedID == session.id { selectedID = nil }
        await refresh()
        return nil
    }

    /// Renames a chat. The directory is renamed too, not just the title: `council session <name>` finds a chat
    /// by the slug in its directory name, so a title-only rename would leave the CLI unable to find it under
    /// the new name — and a resume under the old one would quietly write the old title back.
    ///
    /// Returns a message when it could not be done. Refused while members are running: their runtime holds the
    /// old path.
    @discardableResult
    func rename(_ session: SessionSummary, to newTitle: String, live: LiveSessions?) async -> String? {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "A chat needs a name." }
        guard session.kind == .chat else { return "A verdict run is named by its question." }
        guard live?.runtime(for: session.id) == nil else {
            return "Stop this chat's members before renaming it."
        }
        guard title != session.title else { return nil }

        // `YYYY-MM-DD_HHMMSS_slug`, as both tools name a chat directory.
        let name = session.directory.lastPathComponent
        guard name.count > 18 else { return "This chat's folder is not named the way the CLI names one." }
        let stamp = String(name.prefix(17))
        let target = paths.chats.appendingPathComponent("\(stamp)_\(ChatSessionFactory.slugify(title, 24))")
        let fm = FileManager.default
        if target != session.directory, fm.fileExists(atPath: target.path) {
            return "A chat folder called “\(target.lastPathComponent)” already exists."
        }

        // The title goes in first so a failed move leaves nothing renamed; the JSON is edited key by key
        // because `config.json` is the CLI's file and carries member fields the app does not model.
        let configURL = session.directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "Could not read \(configURL.lastPathComponent)."
        }
        let previous = json["title"]
        json["title"] = title
        func write(_ object: [String: Any]) throws {
            let out = try JSONSerialization.data(withJSONObject: object,
                                                 options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try out.write(to: configURL, options: .atomic)
        }
        do { try write(json) } catch { return error.localizedDescription }

        if target != session.directory {
            do {
                try fm.moveItem(at: session.directory, to: target)
            } catch {
                json["title"] = previous
                try? write(json)
                return error.localizedDescription
            }
            repointCurrent(from: session.directory, to: target)
            if selectedID == session.id { selectedID = target.lastPathComponent }
            unread[target.lastPathComponent] = unread.removeValue(forKey: session.id)
        }
        await refresh()
        return nil
    }

    /// `chats/current` is how `council post` and `council log` find a chat with no `--chat`. When the deleted
    /// chat was the current one the link is moved to the newest chat left, or removed when none is.
    private func repointCurrent(after removed: URL) {
        let link = paths.chats.appendingPathComponent("current")
        let fm = FileManager.default
        guard currentLinkPoints(at: removed) else { return }
        try? fm.removeItem(at: link)
        let next = sessions.first { $0.kind == .chat && $0.id != removed.lastPathComponent }
        if let next { try? fm.createSymbolicLink(at: link, withDestinationURL: next.directory) }
    }

    /// A renamed chat keeps `chats/current` if it held it; the link would otherwise dangle.
    private func repointCurrent(from old: URL, to new: URL) {
        guard currentLinkPoints(at: old) else { return }
        let link = paths.chats.appendingPathComponent("current")
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: new)
    }

    /// Every chat is a direct child of `chats/`, so the folder name is the whole comparison. Comparing paths
    /// does not work: `standardizedFileURL` resolves `/var` to `/private/var` only while the path still
    /// exists, so after the move the two sides stop matching.
    private func currentLinkPoints(at directory: URL) -> Bool {
        let link = paths.chats.appendingPathComponent("current")
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return false }
        return URL(fileURLWithPath: target).lastPathComponent == directory.lastPathComponent
    }
}
