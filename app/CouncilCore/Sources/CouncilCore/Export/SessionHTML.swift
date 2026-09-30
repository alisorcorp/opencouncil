import Foundation

/// A session as one self-contained HTML page: every message of a chat, or a verdict run's question, rounds and
/// verdict. No scripts and no network: the page is its own record and opens anywhere. Message bodies go through
/// `MarkdownHTML`, and links follow the app's rules — web links open, paths become `file:` links when there is
/// a file there, mentions are styled like the app's chips, anything else stays text.
public enum SessionHTML {
    public struct Style: Sendable {
        /// Member colours as `#RRGGBB`, by position in the roster, as the app assigns them.
        public var palette: [String]
        public var accentLight: String
        public var accentDark: String
        public init(palette: [String], accentLight: String, accentDark: String) {
            self.palette = palette; self.accentLight = accentLight; self.accentDark = accentDark
        }
    }

    public typealias FileExists = (String) -> Bool

    // MARK: chat

    public static func chat(title: String, config: ChatConfig?, messages: [Message], style: Style, folder: URL?,
                            exportedAt: Date, prepare: (String) -> String = { $0 },
                            fileExists: @escaping FileExists = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let links = linkTags(folder: folder, fileExists: fileExists)
        let order = config?.order ?? []
        var body = ""
        var lastDay: String?
        for m in messages {
            if let d = m.date {
                let day = dayFormatter.string(from: d)
                if day != lastDay { body += "<div class=\"day\">\(esc(day))</div>\n"; lastDay = day }
            }
            if m.isNote {
                body += "<div class=\"note\">\(esc(m.text))</div>\n"
                continue
            }
            let label = m.isFromUser ? "You"
                : m.isFromSystem ? "Council"
                : (config?.members[m.sender]?.label ?? m.sender)
            let color = m.isFromUser || m.isFromSystem ? nil : colour(for: m.sender, in: order, style: style)
            let content = m.isUnreadable
                ? "<p>\(esc(m.text))</p>"
                : MarkdownHTML.render(prepare(m.text), link: links)
            body += article(label: label, time: String(m.clock.prefix(5)), color: color,
                            classes: (m.isFromUser ? ["you"] : []) + (m.isUnreadable ? ["unreadable"] : []),
                            content: content)
        }
        var meta: [String] = []
        if let config {
            if let started = MessageTime.parse(config.created) { meta.append("Started \(stampFormatter.string(from: started))") }
            let names = config.order.map { config.members[$0]?.label ?? $0 }
            if !names.isEmpty { meta.append("\(names.count) member\(names.count == 1 ? "" : "s"): \(names.joined(separator: ", "))") }
            meta.append(config.cwd)
        }
        let count = messages.filter(\.isContent).count
        return page(title: title, meta: meta, body: body, style: style, exportedAt: exportedAt,
                    summary: "\(count) message\(count == 1 ? "" : "s")")
    }

    // MARK: verdict run

    public static func run(_ run: VerdictRun, title: String, style: Style, folder: URL?, exportedAt: Date,
                           prepare: (String) -> String = { $0 },
                           fileExists: @escaping FileExists = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let links = linkTags(folder: folder, fileExists: fileExists)
        var body = "<section class=\"question\"><h2>Question</h2>\n"
            + MarkdownHTML.render(prepare(run.question), link: links) + "</section>\n"
        var answered = 0
        for round in 1...run.rounds {
            var section = ""
            for name in run.order {
                let answer = run.answer(name, round: round).trimmingCharacters(in: .whitespacesAndNewlines)
                if answer.isEmpty {
                    if let error = run.done(name, round: round)?.error {
                        section += "<div class=\"note\">\(esc(run.label(name))) did not answer: \(esc(error))</div>\n"
                    }
                    continue
                }
                answered += 1
                section += article(label: run.label(name), time: nil,
                                   color: colour(for: name, in: run.order, style: style), classes: [],
                                   content: MarkdownHTML.render(prepare(answer), link: links))
            }
            guard !section.isEmpty else { continue }
            if run.rounds > 1 { body += "<h2 class=\"round\">Round \(round)</h2>\n" }
            body += section
        }
        if let verdict = run.verdict?.trimmingCharacters(in: .whitespacesAndNewlines), !verdict.isEmpty {
            body += "<h2 class=\"round\">Verdict</h2>\n"
            body += article(label: run.moderatorLabel, time: nil, color: nil, classes: ["verdict"],
                            content: MarkdownHTML.render(prepare(verdict), link: links))
        }
        let meta = ["Verdict run", "\(run.rounds) round\(run.rounds == 1 ? "" : "s")",
                    "moderated by \(run.moderatorLabel)"]
        return page(title: title, meta: meta, body: body, style: style, exportedAt: exportedAt,
                    summary: "\(answered) answer\(answered == 1 ? "" : "s")")
    }

    // MARK: shared

    static func linkTags(folder: URL?, fileExists: @escaping FileExists) -> (URL) -> MarkdownHTML.LinkTags? {
        { url in
            if url.scheme == "council" { return .init(open: "<span class=\"mention\">", close: "</span>") }
            switch LinkTarget.resolve(url, relativeTo: folder, fileExists: fileExists) {
            case .web(let target):
                return .init(open: "<a href=\"\(esc(target.absoluteString))\" target=\"_blank\" rel=\"noopener noreferrer\">",
                             close: "</a>")
            case .file(let target, _):
                return .init(open: "<a href=\"\(esc(target.absoluteString))\">", close: "</a>")
            case .missing, .system:
                return nil
            }
        }
    }

    private static func colour(for name: String, in order: [String], style: Style) -> String? {
        guard !style.palette.isEmpty, let i = order.firstIndex(of: name) else { return nil }
        return style.palette[i % style.palette.count]
    }

    private static func article(label: String, time: String?, color: String?, classes: [String],
                                content: String) -> String {
        let cls = (["msg"] + classes).joined(separator: " ")
        let tint = color.flatMap(validHex).map { " style=\"--c:\($0)\"" } ?? ""
        let stamp = time.map { $0.isEmpty ? "" : "<time>\(esc($0))</time>" } ?? ""
        return "<article class=\"\(cls)\"\(tint)><header><span class=\"who\">\(esc(label))</span>\(stamp)</header>"
            + "<div class=\"body\">\n\(content)</div></article>\n"
    }

    /// Colours arrive from the app's palette; anything that is not plain `#RRGGBB` is dropped rather than
    /// written into a style attribute.
    static func validHex(_ s: String) -> String? {
        let hex = s.hasPrefix("#") ? s.dropFirst() : Substring(s)
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + hex.uppercased()
    }

    private static func page(title: String, meta: [String], body: String, style: Style, exportedAt: Date,
                             summary: String) -> String {
        let light = validHex(style.accentLight) ?? "#6062D8"
        let dark = validHex(style.accentDark) ?? "#7678ED"
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(title))</title>
        <style>
        :root { color-scheme: light dark; --accent: \(light); --bg: #F6F7FA; --panel: #FFFFFF; --text: #1B1C22;
          --muted: #6B6F7B; --line: #E3E5EC; --code: rgba(0,0,0,.05); }
        @media (prefers-color-scheme: dark) { :root { --accent: \(dark); --bg: #0B0B0F; --panel: #15161C;
          --text: #E8E9EE; --muted: #9A9DA8; --line: #26272F; --code: rgba(255,255,255,.07); } }
        * { box-sizing: border-box; }
        body { margin: 0; background: var(--bg); color: var(--text);
          font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
        main { max-width: 820px; margin: 0 auto; padding: 36px 20px 64px; }
        .top h1 { font-size: 26px; line-height: 1.25; margin: 0 0 6px; }
        .meta { color: var(--muted); font-size: 13px; margin: 0 0 28px; overflow-wrap: anywhere; }
        .day { text-align: center; color: var(--muted); font-size: 11.5px; letter-spacing: .06em;
          text-transform: uppercase; margin: 30px 0 10px; }
        .msg { margin: 14px 0; padding: 10px 16px 12px; border-left: 3px solid var(--c, var(--line));
          background: color-mix(in srgb, var(--c, var(--line)) 8%, var(--panel)); border-radius: 0 10px 10px 0; }
        .msg.you { margin-left: 56px; border-left: 0; border-right: 3px solid var(--accent);
          background: var(--panel); border-radius: 10px 0 0 10px; }
        .msg.verdict { border-left-color: var(--accent); background: color-mix(in srgb, var(--accent) 7%, var(--panel)); }
        .msg header { font-size: 13px; }
        .who { font-weight: 650; color: var(--c, var(--text)); }
        .msg.you .who, .msg.verdict .who { color: var(--accent); }
        time { color: var(--muted); font-size: 12px; margin-left: 8px; }
        .body { overflow-wrap: anywhere; }
        .body > :first-child { margin-top: 6px; }
        .body > :last-child { margin-bottom: 0; }
        .unreadable .body { font-style: italic; color: var(--muted); }
        .note { color: var(--muted); font-size: 12.5px; font-style: italic; text-align: center; margin: 10px 0; }
        .question { margin-bottom: 8px; }
        h2 { font-size: 17px; margin: 30px 0 8px; }
        .mention { font-weight: 650; color: var(--accent); }
        a { color: var(--accent); }
        code { font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--code);
          padding: 1px 5px; border-radius: 5px; }
        pre { background: var(--code); padding: 12px 14px; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        pre[data-lang]::before { content: attr(data-lang); display: block; color: var(--muted);
          font: 600 11px -apple-system, system-ui, sans-serif; margin-bottom: 6px; }
        blockquote { margin: 8px 0; padding: 0 12px; border-left: 3px solid var(--line); color: var(--muted); }
        table { border-collapse: collapse; margin: 8px 0; display: block; overflow-x: auto; }
        th, td { border: 1px solid var(--line); padding: 5px 9px; vertical-align: top; }
        th { background: var(--code); }
        hr { border: 0; border-top: 1px solid var(--line); margin: 16px 0; }
        footer { color: var(--muted); font-size: 12px; margin-top: 44px; text-align: center; }
        @media (max-width: 560px) { .msg.you { margin-left: 16px; } }
        </style>
        </head>
        <body>
        <main>
        <header class="top"><h1>\(esc(title))</h1>
        <p class="meta">\(meta.map(esc).joined(separator: " · "))</p></header>
        \(body)<footer>Exported from Open Council · \(esc(stampFormatter.string(from: exportedAt))) · \(esc(summary))</footer>
        </main>
        </body>
        </html>

        """
    }

    private static func esc(_ s: String) -> String { MarkdownHTML.escape(s) }

    // DateFormatter formats safely from any thread once configured, as MessageTime relies on.
    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        return f
    }()

    nonisolated(unsafe) private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
