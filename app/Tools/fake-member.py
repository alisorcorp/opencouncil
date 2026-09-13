#!/usr/bin/env python3
"""A stand-in for Claude Code / Codex / pi inside the app's embedded terminals.

Behaves like a TUI: enables bracketed paste, shows a prompt, reads what the app pastes, and reports state the
way the real CLIs do through their hooks (by calling `council event`), then replies with `council post`.
No model calls, so the delivery, detection and ledger machinery can be exercised end to end for free.

Environment knobs (all optional):
  FAKE_SLOW_START=<s>   sleep before announcing SessionStart
  FAKE_DELAY=<s>        thinking time before the reply (default 0.5)
  FAKE_NO_POST=1        finish the turn without posting ("nothing to add")
  FAKE_NO_POST_TURNS=<n> forget to post for the first n turns, then post normally (a model that wrote its
                        answer and never ran the tool; the app nudges it and this is what answering looks like)
  FAKE_BLOCK=1          raise a permission prompt and wait for the user to press y
  FAKE_CRASH=1          exit(1) right after accepting the first prompt
  FAKE_MENTION=<name>   include @<name> in the reply (exercises routing)
  FAKE_SILENT=1         accept the prompt but never finish the turn (stall detection)
  FAKE_DEAF=1           read the paste and report nothing at all (the app must re-paste, then give up)
  FAKE_DEAF_TURN=<n>    on the first launch only, go deaf from turn n (1 = the briefing, 2 = the first
                        question after it), so a Retry can be seen to recover the member and re-ask it
  FAKE_NO_START=1       never announce SessionStart (readiness must come from quiescence, like Codex)
  FAKE_TRUST_PROMPT=1   open on Codex's directory-trust dialog and announce nothing until it is answered,
                        recording whatever answers it (the app used to answer it by accident)
  FAKE_PERMISSION=1     stop mid-turn on an approval prompt, announced with the shared PermissionRequest
                        hook, and record whatever answers it — what every member now does when it wants to
                        run a command, since members no longer start with their CLI's stop-asking flag
  FAKE_RESUME_FAILS=1   exit at once when asked to resume, the way a CLI does when the session is gone
  FAKE_NO_SCORE=1       moderate without a `Score: NN/100` line (the app must cope with an unscored verdict)
  FAKE_UNREADABLE=1     answer by writing a record straight into the log that no strict decoder will take:
                        complete, attributed, and unreadable — what an older `council post` left behind when
                        the shell had eaten half a character
  FAKE_CHURN=<hz>       while thinking, repaint the screen this many times a second the way a real TUI does
                        (Codex redraws its whole frame the entire time it works). Costs the app terminal
                        parsing and view invalidation for the length of FAKE_DELAY, which a stand-in that
                        sits silently never does
  FAKE_REPLIES=<path>   a JSON object of {member: [text, ...]}; this member posts them in order instead of
                        the synthetic one-liner, so a replay can carry the payloads a real conversation had
                        (long markdown, mentions) and the app does the rendering and routing it really does
  FAKE_ONLY=<name>      apply every knob above to that member only; the others behave normally
Ignores unknown arguments (the app passes the real CLI's flags).
"""
import json, os, shutil, subprocess, sys, termios, time, tty, uuid

NAME = os.environ.get("COUNCIL_AS", "fake")
# Every member of a run is this same script with the same environment, so a scenario about one member
# misbehaving needs a way to say which: FAKE_ONLY names it, and everybody else drops the knobs.
if os.environ.get("FAKE_ONLY", NAME) != NAME:
    for key in [k for k in os.environ if k.startswith("FAKE_") and k != "FAKE_ONLY"]:
        del os.environ[key]
CHAT = os.environ.get("COUNCIL_CHAT", "")
COUNCIL = os.environ.get("COUNCIL_CLI") or shutil.which("council") or "council"
SESSION_ID = None
for i, a in enumerate(sys.argv):
    if a in ("--session-id", "--resume") and i + 1 < len(sys.argv):
        SESSION_ID = sys.argv[i + 1]
SESSION_ID = SESSION_ID or str(uuid.uuid4())
RESUMED = "--resume" in sys.argv or ("resume" in sys.argv[1:2])
# FAKE_DEAF_TURN goes deaf from turn n, but only until this member has been launched a second time. The
# marker outlives the process, so Retry — which replaces the terminal — gets a member that answers again, and
# both the recovery and the re-asking of whatever it dropped are observable.
DEAF_TURN = int(os.environ.get("FAKE_DEAF_TURN", "0"))
NO_POST_TURNS = int(os.environ.get("FAKE_NO_POST_TURNS", "0"))
DEAF_MARKER = os.path.join(CHAT, f".fake-deaf-{NAME}") if CHAT else ""
# Anything sent to the trust dialog is written here. Its existence is the scenario's evidence that something
# answered a security prompt, which is precisely what the app must never do.
TRUST_MARKER = os.path.join(CHAT, f".fake-trust-{NAME}") if CHAT else ""
PERMISSION_MARKER = os.path.join(CHAT, f".fake-permission-{NAME}") if CHAT else ""
FIRST_LAUNCH = False
if DEAF_TURN and DEAF_MARKER:
    FIRST_LAUNCH = not os.path.exists(DEAF_MARKER)
    if FIRST_LAUNCH:
        open(DEAF_MARKER, "w").close()

def out(s: str) -> None:
    sys.stdout.write(s.replace("\n", "\r\n"))
    sys.stdout.flush()

def event(hook: str, **payload) -> None:
    payload.update(session_id=SESSION_ID, hook_event_name=hook, cwd=os.getcwd())
    try:
        subprocess.run([COUNCIL, "event", "--backend", "claude", "--hook", hook], input=json.dumps(payload),
                       text=True, capture_output=True, timeout=10)
    except Exception as e:  # noqa: BLE001
        out(f"[fake] event failed: {e}\n")

SCRIPTED: list = []
if os.environ.get("FAKE_REPLIES"):
    try:
        with open(os.environ["FAKE_REPLIES"], encoding="utf-8") as f:
            SCRIPTED = list(json.load(f).get(NAME, []))
    except Exception:
        SCRIPTED = []


def next_scripted_reply():
    """The next payload this member had in the conversation being replayed, or None once they run out."""
    return SCRIPTED.pop(0) if SCRIPTED else None


def think(seconds: float) -> None:
    """Wait the way a working CLI waits. Silently by default; with FAKE_CHURN, redrawing a frame the whole
    time, which is what the app's terminals actually have to keep up with while three members think."""
    hz = float(os.environ.get("FAKE_CHURN", "0") or 0)
    if hz <= 0:
        time.sleep(seconds)
        return
    frames, spin = int(seconds * hz), "|/-\\"
    for i in range(max(frames, 1)):
        rows = "\n".join(f"  {spin[i % 4]} working  line {r:2d} " + "\u2500" * 40 for r in range(20))
        out("\x1b[H\x1b[2J" + rows + "\n")
        time.sleep(1.0 / hz)


def post(text: str) -> None:
    r = subprocess.run([COUNCIL, "post", "--as", NAME, text], text=True, capture_output=True, timeout=20)
    out((r.stdout or r.stderr).strip() + "\n")

def post_unreadable() -> None:
    """Appends a complete record nothing can decode, bypassing `council post` — which sanitises its text now,
    so a damaged line can only come from an older writer or another tool. The app has to show it, attribute it,
    and not mistake the sentence it displays instead for what the member said."""
    raw = ('{"id": %d, "ts": "%s", "from": "%s", "kind": "msg", "text": "an answer that never finished'
           % (time.time_ns(), time.strftime("%Y-%m-%dT%H:%M:%S"), NAME))
    with open(os.path.join(CHAT, "chat.jsonl"), "a") as f:
        f.write(raw + "\n")
    out("[fake] wrote a record the log cannot decode\n")

def read_submission(fd) -> str | None:
    """Reads keys until Enter outside a bracketed paste. Returns the text, or None on Ctrl-C / Ctrl-D."""
    buf = bytearray()
    in_paste = False
    while True:
        b = os.read(fd, 4096)
        if not b:
            return None
        buf += b
        while True:
            if in_paste:
                end = buf.find(b"\x1b[201~")
                if end < 0:
                    break
                text = buf[:end]
                del buf[:end + 6]
                in_paste = False
                pending.extend(text)
                continue
            start = buf.find(b"\x1b[200~")
            if start >= 0 and (start == 0 or b"\r" not in buf[:start] and b"\n" not in buf[:start]):
                pending.extend(buf[:start])
                del buf[:start + 6]
                in_paste = True
                continue
            nl = min([i for i in (buf.find(b"\r"), buf.find(b"\n")) if i >= 0], default=-1)
            if nl < 0:
                pending.extend(buf)
                buf.clear()
                break
            pending.extend(buf[:nl])
            del buf[:nl + 1]
            text = pending.decode("utf-8", "replace")
            pending.clear()
            if "\x03" in text or "\x04" in text:
                return None
            return text

pending = bytearray()

def trust_prompt(fd) -> None:
    """Codex's directory-trust dialog, drawn the way the real one draws it: every word is placed with a cursor
    move, so the cells between the words are never written and reach the app's screen buffer as NUL. Nothing is
    announced while it is up — the real CLI emits no SessionStart until it is answered — and whatever answers it
    is recorded, because the app used to answer it by accident: the Enter that ends a pasted briefing selects
    the highlighted "1. Yes, continue".
    """
    out("\x1b[2J")
    for row, col, word in [(2, 3, "Do"), (2, 6, "you"), (2, 10, "trust"), (2, 16, "the"), (2, 20, "contents"),
                           (2, 29, "of"), (2, 32, "this"), (2, 37, "directory?"),
                           (4, 3, "1."), (4, 6, "Yes,"), (4, 11, "continue"),
                           (6, 3, "2."), (6, 6, "No,"), (6, 10, "exit")]:
        out(f"\x1b[{row};{col}H{word}")
    out("\x1b[8;3H> ")
    answered = bytearray()
    while True:
        k = os.read(fd, 4096)
        if not k:
            continue
        answered += k
        if TRUST_MARKER:
            with open(TRUST_MARKER, "wb") as f:
                f.write(bytes(answered))
        if b"\x03" in k or b"\x04" in k:
            raise SystemExit(130)
        if any(c in k for c in (b"1", b"y", b"Y", b"\r", b"\n")):
            break
    out("\x1b[2J\x1b[H")

def permission_prompt(fd) -> None:
    """An approval prompt mid-turn: what a member does when it wants to run a command and was not started
    with its CLI's stop-asking flag. The announcement is the shared `PermissionRequest` hook, which the app
    subscribes to on every backend and turns into a `needs attention` card.

    Whatever answers the prompt is recorded. Nothing the app sends may answer it: a delivery it re-pastes
    while this is up would end in a Return, and a Return here runs the command. The trust dialog taught that
    lesson before a member could start; this is the same lesson once one is running, and the command on the
    other side of it is the user's files.
    """
    event("PermissionRequest", tool_name="Bash", tool_input={"command": "rm -rf ."})
    out("\nBash wants to run: rm -rf .\n  1. Allow   2. Deny\n> ")
    answered = bytearray()
    while True:
        k = os.read(fd, 4096)
        if not k:
            continue
        answered += k
        if PERMISSION_MARKER:
            with open(PERMISSION_MARKER, "wb") as f:
                f.write(bytes(answered))
        if b"\x03" in k or b"\x04" in k:
            raise SystemExit(130)
        # Only an explicit allow gets past this; a Return does not, so a scenario in which nobody answers
        # stays blocked until the harness gives up, which is the point of it.
        if b"1" in k or b"y" in k or b"Y" in k:
            break
    event("Notification", notification_type="auth_success", message="allowed")


def main() -> int:
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    tty.setcbreak(fd)
    out("\x1b[?2004h")                      # bracketed paste on, like a real TUI
    try:
        if RESUMED and os.environ.get("FAKE_RESUME_FAILS"):
            out("No conversation found with that session ID\n")
            return 1
        if os.environ.get("FAKE_TRUST_PROMPT"):
            trust_prompt(fd)
        if os.environ.get("FAKE_SLOW_START"):
            time.sleep(float(os.environ["FAKE_SLOW_START"]))
        out(f"\x1b[1mfake member\x1b[0m {NAME} · session {SESSION_ID[:8]}{' (resumed)' if RESUMED else ''}\n")
        out(f"chat {CHAT or '(none)'}\n\n> ")
        if not os.environ.get("FAKE_NO_START"):
            event("SessionStart", source="resume" if RESUMED else "startup")
        turn = 0
        while True:
            text = read_submission(fd)
            if text is None:
                break
            if not text.strip():
                out("> ")
                continue
            turn += 1
            lines = text.split("\n")
            out(f"\x1b[2m[received {len(lines)} line(s)]\x1b[0m\n")
            if os.environ.get("FAKE_DEAF") or (FIRST_LAUNCH and turn >= DEAF_TURN):
                out("> ")           # no UserPromptSubmit: as far as the app can tell, nothing arrived
                continue
            event("UserPromptSubmit", prompt=text[:500])
            if os.environ.get("FAKE_CRASH"):
                out("[fake] crashing on purpose\n")
                return 1
            if os.environ.get("FAKE_SILENT"):
                out("[fake] going silent\n> ")
                continue
            if os.environ.get("FAKE_PERMISSION"):
                permission_prompt(fd)
            if os.environ.get("FAKE_BLOCK"):
                event("Notification", notification_type="permission_prompt", message="fake needs your permission")
                out("permission needed: press y to allow\n")
                while True:
                    k = os.read(fd, 1)
                    if k in (b"y", b"Y"):
                        break
                    if k in (b"\x03", b"\x04"):
                        return 130
                event("Notification", notification_type="auth_success", message="allowed")
            event("PreToolUse", tool_name="Read", tool_input={"file_path": os.path.join(os.getcwd(), "chat.py")})
            think(float(os.environ.get("FAKE_DELAY", "0.5")))
            event("PostToolUse", tool_name="Read", tool_input={"file_path": os.path.join(os.getcwd(), "chat.py")})
            if os.environ.get("FAKE_NO_POST") or turn <= NO_POST_TURNS:
                out("[fake] nothing to add\n")
                event("Stop", last_assistant_message="(nothing to add)", stop_reason="end_turn")
            else:
                first = lines[0].strip()
                scripted = next_scripted_reply()
                # A member's prompt (DELIVERY) starts with a header line; quote the first chat line instead.
                quoted = next((l for l in lines if l.startswith("[")), first)
                mention = f" @{os.environ['FAKE_MENTION']}" if os.environ.get("FAKE_MENTION") else ""
                reply = scripted or f"{NAME} #{turn}: got {len(lines)} line(s), first: {quoted[:80]}{mention}"
                if "Produce the verdict now." in text:
                    # The moderator's prompt: answer in the shape council.py's parse_score expects.
                    score = "" if os.environ.get("FAKE_NO_SCORE") else "\n\n## Consensus\nScore: 73/100 broadly agreed."
                    reply = f"## Verdict\n\n{NAME} merged {len(lines)} line(s) of answers.{score}"
                event("PreToolUse", tool_name="Bash", tool_input={"command": f"council post --as {NAME} ..."})
                if os.environ.get("FAKE_UNREADABLE"):
                    post_unreadable()
                else:
                    post(reply)
                event("PostToolUse", tool_name="Bash", tool_input={"command": "council post"})
                event("Stop", last_assistant_message=reply, stop_reason="end_turn")
            out("> ")
        event("SessionEnd", reason="exit")
        return 0
    finally:
        out("\x1b[?2004l")
        termios.tcsetattr(fd, termios.TCSADRAIN, old)

if __name__ == "__main__":
    sys.exit(main())
