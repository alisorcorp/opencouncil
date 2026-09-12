import Foundation

/// Where council keeps its data. The layout is shared with the Python CLI and must not change (R20):
/// `<root>/council.toml`, `<root>/chats/<stamp>_<slug>/`, `<root>/runs/<stamp>_<slug>/`.
public struct CouncilPaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    public var configFile: URL { root.appendingPathComponent("council.toml") }
    public var chats: URL { root.appendingPathComponent("chats", isDirectory: true) }
    public var runs: URL { root.appendingPathComponent("runs", isDirectory: true) }
    public var councilScript: URL { root.appendingPathComponent("council.py") }

    /// True when the folder looks like a council checkout.
    public var isValid: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: configFile.path) && fm.fileExists(atPath: councilScript.path)
    }

    /// Finds the council folder. Order: an explicit preference, the folder the installed `council`
    /// wrapper points at (install.sh writes `exec python3 <root>/council.py`), then the conventional location.
    public static func discoverRoot(preferred: URL? = nil,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   fileManager: FileManager = .default) -> CouncilPaths? {
        var candidates: [URL] = []
        if let p = preferred { candidates.append(p) }
        let wrapper = home.appendingPathComponent(".local/bin/council")
        if let text = try? String(contentsOf: wrapper, encoding: .utf8), let root = rootFromWrapper(text) {
            candidates.append(root)
        }
        candidates.append(home.appendingPathComponent("Documents/AI/council"))
        for c in candidates {
            let p = CouncilPaths(root: c)
            if fileManager.fileExists(atPath: p.configFile.path), fileManager.fileExists(atPath: p.councilScript.path) {
                return p
            }
        }
        return nil
    }

    /// Extracts `<root>` from a wrapper line like `exec "/usr/bin/python3" "/path/to/council/council.py" "$@"`.
    static func rootFromWrapper(_ text: String) -> URL? {
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: "council.py") else { continue }
            var start = range.lowerBound
            while start > line.startIndex {
                let prev = line.index(before: start)
                if line[prev] == "\"" || line[prev] == " " || line[prev] == "'" { break }
                start = prev
            }
            let path = String(line[start..<range.upperBound])
            return URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        return nil
    }
}
