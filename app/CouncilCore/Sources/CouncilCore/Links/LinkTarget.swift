import Foundation
import UniformTypeIdentifiers

/// What a link in a message points at, worked out before anything is opened.
///
/// Members write file links the way their CLIs print them: an absolute path, a path relative to the folder
/// they work in, `~/…`, often with `:42`, `:42:7` or `#L42` on the end. Markdown hands all of those over as a
/// URL with no scheme, and passing one of those straight to the system is what raised "The application can't
/// be opened. -50". So a scheme-less link is read as a path, resolved against the chat's working folder, and
/// checked on disk; only real schemes go to the system untouched.
public enum LinkTarget: Equatable, Sendable {
    /// `http`, `https`, `mailto`: the browser or mail app.
    case web(URL)
    /// A file or folder that exists. `line` is what the link named, when it named one.
    case file(URL, line: Int?)
    /// It was written as a path and nothing is there. `path` is what was looked for, for the message.
    case missing(path: String)
    /// Any other scheme (`vscode://`, `zoommtg:`…): the system decides what handles it.
    case system(URL)

    public static func resolve(_ url: URL, relativeTo folder: URL?,
                               fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> LinkTarget {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            return .web(url)
        case "file":
            var line: Int? = nil
            if let fragment = url.fragment(percentEncoded: false) { line = lineNumber(inFragment: fragment) }
            return locate(url.path(percentEncoded: false), line: line, relativeTo: nil, fileExists: fileExists)
        case nil:
            return locatePath(url.absoluteString, relativeTo: folder, fileExists: fileExists)
        default:
            // `README.md:12` parses as scheme "readme.md", and `Foo:42` as scheme "foo" with a line number
            // where a real URL would have its body. Neither is a scheme anybody registered.
            if looksLikePath(url.absoluteString) {
                return locatePath(url.absoluteString, relativeTo: folder, fileExists: fileExists)
            }
            return .system(url)
        }
    }

    // MARK: opening

    /// How an existing file should be opened. A link in a message is something a member wrote, and opening
    /// some files runs them: a `.command` in Terminal, an app, an installer, an extensionless executable. So
    /// scripts are shown as text in the user's text editor, anything runnable is revealed in Finder for the
    /// user to launch themselves, and everything else opens normally.
    public enum OpenMode: Equatable, Sendable {
        case open
        case openAsText
        case reveal
    }

    public static func openMode(for url: URL, isDirectory: Bool, isPackage: Bool, isExecutable: Bool) -> OpenMode {
        if isDirectory && !isPackage { return .open }
        let ext = url.pathExtension.lowercased()
        let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        if let type, type.conforms(to: .script) { return .openAsText }
        if let type, runnableTypes.contains(where: { type.conforms(to: $0) }) { return .reveal }
        if revealedExtensions.contains(ext) { return .reveal }
        // Opening an extensionless executable runs it in Terminal; with an extension, the type decided above.
        if isExecutable && !isDirectory && ext.isEmpty { return .reveal }
        return .open
    }

    static let runnableTypes: [UTType] = [.application, .applicationBundle, .executable, .unixExecutable]
    /// Types that act when opened but do not declare themselves executable: installers, Terminal settings
    /// (which can run a command), Automator documents, and `.fileloc`, which opens whatever it points at.
    static let revealedExtensions: Set<String> = ["pkg", "mpkg", "terminal", "workflow", "action", "fileloc",
                                                  "mobileconfig"]

    // MARK: paths

    private static func locatePath(_ raw: String, relativeTo folder: URL?,
                                   fileExists: (String) -> Bool) -> LinkTarget {
        var path = raw.removingPercentEncoding ?? raw
        var line: Int? = nil
        if let hash = path.lastIndex(of: "#") {
            line = lineNumber(inFragment: String(path[path.index(after: hash)...]))
            path = String(path[..<hash])
        }
        return locate(path, line: line, relativeTo: folder, fileExists: fileExists)
    }

    private static func locate(_ path: String, line: Int?, relativeTo folder: URL?,
                               fileExists: (String) -> Bool) -> LinkTarget {
        guard !path.isEmpty else { return .missing(path: "#") }
        // The path as written first, so a file whose name really ends in ":12" is still found; then without a
        // trailing line (and column) number.
        var candidates: [(path: String, line: Int?)] = [(path, line)]
        if let (bare, suffixLine) = splitLineSuffix(path) { candidates.append((bare, line ?? suffixLine)) }
        var looked: String?
        for candidate in candidates {
            guard let absolute = absolutePath(candidate.path, relativeTo: folder) else { continue }
            let url = URL(fileURLWithPath: absolute).standardizedFileURL
            if fileExists(url.path) { return .file(url, line: candidate.line) }
            looked = url.path
        }
        return .missing(path: looked ?? candidates.last!.path)
    }

    private static func absolutePath(_ path: String, relativeTo folder: URL?) -> String? {
        if path == "~" || path.hasPrefix("~/") { return NSString(string: path).expandingTildeInPath }
        if path.hasPrefix("/") { return path }
        return folder?.appendingPathComponent(path).path
    }

    /// `a.swift:42` → (`a.swift`, 42); `a.swift:42:7` → (`a.swift`, 42); anything else → nil.
    static func splitLineSuffix(_ path: String) -> (String, Int)? {
        var parts = path.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let last = Int(parts[parts.count - 1]) else { return nil }
        parts.removeLast()
        var line = last
        if parts.count >= 2, let previous = Int(parts[parts.count - 1]) {
            parts.removeLast()
            line = previous
        }
        let bare = parts.joined(separator: ":")
        return bare.isEmpty ? nil : (bare, line)
    }

    /// `L42`, `L42-L60`, `42` → 42.
    static func lineNumber(inFragment fragment: String) -> Int? {
        Int(fragment.drop(while: { $0 == "L" || $0 == "l" }).prefix(while: \.isNumber))
    }

    /// A "scheme" with a dot in it is a filename (`readme.md:12`), and one followed only by digits and colons
    /// is a path with a line number (`Makefile:10`). Registered schemes have neither.
    static func looksLikePath(_ raw: String) -> Bool {
        guard let colon = raw.firstIndex(of: ":") else { return true }
        let scheme = raw[..<colon]
        let rest = raw[raw.index(after: colon)...]
        return scheme.contains(".") || (!rest.isEmpty && rest.allSatisfy { $0.isNumber || $0 == ":" })
    }
}
