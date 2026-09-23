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

    /// Whether a chat's working folder is the folder that holds `council.toml` and `council.py` — this
    /// checkout's root, or any folder above it. That is where members get file and shell tools, so a working
    /// folder here means those tools reach the config that sets a member's own permissions and the scripts its
    /// hooks run. It is a real thing to want (working on Council itself), so the app warns rather than refuses;
    /// this is the pure path test behind that warning. `standardizedFileURL` resolves `.`/`..` and symlinks in
    /// the last component so `/x/../root` and `root` compare equal.
    public func exposesCouncilRoot(_ workingFolder: URL) -> Bool {
        let w = workingFolder.standardizedFileURL.path
        let r = root.standardizedFileURL.path
        if w == r { return true }
        let prefix = w.hasSuffix("/") ? w : w + "/"   // "/" stays "/", so a working folder of "/" catches all
        return r.hasPrefix(prefix)
    }

    /// True when `folder` is itself a council checkout (holds a `council.toml`). Catches a *second* clone
    /// chosen as a working folder, which `exposesCouncilRoot` — comparing only against this checkout's root —
    /// cannot see.
    public static func holdsConfig(_ folder: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: folder.appendingPathComponent("council.toml").path)
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
