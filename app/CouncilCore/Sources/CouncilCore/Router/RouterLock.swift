import Foundation
import Darwin

/// `router.lock` in a chat directory: whoever holds it is the one delivering messages to that chat's members.
/// Two routers on one chat would paste into the same terminals and double every reply, so the app takes the
/// lock when a chat goes live and `chat.py` refuses to start a router while it is held (and the other way round).
/// A lock whose process is gone is stale and can be taken over; one from another machine is not touched.
public struct RouterLock: Sendable {
    public struct Holder: Codable, Sendable, Equatable {
        public var pid: Int32
        public var host: String
        /// "app" or "cli".
        public var owner: String
        public var since: String

        public init(pid: Int32, host: String, owner: String, since: String) {
            self.pid = pid; self.host = host; self.owner = owner; self.since = since
        }

        /// Whether the process named here still exists. Only meaningful on the machine that wrote it.
        public var isAlive: Bool {
            guard host == RouterLock.hostName else { return true }   // another machine: assume it is running
            if pid <= 0 { return false }
            if kill(pid, 0) == 0 { return true }
            return errno == EPERM      // alive but owned by someone else
        }

        public var description: String {
            let who = owner == "cli" ? "the council CLI" : "Open Council"
            return "\(who) (pid \(pid)\(host == RouterLock.hostName ? "" : " on \(host)"))"
        }
    }

    public enum LockError: Error, LocalizedError {
        case held(Holder)

        public var errorDescription: String? {
            switch self {
            case .held(let h): return "This chat is already being routed by \(h.description). Stop it there first."
            }
        }
    }

    public let url: URL
    public let owner: String

    public init(directory: URL, owner: String = "app") {
        self.url = directory.appendingPathComponent("router.lock")
        self.owner = owner
    }

    nonisolated(unsafe) static let hostName = ProcessInfo.processInfo.hostName

    /// Who holds the lock, if anyone. A file that cannot be parsed is treated as no lock.
    public func holder() -> Holder? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Holder.self, from: data)
    }

    /// Takes the lock. Throws `.held` when someone else's router is still running; takes over a stale lock.
    /// `force` takes over a live lock, which the user has to ask for explicitly.
    @discardableResult
    public func acquire(force: Bool = false, now: Date = Date()) throws -> Holder {
        let guardFD = try openGuard()
        defer { flock(guardFD, LOCK_UN); close(guardFD) }
        if let current = holder(), current.isAlive, !force,
           !(current.pid == ProcessInfo.processInfo.processIdentifier && current.host == Self.hostName) {
            throw LockError.held(current)
        }
        let mine = Holder(pid: ProcessInfo.processInfo.processIdentifier, host: Self.hostName, owner: owner,
                          since: MessageTime.format(now))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(mine).write(to: url, options: .atomic)
        return mine
    }

    /// Releases the lock, but only if this process still holds it (never removes someone else's).
    public func release() {
        guard let guardFD = try? openGuard() else { return }
        defer { flock(guardFD, LOCK_UN); close(guardFD) }
        guard let current = holder() else { return }
        guard current.pid == ProcessInfo.processInfo.processIdentifier, current.host == Self.hostName else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// One critical section around the read/check/write, shared with chat.py's `router_guard` and anything else
    /// that routes a chat: without it, two routers starting together could both read "no lock" and both write
    /// themselves in. The guard is a separate file because `router.lock` is replaced atomically on every write,
    /// so a lock taken on it would be on an inode the next writer has already swapped out.
    private func openGuard() throws -> Int32 {
        let path = url.deletingLastPathComponent().appendingPathComponent("router.guard").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(fd, LOCK_EX) == 0 else {
            let code = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return fd
    }
}
