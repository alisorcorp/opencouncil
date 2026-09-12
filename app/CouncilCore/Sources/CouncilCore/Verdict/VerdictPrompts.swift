import Foundation

/// The verdict prompts, ported verbatim from council.py so a run started in the app reads exactly as one
/// started from the CLI. `VerdictPromptsTests` compares these with the Python source and fails on drift.
///
/// The CLI hands a backend a system prompt and a user prompt separately. The app's members are interactive
/// terminals with no system-prompt channel, so the two are pasted as one message that ends with the
/// instruction to post the answer back — the same shape a chat delivery has.
public enum VerdictPrompts {
    // MARK: templates (council.py)

    public static let memberSystem = """
    You are one member of a council of independent AI models. Every member receives the same question and answers without seeing the others. A moderator will then compare all the answers and produce a merged verdict, so be specific and commit to positions.

    Rules:
    - Answer the question directly first, then give your reasoning.
    - Prefer concrete facts, numbers, trade-offs and recommendations over generic advice.
    - Flag what you are unsure of and say what would resolve it. Do not invent facts.
    - If the question is flawed or rests on a false premise, say so.
    - Write in Markdown. Aim for {length} unless the task clearly needs more.
    - Do not mention the council, the moderator, or other members.
    """

    public static let critiquePrompt = """
    This is round {rnd} of {rounds}. Below are the other council members' previous answers to the same question (anonymized), followed by your own previous answer.

    1. Under "## Critique", go through each response: what it gets right, what it gets wrong or misses. Be direct; name factual errors.
    2. Under "## Revised answer", give your complete final answer to the original question. Change your position only where the arguments warrant it. Do not converge just to agree; disagreement backed by reasons is more useful than consensus without them.

    # Original question

    {question}

    {peers}

    # Your previous answer

    {own}
    """

    public static let moderatorSystem = """
    You are the moderator of a council of AI models. Each member answered the same question independently{rounds_note}. Your job is to produce one merged verdict and to name the disagreements plainly. Do not add claims no member made unless you label them as your own view. Do not soften disagreements into vague consensus.

    Write in Markdown with exactly these sections:

    ## Verdict
    The single best answer to the question, merged from the strongest material across members. Direct, complete and actionable; this is what the reader will act on.

    ## Where they agree
    Bullets. Only substantive points.

    ## Where they disagree
    One bullet per disagreement, formatted **topic** — what each side says (cite members by their label), then which side has the better argument and why. If a member is factually wrong, say so explicitly.

    ## Member notes
    One line per member: what it uniquely contributed, and anything it got wrong.

    ## Consensus
    A line of the exact form `Score: NN/100` followed by one sentence explaining it. 100 means all members give substantively the same answer; around 50 means they agree on the core but differ on important specifics; below 30 means fundamentally different answers. A low score signals the reader should weigh the disagreements themselves.
    """

    public static let moderatorPrompt = """
    # Question put to the council

    {question}

    # Member answers{round_note}

    {answers}

    Produce the verdict now.
    """

    /// App-only: how a member in a terminal returns its answer. The CLI collects stdout instead.
    /// The heredoc is the only form shown here: a verdict answer is long prose, and a double-quoted one hands
    /// the shell every `$`, backtick and backslash in it before `council post` sees a character.
    public static let postInstruction =
        "\n\nWhen you are done, post your complete answer with:\n"
        + "council post --as {name} - <<'COUNCIL'\nyour answer, however it is punctuated\nCOUNCIL\n"
        + "Post exactly one message, and put the whole answer in it."

    // MARK: assembly (council.py `member_prompt` / `moderator_prompt`)

    /// The system half for a member, with the run's requested length filled in.
    public static func memberSystem(length: String) -> String {
        fill(memberSystem, ["length": length])
    }

    /// Round 1 is the question itself; later rounds are the critique prompt over the previous round.
    /// `peerAnswers` is in the order the peers should be shown, already anonymised by the caller.
    public static func memberUser(round: Int, rounds: Int, question: String,
                                  peerAnswers: [String], ownPrevious: String?) -> String {
        guard round > 1 else { return question }
        let peers = peerAnswers.enumerated()
            .map { i, answer in "# Response \(i + 1)\n\n\(answer.isEmpty ? "(no answer produced)" : answer)" }
            .joined(separator: "\n\n")
        return fill(critiquePrompt, [
            "rnd": "\(round)", "rounds": "\(rounds)", "question": question,
            "peers": peers, "own": (ownPrevious?.isEmpty == false ? ownPrevious! : "(none)"),
        ])
    }

    /// One pasted message: what the CLI would send as system and user, plus how to post the answer back.
    public static func memberPaste(name: String, round: Int, rounds: Int, length: String, question: String,
                                   peerAnswers: [String], ownPrevious: String?) -> String {
        memberSystem(length: length) + "\n\n"
            + memberUser(round: round, rounds: rounds, question: question,
                         peerAnswers: peerAnswers, ownPrevious: ownPrevious)
            + fill(postInstruction, ["name": name])
    }

    public static func moderatorSystem(rounds: Int) -> String {
        let note = rounds > 1 ? ", then critiqued each other's answers over \(rounds) rounds" : ""
        return fill(moderatorSystem, ["rounds_note": note])
    }

    /// `answers` is in run order: the label each member is shown under, and its final answer — or nil when it
    /// did not produce one, which the moderator is told about rather than left to guess.
    public static func moderatorUser(question: String, rounds: Int,
                                     answers: [(label: String, answer: String?, error: String?)]) -> String {
        let body = answers.map { entry in
            let text = entry.answer ?? "(no answer: \(entry.error ?? "member did not finish"))"
            return "## \(entry.label)\n\n\(text)"
        }.joined(separator: "\n\n")
        return fill(moderatorPrompt, [
            "question": question,
            "round_note": rounds > 1 ? " (final round \(rounds) of \(rounds))" : "",
            "answers": body,
        ])
    }

    public static func moderatorPaste(name: String, question: String, rounds: Int,
                                      answers: [(label: String, answer: String?, error: String?)]) -> String {
        moderatorSystem(rounds: rounds) + "\n\n"
            + moderatorUser(question: question, rounds: rounds, answers: answers)
            + fill(postInstruction, ["name": name])
    }

    /// The order peers are shown in for a critique round: stable for a given member and round, so a prompt is
    /// reproducible, and different between members, so nobody's answer is always first.
    ///
    /// The CLI seeds Python's Mersenne Twister with `"<name>:<round>"`; that generator is not reproducible in
    /// Swift, so this uses its own stable hash. The property that matters — a fixed, unbiased order per member
    /// per round — holds either way, and the order of peers in a critique carries no meaning of its own.
    public static func peerOrder(_ peers: [String], for member: String, round: Int) -> [String] {
        var keyed: [(key: UInt64, name: String)] = []
        for peer in peers {
            keyed.append((key: stableHash(member + ":\(round):" + peer), name: peer))
        }
        keyed.sort { a, b in a.key == b.key ? a.name < b.name : a.key < b.key }
        return keyed.map(\.name)
    }

    /// FNV-1a, so the order does not move between releases the way `Hasher` (seeded per process) would.
    static func stableHash(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    static func fill(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }
}
