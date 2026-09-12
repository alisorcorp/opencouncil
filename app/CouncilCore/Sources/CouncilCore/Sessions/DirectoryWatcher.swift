import Foundation

/// Fires when entries are added to or removed from a directory (kqueue `.write` on the directory fd).
/// Used for `chats/` and `runs/` so the sessions list refreshes when the CLI creates something.
public final class DirectoryWatcher: @unchecked Sendable {
    private let url: URL
    private let queue: DispatchQueue
    private let handler: @Sendable () -> Void
    private var source: DispatchSourceFileSystemObject?

    public init(url: URL, queue: DispatchQueue? = nil, handler: @escaping @Sendable () -> Void) {
        self.url = url
        self.queue = queue ?? DispatchQueue(label: "council.dirwatch.\(url.lastPathComponent)", qos: .utility)
        self.handler = handler
    }

    deinit { source?.cancel() }

    public func start() {
        queue.async { [self] in
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let fd = Darwin.open(url.path, O_EVTONLY)
            guard fd >= 0 else { return }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
            src.setEventHandler { [weak self] in self?.handler() }
            src.setCancelHandler { Darwin.close(fd) }
            source = src
            src.resume()
        }
    }

    public func stop() {
        queue.async { [self] in source?.cancel(); source = nil }
    }
}
