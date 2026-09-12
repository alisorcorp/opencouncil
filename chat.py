#!/usr/bin/env python3
"""council chat — a live group chat between you, Claude Code, Codex and an OpenRouter model.

Layout (one herdr tab): the chat on the left, the members stacked on the right.
You type in the chat; every member receives it. Members reply by posting to the
shared log, can @mention each other, and keep talking until you wrap it up.

    council chat                     # start (from inside herdr)
    council post --as codex '...'    # what the members run to speak
    council log                      # print the chat so far
"""
from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import fcntl
import json
import os
import pathlib
import queue
import re
import shutil
import socket
import subprocess
import sys
import textwrap
import threading
import time

import council as C

CHATS = C.HERE / "chats"
USER = "user"
SYSTEM = "system"
# What a member runs with when council.toml does not say. Members are asked to confirm anything risky; see
# the note above [members.claude] in council.toml for how to let one run unattended instead. Mirrored in
# ChatSessionFactory.defaultChatArgs, and a test holds the two together.
DEFAULT_CHAT_ARGS = {"claude": ["--permission-mode", "acceptEdits", "--allow-dangerously-skip-permissions"],
                     "codex": ["--sandbox", "workspace-write", "-a", "on-request"],
                     "kimi": ["--yolo"],
                     "pi": ["--no-session", "--offline"]}
WRAP_RE = re.compile(r"\bwrap(?:ping)?\s+(?:it|this|things)?\s*up\b|^/wrap\b", re.I)
MENTION_RE = re.compile(r"@([a-z][a-z0-9_-]*)", re.I)
WHITE = "\033[97m"


# --------------------------------------------------------------------- bus ---
def readable(text: str) -> str:
    """Bytes that were never valid UTF-8 reach argv as lone surrogates (PEP 383) — a shell that ate half a
    multi-byte character while expanding an unquoted $ is the way this happens. json.dumps writes them without
    complaint and every strict decoder rejects the whole line, so the message stays readable here and becomes
    invisible to anything else reading the log. One replacement character per broken half says so instead."""
    return "".join("\ufffd" if 0xD800 <= ord(c) <= 0xDFFF else c for c in text)


class Bus:
    """Append-only chat.jsonl shared by the UI, the members and `council post`."""

    def __init__(self, cdir: pathlib.Path):
        self.dir = pathlib.Path(cdir).resolve()
        self.path = self.dir / "chat.jsonl"
        self.cfg = json.loads((self.dir / "config.json").read_text())
        self.path.touch()

    @property
    def members(self) -> list[str]:
        return self.cfg["order"]

    def mentions(self, text: str) -> list[str]:
        found = []
        for m in MENTION_RE.findall(text):
            m = m.lower()
            if m in ("all", "everyone"):
                found += [x for x in self.members if x not in found]
            elif (m in self.members or m == USER) and m not in found:
                found.append(m)
        return found

    def post(self, sender: str, text: str, kind: str = "msg") -> dict:
        msg = {"id": time.time_ns(), "ts": dt.datetime.now().isoformat(timespec="seconds"),
               "from": sender, "kind": kind, "text": readable(text.rstrip()), "to": self.mentions(text)}
        with open(self.path, "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            f.write(json.dumps(msg) + "\n")
            f.flush()
            fcntl.flock(f, fcntl.LOCK_UN)
        return msg

    def read(self) -> list[dict]:
        msgs = []
        with open(self.path) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        msgs.append(json.loads(line))
                    except ValueError:
                        pass
        return msgs

    def label(self, name: str) -> str:
        if name == USER:
            return "you"
        return self.cfg["members"].get(name, {}).get("label", name)

    def color(self, name: str) -> str:
        if name == USER:
            return WHITE
        if name == SYSTEM:
            return C.GREY
        try:
            return C.PALETTE[self.members.index(name) % len(C.PALETTE)]
        except ValueError:
            return C.GREY


def resolve_chat(arg: str | None) -> pathlib.Path:
    p = arg or os.environ.get("COUNCIL_CHAT") or str(CHATS / "current")
    d = pathlib.Path(p).expanduser()
    if not d.is_absolute() and (CHATS / p).exists():
        d = CHATS / p
    d = d.resolve()
    if not (d / "config.json").exists():
        sys.exit(f"no council chat at {d} (set COUNCIL_CHAT, pass --chat, or start one with `council chat`)")
    return d


# --------------------------------------------------------------- rendering ---
def render(bus: Bus, msg: dict, width: int) -> str:
    name = msg["from"]
    color = bus.color(name)
    ts = msg.get("ts", "")[11:16]
    if msg.get("kind") == "note":
        return f"{C.DIM}{ts}  · {msg['text']}{C.RESET}"
    shown = "you" if name == USER else name
    head = f"{C.DIM}{ts}{C.RESET} {color}{C.BOLD}{shown:<7}{C.RESET} "
    indent = " " * 14
    body = MENTION_RE.sub(lambda m: f"{C.BOLD}@{m.group(1)}{C.RESET}", msg["text"])
    lines = []
    for para in body.split("\n"):
        if not para.strip():
            lines.append("")
            continue
        wrapped = textwrap.wrap(para, width=max(30, width - 14), subsequent_indent="", break_long_words=False) or [""]
        lines += wrapped
    first = lines[0] if lines else ""
    rest = "\n".join(indent + ln for ln in lines[1:])
    return head + first + ("\n" + rest if rest else "")


def transcript(bus: Bus, msgs: list[dict]) -> None:
    out = [f"# Council chat · {bus.cfg['created']}", "",
           f"members: {', '.join(bus.label(m) for m in bus.members)}", f"cwd: {bus.cfg['cwd']}"]
    if bus.cfg.get("resumed"):
        out.append(f"resumed: {', '.join(bus.cfg['resumed'])}")
    out.append("")
    for m in msgs:
        if m.get("kind") == "note":
            out.append(f"_{m['ts'][11:19]} · {m['text']}_\n")
        else:
            who = "**you**" if m["from"] == USER else f"**{m['from']}**"
            out.append(f"{who} · {m['ts'][11:19]}\n\n{m['text']}\n")
    (bus.dir / "transcript.md").write_text("\n".join(out))


# ----------------------------------------------------------------- prompts ---
BRIEFING = """\
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

Post a one-line hello now to confirm you're connected."""

RESUME_BRIEFING = """
- This chat resumes an earlier conversation (the session was restarted). Before your hello, read {cdir}/transcript.md so you know what was discussed and decided; don't summarize it unless asked."""

RESUMED_NOTE = """\
The council chat "{title}" has resumed after a restart and you are still "{name}". The log is {cdir}/transcript.md; you still post to it with `council post --as {name} - <<'COUNCIL'`, ending with a COUNCIL line. Nothing to do now: wait for the next message."""

DELIVERY = """\
New council chat messages (you are "{name}"):

{lines}

Reply by posting, with the heredoc so an apostrophe cannot break the command:
    council post --as {name} - <<'COUNCIL'
    your message, however it is punctuated
    COUNCIL
Only posted messages are seen; at most one message; post nothing if you have nothing to add.{wrap}"""

DELIVERY_PLAIN = """\
{lines}{wrap}"""

WRAP_NOTE = "\n\nThe user is wrapping up: post one final message with your conclusion, and do not @mention anyone."

OR_SYSTEM = """\
You are "{name}" ({label}) in a live council chat with a human ("user") and other AI agents ({others}). New chat messages arrive as user turns, formatted as `[sender → @mentions] text`. Whatever you reply is posted to the chat under your name.

- Address someone with @{others_at} or @user. Messages with @mentions are delivered to them and they will reply; messages without mentions are visible to all but trigger no reply.
- Keep messages chat-length: a few sentences, occasionally a short list. Take positions; disagree when you disagree. Don't @mention just to be polite, and stop once an exchange is resolved.
- You have no tools; if a claim needs checking in the working directory, ask @claude or @codex to check it.
- When the user wraps up, reply with one final conclusion and no mentions.
- Reply with exactly PASS to stay silent."""


def format_lines(bus: Bus, msgs: list[dict], me: str) -> str:
    out = []
    for m in msgs:
        if m.get("kind") == "note":
            continue
        who = "you" if m["from"] == me else m["from"]
        to = " → " + " ".join("@" + t for t in m.get("to", [])) if m.get("to") else ""
        out.append(f"[{who}{to}] {m['text']}")
    return "\n\n".join(out)


def agent_status(agent: str) -> str | None:
    try:
        r = C.herdr("agent", "get", agent)
    except RuntimeError:
        return None
    a = r.get("agent") or r
    return a.get("agent_status") if isinstance(a, dict) else None


def agent_pane(agent: str) -> str | None:
    try:
        r = C.herdr("agent", "get", agent)
        a = r.get("agent") or r
        return a.get("pane_id") if isinstance(a, dict) else None
    except RuntimeError:
        return None


def detection_is_fallback(agent: str) -> bool:
    """herdr has no working/idle rule for some agents (pi today) and reports them idle at all times."""
    try:
        r = subprocess.run(["herdr", "agent", "explain", agent], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False
    return "fallback" in (r.stdout + r.stderr)


def pane_text(pane: str) -> str:
    try:
        r = subprocess.run(["herdr", "pane", "read", pane, "--source", "visible", "--lines", "60"],
                           capture_output=True, text=True, timeout=10)
        return r.stdout
    except (OSError, subprocess.SubprocessError):
        return ""


_FALLBACK: dict[str, bool] = {}


def prompt_agent(agent: str, text: str, timeout_ms: int = 900000, attempts: int = 3) -> str:
    """Submit text to a herdr agent and wait for it to settle. Retries when the paste was swallowed
    (herdr reports agent_prompt_stalled and the agent never went to work). Returns the final status.
    herdr can't see some agents (pi) start working and calls every prompt to them stalled, so for those
    the pane is compared before and after: a paste that changed it landed, and is not sent again."""
    if agent not in _FALLBACK:
        _FALLBACK[agent] = detection_is_fallback(agent)
    watched = agent_pane(agent) if _FALLBACK[agent] else None
    for i in range(attempts):
        before = pane_text(watched) if watched else ""
        try:
            r = C.herdr("agent", "prompt", agent, text, "--wait", "--timeout", str(timeout_ms), timeout=timeout_ms / 1000 + 30)
            a = r.get("agent") or r
            return a.get("agent_status", "idle") if isinstance(a, dict) else "idle"
        except RuntimeError as e:
            msg = str(e)
            if "blocked" in msg:
                return "blocked"
            if "stalled" not in msg:
                raise
            time.sleep(1.5)
            st = agent_status(agent)
            if st == "working":                    # it did take the prompt, herdr just missed the transition
                try:
                    C.herdr("agent", "wait", agent, "--timeout", str(timeout_ms), timeout=timeout_ms / 1000 + 30)
                except RuntimeError:
                    pass
                return "idle"
            if watched and pane_text(watched) != before:
                return "idle"
            time.sleep(2.0 * (i + 1))
    return "stalled"


# ------------------------------------------------------------------ router ---
# ---------------------------------------------------------------- router lock ---
def router_lock_holder(cdir: pathlib.Path) -> dict | None:
    """Who is routing this chat, if anyone. `router.lock` is shared with the macOS app."""
    try:
        h = json.loads((cdir / "router.lock").read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(h, dict) or not h.get("pid"):
        return None
    if h.get("host") and h["host"] != socket.gethostname():
        return h                                    # another machine: cannot check, assume it is running
    try:
        os.kill(int(h["pid"]), 0)
    except ProcessLookupError:
        return None                                 # stale: the router is gone
    except (PermissionError, ValueError, TypeError):
        pass
    return h


def acquire_router_lock(cdir: pathlib.Path) -> None:
    """Take the router lock or exit. Two routers on one chat would prompt every member twice."""
    held = router_lock_holder(cdir)
    if held and held.get("pid") != os.getpid():
        who = "the Open Council app" if held.get("owner") == "app" else "another council chat"
        sys.exit(f"{cdir.name} is already being routed by {who} (pid {held['pid']}). Stop it there first, "
                 f"or remove {cdir / 'router.lock'} if you are sure it is gone.")
    (cdir / "router.lock").write_text(json.dumps(
        {"host": socket.gethostname(), "owner": "cli", "pid": os.getpid(),
         "since": dt.datetime.now().isoformat(timespec="seconds")}, sort_keys=True))


def release_router_lock(cdir: pathlib.Path) -> None:
    """Remove our own lock; never someone else's."""
    held = router_lock_holder(cdir)
    if held and held.get("pid") == os.getpid():
        try:
            (cdir / "router.lock").unlink()
        except OSError:
            pass


class Router:
    """Tails the bus, prints new messages, and decides who gets prompted."""

    def __init__(self, bus: Bus, printer):
        acquire_router_lock(bus.dir)
        self.bus = bus
        self.printer = printer
        self.msgs: list[dict] = bus.read()          # history of a resumed chat: shown, never re-routed
        self.seeded = len(self.msgs)
        self.queues: dict[str, queue.Queue] = {m: queue.Queue() for m in bus.members}
        self.status: dict[str, str] = {m: "starting" for m in bus.members}
        self.budget = int(bus.cfg.get("budget", 20))
        self.spent: dict[str, int] = {}      # replies routed per member since the last user message
        self.noticed: set[str] = set()       # members already told they are out
        self.wrapping = False
        self.muted: set[str] = set()
        self.fallback: dict[str, bool] = {}
        self.lock = threading.Lock()
        self.stop = threading.Event()

    def tail(self):
        while not self.stop.is_set():
            msgs = self.bus.read()
            if len(msgs) > len(self.msgs):
                new = msgs[len(self.msgs):]
                self.msgs = msgs
                for m in new:
                    self.printer(m)
                    self.route(m)
                try:
                    transcript(self.bus, msgs)
                except OSError:
                    pass
            time.sleep(0.3)

    def route(self, m: dict):
        if m.get("kind") == "note":
            return
        sender = m["from"]
        if sender == USER:
            self.wrapping = bool(WRAP_RE.search(m["text"]))
            self.spent = {}
            self.noticed = set()
            targets = m.get("to") or list(self.bus.members)
            targets = [t for t in targets if t != USER]
        else:
            if self.wrapping:
                return
            targets = [t for t in m.get("to", []) if t != sender and t != USER]
            if not targets:
                return
            if self.spent.get(sender, 0) >= self.budget:
                if sender not in self.noticed:
                    self.noticed.add(sender)
                    self.bus.post(SYSTEM, f"reply budget ({self.budget}) reached for {sender}; "
                                          "say something to continue", "note")
                return
            self.spent[sender] = self.spent.get(sender, 0) + 1
        for t in targets:
            if t in self.queues and t not in self.muted:
                self.queues[t].put(m)

    def poll_status(self):
        """Mirror herdr's view of the interactive agents into the toolbar (idle/working/blocked)."""
        agents = {m: self.bus.cfg["members"][m]["agent"] for m in self.bus.members
                  if self.bus.cfg["members"][m].get("chat_kind") == "herdr"}
        while not self.stop.is_set():
            try:
                r = C.herdr("agent", "list")
                live = {a.get("name"): a.get("agent_status") for a in r.get("agents", [])}
            except RuntimeError:
                live = {}
            for name, agent in agents.items():
                st = live.get(agent)
                if st is None:
                    if self.status.get(name) == "starting":
                        continue
                    self.status[name] = "gone"
                elif st in ("idle", "done"):
                    if self.status.get(name) != "waiting":
                        self.status[name] = "idle"
                elif st in ("working", "blocked"):
                    self.status[name] = st
            time.sleep(2)

    # ---- delivery threads
    def deliver_loop(self, name: str):
        q = self.queues[name]
        member = self.bus.cfg["members"][name]
        last = self.seeded
        while not self.stop.is_set():
            try:
                q.get(timeout=0.5)
            except queue.Empty:
                continue
            time.sleep(4.0)                      # let a burst of messages land in one delivery
            while not q.empty():
                q.get_nowait()
            with self.lock:
                msgs = self.msgs[last:]
                last = len(self.msgs)
            fresh = [m for m in msgs if m["from"] != name and m.get("kind") != "note"]
            if not fresh:
                continue
            try:
                if member.get("chat_kind") == "openai":
                    text = DELIVERY_PLAIN.format(lines=format_lines(self.bus, fresh, name),
                                                 wrap="\n\n(The user is wrapping up: reply with one final conclusion and no mentions.)" if self.wrapping else "")
                    self.deliver_openai(name, text)
                else:
                    text = DELIVERY.format(name=name, lines=format_lines(self.bus, fresh, name),
                                           wrap=WRAP_NOTE if self.wrapping else "")
                    self.deliver_herdr(name, member, text)
            except Exception as e:  # noqa: BLE001 - a dead deliverer would silently mute the member
                self.bus.post(SYSTEM, f"{name} delivery failed: {type(e).__name__}: {str(e)[:120]}", "note")
                self.status[name] = "error"

    def deliver_openai(self, name: str, text: str):
        with open(self.bus.dir / "inbox" / f"{name}.jsonl", "a") as f:
            f.write(json.dumps({"text": text, "ts": time.time()}) + "\n")

    def deliver_herdr(self, name: str, member: dict, text: str):
        agent = member["agent"]
        self.status[name] = "waiting"
        deadline = time.time() + 300
        while time.time() < deadline and not self.stop.is_set():
            try:
                r = C.herdr("agent", "wait", agent, "--timeout", "600000", timeout=630)
                st = (r.get("agent") or r).get("agent_status") if isinstance(r, dict) else None
                if st == "blocked":
                    self.bus.post(SYSTEM, f"{name} is blocked on a dialog in its pane; answer it there", "note")
                    self.status[name] = "blocked"
                    return
                break
            except RuntimeError as e:
                if "not found" in str(e) or "unknown" in str(e).lower():
                    time.sleep(2)           # agent still starting
                    continue
                self.bus.post(SYSTEM, f"{name}: {str(e)[:120]}", "note")
                self.status[name] = "error"
                return
        else:
            self.bus.post(SYSTEM, f"{name} never became ready", "note")
            self.status[name] = "error"
            return
        before = sum(1 for m in self.bus.read() if m["from"] == name)
        self.status[name] = "working"
        try:
            st = prompt_agent(agent, text)
        except RuntimeError as e:
            self.bus.post(SYSTEM, f"{name}: {str(e)[:120]}", "note")
            self.status[name] = "error"
            return
        if st == "blocked":
            self.bus.post(SYSTEM, f"{name} is blocked on a dialog in its pane", "note")
            self.status[name] = "blocked"
            return
        if st == "stalled":
            self.bus.post(SYSTEM, f"{name} did not accept the prompt", "note")
            self.status[name] = "idle"
            return
        if name not in self.fallback:
            self.fallback[name] = detection_is_fallback(agent)
        if self.fallback[name]:
            # herdr can't see this agent working, so "idle" came back immediately; watch its pane instead
            self.wait_quiet(name, agent, before)
        self.status[name] = "idle"
        after = sum(1 for m in self.bus.read() if m["from"] == name)
        if after == before:
            self.bus.post(SYSTEM, f"{name} had nothing to add", "note")

    RETRY_PROMPT = ("Your previous request failed with an API error. Try again now, and post your reply with "
                    "`council post --as {name} - <<'COUNCIL'`, ending with a COUNCIL line, when done.")

    def wait_quiet(self, name: str, agent: str, before: int, still_for: float = 20.0, max_wait: float = 900.0,
                   retries: int = 2):
        """Wait until the member posts, or its pane output has been unchanged for `still_for` seconds.
        If the pane ends on an API error line (pi prints `Error: ...`), nudge the agent to retry."""
        pane = agent_pane(agent)
        if not pane:
            return
        t0 = time.time()
        last, last_change = pane_text(pane), time.time()
        while time.time() - t0 < max_wait and not self.stop.is_set():
            time.sleep(3)
            if sum(1 for m in self.bus.read() if m["from"] == name) > before:
                return
            cur = pane_text(pane)
            if cur != last:
                last, last_change = cur, time.time()
            elif time.time() - last_change >= still_for and time.time() - t0 >= 15:
                err = trailing_error(cur)
                if err and retries > 0:
                    self.bus.post(SYSTEM, f"{name} hit an API error ({err[:80]}); retrying", "note")
                    retries -= 1
                    try:
                        prompt_agent(agent, self.RETRY_PROMPT.format(name=name), timeout_ms=300000)
                    except RuntimeError:
                        return
                    t0 = time.time()
                    last, last_change = pane_text(pane), time.time()
                    continue
                return


def trailing_error(text: str) -> str | None:
    """The last non-empty lines of a pane end with an error line and nothing substantive after it."""
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    tail = lines[-6:]
    for ln in reversed(tail):
        if re.match(r"^(Error|error|✗|⚠)[:\s]", ln) or "Corrupted thought signature" in ln:
            return ln
        if len(ln) > 40 and not re.search(r"\b(TPS|TTFT|ctx)\b", ln):
            return None                 # real content after the last error line
    return None


# ---------------------------------------------------------------------- UI ---
HELP = """\
/wrap          ask everyone for final conclusions (or just type "let's wrap it up")
/budget N      replies each member may send per message you send (default 20)
/mute NAME     stop delivering to a member       /unmute NAME
/who           member status                     /log  print the chat path
/quit          leave the chat (members keep running in their panes)
@name          address a member directly; no mention = everyone"""


def cmd_chat_ui(args) -> int:
    from prompt_toolkit import PromptSession
    from prompt_toolkit.formatted_text import ANSI
    from prompt_toolkit.patch_stdout import patch_stdout

    bus = Bus(resolve_chat(args.chat))
    width = shutil.get_terminal_size((100, 30)).columns

    def printer(m):
        print(render(bus, m, shutil.get_terminal_size((100, 30)).columns))

    router = Router(bus, printer)
    C.out(C.rule(C.MAGENTA))
    C.out(f"{C.MAGENTA}{C.BOLD}Council chat{C.RESET}  {C.DIM}{' · '.join(bus.label(m) for m in bus.members)}{C.RESET}")
    C.out(f"{C.DIM}cwd {bus.cfg['cwd']} · /help for commands · say \"wrap it up\" when you're done{C.RESET}")
    C.out(C.rule(C.MAGENTA))
    if router.msgs:
        C.out(f"{C.DIM}earlier in this chat ({len(router.msgs)} messages since {bus.cfg['created'][:16].replace('T', ' ')}){C.RESET}")
        for m in router.msgs:
            printer(m)
        C.out(C.rule(C.MAGENTA))

    def status_text():
        parts = []
        for m in bus.members:
            st = router.status.get(m, "?")
            if bus.cfg["members"][m].get("chat_kind") == "openai":
                try:
                    st = (bus.dir / "status" / m).read_text().strip() or st
                except OSError:
                    st = "starting"
            if m in router.muted:
                st = "muted"
            dot = "●" if st == "working" else "◐" if st in ("starting", "waiting") else "○"
            parts.append(f"{m} {dot} {st}")
        wrap = " · wrapping" if router.wrapping else ""
        left = min((router.budget - router.spent.get(m, 0) for m in bus.members), default=router.budget)
        return "  ".join(parts) + f"  · budget {max(left, 0)}/{router.budget} each{wrap}"

    session = PromptSession(bottom_toolbar=status_text, refresh_interval=0.5)

    async def loop():
        threading.Thread(target=router.tail, daemon=True).start()
        threading.Thread(target=router.poll_status, daemon=True).start()
        for m in bus.members:
            threading.Thread(target=router.deliver_loop, args=(m,), daemon=True).start()
        while True:
            try:
                text = await session.prompt_async(ANSI(f"{WHITE}{C.BOLD}you ›{C.RESET} "))
            except (EOFError, KeyboardInterrupt):
                break
            text = text.strip()
            if not text:
                continue
            if text.startswith("/"):
                cmd, _, rest = text[1:].partition(" ")
                cmd = cmd.lower()
                if cmd in ("quit", "exit", "q"):
                    break
                if cmd == "help":
                    print(C.DIM + HELP + C.RESET)
                elif cmd == "wrap":
                    bus.post(USER, rest.strip() or "Let's wrap it up. Final conclusions, please.")
                elif cmd == "budget" and rest.strip().isdigit():
                    router.budget = int(rest.strip())
                    router.spent = {}
                    router.noticed = set()
                    print(f"{C.DIM}budget set to {router.budget} replies each{C.RESET}")
                elif cmd == "mute" and rest.strip() in bus.members:
                    router.muted.add(rest.strip())
                elif cmd == "unmute":
                    router.muted.discard(rest.strip())
                elif cmd == "who":
                    print(C.DIM + status_text() + C.RESET)
                elif cmd == "log":
                    print(f"{C.DIM}{bus.path}{C.RESET}")
                else:
                    print(f"{C.DIM}unknown command; /help{C.RESET}")
                continue
            bus.post(USER, text)

    with patch_stdout(raw=True):
        asyncio.run(loop())
    router.stop.set()
    release_router_lock(bus.dir)
    C.out(f"{C.DIM}left the chat · transcript {bus.dir / 'transcript.md'}{C.RESET}")
    return 0


def unwrap_post(reply: str, name: str) -> str:
    """Models sometimes imitate the shell form they see in the log: council post --as gemini '...'.
    Either heredoc delimiter is accepted: COUNCIL is what the briefing shows, EOF what habit reaches for."""
    t = reply.strip()
    m = re.match(rf'^`?council post --as {re.escape(name)}\s+(?:-\s*<<\s*\'?(?:COUNCIL|EOF)\'?\s*)?(.*?)'
                 rf'(?:\s*(?:COUNCIL|EOF))?`?$', t, re.S)
    if not m:
        return t
    inner = m.group(1).strip()
    if len(inner) >= 2 and inner[0] == inner[-1] and inner[0] in "\"'":
        inner = inner[1:-1]
    return inner.replace('\\"', '"').strip()


# ------------------------------------------------------------- or-agent ---
def cmd_or_agent(args) -> int:
    bus = Bus(resolve_chat(args.chat))
    name = args.name
    m = bus.cfg["members"][name]
    color = bus.color(name)
    status = bus.dir / "status"
    status.mkdir(exist_ok=True)
    inbox = bus.dir / "inbox" / f"{name}.jsonl"
    inbox.touch()

    def set_status(s: str):
        (status / name).write_text(s)

    others = [x for x in bus.members if x != name]
    C.out(C.rule(color))
    C.out(f"{color}{C.BOLD}{m['label']}{C.RESET}  {C.DIM}{m.get('model', '')} · {m.get('base_url', '')}{C.RESET}")
    C.out(C.rule(color))
    history = [{"role": "system", "content": OR_SYSTEM.format(
        name=name, label=m["label"], others=", ".join(others), others_at=" @".join(others))}]
    bus.post(name, f"{m['label']} connected.")
    set_status("idle")
    seen = 0
    while True:
        try:
            lines = inbox.read_text().splitlines()
        except OSError:
            lines = []
        if len(lines) <= seen:
            time.sleep(0.4)
            continue
        batch = lines[seen:]
        seen = len(lines)
        texts = []
        for ln in batch:
            try:
                texts.append(json.loads(ln)["text"])
            except (ValueError, KeyError):
                pass
        if not texts:
            continue
        history.append({"role": "user", "content": "\n\n".join(texts)})
        if len(history) > 41:                     # keep the system prompt plus the last 40 turns
            history = history[:1] + history[-40:]
        set_status("working")
        C.out(f"\n{color}▸{C.RESET} {C.DIM}{dt.datetime.now().strftime('%H:%M:%S')} replying{C.RESET}")
        reply, err, elapsed = C.run_backend_messages(m, history, color, waiting_msg="thinking")
        C.out()
        reply = unwrap_post(reply, name)
        if err:
            C.out(f"{C.RED}✗ {err}{C.RESET}")
            bus.post(SYSTEM, f"{name}: {err[:120]}", "note")
            history.pop()
        elif reply.strip().upper().rstrip(".") == "PASS":
            C.out(f"{C.DIM}(passed){C.RESET}")
            history.append({"role": "assistant", "content": "PASS"})
        else:
            bus.post(name, reply)
            history.append({"role": "assistant", "content": reply})
            C.out(f"{C.DIM}posted · {C.fmt_secs(elapsed)}{C.RESET}")
        set_status("idle")


# ----------------------------------------------------------------- setup ---
EFFORT_ARGS = {
    "claude": lambda e: ["--effort", e],
    "codex": lambda e: ["-c", f'model_reasoning_effort="{e}"'],
    "pi": lambda e: ["--thinking", e],
}


def build_members(cfg: dict, names: list[str], effort: str, suffix: str) -> dict[str, dict]:
    members = {}
    for n in names:
        m = dict(cfg["members"][n])
        m["name"] = n
        m.setdefault("label", n)
        if m.get("backend") in ("claude", "codex", "pi"):
            m["chat_kind"] = "herdr"
            m["agent"] = f"{n}-c{suffix}"
            m["chat_args"] = list(m.get("chat_args") or DEFAULT_CHAT_ARGS[m["backend"]])
            if m["backend"] == "pi":
                m["chat_args"] = C.pi_model_args(m) + m["chat_args"]
                if "--no-session" not in m["chat_args"]:
                    m["chat_args"].insert(0, "--no-session")
            if effort != "default":
                m["chat_args"] += EFFORT_ARGS[m["backend"]](effort)
                m["label"] = f"{m['label']} · {effort}"
        elif m.get("backend") == "openai":
            m["chat_kind"] = "openai"
        else:
            backend = m.get("backend")
            if backend == "kimi":
                sys.exit(f"member {n}: kimi runs in the macOS app, which hosts its own terminals; "
                         "`council chat` starts members as herdr agents and herdr has no kimi kind")
            sys.exit(f"member {n}: backend {backend!r} cannot join a chat")
        members[n] = m
    return members


def find_chat(title: str) -> pathlib.Path | None:
    """The latest chat directory for this title; one with messages wins over an empty one."""
    slug = C.slugify(title, 24)
    cands = sorted(p for p in CHATS.glob(f"*_{slug}") if (p / "config.json").exists())
    with_msgs = [p for p in cands if (p / "chat.jsonl").exists() and (p / "chat.jsonl").stat().st_size > 0]
    return (with_msgs or cands or [None])[-1]


def prepare_chat(cfg: dict, names: list[str], cwd: pathlib.Path | None, budget: int | None, effort: str | None,
                 title: str, resume: pathlib.Path | None = None) -> Bus:
    """Create the chat directory, config.json and the chats/current symlink. With `resume`, reuse that
    chat directory and its log: the members come from council.toml as now, but keep the original
    agent-name suffix so agents herdr restored after a restart still match."""
    chat_cfg = cfg.get("chat", {})
    effort = effort or chat_cfg.get("effort") or "medium"
    for n in names:
        if n not in cfg["members"]:
            sys.exit(f"unknown member '{n}'. Configured: {', '.join(cfg['members'])}")
        if n in (USER, SYSTEM, "all", "everyone"):
            sys.exit(f"'{n}' is a reserved name")
    if not names:
        sys.exit("no members")
    now = dt.datetime.now()
    old: dict = {}
    if resume:
        cdir = resume
        old = json.loads((cdir / "config.json").read_text())
        stamp = cdir.name[:17]
        cwd = cwd or pathlib.Path(old.get("cwd") or os.getcwd())
    else:
        stamp = now.strftime("%Y-%m-%d_%H%M%S")
        cdir = CHATS / f"{stamp}_{C.slugify(title, 24)}"
        cwd = cwd or pathlib.Path(os.getcwd())
    (cdir / "inbox").mkdir(parents=True, exist_ok=True)
    (cdir / "status").mkdir(exist_ok=True)
    members = build_members(cfg, names, effort, stamp[-4:])
    config = {"created": old.get("created") or now.isoformat(timespec="seconds"), "cwd": str(cwd), "title": title,
              "members": members, "order": names, "budget": int(budget or old.get("budget") or chat_cfg.get("budget", 20)),
              "effort": effort}
    if resume:
        config["resumed"] = list(old.get("resumed") or []) + [now.isoformat(timespec="seconds")]
    (cdir / "config.json").write_text(json.dumps(config, indent=2))
    (cdir / "chat.jsonl").touch()
    cur = CHATS / "current"
    if cur.is_symlink() or cur.exists():
        cur.unlink()
    cur.symlink_to(cdir)
    return Bus(cdir)


def chat_ui_running(cdir: pathlib.Path) -> bool:
    try:
        r = subprocess.run(["pgrep", "-f", f"chat-ui --chat {cdir}"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False
    return r.returncode == 0


def launch_chat_ui(bus: Bus, pane: str) -> None:
    C.herdr("pane", "rename", pane, "Council chat")
    C.herdr("pane", "run", pane, f"clear; export COUNCIL_CHAT={bus.dir}; {C.PY} {C.SCRIPT} chat-ui --chat {bus.dir}")


def start_member(bus: Bus, n: str, pane: str, resumed: bool = False) -> None:
    """Start member `n` in `pane` (which must be at a shell prompt) and brief it. Raises RuntimeError."""
    cdir, cwd, names, m = bus.dir, pathlib.Path(bus.cfg["cwd"]), bus.members, bus.cfg["members"][n]
    if m["chat_kind"] == "openai":
        C.herdr("pane", "run", pane, f"clear; {C.PY} {C.SCRIPT} or-agent --chat {cdir} --as {n}")
        return
    C.out(f"{C.DIM}starting {n} ({m['backend']} {' '.join(m['chat_args'])})…{C.RESET}")
    if resumed:                                   # a restored pane's shell no longer carries COUNCIL_CHAT
        C.herdr("pane", "run", pane, f"export COUNCIL_CHAT={cdir}; clear")
        time.sleep(0.5)
    C.herdr("agent", "start", m["agent"], "--kind", m["backend"], "--pane", pane,
            "--timeout", "120000", "--", *m["chat_args"])
    others = [x for x in names if x != n]
    brief = BRIEFING.format(name=n, others=", ".join(others), others_at=" @".join(others), cwd=cwd,
                            resume=RESUME_BRIEFING.format(cdir=cdir) if resumed else "")
    time.sleep(2.0)                               # let the TUI finish drawing before pasting
    prompt_agent(m["agent"], brief, timeout_ms=300000)


def report_start(bus: Bus, names: list[str], errors: dict[str, str]) -> None:
    ok = [n for n in names if n not in errors]
    C.out(f"{C.GREEN}chat open{C.RESET} · connected: {', '.join(ok) or 'nobody'}"
          + (f" · {C.RED}failed: {', '.join(errors)}{C.RESET}" if errors else ""))
    for n, e in errors.items():
        C.out(f"  {C.RED}{n}{C.RESET}: {e[:200]}")


def run_starts(bus: Bus, jobs: list[tuple[str, str, bool]]) -> dict[str, str]:
    """Start (name, pane, resumed) jobs in parallel; returns start errors by member."""
    errors: dict[str, str] = {}

    def start(n: str, pane: str, resumed: bool):
        try:
            start_member(bus, n, pane, resumed)
        except RuntimeError as e:
            errors[n] = str(e)
            bus.post(SYSTEM, f"{n} failed to start: {str(e)[:160]}", "note")

    threads = [threading.Thread(target=start, args=j) for j in jobs]
    for th in threads:
        th.start()
    for th in threads:
        th.join()
    return errors


def build_chat(bus: Bus, root: str, chat_width: float) -> dict[str, str]:
    """Split `root` into chat (left) + stacked members (right), start everything. Returns start errors."""
    cdir, cwd, names, members = bus.dir, pathlib.Path(bus.cfg["cwd"]), bus.members, bus.cfg["members"]
    env = f"COUNCIL_CHAT={cdir}"
    right = C.split(root, "right", chat_width, cwd, env=env)
    column = C.split_even(right, "down", len(names), cwd, env=env)
    for n, pane in zip(names, column):
        C.herdr("pane", "rename", pane, members[n]["label"])
    launch_chat_ui(bus, root)
    resumed = bool(bus.cfg.get("resumed"))
    errors = run_starts(bus, [(n, p, resumed) for n, p in zip(names, column)])
    report_start(bus, names, errors)
    return errors


def repair_chat(bus: Bus, panes: list[dict], live: dict[str, dict], chat_pane: str) -> dict[str, str]:
    """A restarted herdr session restored the layout: relaunch the chat UI if it's gone, re-brief the
    members herdr brought back, and start the ones it couldn't (pi runs without a session) in their old
    panes. New members get a spare agentless pane or a fresh split. Returns start errors."""
    cdir, cwd, names, members = bus.dir, pathlib.Path(bus.cfg["cwd"]), bus.members, bus.cfg["members"]
    env = f"COUNCIL_CHAT={cdir}"
    tab = next(p["tab_id"] for p in panes if p["pane_id"] == chat_pane)
    panes = [p for p in panes if p["tab_id"] == tab]
    by_agent = {a["name"]: a["pane_id"] for a in live.values() if a.get("pane_id")}
    by_label = {p["label"]: p["pane_id"] for p in panes if p.get("label")}
    matched: dict[str, str] = {}
    for n in names:
        pid = by_agent.get(members[n]["agent"]) or by_label.get(members[n]["label"])
        if pid and pid != chat_pane:
            matched[n] = pid
    spare = [p["pane_id"] for p in panes
             if p["pane_id"] != chat_pane and not p.get("agent") and p["pane_id"] not in matched.values()]
    stamp = (bus.cfg.get("resumed") or [""])[-1][:16].replace("T", " ")
    bus.post(SYSTEM, f"chat resumed {stamp} · members: {', '.join(names)}", "note")
    if not chat_ui_running(cdir):
        launch_chat_ui(bus, chat_pane)
    jobs: list[tuple[str, str, bool]] = []
    errors: dict[str, str] = {}
    last_pane = chat_pane
    for n in names:
        m, pane = members[n], matched.get(n)
        if pane and m.get("agent") in live:
            last_pane = pane
            C.herdr("pane", "rename", pane, m["label"])
            note = RESUMED_NOTE.format(title=bus.cfg["title"], name=n, cdir=cdir)
            try:
                prompt_agent(m["agent"], note, timeout_ms=120000)
            except RuntimeError as e:
                errors[n] = str(e)
            continue
        if not pane:
            pane = spare.pop(0) if spare else C.split(last_pane, "down", 0.5, cwd, env=env)
        last_pane = pane
        C.herdr("pane", "rename", pane, m["label"])
        jobs.append((n, pane, True))
    errors.update(run_starts(bus, jobs))
    report_start(bus, names, errors)
    return errors


def member_names(cfg: dict, arg: str | None) -> list[str]:
    raw = arg or ",".join(cfg.get("chat", {}).get("members") or cfg["defaults"].get("members", []))
    return [m.strip() for m in raw.split(",") if m.strip()]


def cmd_chat(args) -> int:
    """Chat as a new tab in the current herdr session."""
    cfg = C.load_config()
    if os.environ.get("HERDR_ENV") != "1" or not shutil.which("herdr"):
        sys.exit("council chat builds herdr panes; run it inside herdr, or use `council session NAME` from a plain terminal")
    cwd = pathlib.Path(args.cwd).resolve() if args.cwd else None
    title = getattr(args, "name", None) or "chat"
    bus = prepare_chat(cfg, member_names(cfg, args.members), cwd, args.budget, args.effort, title)
    ws = os.environ.get("HERDR_WORKSPACE_ID", "")
    tab_args = ["tab", "create", "--cwd", bus.cfg["cwd"], "--label", f"💬 {title}", "--env", f"COUNCIL_CHAT={bus.dir}",
                "--no-focus" if args.no_focus else "--focus"]
    if ws:
        tab_args += ["--workspace", ws]
    t = C.herdr(*tab_args)
    time.sleep(0.4)
    C.out(f"{C.DIM}chat {bus.dir}{C.RESET}")
    errors = build_chat(bus, t["root_pane"]["pane_id"], float(args.chat_width))
    return 1 if errors else 0


SESSION_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")


def session_paths(name: str) -> tuple[pathlib.Path, pathlib.Path]:
    sdir = pathlib.Path.home() / ".config" / "herdr" / "sessions" / name
    return sdir, sdir / "herdr.sock"


def cmd_session(args) -> int:
    """`council session NAME` from a plain terminal: start/attach a herdr session and arrange the chat in it.
    A chat with that name is resumed (log, members, panes) unless --new is given."""
    cfg = C.load_config()
    name = args.name.strip()
    if not SESSION_NAME_RE.match(name):
        name = C.slugify(name, 40)
    if not name:
        sys.exit("give the session a name")
    if not shutil.which("herdr"):
        sys.exit("herdr is not on PATH")
    if os.environ.get("HERDR_ENV") == "1":
        C.out(f"{C.YELLOW}already inside herdr; opening the chat as a tab in this session instead{C.RESET}")
        args.name = name
        return cmd_chat(args)
    sdir, sock = session_paths(name)
    prev = None if getattr(args, "new", False) else find_chat(name)
    if prev and session_complete(name, sock, prev):
        C.out(f"{C.DIM}session '{name}' is up with its council chat; attaching{C.RESET}")
        os.execvp("herdr", ["herdr", "--session", name])
    cwd = pathlib.Path(args.cwd).resolve() if args.cwd else None
    bus = prepare_chat(cfg, member_names(cfg, args.members), cwd, args.budget, args.effort, name, resume=prev)
    sdir.mkdir(parents=True, exist_ok=True)
    log = open(sdir / "council-arrange.log", "a")
    env = {k: v for k, v in os.environ.items() if not k.startswith("HERDR_")}
    env.update(HERDR_ENV="1", HERDR_SESSION=name, HERDR_SOCKET_PATH=str(sock))
    subprocess.Popen([C.PY, str(C.SCRIPT), "session-arrange", name, "--chat", str(bus.dir),
                      "--chat-width", str(args.chat_width)],
                     stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env, start_new_session=True)
    what = f"resuming chat {bus.dir} ({len(bus.read())} messages)" if prev else f"chat {bus.dir}"
    C.out(f"{C.DIM}{what} · arranging in herdr session '{name}' (log: {sdir / 'council-arrange.log'}){C.RESET}")
    os.execvp("herdr", ["herdr", "--session", name])


def live_council_agents(name: str, sock: pathlib.Path) -> dict[str, dict] | None:
    """Council agents (name → herdr record) alive in the session, or None when it isn't running."""
    if not sock.exists():
        return None
    env = {k: v for k, v in os.environ.items() if not k.startswith("HERDR_")}
    env.update(HERDR_ENV="1", HERDR_SESSION=name, HERDR_SOCKET_PATH=str(sock))
    try:
        r = subprocess.run(["herdr", "agent", "list"], capture_output=True, text=True, timeout=10, env=env)
        agents = json.loads(r.stdout).get("result", {}).get("agents", [])
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    return {a["name"]: a for a in agents if re.search(r"-c\d{4}$", a.get("name") or "")}


def session_complete(name: str, sock: pathlib.Path, cdir: pathlib.Path) -> bool:
    """True when the session runs, its chat UI is up on `cdir`, and every member of that chat is alive."""
    live = live_council_agents(name, sock)
    if live is None or not chat_ui_running(cdir):
        return False
    try:
        cfg = json.loads((cdir / "config.json").read_text())
    except (OSError, ValueError):
        return False
    return all(m.get("chat_kind") != "herdr" or m.get("agent") in live for m in cfg["members"].values())


def cmd_session_arrange(args) -> int:
    """Runs in the background while `herdr --session NAME` attaches: waits for the server, then builds
    the layout, or repairs a restored one when the session came back from a restart."""
    name = args.name
    sdir, sock = session_paths(name)
    os.environ.update(HERDR_ENV="1", HERDR_SESSION=name, HERDR_SOCKET_PATH=str(sock))
    bus = Bus(resolve_chat(args.chat))
    C.out(f"{dt.datetime.now().isoformat(timespec='seconds')} arranging chat {bus.dir} in session {name}")
    # The attaching client creates (and may recreate) the first workspace while it starts up,
    # so wait until the pane set has been stable for a few seconds before touching it.
    deadline = time.time() + 90
    panes, up_since, stable_since, last_ids = [], None, None, None
    while time.time() < deadline:
        try:
            panes = C.herdr("pane", "list").get("panes", [])
            up_since = up_since or time.time()
        except RuntimeError:
            time.sleep(0.5)
            continue
        ids = tuple(p["pane_id"] for p in panes)
        if ids != last_ids:
            last_ids, stable_since = ids, time.time()
        if panes and time.time() - stable_since >= 3:
            break
        if not panes and time.time() - up_since > 15:   # nobody attached; make our own workspace
            C.herdr("workspace", "create", "--cwd", bus.cfg["cwd"])
            last_ids = None
        time.sleep(0.5)
    if up_since is None:
        C.out("session never came up")
        return 1
    if not panes:
        C.out("no pane appeared in the session")
        return 1
    for attempt in range(3):
        panes = C.herdr("pane", "list").get("panes", [])
        if not panes:
            time.sleep(2)
            continue
        try:
            live = {a["name"]: a for a in C.herdr("agent", "list").get("agents", [])
                    if re.search(r"-c\d{4}$", a.get("name") or "")}
            chat_panes = [p["pane_id"] for p in panes if p.get("label") == "Council chat"]
            if chat_panes:
                C.out("council layout already present; repairing what's missing")
                errors = repair_chat(bus, panes, live, chat_panes[0])
                return 1 if errors else 0
            if any(p.get("agent") for p in panes) or len(panes) > 1:
                t = C.herdr("tab", "create", "--workspace", panes[0]["workspace_id"], "--cwd", bus.cfg["cwd"],
                            "--label", f"💬 {name}", "--env", f"COUNCIL_CHAT={bus.dir}", "--focus")
                root = t["root_pane"]["pane_id"]
                time.sleep(0.6)
            else:
                root = panes[0]["pane_id"]
                try:
                    C.herdr("tab", "rename", panes[0]["tab_id"], f"💬 {name}")
                    C.herdr("workspace", "rename", panes[0]["workspace_id"], name)
                except RuntimeError:
                    pass
            errors = build_chat(bus, root, float(args.chat_width))
            return 1 if errors else 0
        except RuntimeError as e:
            if "pane_not_found" in str(e) and attempt < 2:
                C.out(f"layout changed under us ({e}); retrying")
                time.sleep(3)
                continue
            raise
    C.out("could not arrange the session")
    return 1


# ----------------------------------------------------------- post / log ---
def cmd_post(args) -> int:
    bus = Bus(resolve_chat(args.chat))
    sender = args.sender.lower()
    if sender not in bus.members and sender not in (USER, SYSTEM):
        sys.exit(f"unknown sender '{sender}'; members: {', '.join(bus.members)}")
    pinned = os.environ.get("COUNCIL_AS", "").lower()
    if pinned and sender != pinned:
        # The app sets COUNCIL_AS in each member's terminal; a member may only speak as itself, never as the user.
        sys.exit(f"this terminal posts as '{pinned}'; use: council post --as {pinned} '...'")
    text = " ".join(args.text) if args.text else ""
    if not args.text or text == "-":
        text = sys.stdin.read()
    if not text.strip():
        sys.exit("empty message")
    m = bus.post(sender, text)
    to = " → " + " ".join("@" + t for t in m["to"]) if m["to"] else ""
    print(f"posted as {sender}{to} ({C.words(text)} words)")
    return 0


def cmd_event(args) -> int:
    """Hook target for the macOS app. Claude Code and Codex run `council event --backend X` from their hooks
    with the JSON payload on stdin; the app tails <chat>/events.jsonl. The chat and member come from
    COUNCIL_CHAT / COUNCIL_AS in the member's environment, so one hook definition serves every member and is
    a no-op in a plain terminal. Prints nothing (hook stdout is interpreted by the CLIs) and always exits 0."""
    try:
        cdir = args.chat or os.environ.get("COUNCIL_CHAT")
        member = (args.sender or os.environ.get("COUNCIL_AS") or "").lower()
        if not cdir or not member:
            return 0
        raw = ""
        if not sys.stdin.isatty():
            try:
                raw = sys.stdin.read()
            except OSError:
                raw = ""
        try:
            payload = json.loads(raw) if raw.strip() else {}
        except ValueError:
            payload = {"raw": raw[:2000]}
        hook = args.hook
        if not hook and isinstance(payload, dict):
            hook = payload.get("hook_event_name") or payload.get("type")
        rec = {"ts": dt.datetime.now().isoformat(timespec="seconds"), "member": member, "backend": args.backend,
               "hook": hook or "unknown", "payload": payload}
        path = pathlib.Path(cdir) / "events.jsonl"
        with open(path, "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            f.write(json.dumps(rec) + "\n")
            f.flush()
            fcntl.flock(f, fcntl.LOCK_UN)
    except Exception:  # noqa: BLE001 - a hook must never disturb the member
        pass
    return 0


def cmd_log(args) -> int:
    bus = Bus(resolve_chat(args.chat))
    msgs = bus.read()
    if args.tail:
        msgs = msgs[-int(args.tail):]
    for m in msgs:
        if m.get("kind") == "note":
            print(f"· {m['text']}")
            continue
        to = " → " + " ".join("@" + t for t in m.get("to", [])) if m.get("to") else ""
        print(f"[{m['from']}{to}] {m['text']}\n")
    return 0


def _chat_options(p) -> None:
    p.add_argument("-m", "--members", help="comma-separated member names (default: [chat].members in council.toml)")
    p.add_argument("--cwd", help="working directory the members operate in (default: current)")
    p.add_argument("--budget", type=int, help="replies each member may send per message you send")
    p.add_argument("--effort", help="reasoning effort for claude and codex: low, medium, high, xhigh, or default")
    p.add_argument("--chat-width", default="0.5", help="share of the width for the chat pane (default 0.5)")
    p.add_argument("--no-focus", action="store_true")


def add_subcommands(sub) -> None:
    se = sub.add_parser("session", help="from a plain terminal: open herdr session NAME with the chat and all members")
    se.add_argument("name")
    se.add_argument("--new", action="store_true", help="start a fresh chat even if one named NAME exists (default: resume it)")
    _chat_options(se)
    se.set_defaults(fn=cmd_session)

    c = sub.add_parser("chat", help="open the group chat as a new tab in the current herdr session")
    c.add_argument("--name", default=None)
    _chat_options(c)
    c.set_defaults(fn=cmd_chat)

    sa = sub.add_parser("session-arrange")
    sa.add_argument("name")
    sa.add_argument("--chat")
    sa.add_argument("--chat-width", default="0.5")
    sa.set_defaults(fn=cmd_session_arrange)

    p = sub.add_parser("post", help="post a message to the current chat (what members run to speak)")
    p.add_argument("--as", dest="sender", required=True, help="sender name")
    p.add_argument("--chat", help="chat directory (default: $COUNCIL_CHAT or chats/current)")
    p.add_argument("text", nargs="*", help="message; '-' or omitted reads stdin")
    p.set_defaults(fn=cmd_post)

    ev = sub.add_parser("event", help="hook target for the macOS app: append the CLI's hook payload to events.jsonl")
    ev.add_argument("--backend", required=True, choices=["claude", "codex", "pi", "kimi"])
    ev.add_argument("--as", dest="sender", help="member name (default: $COUNCIL_AS)")
    ev.add_argument("--chat", help="chat directory (default: $COUNCIL_CHAT)")
    ev.add_argument("--hook", help="event name (default: hook_event_name from the payload)")
    ev.set_defaults(fn=cmd_event)

    lg = sub.add_parser("log", help="print the current chat")
    lg.add_argument("--chat")
    lg.add_argument("-n", "--tail", type=int)
    lg.set_defaults(fn=cmd_log)

    ui = sub.add_parser("chat-ui")
    ui.add_argument("--chat")
    ui.set_defaults(fn=cmd_chat_ui)

    oa = sub.add_parser("or-agent")
    oa.add_argument("--chat")
    oa.add_argument("--as", dest="name", required=True)
    oa.set_defaults(fn=cmd_or_agent)
