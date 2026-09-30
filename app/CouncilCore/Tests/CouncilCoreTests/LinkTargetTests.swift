import XCTest
@testable import CouncilCore

/// Links reach the app through Foundation's Markdown parser, which is what Textual uses, so every case here is
/// fed through it: the point is the URL the app is actually handed, not one constructed to be convenient. A
/// path link arrives with no scheme, and handing that to the system is what raised "-50".
final class LinkTargetTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/work/project")

    /// The URL `[x](target)` becomes.
    private func link(_ target: String) throws -> URL {
        let parsed = try AttributedString(markdown: "[x](\(target))",
                                          options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return try XCTUnwrap(parsed.runs.compactMap(\.link).first, "no link parsed from \(target)")
    }

    private func resolve(_ target: String, existing: Set<String>, folder: URL? = nil) throws -> LinkTarget {
        LinkTarget.resolve(try link(target), relativeTo: folder ?? self.folder, fileExists: existing.contains)
    }

    // MARK: web and other schemes

    func testWebLinksGoToTheBrowser() throws {
        XCTAssertEqual(try resolve("https://example.com/a?b=1", existing: []), .web(URL(string: "https://example.com/a?b=1")!))
        XCTAssertEqual(try resolve("mailto:jane@example.com", existing: []), .web(URL(string: "mailto:jane@example.com")!))
    }

    func testARegisteredSchemeIsLeftToTheSystem() throws {
        XCTAssertEqual(try resolve("vscode://file/a.swift", existing: []), .system(URL(string: "vscode://file/a.swift")!))
    }

    // MARK: the shapes members actually write

    /// The case from the chats: an absolute path with a line number on the end.
    func testAnAbsolutePathWithALine() throws {
        let path = "/Users/x/llm-wiki/mail/PEOPLE-DIRECTORY.md"
        XCTAssertEqual(try resolve("\(path):123", existing: [path]), .file(URL(fileURLWithPath: path), line: 123))
    }

    func testARelativePathResolvesAgainstTheWorkingFolder() throws {
        let path = "/work/project/app/Foo.swift"
        XCTAssertEqual(try resolve("app/Foo.swift:42:7", existing: [path]), .file(URL(fileURLWithPath: path), line: 42))
    }

    /// `README.md:12` parses as a URL whose scheme is "readme.md"; it is still a path.
    func testAFilenameIsNotMistakenForAScheme() throws {
        let path = "/work/project/README.md"
        XCTAssertEqual(try resolve("README.md:12", existing: [path]), .file(URL(fileURLWithPath: path), line: 12))
        XCTAssertEqual(try resolve("Makefile:10", existing: ["/work/project/Makefile"]),
                       .file(URL(fileURLWithPath: "/work/project/Makefile"), line: 10))
    }

    func testAnAnchorNamesTheLine() throws {
        let path = "/work/project/a.swift"
        XCTAssertEqual(try resolve("a.swift#L10-L20", existing: [path]), .file(URL(fileURLWithPath: path), line: 10))
    }

    func testAHomeRelativePath() throws {
        let path = NSString(string: "~/Code/b.md").expandingTildeInPath
        XCTAssertEqual(try resolve("~/Code/b.md", existing: [path]), .file(URL(fileURLWithPath: path), line: nil))
    }

    func testAFileURLKeepsItsLine() throws {
        let path = "/work/project/c.swift"
        XCTAssertEqual(try resolve("file:///work/project/c.swift#L5", existing: [path]),
                       .file(URL(fileURLWithPath: path), line: 5))
    }

    func testSpacesInAPath() throws {
        let path = "/work/project/My Notes/plan.md"
        XCTAssertEqual(try resolve("<My Notes/plan.md>", existing: [path]), .file(URL(fileURLWithPath: path), line: nil))
    }

    /// A file whose name really ends in ":12" is found as written before the suffix is read as a line.
    func testTheNameAsWrittenWinsOverALineSuffix() throws {
        let path = "/work/project/notes:12"
        XCTAssertEqual(try resolve("/work/project/notes:12", existing: [path, "/work/project/notes"]),
                       .file(URL(fileURLWithPath: path), line: nil))
    }

    func testDotSegmentsAreResolved() throws {
        let path = "/work/shared/x.md"
        XCTAssertEqual(try resolve("../shared/x.md", existing: [path]), .file(URL(fileURLWithPath: path), line: nil))
    }

    // MARK: nothing there

    /// Saying what was looked for is the whole replacement for an error code.
    func testAPathWithNothingThereSaysWhere() throws {
        XCTAssertEqual(try resolve("gone/file.swift:3", existing: []), .missing(path: "/work/project/gone/file.swift"))
    }

    // MARK: opening

    func testFoldersAndDocumentsOpen() {
        XCTAssertEqual(LinkTarget.openMode(for: URL(fileURLWithPath: "/w/dir"), isDirectory: true, isPackage: false, isExecutable: true), .open)
        XCTAssertEqual(LinkTarget.openMode(for: URL(fileURLWithPath: "/w/a.md"), isDirectory: false, isPackage: false, isExecutable: false), .open)
        XCTAssertEqual(LinkTarget.openMode(for: URL(fileURLWithPath: "/w/a.pdf"), isDirectory: false, isPackage: false, isExecutable: false), .open)
        // A document bundle is a directory the Finder shows as a file; it is still a document.
        XCTAssertEqual(LinkTarget.openMode(for: URL(fileURLWithPath: "/w/a.rtfd"), isDirectory: true, isPackage: true, isExecutable: true), .open)
        // An executable bit on a document does not make opening it run anything.
        XCTAssertEqual(LinkTarget.openMode(for: URL(fileURLWithPath: "/w/a.md"), isDirectory: false, isPackage: false, isExecutable: true), .open)
    }

    /// Scripts are shown, never run: `.command` would otherwise execute in Terminal.
    func testScriptsOpenAsText() {
        for name in ["run.py", "setup.sh", "go.command", "app.js", "t.rb", "x.applescript"] {
            XCTAssertEqual(LinkTarget.openMode(for: URL(fileURLWithPath: "/w/\(name)"), isDirectory: false,
                                               isPackage: false, isExecutable: false), .openAsText, name)
        }
    }

    func testAnythingRunnableIsRevealedInstead() {
        XCTAssertEqual(LinkTarget.openMode(for: URL(fileURLWithPath: "/w/Evil.app"), isDirectory: true, isPackage: true, isExecutable: true), .reveal)
        for name in ["setup.pkg", "shell.terminal", "flow.workflow", "go.fileloc"] {
            XCTAssertEqual(LinkTarget.openMode(for: URL(fileURLWithPath: "/w/\(name)"), isDirectory: false,
                                               isPackage: false, isExecutable: false), .reveal, name)
        }
        // Opening an extensionless executable runs it in Terminal.
        XCTAssertEqual(LinkTarget.openMode(for: URL(fileURLWithPath: "/w/tool"), isDirectory: false, isPackage: false, isExecutable: true), .reveal)
    }
}
