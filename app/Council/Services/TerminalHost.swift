import AppKit
import SwiftTerm
import CouncilCore

/// One member's terminal: SwiftTerm's local-process view plus what the app needs on top. Every SwiftTerm call
/// the app makes goes through here, so a library upgrade touches one file.
///
/// - User input (keys, IME text, mouse reports) is dropped, never queued, while `inputLocked` is set, so a
///   delivery the app pastes cannot interleave with keystrokes. Replies the emulator owes the child (device
///   attributes, cursor position, focus reports) bypass the lock; dropping those would hang a TUI.
/// - `paste` writes the text as one bracketed-paste frame when the child has enabled bracketed paste and,
///   after a short pause, a carriage return, so multi-line text arrives as a single submission.
/// - Output is timestamped for quiescence detection; `recentLines` reads the visible screen for the
///   error-line fallback.
@MainActor
final class TerminalHost: LocalProcessTerminalView {
    let member: String
    private(set) var plan: LaunchPlan?
    /// Drop user input while set. The app's own writes are unaffected.
    var inputLocked = false
    private(set) var lastOutputAt: Date?
    private(set) var outputBytes = 0
    /// Exit status once the child is gone: the exit code, or 128 + signal number.
    private(set) var exitStatus: Int32?
    private(set) var hasExited = false
    var onExit: ((TerminalHost, Int32?) -> Void)?

    static let pasteStart: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]   // ESC [ 200 ~
    static let pasteEnd: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]     // ESC [ 201 ~
    /// Hosts get a real size before any container shows them, so the pty starts with a sane grid.
    static let defaultFrame = CGRect(x: 0, y: 0, width: 960, height: 600)

    init(member: String, frame: CGRect = TerminalHost.defaultFrame) {
        self.member = member
        super.init(frame: frame)
        font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        bellStyle = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("TerminalHost is created in code") }

    var isRunning: Bool { process.running }
    var pid: pid_t { process.shellPid }

    func launch(_ plan: LaunchPlan) {
        self.plan = plan
        hasExited = false
        exitStatus = nil
        startProcess(executable: plan.executable.path, args: plan.arguments, environment: plan.environmentList,
                     execName: nil, currentDirectory: plan.currentDirectory.path)
    }

    /// SIGTERM to the child. SwiftTerm stops watching the process on `terminate`, so the exit is recorded here.
    func stop() {
        guard !hasExited else { return }
        let wasRunning = isRunning
        terminate()
        hasExited = true
        exitStatus = wasRunning ? 128 + SIGTERM : exitStatus
        onExit?(self, exitStatus)
    }

    /// Bytes from the app itself; never subject to the input lock.
    func write(_ bytes: [UInt8]) {
        guard process.running else { return }
        process.send(data: bytes[...])
    }

    func write(_ text: String) { write(Array(text.utf8)) }

    /// Delivers `text` as one paste and, when `submit`, presses Enter after `submitDelay` so the TUI has
    /// consumed the paste before it sees the key. Callers manage `inputLocked` around the whole delivery.
    func paste(_ text: String, submit: Bool = true, submitDelay: Duration = .milliseconds(150)) async {
        var bytes: [UInt8] = []
        let bracketed = terminal.bracketedPasteMode
        if bracketed { bytes += Self.pasteStart }
        bytes += Array(text.replacingOccurrences(of: "\r\n", with: "\n").utf8)
        if bracketed { bytes += Self.pasteEnd }
        write(bytes)
        guard submit else { return }
        try? await Task.sleep(for: submitDelay)
        write([0x0d])
    }

    /// True when the child has printed nothing for `seconds` (and has printed something at all).
    func isQuiescent(for seconds: TimeInterval, now: Date = Date()) -> Bool {
        guard let last = lastOutputAt else { return false }
        return now.timeIntervalSince(last) >= seconds
    }

    /// The last non-empty lines of the visible screen, oldest first.
    func recentLines(_ count: Int = 20) -> [String] {
        let t = getTerminal()
        var lines: [String] = []
        for row in 0..<t.rows {
            lines.append(t.getLine(row: row)?.translateToString(trimRight: true) ?? "")
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return Array(lines.suffix(count))
    }

    // MARK: SwiftTerm overrides

    /// User input arrives here from `TerminalView.send(data:)` (key presses, pasted text, mouse reports).
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if inputLocked { return }
        super.send(source: source, data: data)
    }

    /// The emulator's own replies to the child (DA, DSR, focus events) must never be dropped.
    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        process.send(data: data)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        lastOutputAt = Date()
        outputBytes += slice.count
        super.dataReceived(slice: slice)
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        guard !hasExited else { return }
        hasExited = true
        exitStatus = exitCode.map(Self.decodeWaitStatus)
        super.processTerminated(source, exitCode: exitCode)
        onExit?(self, exitStatus)
    }

    /// `LocalProcess` hands over the raw `waitpid` status word.
    nonisolated static func decodeWaitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}
