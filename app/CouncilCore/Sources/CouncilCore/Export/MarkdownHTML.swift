import Foundation

/// Markdown to an HTML fragment, by walking Foundation's own parse — the parser the app renders messages with —
/// so an exported conversation has the same structure as the one on screen. Every piece of text is escaped,
/// including anything the source spelled as raw HTML, which is shown as the characters it was written with.
public enum MarkdownHTML {
    /// The tags around a link's text. `link` returns nil to leave a link's text plain.
    public struct LinkTags: Sendable, Equatable {
        public var open: String
        public var close: String
        public init(open: String, close: String) { self.open = open; self.close = close }
    }

    public static func render(_ markdown: String, link: (URL) -> LinkTags? = { _ in nil }) -> String {
        guard let parsed = try? AttributedString(markdown: markdown,
                                                 options: .init(interpretedSyntax: .full,
                                                                failurePolicy: .returnPartiallyParsedIfPossible))
        else {
            return "<p>" + escape(markdown).replacingOccurrences(of: "\n", with: "<br>") + "</p>"
        }
        var html = ""
        var blocks: [(identity: Int, close: String, isCode: Bool)] = []
        var linkOpen: (url: URL, close: String)?

        func closeLink() {
            if let l = linkOpen { html += l.close; linkOpen = nil }
        }

        for run in parsed.runs {
            // Outermost block first: a list, then its item, then the item's paragraph.
            let path = Array((run.presentationIntent?.components ?? []).reversed())
            var shared = 0
            while shared < blocks.count, shared < path.count, blocks[shared].identity == path[shared].identity {
                shared += 1
            }
            if shared < blocks.count || shared < path.count { closeLink() }
            while blocks.count > shared { html += blocks.removeLast().close }
            for index in shared..<path.count {
                let (open, close, isCode) = tags(for: path, at: index)
                html += open
                blocks.append((path[index].identity, close, isCode))
            }

            let text = String(parsed[run.range].characters)
            if blocks.contains(where: \.isCode) { html += escape(text); continue }
            if path.last.map({ if case .thematicBreak = $0.kind { return true } else { return false } }) == true {
                continue
            }

            if run.link != linkOpen?.url {
                closeLink()
                if let url = run.link, let t = link(url) {
                    html += t.open
                    linkOpen = (url, t.close)
                }
            }
            html += inline(text, run.inlinePresentationIntent ?? [])
        }
        closeLink()
        while let block = blocks.popLast() { html += block.close }
        return html
    }

    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    // MARK: pieces

    private static func inline(_ text: String, _ intent: InlinePresentationIntent) -> String {
        if intent.contains(.lineBreak) { return "<br>\n" }
        if intent.contains(.softBreak) { return "\n" }
        let body = escape(text)
        if intent.contains(.code) { return "<code>\(body)</code>" }
        // Raw HTML in the source is text here, never markup.
        if intent.contains(.inlineHTML) || intent.contains(.blockHTML) { return body }
        var open = "", close = ""
        if intent.contains(.strikethrough) { open += "<del>"; close = "</del>" + close }
        if intent.contains(.stronglyEmphasized) { open += "<strong>"; close = "</strong>" + close }
        if intent.contains(.emphasized) { open += "<em>"; close = "</em>" + close }
        return open + body + close
    }

    /// Opening and closing tags for the block at `index` of `path`, which some blocks need to read: a list's
    /// first item carries its starting number, a cell's row says whether it is a heading.
    private static func tags(for path: [PresentationIntent.IntentType], at index: Int)
        -> (open: String, close: String, isCode: Bool) {
        switch path[index].kind {
        case .paragraph:
            return ("<p>", "</p>\n", false)
        case .header(let level):
            let n = min(max(level, 1), 6)
            return ("<h\(n)>", "</h\(n)>\n", false)
        case .unorderedList:
            return ("<ul>\n", "</ul>\n", false)
        case .orderedList:
            if index + 1 < path.count, case .listItem(let first) = path[index + 1].kind, first != 1 {
                return ("<ol start=\"\(first)\">\n", "</ol>\n", false)
            }
            return ("<ol>\n", "</ol>\n", false)
        case .listItem:
            return ("<li>", "</li>\n", false)
        case .blockQuote:
            return ("<blockquote>\n", "</blockquote>\n", false)
        case .codeBlock(let hint):
            let lang = hint.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            let attrs = lang.map { " data-lang=\"\(escape($0))\" class=\"language-\(escape($0))\"" } ?? ""
            return ("<pre\(attrs)><code>", "</code></pre>\n", true)
        case .thematicBreak:
            return ("<hr>\n", "", false)
        case .table:
            return ("<table>\n", "</table>\n", false)
        case .tableHeaderRow, .tableRow:
            return ("<tr>", "</tr>\n", false)
        case .tableCell(let column):
            let inHeader = index > 0 && { if case .tableHeaderRow = path[index - 1].kind { return true }; return false }()
            let tag = inHeader ? "th" : "td"
            return ("<\(tag)\(alignment(column, in: path))>", "</\(tag)>", false)
        @unknown default:
            return ("<div>", "</div>\n", false)
        }
    }

    private static func alignment(_ column: Int, in path: [PresentationIntent.IntentType]) -> String {
        for component in path {
            guard case .table(let columns) = component.kind, column < columns.count else { continue }
            switch columns[column].alignment {
            case .center: return " style=\"text-align:center\""
            case .right: return " style=\"text-align:right\""
            default: return ""
            }
        }
        return ""
    }
}
