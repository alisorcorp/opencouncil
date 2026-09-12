import Foundation

/// Tails an append-only text file and delivers complete new lines. Built on a kqueue-backed
/// `DispatchSource`; survives atomic replacement (reopens by path) and shrinking, holds partial
/// trailing lines until the newline arrives. A rewrite that leaves the file at exactly the old size
/// within one event delivery is indistinguishable from no change; the files this tails are append-only. Creates the file if it does not exist yet, since the
/// app owns the session directory. All state is confined to `queue`.
///
/// kqueue alone is not enough to be sure of seeing everything: it is edge-triggered and only reports what
/// happens once the source is running, so a write that lands while the source is being set up produces no event
/// at all. The file is therefore read once more straight after the source starts, and a slow timer reads it
/// again periodically — the same belt and braces the CLI gets for free from its 0.3 s polling loop.
public final class FileTail: @unchecked Sendable {
    /// Complete lines, as bytes. Bytes rather than `String` because deciding what a line means — including
    /// what to do with one that is not valid UTF-8 — belongs to the reader that knows the format, and
    /// because a tail that quietly dropped such a line would disagree with a whole-file read of the same
    /// file. See `Bus.record(_:)`.
    public typealias Handler = @Sendable ([Data]) -> Void

    private let url: URL
    private let queue: DispatchQueue
    private let handler: Handler
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var retry: DispatchSourceTimer?
    private var safety: DispatchSourceTimer?
    private var offset: UInt64 = 0
    private var partial = Data()
    private var stopped = false

    public init(url: URL, queue: DispatchQueue? = nil, handler: @escaping Handler) {
        self.url = url
        self.queue = queue ?? DispatchQueue(label: "council.filetail.\(url.lastPathComponent)", qos: .utility)
        self.handler = handler
    }

    deinit { stopNow() }

    /// Starts watching. With `replayExisting`, current contents are delivered first; otherwise only new lines.
    public func start(replayExisting: Bool = true) {
        queue.async { [self] in
            stopped = false
            open(replay: replayExisting)
        }
    }

    public func stop() {
        queue.async { [self] in stopNow() }
    }

    /// Reads whatever is new right now. Useful after an external write when you don't want to wait for kqueue.
    public func poll() {
        queue.async { [self] in readNew() }
    }

    /// How often the file is read even when kqueue has said nothing.
    public static let safetyInterval: TimeInterval = 2

    private func stopNow() {
        stopped = true
        safety?.cancel(); safety = nil
        retry?.cancel(); retry = nil
        source?.cancel(); source = nil
        fd = -1
    }

    private func open(replay: Bool) {
        guard !stopped else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { scheduleReopen(); return }
        fd = descriptor
        offset = 0
        partial = Data()
        if replay { readNew() } else { offset = currentSize() }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
                                                            queue: queue)
        src.setEventHandler { [weak self] in self?.handleEvent() }
        src.setCancelHandler { Darwin.close(descriptor) }
        source = src
        src.resume()
        // Anything written while the source was being set up produced no event: read it now.
        readNew()
        startSafetyTimer()
    }

    /// A missed event would otherwise hold a member's reply until the next write came along.
    private func startSafetyTimer() {
        safety?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.safetyInterval, repeating: Self.safetyInterval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.readNew() }
        safety = t
        t.resume()
    }

    private func handleEvent() {
        guard let src = source else { return }
        let flags = src.data
        if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
            // The inode we watched is gone; whatever appears at the path next is new content.
            src.cancel(); source = nil; fd = -1
            scheduleReopen()
            return
        }
        readNew()
    }

    private func scheduleReopen() {
        guard !stopped else { return }
        retry?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.3)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.retry = nil
            self.open(replay: true)
        }
        retry = t
        t.resume()
    }

    private func currentSize() -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    private func readNew() {
        guard !stopped, let fh = FileHandle(forReadingAtPath: url.path) else { return }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial = Data() }          // truncated or rewritten shorter
        guard size > offset else { return }
        do { try fh.seek(toOffset: offset) } catch { return }
        let chunk = fh.readData(ofLength: Int(size - offset))
        offset = size
        var buffer = partial
        buffer.append(chunk)
        var lines: [Data] = []
        var start = buffer.startIndex
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            let line = buffer[start..<nl]
            if !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { lines.append(Data(line)) }
            start = buffer.index(after: nl)
        }
        partial = Data(buffer[start...])
        if !lines.isEmpty { handler(lines) }
    }
}

/// A `FileTail` over `chat.jsonl` that decodes lines into `Message`s.
public final class BusTail: @unchecked Sendable {
    private let tail: FileTail

    public init(bus: Bus, queue: DispatchQueue? = nil, handler: @escaping @Sendable ([Message]) -> Void) {
        // The same policy the whole-file read uses, so that what arrives live and what is there on reopening
        // are the same messages — a damaged record included.
        tail = FileTail(url: bus.logURL, queue: queue) { lines in
            let msgs = lines.compactMap(Bus.record)
            if !msgs.isEmpty { handler(msgs) }
        }
    }

    public func start(replayExisting: Bool = true) { tail.start(replayExisting: replayExisting) }
    public func stop() { tail.stop() }
    public func poll() { tail.poll() }
}
