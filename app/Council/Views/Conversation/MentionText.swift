import SwiftUI
import Textual
import CouncilCore

/// Renders a message body as Markdown with `@mentions` turned into accent-coloured chips (links on a
/// `council://mention/<name>` URL, so clicking one jumps to that member).
struct MessageMarkdown: View {
    let text: String
    let members: [String]
    var onMention: ((String) -> Void)?

    var body: some View {
        StructuredText(markdown: MentionMarkup.apply(to: text, members: members))
            // A point above the app's body size: this is the text people actually read, and line height
            // follows the font rather than being set, so it grows with it.
            .font(Typography.font(14))
            .textual.structuredTextStyle(.gitHub)
            .textual.codeBlockStyle(CouncilCodeBlockStyle())
            .textual.inlineStyle(.council)
            .textual.textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == MentionMarkup.scheme {
                    if let name = url.host() ?? url.pathComponents.dropFirst().first { onMention?(name) }
                    return .handled
                }
                return .systemAction
            })
    }
}

enum MentionMarkup {
    static let scheme = "council"

    /// `@codex` → `**[@codex](council://codex)**` for known members, `@user`, `@all`, `@everyone`.
    /// Fenced code blocks and inline code are left alone.
    static func apply(to text: String, members: [String]) -> String {
        let known = Set(members.map { $0.lowercased() } + [Message.userSender, "all", "everyone"])
        var out = ""
        var inFence = false
        for (i, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)
            if i > 0 { out += "\n" }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); out += line; continue }
            if inFence { out += line; continue }
            out += rewriteLine(line, known: known)
        }
        return out
    }

    private static func rewriteLine(_ line: String, known: Set<String>) -> String {
        // Split on backticks so inline code is untouched (odd segments are inside code).
        let parts = line.components(separatedBy: "`")
        return parts.enumerated().map { i, part in
            i % 2 == 1 ? part : rewriteText(part, known: known)
        }.joined(separator: "`")
    }

    private static func rewriteText(_ text: String, known: Set<String>) -> String {
        var result = ""
        var last = text.startIndex
        for range in Mentions.ranges(in: text) {
            let name = String(text[text.index(after: range.lowerBound)..<range.upperBound]).lowercased()
            result += text[last..<range.lowerBound]
            if known.contains(name) {
                result += "**[\(text[range])](\(scheme)://\(name))**"
            } else {
                result += text[range]
            }
            last = range.upperBound
        }
        result += text[last...]
        return result
    }
}

extension InlineStyle {
    /// Links (and therefore mention chips) in the accent colour, no underline; code in a soft grey pill.
    static var council: InlineStyle {
        InlineStyle.gitHub
            .link(.foregroundColor(Palette.accent))
    }
}

/// GitHub-style code block with a small header naming the language.
struct CouncilCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(configuration.languageHint ?? "")
                    .font(Typography.caption2Semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    configuration.codeBlock.copyToPasteboard()
                } label: {
                    Image(systemName: "doc.on.doc").font(Typography.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy code")
            }
            .padding(.horizontal, 12).padding(.top, 8)
            configuration.label
                .textual.lineSpacing(.fontScaled(0.2))
                .textual.fontScale(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .monospaced()
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .textual.blockSpacing(.init(top: 0, bottom: 12))
    }
}
