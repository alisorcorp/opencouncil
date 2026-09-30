import XCTest
@testable import CouncilCore

final class MarkdownHTMLTests: XCTestCase {
    private func html(_ md: String) -> String { MarkdownHTML.render(md) }

    func testInlineStyles() {
        let out = html("Plain **bold** *em* ~~gone~~ and `code <x>`")
        XCTAssertTrue(out.hasPrefix("<p>"), out)
        XCTAssertTrue(out.contains("<strong>bold</strong>"), out)
        XCTAssertTrue(out.contains("<em>em</em>"), out)
        XCTAssertTrue(out.contains("<del>gone</del>"), out)
        XCTAssertTrue(out.contains("<code>code &lt;x&gt;</code>"), out)
    }

    func testBlocks() {
        let out = html("# Title\n\n- a\n- b\n\n3. three\n4. four\n\n> quoted\n\n---\n\nend")
        XCTAssertTrue(out.contains("<h1>Title</h1>"), out)
        XCTAssertTrue(out.contains("<ul>\n<li><p>a</p>\n</li>\n<li><p>b</p>\n</li>\n</ul>"), out)
        XCTAssertTrue(out.contains("<ol start=\"3\">"), out)
        XCTAssertTrue(out.contains("<blockquote>\n<p>quoted</p>\n</blockquote>"), out)
        XCTAssertTrue(out.contains("<hr>"), out)
        XCTAssertFalse(out.contains("⸻"), "a thematic break's placeholder character is not text")
    }

    /// Code keeps its characters and its line breaks, and nothing inside it is read as Markdown.
    func testCodeBlocks() {
        let out = html("```swift\nlet a = \"<b>\" // **not bold**\n```")
        XCTAssertTrue(out.contains("<pre data-lang=\"swift\" class=\"language-swift\"><code>"), out)
        XCTAssertTrue(out.contains("let a = &quot;&lt;b&gt;&quot; // **not bold**"), out)
        XCTAssertFalse(out.contains("<strong>"), out)
    }

    func testTables() {
        let out = html("| a | b |\n|:--|--:|\n| 1 | 2 |")
        XCTAssertTrue(out.contains("<table>"), out)
        XCTAssertTrue(out.contains("<th>a</th><th style=\"text-align:right\">b</th>"), out)
        XCTAssertTrue(out.contains("<td>1</td><td style=\"text-align:right\">2</td>"), out)
    }

    /// Markup written into a message is shown as the characters it is made of.
    func testSourceMarkupIsShownAsText() {
        let out = html("before <b>raw</b> after\n\n<div>block</div>")
        XCTAssertFalse(out.contains("<b>"), out)
        XCTAssertFalse(out.contains("<div>"), out)
        XCTAssertTrue(out.contains("&lt;b&gt;raw&lt;/b&gt;"), out)
    }

    func testBreaks() {
        let out = html("one\ntwo  \nthree")
        XCTAssertTrue(out.contains("one\ntwo<br>\nthree"), out)
    }

    func testLinksUseTheTagsTheyAreGiven() {
        // Emphasis around a link survives the parse (it is how mention chips are written); emphasis inside a
        // link's text does not — Foundation drops it, on screen as well as here.
        let out = MarkdownHTML.render("see **[here](https://e.com/x)** and [there](nowhere)") { url in
            url.scheme == "https" ? .init(open: "<a href=\"\(url.absoluteString)\">", close: "</a>") : nil
        }
        XCTAssertTrue(out.contains("<a href=\"https://e.com/x\"><strong>here</strong></a>"), out)
        XCTAssertTrue(out.contains(" and there"), "a link with no tags keeps its text: \(out)")
    }
}

final class SessionHTMLTests: XCTestCase {
    private let style = SessionHTML.Style(palette: ["#7678ED", "#F18701"], accentLight: "#6062D8", accentDark: "#7678ED")
    private let t0 = Date(timeIntervalSince1970: 1_789_000_000)

    private func config() -> ChatConfig {
        ChatConfig(created: "2026-09-22T12:10:25", cwd: "/work/project", title: "Agent swarms",
                   members: ["claude": .init(name: "claude", label: "Claude Opus 5.5"),
                             "codex": .init(name: "codex", label: "Codex")],
                   order: ["claude", "codex"])
    }

    private func message(_ sender: String, _ text: String, kind: String = Message.kindMessage,
                         at ts: String = "2026-09-22T12:10:31") -> Message {
        Message(id: 1, ts: ts, sender: sender, kind: kind, text: text, to: [])
    }

    private func export(_ messages: [Message], existing: Set<String> = []) -> String {
        SessionHTML.chat(title: "Agent swarms", config: config(), messages: messages, style: style,
                         folder: URL(fileURLWithPath: "/work/project"), exportedAt: t0,
                         prepare: { $0.replacingOccurrences(of: "@codex", with: "**[@codex](council://codex)**") },
                         fileExists: existing.contains)
    }

    func testAChatBecomesACompletePage() {
        let page = export([message("user", "What do you think?"),
                           message("claude", "I think **yes**."),
                           message("system", "reply budget set to 12", kind: Message.kindNote)])
        XCTAssertTrue(page.hasPrefix("<!DOCTYPE html>"), page)
        XCTAssertTrue(page.contains("<title>Agent swarms</title>"))
        XCTAssertTrue(page.contains("<article class=\"msg you\"><header><span class=\"who\">You</span><time>12:10</time>"), page)
        XCTAssertTrue(page.contains("<article class=\"msg\" style=\"--c:#7678ED\"><header><span class=\"who\">Claude Opus 5.5</span>"), page)
        XCTAssertTrue(page.contains("<strong>yes</strong>"))
        XCTAssertTrue(page.contains("<div class=\"note\">reply budget set to 12</div>"))
        XCTAssertTrue(page.contains("2 messages"), "the note is not counted as a message")
        XCTAssertTrue(page.contains("2 members: Claude Opus 5.5, Codex"))
        XCTAssertFalse(page.contains("<script"), "the page is self-contained and runs nothing")
    }

    func testMentionsAreStyledNotLinked() {
        let page = export([message("claude", "@codex over to you")])
        XCTAssertTrue(page.contains("<span class=\"mention\"><strong>@codex</strong></span>"), page)
        XCTAssertFalse(page.contains("council://"), page)
    }

    /// The same rules as clicking in the app: web links open, a path becomes a `file:` link only when there is a
    /// file, and every other scheme stays text.
    func testOnlyWebAndExistingFileLinksBecomeLinks() {
        let page = export([message("claude", "[site](https://e.com) [src](app/A.swift:3) [gone](app/B.swift) [x](javascript:void(0))")],
                          existing: ["/work/project/app/A.swift"])
        XCTAssertTrue(page.contains("<a href=\"https://e.com\" target=\"_blank\" rel=\"noopener noreferrer\">site</a>"), page)
        XCTAssertTrue(page.contains("<a href=\"file:///work/project/app/A.swift\">src</a>"), page)
        XCTAssertTrue(page.contains(" gone "), page)
        XCTAssertFalse(page.contains("javascript"), page)
    }

    func testNamesAndTitlesAreEscaped() {
        let page = SessionHTML.chat(title: "A <b> & \"q\"", config: nil, messages: [message("sam<x>", "hi")],
                                    style: style, folder: nil, exportedAt: t0)
        XCTAssertTrue(page.contains("<title>A &lt;b&gt; &amp; &quot;q&quot;</title>"), page)
        XCTAssertTrue(page.contains("<span class=\"who\">sam&lt;x&gt;</span>"), page)
    }

    func testAColourThatIsNotAHexIsDropped() {
        XCTAssertEqual(SessionHTML.validHex("#abcdef"), "#ABCDEF")
        XCTAssertNil(SessionHTML.validHex("red;background:url(x)"))
        XCTAssertNil(SessionHTML.validHex("#12345"))
    }

    func testANewDayGetsAHeading() {
        let page = export([message("user", "a", at: "2026-09-22T23:59:00"), message("user", "b", at: "2026-09-23T00:01:00")])
        XCTAssertEqual(page.components(separatedBy: "<div class=\"day\">").count - 1, 2, page)
    }

    func testAVerdictRunExportsItsQuestionAnswersAndVerdict() throws {
        let run = try VerdictRun(directory: Fixtures.runDir)
        let page = SessionHTML.run(run, title: "Type hints", style: style, folder: Fixtures.runDir, exportedAt: t0)
        XCTAssertTrue(page.contains("<h2>Question</h2>"), page)
        for name in run.order where !run.answer(name, round: 1).isEmpty {
            XCTAssertTrue(page.contains("<span class=\"who\">\(MarkdownHTML.escape(run.label(name)))</span>"), name)
        }
        if run.verdict != nil { XCTAssertTrue(page.contains("<h2 class=\"round\">Verdict</h2>"), page) }
    }
}
