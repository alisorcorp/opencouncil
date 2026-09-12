import Foundation

/// The prompts a member sees: the opening briefing, the resume note, and the delivery wrapper around new chat
/// messages. The templates are byte-for-byte the ones in `chat.py`, so a member briefed by the app and a member
/// briefed by the CLI read exactly the same instructions (`BriefingTests` fails if chat.py drifts).
/// Substitution follows Python's `str.format`: `{key}` is replaced, and the templates contain no literal braces.
public enum Briefing {
    public static let briefingTemplate = """
    You are "{name}" in a live council chat with a human ("user") and other AI agents ({others}). The human types in a shared chat window; new messages are delivered to you here as prompts.

    How it works:
    - Your terminal is private. The chat only sees what you post with:
        council post --as {name} 'your message'
      For anything long, or containing an apostrophe, $, backticks or backslashes, use the heredoc form:
        council post --as {name} - <<'COUNCIL'
        your message, however it is punctuated
        COUNCIL
      In double quotes the shell expands $variables and eats backslashes, which has silently rewritten messages.
    - Address someone with @{others_at} or @user. A message with @mentions is delivered to them and they will reply. A message without mentions is visible to everyone but triggers no reply.
    - Keep messages chat-length: a few sentences, occasionally a short list. Take positions; disagree when you disagree. Don't @mention just to be polite, and stop once an exchange is resolved.
    - Use your tools on the working directory ({cwd}) when the conversation needs facts; say what you actually checked.
    - When the user wraps up, post one final message with your conclusion and no mentions.
    - `council log` prints the whole chat so far.{resume}

    Post a one-line hello now to confirm you're connected.
    """

    public static let resumeTemplate = """

    - This chat resumes an earlier conversation (the session was restarted). Before your hello, read {cdir}/transcript.md so you know what was discussed and decided; don't summarize it unless asked.
    """

    public static let resumedNoteTemplate = """
    The council chat "{title}" has resumed after a restart and you are still "{name}". The log is {cdir}/transcript.md; `council post --as {name} '...'` still posts to it. Nothing to do now: wait for the next message.
    """

    public static let deliveryTemplate = """
    New council chat messages (you are "{name}"):

    {lines}

    Reply by posting, with the heredoc so an apostrophe cannot break the command:
        council post --as {name} - <<'COUNCIL'
        your message, however it is punctuated
        COUNCIL
    Only posted messages are seen; at most one message; post nothing if you have nothing to add.{wrap}
    """

    /// R11a: the one nudge each member gets after everyone has answered the user. It is app-only — the CLI has
    /// no reaction pass — so it has no counterpart in chat.py. The instruction to stay quiet is the point: a pass
    /// that produced three "I agree" posts would be worse than none.
    public static let reactionTemplate = """
    The others have now replied (you are "{name}"):

    {lines}

    Reply only if you have something to add: a disagreement, a correction, or a point nobody made. Post with the
    heredoc so an apostrophe cannot break the command:
        council post --as {name} - <<'COUNCIL'
        your message, however it is punctuated
        COUNCIL
    Post nothing if you agree or would only be repeating yourself; at most one message.
    """

    public static let wrapNote = "\n\nThe user is wrapping up: post one final message with your conclusion, and do not @mention anyone."

    /// App-only: the header on a delivery being sent a second time because the app stopped while the member
    /// was answering the first one. The CLI cannot lose a delivery this way, so it has no equivalent.
    public static let interruptedNote =
        "The app restarted while you were answering this. Answer it now if it still needs one.\n\n"

    /// chat.py `Deliverer.RETRY_PROMPT`: what a member is told after its request died on an API error.
    public static let retryTemplate =
        "Your previous request failed with an API error. Try again now, and post your reply with " +
        "`council post --as {name} - <<'COUNCIL'`, ending with a COUNCIL line, when done."

    /// Extra bullet the app adds to the briefing: its members run with `COUNCIL_AS` pinned, so `council post`
    /// in this terminal can only speak as this member. The CLI has no equivalent line because it does not pin.
    public static let pinnedIdentityNote =
        "\n- This terminal is pinned to you: `council post` here always posts as \"{name}\", whatever `--as` says."

    /// The opening briefing. `resumeDirectory` adds the "read the transcript first" bullet for a resumed chat.
    public static func briefing(name: String, members: [String], cwd: String, resumeDirectory: URL? = nil,
                                pinnedIdentity: Bool = true) -> String {
        let others = members.filter { $0 != name }
        var resume = ""
        if let dir = resumeDirectory { resume += fill(resumeTemplate, ["cdir": dir.path]) }
        if pinnedIdentity { resume += fill(pinnedIdentityNote, ["name": name]) }
        return fill(briefingTemplate, [
            "name": name,
            "others": others.joined(separator: ", "),
            "others_at": others.joined(separator: " @"),
            "cwd": cwd,
            "resume": resume,
        ])
    }

    public static func resumedNote(title: String, name: String, directory: URL) -> String {
        fill(resumedNoteTemplate, ["title": title, "name": name, "cdir": directory.path])
    }

    /// One delivery: the new messages a member has not seen, wrapped in the posting instructions.
    public static func delivery(name: String, messages: [Message], wrapping: Bool = false) -> String {
        fill(deliveryTemplate, [
            "name": name,
            "lines": formatLines(messages, me: name),
            "wrap": wrapping ? wrapNote : "",
        ])
    }

    /// One reaction pass: what the other members said since the user's message.
    public static func reaction(name: String, messages: [Message]) -> String {
        fill(reactionTemplate, ["name": name, "lines": formatLines(messages, me: name)])
    }

    /// `format_lines` in chat.py: `[sender → @mentions] text`, notes skipped, the member's own name shown as "you".
    /// The nudge after an API error, worded exactly as the CLI words it.
    public static func retryPrompt(name: String) -> String { fill(retryTemplate, ["name": name]) }

    public static func formatLines(_ messages: [Message], me: String) -> String {
        messages.filter { !$0.isNote }.map { m in
            let who = m.sender == me ? "you" : m.sender
            let to = m.to.isEmpty ? "" : " → " + m.to.map { "@" + $0 }.joined(separator: " ")
            return "[\(who)\(to)] \(m.text)"
        }.joined(separator: "\n\n")
    }

    static func fill(_ template: String, _ values: [String: String]) -> String {
        var out = template
        for (key, value) in values { out = out.replacingOccurrences(of: "{\(key)}", with: value) }
        return out
    }
}
