import Foundation

/// GUI apps do not inherit the user's shell PATH, so `claude`, `codex`, `pi` and `council` would not be found.
/// Resolve PATH once by running the login shell (the VS Code approach) with a sentinel and a timeout,
/// falling back to `/etc/paths` plus the usual tool directories.
public struct ShellEnvironment: Sendable, Equatable {
    public enum Source: Sendable, Equatable { case loginShell, fallback }

    public var path: [String]
    public var source: Source

    public init(path: [String], source: Source) {
        self.path = path
        self.source = source
    }

    public var pathString: String { path.joined(separator: ":") }

    static let beginMarker = "__COUNCIL_PATH_BEGIN__"
    static let endMarker = "__COUNCIL_PATH_END__"

    /// Resolves the environment. Blocking; call off the main thread.
    public static func resolve(shell: String? = nil, timeout: TimeInterval = 10,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ShellEnvironment {
        let sh = shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Try an interactive login shell first (loads .zprofile and .zshrc), then a plain login shell.
        for flags in [["-l", "-i", "-c"], ["-l", "-c"]] {
            if let out = run(sh, flags + ["printf '\\n%s\\n%s\\n%s\\n' '\(beginMarker)' \"$PATH\" '\(endMarker)'"], timeout: timeout),
               let p = parseSentinel(out) {
                let entries = p.split(separator: ":").map(String.init).filter { !$0.isEmpty }
                if !entries.isEmpty { return ShellEnvironment(path: merged(entries, home: home), source: .loginShell) }
            }
        }
        return ShellEnvironment(path: fallbackPath(home: home), source: .fallback)
    }

    /// Extracts the PATH between the sentinels; tolerant of banners, warnings, and colour codes around it.
    static func parseSentinel(_ output: String) -> String? {
        guard let b = output.range(of: beginMarker), let e = output.range(of: endMarker, range: b.upperBound..<output.endIndex) else {
            return nil
        }
        let inner = output[b.upperBound..<e.lowerBound]
        // The PATH is the last non-empty line between the markers (shells may echo noise after the begin marker).
        let lines = inner.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return lines.last
    }

    /// `/etc/paths`, `/etc/paths.d/*`, then the directories the council toolchain usually lives in.
    public static func fallbackPath(home: URL, fileManager: FileManager = .default) -> [String] {
        var entries: [String] = []
        entries += readPathsFile("/etc/paths")
        if let d = try? fileManager.contentsOfDirectory(atPath: "/etc/paths.d") {
            for f in d.sorted() { entries += readPathsFile("/etc/paths.d/\(f)") }
        }
        return merged(entries, home: home)
    }

    /// Adds the well-known tool directories when missing, keeping the shell's order for what it provided.
    static func merged(_ entries: [String], home: URL) -> [String] {
        let h = home.path
        let extras = ["\(h)/.local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
                      "\(h)/.npm-global/bin", "\(h)/.bun/bin", "\(h)/.cargo/bin",
                      "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        var out: [String] = []
        for e in entries + extras where !e.isEmpty {
            let expanded = e.hasPrefix("~") ? h + e.dropFirst() : e
            if seen.insert(expanded).inserted { out.append(expanded) }
        }
        return out
    }

    private static func readPathsFile(_ path: String) -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// First executable named `tool` on the resolved PATH.
    public func which(_ tool: String, fileManager: FileManager = .default) -> URL? {
        for dir in path {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(tool)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The base environment for member terminals: the app's environment with this PATH, and without the
    /// Anthropic API key so Claude Code uses the claude.ai login (see README notes).
    public func memberBaseEnvironment(from env: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var e = env
        e["PATH"] = pathString
        e.removeValue(forKey: "ANTHROPIC_API_KEY")
        return e
    }

    private static func run(_ executable: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env["COUNCIL_ENV_PROBE"] = "1"
        p.environment = env
        do { try p.run() } catch { return nil }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        // Read on a background queue so a chatty shell cannot fill the pipe and deadlock.
        let dataBox = DataBox()
        DispatchQueue.global().async {
            let d = out.fileHandleForReading.readDataToEndOfFile()
            dataBox.set(d)
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 1)
            return nil
        }
        return String(data: dataBox.get(), encoding: .utf8)
    }
}

private final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
