import Foundation

/// Tails `events.jsonl` in a session directory and delivers normalised events per member, in file order.
public final class EventTail: @unchecked Sendable {
    public static let fileName = "events.jsonl"
    private let tail: FileTail

    public init(directory: URL, queue: DispatchQueue? = nil,
                handler: @escaping @Sendable (_ member: String, _ raw: RawEvent, _ events: [MemberEvent]) -> Void) {
        tail = FileTail(url: directory.appendingPathComponent(EventTail.fileName), queue: queue) { lines in
            for line in lines {
                guard let text = String(data: line, encoding: .utf8),
                      let raw = RawEvent.decode(line: text) else { continue }
                let events = EventNormalizer.normalize(raw)
                handler(raw.member, raw, events)
            }
        }
    }

    public func start(replayExisting: Bool = false) { tail.start(replayExisting: replayExisting) }
    public func stop() { tail.stop() }
    public func poll() { tail.poll() }
}
