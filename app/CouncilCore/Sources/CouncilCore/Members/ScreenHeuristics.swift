import Foundation

/// Screen-text fallbacks for states the CLIs do not report through hooks: the dialogs they show before a session
/// exists (folder trust, hook trust, login, mode acknowledgements). Hooks stay the primary signal; these only
/// classify a terminal that has printed something and then gone quiet while no start event arrived.
public enum ScreenHeuristics {
    public struct Dialog: Equatable, Sendable {
        public let reason: String
        public let hint: String
    }

    /// Ordered so the most specific match wins.
    static let dialogs: [(needles: [String], dialog: Dialog)] = [
        (["Yes, I trust this folder"], Dialog(reason: "folder trust dialog", hint: "Choose “Yes, I trust this folder” in the terminal")),
        (["Quick safety check"], Dialog(reason: "folder trust dialog", hint: "Choose “Yes, I trust this folder” in the terminal")),
        (["Bypass Permissions mode", "Yes, I accept"], Dialog(reason: "bypass-permissions acknowledgement", hint: "Choose “Yes, I accept” in the terminal")),
        (["Hooks need review"], Dialog(reason: "hooks review dialog", hint: "Press t to trust the hooks in the terminal")),
        (["Trust all and continue"], Dialog(reason: "hooks review dialog", hint: "Press t to trust the hooks in the terminal")),
        (["Select login method"], Dialog(reason: "login required", hint: "Log in from the terminal")),
        (["Paste code here"], Dialog(reason: "login required", hint: "Finish the login in the terminal")),
        (["Sign in with ChatGPT"], Dialog(reason: "login required", hint: "Log in from the terminal")),
        (["Do you trust the files in this folder"], Dialog(reason: "folder trust dialog", hint: "Confirm the folder in the terminal")),
        (["Trust this project"], Dialog(reason: "project trust prompt", hint: "Answer the trust prompt in the terminal")),
        // kimi. The app pre-writes the folder's trust bucket so this should never appear; if it does, the
        // bucket could not be written, and the member is waiting on a menu nobody may answer for it.
        (["Trust this folder?"], Dialog(reason: "folder trust dialog", hint: "Choose “Trust this folder” in the terminal")),
        // kimi. The app pre-writes the folder's trust bucket so this should never appear; if it does, the
        // bucket could not be written, and the member is waiting on a menu nobody may answer for it.
        (["Do you trust the contents of this directory"],
         Dialog(reason: "folder trust dialog", hint: "Choose “Yes, continue” in the terminal")),
    ]

    /// The screen as one run of words, for needle matching.
    ///
    /// Control characters become spaces here rather than vanishing, and runs of whitespace collapse. A TUI that
    /// lays a paragraph out by moving the cursor leaves the cells between words unwritten, and those arrive as
    /// NUL: deleting them glues "Do you trust" into "Doyoutrust", so a needle with spaces in it never matches
    /// however carefully it was copied off the screen. Rows are joined for the same reason — a dialog's question
    /// can wrap.
    static func matchable(_ lines: [String]) -> String {
        var out = ""
        var pendingSpace = false
        for scalar in lines.joined(separator: " ").unicodeScalars {
            let v = scalar.value
            if v < 0x20 || v == 0x7F || scalar == " " || v == 0xA0 { pendingSpace = true; continue }
            if pendingSpace, !out.isEmpty { out.append(" ") }
            pendingSpace = false
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// The blocking dialog visible on screen, if any. `lines` are the visible rows, oldest first.
    public static func blockingDialog(in lines: [String]) -> Dialog? {
        let screen = matchable(lines)
        for entry in dialogs where entry.needles.allSatisfy({ screen.localizedCaseInsensitiveContains($0) }) {
            return entry.dialog
        }
        return nil
    }

    /// Readiness by a settled screen: the terminal has drawn something, its visible text has not changed for
    /// `stableFor`, no dialog is showing, and at least `graceAfterLaunch` has passed so a slow CLI is not declared
    /// ready while still booting. Text stability rather than byte silence, because idle TUIs keep redrawing
    /// (cursor blink, shimmering tips) without changing what they say.
    public static func looksReady(lines: [String], outputBytes: Int, screenStableFor: TimeInterval, launchedAt: Date,
                                  now: Date = Date(), stableFor: TimeInterval = 3, graceAfterLaunch: TimeInterval = 5) -> Bool {
        guard outputBytes > 0, !lines.allSatisfy(\.isEmpty) else { return false }
        guard now.timeIntervalSince(launchedAt) >= graceAfterLaunch, screenStableFor >= stableFor else { return false }
        return blockingDialog(in: lines) == nil
    }

    /// The screen reduced to its words: braille, box-drawing and block glyphs (spinners, twinkling decorations,
    /// borders, block cursors), control characters and whitespace runs are removed and empty lines dropped, so
    /// two frames of an idle TUI's decoration animation compare equal.
    public static func normalized(_ lines: [String]) -> [String] {
        lines.compactMap { line -> String? in
            var out = ""
            var pendingSpace = false
            for scalar in line.unicodeScalars {
                let v = scalar.value
                let decoration = (0x2800...0x28FF).contains(v) || (0x2500...0x259F).contains(v) || v < 0x20 || v == 0x7F
                if decoration { continue }
                if scalar == " " || v == 0xA0 { pendingSpace = true; continue }
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            }
            return out.isEmpty ? nil : out
        }
    }

    /// chat.py `trailing_error`: the visible screen ends on an error line with nothing substantial after it.
    /// pi prints `Error: ...` and stops; the agent then sits there until someone nudges it. Anything longer
    /// than a short line counts as real content and means the member moved on — except throughput footers,
    /// which some CLIs keep printing under the error.
    public static func trailingError(in lines: [String]) -> String? {
        let meaningful = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for line in meaningful.suffix(6).reversed() {
            if isErrorLine(line) { return line }
            if line.count > 40, !isStatusFooter(line) { return nil }
        }
        return nil
    }

    private static func isErrorLine(_ line: String) -> Bool {
        if line.contains("Corrupted thought signature") { return true }
        for prefix in ["Error", "error", "✗", "⚠"] where line.hasPrefix(prefix) {
            let rest = line.dropFirst(prefix.count)
            if rest.first == ":" || rest.first == " " || rest.isEmpty { return true }
        }
        return false
    }

    /// A model's own throughput line ("… 42 TPS · 0.4s TTFT · 12k ctx") is not content.
    private static func isStatusFooter(_ line: String) -> Bool {
        ["TPS", "TTFT", "ctx"].contains { line.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
    }

    /// True when `new` differs from `old` only cosmetically: at most one line changed (a trailing empty line may
    /// appear or vanish), and that line changed in at most `maxChars` characters. Idle TUIs toggle a block cursor
    /// or rotate a spinner glyph; neither means the CLI is doing anything.
    public static func isCosmeticChange(from old: [String], to new: [String], maxChars: Int = 2) -> Bool {
        var a = old, b = new
        guard abs(a.count - b.count) <= 1 else { return false }
        while a.count < b.count { a.append("") }
        while b.count < a.count { b.append("") }
        var changed: (String, String)?
        for (x, y) in zip(a, b) where x != y {
            if changed != nil { return false }
            changed = (x, y)
        }
        guard let (x, y) = changed else { return true }
        let xs = Array(x), ys = Array(y)
        var prefix = 0
        while prefix < xs.count, prefix < ys.count, xs[prefix] == ys[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < xs.count - prefix, suffix < ys.count - prefix, xs[xs.count - 1 - suffix] == ys[ys.count - 1 - suffix] { suffix += 1 }
        return max(xs.count, ys.count) - prefix - suffix <= maxChars
    }
}
