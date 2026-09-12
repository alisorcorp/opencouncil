import Foundation

/// A run directory as a value: council.py's `Run` class, plus the writes the CLI does from `cmd_member` and
/// `cmd_moderate`. Everything the app produces here is read back by `council runs`, `council show` and a
/// resumed `council ask`, so the file names, the JSON and the transcript wording are the Python's (R20).
public struct VerdictRun: Sendable, Equatable {
    public let directory: URL
    public let config: RunConfig

    public init(directory: URL, config: RunConfig) {
        self.directory = directory.standardizedFileURL
        self.config = config
    }

    public init(directory: URL) throws {
        self.init(directory: directory, config: try RunConfig.load(from: directory))
    }

    public var rounds: Int { max(config.rounds, 1) }
    public var order: [String] { config.order }
    public var anonymous: Bool { config.anonymous }
    public var length: String { config.length ?? "about 300-500 words" }
    public var moderatorName: String { config.moderator.name ?? "moderator" }
    public var moderatorLabel: String { config.moderator.label ?? moderatorName }

    public var question: String {
        (try? String(contentsOf: directory.appendingPathComponent("question.md"), encoding: .utf8)) ?? ""
    }

    /// The name a member is shown under while the run is in progress: its alias in an anonymous run.
    public func display(_ name: String) -> String {
        anonymous ? (config.members[name]?.alias ?? label(name)) : label(name)
    }

    /// The member's real label, which the user always sees even when the models do not.
    public func label(_ name: String) -> String { config.members[name]?.label ?? name }

    public func answerURL(_ name: String, round: Int) -> URL { config.answerURL(name, round: round, in: directory) }
    public func doneURL(_ name: String, round: Int) -> URL { config.doneURL(name, round: round, in: directory) }

    public func answer(_ name: String, round: Int) -> String {
        (try? String(contentsOf: answerURL(name, round: round), encoding: .utf8)) ?? ""
    }

    public func done(_ name: String, round: Int) -> RunDone? { RunDone.load(doneURL(name, round: round)) }

    public var verdict: String? {
        try? String(contentsOf: directory.appendingPathComponent("verdict.md"), encoding: .utf8)
    }

    // MARK: writes

    /// One member's round, as `cmd_member` writes it: the answer, then the `.done` record that makes it final.
    /// The order matters — a reader that sees `.done` must already be able to read the answer beside it.
    public func record(_ name: String, round: Int, answer: String, done: RunDone) throws {
        let dir = directory.appendingPathComponent("r\(round)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try answer.write(to: answerURL(name, round: round), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(done).write(to: doneURL(name, round: round), options: .atomic)
    }

    /// `verdict.md`, with the reveal footer an anonymous run ends with so the CLI's `council show` can name
    /// who was who after the fact.
    public func writeVerdict(_ text: String) throws {
        var out = text.rstripped() + "\n"
        if anonymous {
            var footer = ["\n## Reveal\n"]
            for m in order { footer.append("- \(config.members[m]?.alias ?? m) = \(label(m))") }
            out += footer.joined(separator: "\n") + "\n"
        }
        try out.write(to: directory.appendingPathComponent("verdict.md"), atomically: true, encoding: .utf8)
    }

    /// council.py `write_transcript`: the whole run as one Markdown file, the only artefact that carries both
    /// the anonymous aliases and the real labels.
    public func writeTranscript(verdict: String) throws {
        var lines = ["# Council transcript", "",
                     "- created: \(config.created)",
                     "- members: \(order.map(label).joined(separator: ", "))",
                     "- moderator: \(moderatorLabel)",
                     "- rounds: \(rounds)" + (anonymous ? " · anonymous" : ""), "",
                     "# Question", "", question.rstripped(), ""]
        for r in 1...rounds {
            lines += ["# Round \(r)", ""]
            for m in order {
                let d = done(m, round: r)
                let title = label(m) + (anonymous ? " (as \(config.members[m]?.alias ?? m))" : "")
                var meta = "no result"
                if let d {
                    meta = "\(VerdictRun.formatSeconds(d.elapsed ?? 0)) · \(d.words ?? 0) words"
                    // The CLI interpolates a missing error as "None"; matched so a transcript reads the same
                    // whichever tool wrote it. Nothing the app writes takes that branch: it always has a reason.
                    if !d.isOK { meta += " · FAILED: \(d.error ?? "None")" }
                }
                let body = answer(m, round: r).rstripped()
                lines += ["## \(title)", "", "_\(meta)_", "", body.isEmpty ? "(no answer)" : body, ""]
            }
        }
        let v = verdict.rstripped()
        lines += ["# Verdict", "", v.isEmpty ? "(none)" : v, ""]
        try lines.joined(separator: "\n").write(to: directory.appendingPathComponent("transcript.md"),
                                                atomically: true, encoding: .utf8)
    }

    // MARK: formatting (council.py)

    /// `fmt_secs`: seconds under 100, then minutes to one decimal.
    public static func formatSeconds(_ s: Double) -> String {
        s < 100 ? String(format: "%.0fs", s) : String(format: "%.1fm", s / 60)
    }

    /// Python's `len(text.split())`: runs of any whitespace, empties dropped.
    public static func words(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

extension String {
    /// Python's `str.rstrip()`.
    func rstripped() -> String {
        var s = Substring(self)
        while let last = s.last, last.isWhitespace || last.isNewline { s.removeLast() }
        return String(s)
    }
}
