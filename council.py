#!/usr/bin/env python3
"""council — a council-ai.app style multi-model verdict, inside a herdr session.

Every council member answers the same question independently, each in its own
herdr pane. A moderator waits for all of them, then streams one merged verdict
with the disagreements named and a consensus score.

    council ask "Should we migrate this service from Postgres to SQLite?"
    council ask --file plan.md --rounds 2 --anonymous "Critique this plan"
    council session NAME     # new herdr session: live group chat left, claude/codex/deepseek stacked right
    council chat             # same, as a tab in the herdr session you're already in
    council members          # configured members and whether they are reachable
    council runs             # past runs
    council show             # print the latest verdict

Backends: claude (Claude Code CLI), codex (Codex CLI), pi (pi-mono agent, any provider
it knows), openai (any OpenAI-compatible endpoint, no tools). Configure in council.toml.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import random
import re
import shutil
import subprocess
import sys
import threading
import time
import tomllib
import urllib.error
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = pathlib.Path(__file__).resolve()
CONFIG_PATH = HERE / "council.toml"
RUNS = HERE / "runs"
PY = sys.executable or "python3"

# ---------------------------------------------------------------- terminal ---
BOLD, DIM, RESET = "\033[1m", "\033[2m", "\033[0m"
GREEN, YELLOW, RED, CYAN, MAGENTA, BLUE, GREY = (
    "\033[38;5;82m", "\033[38;5;220m", "\033[38;5;196m", "\033[38;5;51m",
    "\033[38;5;207m", "\033[38;5;75m", "\033[38;5;245m")
PALETTE = ["\033[38;5;51m", "\033[38;5;207m", "\033[38;5;220m", "\033[38;5;82m",
           "\033[38;5;75m", "\033[38;5;209m", "\033[38;5;159m", "\033[38;5;141m"]
SPIN = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"


def out(s: str = "", end: str = "\n") -> None:
    sys.stdout.write(s + end)
    sys.stdout.flush()


def cols() -> int:
    return shutil.get_terminal_size((80, 24)).columns


def rule(color: str = GREY) -> str:
    return color + "─" * max(20, min(cols(), 120)) + RESET


def fmt_secs(s: float) -> str:
    return f"{s:.0f}s" if s < 100 else f"{s/60:.1f}m"


def words(text: str) -> int:
    return len(text.split())


# ------------------------------------------------------------------ config ---
DEFAULT_CONFIG = """\
# council.toml — members of the council and their defaults.
# backend: "claude" (Claude Code CLI), "codex" (Codex CLI), "openai" (OpenAI-compatible HTTP, e.g. LM Studio)

[defaults]
members = ["claude", "codex", "deepseek"]
moderator = "claude"
rounds = 1
anonymous = false
length = "about 300-500 words"

[chat]
members = ["claude", "codex", "deepseek"]   # `council session NAME`: chat pane left, these stacked right
budget = 12                               # max member replies per message you send
effort = "medium"                         # reasoning effort for claude and codex (low/medium/high/xhigh/default)

[members.claude]
backend = "claude"
label = "Claude Fable 5.1"
model = ""                # "", "opus", "sonnet", or a full model id
chat_args = ["--dangerously-skip-permissions"]   # interactive session flags for `council chat`

[members.claude-opus]
backend = "claude"
label = "Claude Opus 5"
model = "opus"

[members.codex]
backend = "codex"
label = "Codex GPT-6 Astra"
model = ""
chat_args = ["--yolo"]

[members.deepseek]
backend = "pi"                               # pi (pi-mono) agent: file/bash tools, OpenRouter via pi's own config
label = "DeepSeek V4.1 Flash"
provider = "openrouter"
model = "deepseek/deepseek-v4.1-flash"       # registered in ~/.pi/agent/models.json under openrouter
chat_args = []                               # extra interactive pi flags for `council session`

[members.gemini]                             # optional: council ask -m claude,codex,gemini
backend = "pi"
label = "Gemini 3.8 Flash"
provider = "openrouter"
model = "google/gemini-3.8-flash"

# Direct HTTP alternative without tools (any OpenAI-compatible endpoint):
# [members.gemini-api]
# backend = "openai"
# label = "Gemini 3.8 Flash (API)"
# base_url = "https://openrouter.ai/api/v1"
# model = "google/gemini-3.8-flash"
# api_key_file = "~/.pi/agent/models.json"
# api_key_json = "providers.openrouter.apiKey"
# max_tokens = 8192

# Any OpenAI-compatible server works, e.g. LM Studio:
# [members.gemma]
# backend = "openai"
# label = "Gemma 4 26B (local)"
# base_url = "http://localhost:1234/v1"
# model = "gemma-4-26b-a4b-it-qat-mlx"
"""


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        CONFIG_PATH.write_text(DEFAULT_CONFIG)
    with open(CONFIG_PATH, "rb") as f:
        cfg = tomllib.load(f)
    cfg.setdefault("defaults", {})
    cfg.setdefault("members", {})
    if not cfg["members"]:
        sys.exit(f"no [members.*] configured in {CONFIG_PATH}")
    return cfg


# ---------------------------------------------------------------- run dirs ---
class Run:
    """A run directory: question, config.json, r<N>/<member>.md answers, verdict.md."""

    def __init__(self, path: pathlib.Path):
        self.dir = pathlib.Path(path).resolve()
        self.cfg = json.loads((self.dir / "config.json").read_text())

    @property
    def members(self) -> dict:
        return self.cfg["members"]

    @property
    def order(self) -> list[str]:
        return self.cfg["order"]

    @property
    def rounds(self) -> int:
        return int(self.cfg["rounds"])

    @property
    def anonymous(self) -> bool:
        return bool(self.cfg["anonymous"])

    @property
    def question(self) -> str:
        return (self.dir / "question.md").read_text()

    def display(self, name: str) -> str:
        """Name shown while the run is in progress (anonymized if requested)."""
        return self.members[name]["alias"] if self.anonymous else self.members[name]["label"]

    def answer_path(self, name: str, rnd: int) -> pathlib.Path:
        return self.dir / f"r{rnd}" / f"{name}.md"

    def done_path(self, name: str, rnd: int) -> pathlib.Path:
        return self.dir / f"r{rnd}" / f"{name}.done"

    def done(self, name: str, rnd: int) -> dict | None:
        p = self.done_path(name, rnd)
        if not p.exists():
            return None
        try:
            return json.loads(p.read_text())
        except ValueError:
            return None

    def answer(self, name: str, rnd: int) -> str:
        p = self.answer_path(name, rnd)
        return p.read_text() if p.exists() else ""

    def color(self, name: str) -> str:
        return PALETTE[self.order.index(name) % len(PALETTE)]


def slugify(s: str, n: int = 40) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
    return s[:n].rstrip("-") or "question"


def create_run(cfg: dict, question: str, files: list[str], members: list[str], moderator: str,
               rounds: int, anonymous: bool) -> Run:
    for m in members + [moderator]:
        if m not in cfg["members"]:
            sys.exit(f"unknown member '{m}'. Configured: {', '.join(cfg['members'])}")
    if len(members) < 2:
        sys.exit("a council needs at least two members (--members a,b,...)")
    stamp = dt.datetime.now().strftime("%Y-%m-%d_%H%M%S")
    rdir = RUNS / f"{stamp}_{slugify(question)}"
    rdir.mkdir(parents=True)
    for r in range(1, rounds + 1):
        (rdir / f"r{r}").mkdir()

    body = question.strip() + "\n"
    for f in files:
        p = pathlib.Path(f).expanduser()
        try:
            text = p.read_text(errors="replace")
        except OSError as e:
            shutil.rmtree(rdir)
            sys.exit(f"cannot read attachment {f}: {e}")
        if len(text) > 200_000:
            out(f"{YELLOW}warning:{RESET} {p.name} is {len(text)//1000}k chars; local models may not fit it in context")
        fence = "````" if "```" in text else "```"
        body += f"\n\n## Attached file: {p.name}\n\n{fence}\n{text.rstrip()}\n{fence}\n"
    (rdir / "question.md").write_text(body)

    order = list(members)
    aliases = {}
    if anonymous:
        shuffled = list(members)
        random.shuffle(shuffled)
        for i, m in enumerate(shuffled):
            aliases[m] = f"Model {chr(ord('A') + i)}"
        order = shuffled
    mconf = {}
    for m in members:
        c = dict(cfg["members"][m])
        c["name"] = m
        c.setdefault("label", m)
        c["alias"] = aliases.get(m, c["label"])
        mconf[m] = c
    modc = dict(cfg["members"][moderator])
    modc["name"] = moderator
    modc.setdefault("label", moderator)
    config = {
        "created": dt.datetime.now().isoformat(timespec="seconds"),
        "question_preview": question.strip().splitlines()[0][:120],
        "members": mconf, "order": order, "moderator": modc,
        "rounds": rounds, "anonymous": anonymous,
        "length": cfg["defaults"].get("length", "about 300-500 words"),
        "attachments": [pathlib.Path(f).name for f in files],
    }
    (rdir / "config.json").write_text(json.dumps(config, indent=2))
    return Run(rdir)


# ---------------------------------------------------------------- backends ---
class ThinkSplitter:
    """Route text inside <think>…</think> to the 'think' channel, everything else to 'text'."""

    OPEN, CLOSE = "<think>", "</think>"

    def __init__(self):
        self.buf, self.inside = "", False

    def feed(self, s: str) -> list[tuple[str, str]]:
        self.buf += s
        res = []
        while self.buf:
            tag = self.CLOSE if self.inside else self.OPEN
            i = self.buf.find(tag)
            if i >= 0:
                if i:
                    res.append(("think" if self.inside else "text", self.buf[:i]))
                self.buf = self.buf[i + len(tag):]
                self.inside = not self.inside
                continue
            hold = 0
            for k in range(min(len(tag) - 1, len(self.buf)), 0, -1):
                if tag.startswith(self.buf[-k:]):
                    hold = k
                    break
            emit = self.buf[: len(self.buf) - hold]
            self.buf = self.buf[len(self.buf) - hold:]
            if emit:
                res.append(("think" if self.inside else "text", emit))
            break
        return res

    def flush(self) -> list[tuple[str, str]]:
        res = [("think" if self.inside else "text", self.buf)] if self.buf else []
        self.buf = ""
        return res


def stream_claude(member: dict, system: str, user: str, cwd: pathlib.Path):
    """Claude Code CLI in print mode. Uses the claude.ai login, so the (low-credit) API key is dropped."""
    cmd = ["claude", "-p", "--tools", "", "--no-session-persistence", "--disable-slash-commands",
           "--output-format", "stream-json", "--verbose", "--include-partial-messages",
           "--system-prompt", system]
    if member.get("model"):
        cmd += ["--model", member["model"]]
    env = dict(os.environ)
    env.pop("ANTHROPIC_API_KEY", None)
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, env=env, cwd=cwd)
    threading.Thread(target=_feed_stdin, args=(p, user), daemon=True).start()
    got_text = False
    result_text, result_err = "", None
    for line in p.stdout:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        t = ev.get("type")
        if t == "stream_event":
            e = ev.get("event", {})
            if e.get("type") == "content_block_delta":
                d = e.get("delta", {})
                if d.get("type") == "text_delta":
                    got_text = True
                    yield "text", d["text"]
                elif d.get("type") == "thinking_delta":
                    yield "think", d.get("thinking", "")
        elif t == "result":
            if ev.get("is_error") or ev.get("subtype") not in (None, "success"):
                result_err = str(ev.get("result") or ev.get("subtype") or ev)
            else:
                result_text = ev.get("result") or ""
    p.wait()
    err = p.stderr.read().strip()
    if result_err:
        yield "error", result_err
    elif p.returncode != 0:
        yield "error", err or f"claude exited {p.returncode}"
    elif not got_text and result_text:
        yield "text", result_text


def stream_codex(member: dict, system: str, user: str, cwd: pathlib.Path):
    """Codex CLI non-interactive mode. Read-only sandbox, ephemeral session, JSONL events."""
    cmd = ["codex", "exec", "--skip-git-repo-check", "-s", "read-only", "--ephemeral",
           "--json", "--color", "never", "-C", str(cwd)]
    if member.get("model"):
        cmd += ["-m", member["model"]]
    cmd.append("-")
    prompt = f"{system}\n\n---\n\n{user}"
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, cwd=cwd)
    threading.Thread(target=_feed_stdin, args=(p, prompt), daemon=True).start()
    pending, failed = None, None          # codex emits interim messages before tool calls; only the last one is the answer
    for line in p.stdout:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        t = ev.get("type", "")
        item = ev.get("item", {}) or {}
        if t == "item.completed":
            k = item.get("type")
            if k == "agent_message":
                if pending:
                    yield "status", pending
                pending = item.get("text", "")
            elif k == "reasoning":
                yield "think", (item.get("text") or "").strip() + "\n"
            elif k == "error":
                yield "status", item.get("message", "")
        elif t == "turn.failed" or t == "error":
            failed = ev.get("error", {}).get("message") if isinstance(ev.get("error"), dict) else str(ev.get("message") or ev)
    p.wait()
    err = p.stderr.read().strip()
    if failed:
        yield "error", failed
    elif p.returncode != 0:
        yield "error", err.splitlines()[-1] if err else f"codex exited {p.returncode}"
    elif not pending:
        yield "error", "codex produced no answer"
    else:
        yield "text", pending


def resolve_api_key(member: dict) -> str:
    """api_key literal, or $api_key_env, or a dotted path into a JSON file (api_key_file + api_key_json)."""
    if member.get("api_key"):
        return member["api_key"]
    if member.get("api_key_env") and os.environ.get(member["api_key_env"]):
        return os.environ[member["api_key_env"]]
    if member.get("api_key_file"):
        try:
            node = json.loads(pathlib.Path(member["api_key_file"]).expanduser().read_text())
            for part in member.get("api_key_json", "").split("."):
                if part:
                    node = node[part]
            if isinstance(node, str) and node:
                return node
        except (OSError, ValueError, KeyError, TypeError):
            pass
    return "local"


def stream_openai(member: dict, system: str, user: str, cwd: pathlib.Path):
    """Any OpenAI-compatible /v1/chat/completions endpoint (LM Studio, vLLM, OpenRouter, ...)."""
    yield from stream_openai_messages(member, [{"role": "system", "content": system}, {"role": "user", "content": user}])


def stream_openai_messages(member: dict, messages: list[dict]):
    base = member.get("base_url", "http://localhost:1234/v1").rstrip("/")
    body = {
        "model": member["model"],
        "messages": messages,
        "stream": True,
        "max_tokens": int(member.get("max_tokens", 4096)),
    }
    if "temperature" in member:
        body["temperature"] = float(member["temperature"])
    key = resolve_api_key(member)
    req = urllib.request.Request(base + "/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    splitter = ThinkSplitter()
    try:
        with urllib.request.urlopen(req, timeout=int(member.get("timeout", 900))) as r:
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    ch = json.loads(payload)
                except ValueError:
                    continue
                if ch.get("error"):
                    yield "error", str(ch["error"])
                    return
                choices = ch.get("choices") or []
                if not choices:
                    continue
                d = choices[0].get("delta") or {}
                think = d.get("reasoning_content") or d.get("reasoning")
                if not think and d.get("reasoning_details"):
                    think = "".join(x.get("text", "") for x in d["reasoning_details"] if isinstance(x, dict))
                if think:
                    yield "think", think
                if d.get("content"):
                    for kind, txt in splitter.feed(d["content"]):
                        yield kind, txt
        for kind, txt in splitter.flush():
            yield kind, txt
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:400]
        yield "error", f"HTTP {e.code} from {base}: {detail}"
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        yield "error", f"cannot reach {base}: {e}"


def pi_model_args(member: dict) -> list[str]:
    args = []
    if member.get("provider"):
        args += ["--provider", member["provider"]]
    if member.get("model"):
        args += ["--model", member["model"]]
    return args


def stream_pi(member: dict, system: str, user: str, cwd: pathlib.Path):
    """pi (pi-mono coding agent) in print mode: any provider/model pi knows, tools off, ephemeral.
    Uses --mode json so text streams as it arrives; pi sometimes fails to exit after finishing, so the
    process group is killed once the agent_end event has been seen."""
    import signal
    cmd = ["pi", "-p", "--mode", "json", "--offline", "--no-session", "--no-tools", "--no-extensions",
           "--no-skills", "--no-context-files", "--no-prompt-templates", *pi_model_args(member),
           "--system-prompt", system]
    if member.get("thinking"):
        cmd += ["--thinking", member["thinking"]]
    cmd.append(user)
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, cwd=cwd, start_new_session=True)
    got, final_text, err, ended = False, "", None, False
    try:
        for line in p.stdout:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            t = ev.get("type")
            if t == "message_update":
                e = ev.get("assistantMessageEvent") or {}
                k = e.get("type", "")
                delta = e.get("delta") or e.get("text") or ""
                if k == "text_delta" and delta:
                    got = True
                    yield "text", delta
                elif k in ("thinking_delta", "reasoning_delta") and delta:
                    yield "think", delta
            elif t == "turn_end":
                for block in (ev.get("message") or {}).get("content", []):
                    if block.get("type") == "text":
                        final_text += block.get("text", "")
            elif t == "error":
                err = str(ev.get("error") or ev.get("message") or ev)[:300]
            elif t in ("agent_end", "agent_settled"):
                ended = True
                break
    finally:
        try:
            p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                pass
    if err:
        yield "error", err
    elif not ended and p.returncode not in (None, 0, -9):
        stderr = "\n".join(ln for ln in (p.stderr.read() or "").splitlines() if not ln.startswith("Warning:")).strip()
        yield "error", stderr.splitlines()[-1] if stderr else f"pi exited {p.returncode}"
    elif not got:
        if final_text.strip():
            yield "text", final_text.strip()
        else:
            yield "error", "pi produced no answer"


BACKENDS = {"claude": stream_claude, "codex": stream_codex, "openai": stream_openai, "pi": stream_pi}


def _feed_stdin(p: subprocess.Popen, text: str) -> None:
    try:
        p.stdin.write(text)
        p.stdin.close()
    except (BrokenPipeError, OSError):
        pass


def run_backend(member: dict, system: str, user: str, cwd: pathlib.Path, color: str,
                waiting_msg: str = "thinking") -> tuple[str, str | None, float]:
    """Stream one completion to the terminal. Returns (answer_text, error, elapsed)."""
    backend = BACKENDS.get(member.get("backend", ""))
    if backend is None:
        return "", f"unknown backend '{member.get('backend')}'", 0.0
    return _run_stream(lambda: backend(member, system, user, cwd), waiting_msg)


def run_backend_messages(member: dict, messages: list[dict], color: str,
                         waiting_msg: str = "thinking") -> tuple[str, str | None, float]:
    """Same as run_backend but with a full chat history; openai backends only."""
    if member.get("backend") != "openai":
        return "", f"backend '{member.get('backend')}' has no chat-history mode", 0.0
    return _run_stream(lambda: stream_openai_messages(member, messages), waiting_msg)


def _run_stream(make_iter, waiting_msg: str) -> tuple[str, str | None, float]:
    t0 = time.time()
    text, err = [], None
    first = threading.Event()
    stop = threading.Event()

    def spinner():
        i = 0
        while not first.wait(0.1):
            if stop.is_set():
                return
            i += 1
            sys.stdout.write(f"\r{DIM}{SPIN[i % len(SPIN)]} {waiting_msg}… {fmt_secs(time.time() - t0)}{RESET}\033[K")
            sys.stdout.flush()
        sys.stdout.write("\r\033[K")
        sys.stdout.flush()

    spin = threading.Thread(target=spinner, daemon=True)
    spin.start()
    in_think = False
    try:
        for kind, chunk in make_iter():
            if not chunk and kind != "error":
                continue
            if not first.is_set():
                first.set()
                spin.join()          # let the spinner erase its line before the first chunk lands
            if kind == "text":
                if in_think:
                    out(RESET)
                    in_think = False
                sys.stdout.write(chunk)
                sys.stdout.flush()
                text.append(chunk)
            elif kind == "think":
                if not in_think:
                    sys.stdout.write(f"{DIM}{GREY}")
                    in_think = True
                sys.stdout.write(chunk)
                sys.stdout.flush()
            elif kind == "status":
                sys.stdout.write(f"{DIM}{chunk}{RESET}\n")
            elif kind == "error":
                err = chunk
    except KeyboardInterrupt:
        err = "interrupted"
    finally:
        stop.set()
        first.set()
    if in_think:
        out(RESET)
    answer = "".join(text).strip()
    if not answer and not err:
        err = "empty answer"
    return answer, err, time.time() - t0


# ----------------------------------------------------------------- prompts ---
MEMBER_SYSTEM = """\
You are one member of a council of independent AI models. Every member receives the same question and answers without seeing the others. A moderator will then compare all the answers and produce a merged verdict, so be specific and commit to positions.

Rules:
- Answer the question directly first, then give your reasoning.
- Prefer concrete facts, numbers, trade-offs and recommendations over generic advice.
- Flag what you are unsure of and say what would resolve it. Do not invent facts.
- If the question is flawed or rests on a false premise, say so.
- Write in Markdown. Aim for {length} unless the task clearly needs more.
- Do not mention the council, the moderator, or other members."""

CRITIQUE_PROMPT = """\
This is round {rnd} of {rounds}. Below are the other council members' previous answers to the same question (anonymized), followed by your own previous answer.

1. Under "## Critique", go through each response: what it gets right, what it gets wrong or misses. Be direct; name factual errors.
2. Under "## Revised answer", give your complete final answer to the original question. Change your position only where the arguments warrant it. Do not converge just to agree; disagreement backed by reasons is more useful than consensus without them.

# Original question

{question}

{peers}

# Your previous answer

{own}"""

MODERATOR_SYSTEM = """\
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
A line of the exact form `Score: NN/100` followed by one sentence explaining it. 100 means all members give substantively the same answer; around 50 means they agree on the core but differ on important specifics; below 30 means fundamentally different answers. A low score signals the reader should weigh the disagreements themselves."""

MODERATOR_PROMPT = """\
# Question put to the council

{question}

# Member answers{round_note}

{answers}

Produce the verdict now."""


def member_prompt(run: Run, name: str, rnd: int) -> tuple[str, str]:
    system = MEMBER_SYSTEM.format(length=run.cfg.get("length", "about 300-500 words"))
    if rnd == 1:
        return system, run.question
    peers = []
    others = [m for m in run.order if m != name]
    random.Random(f"{name}:{rnd}").shuffle(others)
    for i, m in enumerate(others, 1):
        a = run.answer(m, rnd - 1) or "(no answer produced)"
        peers.append(f"# Response {i}\n\n{a}")
    user = CRITIQUE_PROMPT.format(rnd=rnd, rounds=run.rounds, question=run.question,
                                  peers="\n\n".join(peers), own=run.answer(name, rnd - 1) or "(none)")
    return system, user


def moderator_prompt(run: Run) -> tuple[str, str]:
    r = run.rounds
    rounds_note = f", then critiqued each other's answers over {r} rounds" if r > 1 else ""
    system = MODERATOR_SYSTEM.format(rounds_note=rounds_note)
    answers = []
    for m in run.order:
        d = run.done(m, r) or {}
        label = run.display(m)
        a = run.answer(m, r)
        if d.get("status") != "ok" or not a:
            a = f"(no answer: {d.get('error') or 'member did not finish'})"
        answers.append(f"## {label}\n\n{a}")
    user = MODERATOR_PROMPT.format(question=run.question,
                                   round_note=f" (final round {r} of {r})" if r > 1 else "",
                                   answers="\n\n".join(answers))
    return system, user


# ------------------------------------------------------------------ member ---
def cmd_member(args) -> int:
    run = Run(args.run)
    name = args.name
    if name not in run.members:
        sys.exit(f"{name} is not a member of this run")
    m = run.members[name]
    color = run.color(name)
    label = run.display(name)
    sub = "" if run.anonymous else f"{DIM}{m.get('backend')}{(' · ' + m['model']) if m.get('model') else ''}{RESET}"
    out(rule(color))
    out(f"{color}{BOLD}{label}{RESET}  {sub}")
    out(f"{DIM}{run.cfg['question_preview']}{RESET}")
    out(rule(color))
    status = 0
    for rnd in range(1, run.rounds + 1):
        if rnd > 1:
            others = [x for x in run.order if x != name]
            wait_for_done(run, others, rnd - 1, prefix=f"round {rnd}: waiting for peers")
            out(f"\n{color}{BOLD}── round {rnd}: critique and revise ──{RESET}")
        system, user = member_prompt(run, name, rnd)
        waiting = "loading model" if m.get("backend") == "openai" else "thinking"
        answer, err, elapsed = run_backend(m, system, user, run.dir, color, waiting_msg=waiting)
        run.answer_path(name, rnd).write_text(answer)
        info = {"status": "error" if err else "ok", "error": err, "elapsed": round(elapsed, 1),
                "words": words(answer), "finished": dt.datetime.now().isoformat(timespec="seconds")}
        run.done_path(name, rnd).write_text(json.dumps(info))
        out()
        if err:
            status = 1
            out(f"{RED}✗ {label} failed after {fmt_secs(elapsed)}: {err}{RESET}")
        else:
            out(f"{GREEN}✓ {label} done{RESET} {DIM}· {fmt_secs(elapsed)} · {info['words']} words · round {rnd}/{run.rounds}{RESET}")
    return status


# ---------------------------------------------------------------- waiting ---
def wait_for_done(run: Run, names: list[str], rnd: int, prefix: str = "waiting", timeout: float = 1800) -> dict:
    """Block until every member in `names` has a .done file for round `rnd`, with a live status block."""
    t0 = time.time()
    started = {}
    n = len(names)
    first_draw = True
    i = 0
    while True:
        states = {}
        for m in names:
            d = run.done(m, rnd)
            if d:
                states[m] = d
            elif run.answer_path(m, rnd).exists() or m not in started:
                started.setdefault(m, time.time())
        remaining = [m for m in names if m not in states]
        if not first_draw:
            sys.stdout.write(f"\033[{n + 1}A")
        first_draw = False
        elapsed = time.time() - t0
        out(f"{DIM}{SPIN[i % len(SPIN)]} {prefix} · {fmt_secs(elapsed)}{RESET}\033[K")
        for m in names:
            c = run.color(m)
            label = run.display(m)
            d = states.get(m)
            if d is None:
                line = f"  {c}{SPIN[(i + names.index(m)) % len(SPIN)]}{RESET} {label:<28}{DIM}working{RESET}"
            elif d.get("status") == "ok":
                line = f"  {GREEN}✓{RESET} {label:<28}{DIM}{fmt_secs(d['elapsed'])} · {d['words']} words{RESET}"
            else:
                line = f"  {RED}✗{RESET} {label:<28}{RED}{(d.get('error') or 'failed')[:60]}{RESET}"
            out(line + "\033[K")
        if not remaining:
            return states
        if elapsed > timeout:
            out(f"{YELLOW}gave up waiting for: {', '.join(run.display(m) for m in remaining)}{RESET}")
            return states
        i += 1
        time.sleep(0.5)


# --------------------------------------------------------------- moderator ---
def cmd_moderate(args) -> int:
    run = Run(args.run)
    mod = run.cfg["moderator"]
    out(rule(MAGENTA))
    out(f"{MAGENTA}{BOLD}Moderator{RESET}  {DIM}{mod['label']} · {len(run.order)} members · "
        f"{run.rounds} round{'s' if run.rounds > 1 else ''}{' · anonymous' if run.anonymous else ''}{RESET}")
    out(f"{DIM}{run.cfg['question_preview']}{RESET}")
    out(rule(MAGENTA))
    states = wait_for_done(run, run.order, run.rounds, prefix="waiting for the council")
    ok = [m for m in run.order if states.get(m, {}).get("status") == "ok"]
    if len(ok) < 2:
        out(f"{RED}only {len(ok)} member(s) answered; nothing to synthesize.{RESET}")
        write_transcript(run, "")
        return 1
    if len(ok) < len(run.order):
        out(f"{YELLOW}synthesizing from {len(ok)} of {len(run.order)} members{RESET}")
    out(f"\n{MAGENTA}{BOLD}── verdict ──{RESET}\n")
    system, user = moderator_prompt(run)
    verdict, err, elapsed = run_backend(mod, system, user, run.dir, MAGENTA, waiting_msg="synthesizing")
    out()
    if err:
        out(f"{RED}✗ moderator failed after {fmt_secs(elapsed)}: {err}{RESET}")
        (run.dir / "verdict.md").write_text(f"(moderator failed: {err})\n")
        write_transcript(run, "")
        return 1
    score = parse_score(verdict)
    footer = []
    if run.anonymous:
        footer.append("\n## Reveal\n")
        for m in run.order:
            footer.append(f"- {run.members[m]['alias']} = {run.members[m]['label']}")
    (run.dir / "verdict.md").write_text(verdict.rstrip() + "\n" + ("\n".join(footer) + "\n" if footer else ""))
    write_transcript(run, verdict)
    out(rule(MAGENTA))
    if score is not None:
        out(f"{BOLD}Consensus{RESET} {score_bar(score)} {score_color(score)}{BOLD}{score}/100{RESET}")
    if run.anonymous:
        out(f"{BOLD}Reveal{RESET}")
        for m in run.order:
            out(f"  {run.color(m)}{run.members[m]['alias']}{RESET} = {run.members[m]['label']}")
    out(f"{DIM}moderator {fmt_secs(elapsed)} · saved {run.dir / 'verdict.md'}{RESET}")
    out(f"{DIM}transcript {run.dir / 'transcript.md'}{RESET}")
    notify(f"Council verdict ready" + (f" · consensus {score}/100" if score is not None else ""),
           run.cfg["question_preview"])
    return 0


def parse_score(text: str) -> int | None:
    m = re.search(r"Score:\s*\**\s*(\d{1,3})\s*/\s*100", text)
    if not m:
        return None
    return max(0, min(100, int(m.group(1))))


def score_color(s: int) -> str:
    return GREEN if s >= 70 else YELLOW if s >= 40 else RED


def score_bar(s: int, width: int = 30) -> str:
    n = round(s / 100 * width)
    return score_color(s) + "█" * n + GREY + "░" * (width - n) + RESET


def write_transcript(run: Run, verdict: str) -> None:
    lines = [f"# Council transcript", "",
             f"- created: {run.cfg['created']}",
             f"- members: {', '.join(run.members[m]['label'] for m in run.order)}",
             f"- moderator: {run.cfg['moderator']['label']}",
             f"- rounds: {run.rounds}" + (" · anonymous" if run.anonymous else ""), "",
             "# Question", "", run.question.rstrip(), ""]
    for r in range(1, run.rounds + 1):
        lines += [f"# Round {r}", ""]
        for m in run.order:
            d = run.done(m, r) or {}
            title = run.members[m]["label"] + (f" (as {run.members[m]['alias']})" if run.anonymous else "")
            meta = f"{fmt_secs(d['elapsed'])} · {d.get('words', 0)} words" if d else "no result"
            if d and d.get("status") != "ok":
                meta += f" · FAILED: {d.get('error')}"
            lines += [f"## {title}", "", f"_{meta}_", "", run.answer(m, r).rstrip() or "(no answer)", ""]
    lines += ["# Verdict", "", verdict.rstrip() or "(none)", ""]
    (run.dir / "transcript.md").write_text("\n".join(lines))


def notify(title: str, body: str) -> None:
    if os.environ.get("HERDR_ENV") != "1":
        return
    try:
        subprocess.run(["herdr", "notification", "show", title, "--body", body[:120], "--sound", "done"],
                       capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        pass


# ------------------------------------------------------------------ herdr ---
def herdr(*args: str, timeout: float = 30) -> dict:
    """Run a herdr CLI command and return its JSON result. Raises RuntimeError on failure.
    Blocking commands (agent wait / agent prompt --wait) must pass a timeout longer than their own --timeout."""
    try:
        r = subprocess.run(["herdr", *args], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"herdr {' '.join(args[:3])} timed out after {timeout:.0f}s")
    if r.returncode != 0:
        raise RuntimeError(f"herdr {' '.join(args)} failed (exit {r.returncode}): {(r.stderr or r.stdout).strip()[:300]}")
    if not r.stdout.strip():
        return {}                      # some commands (pane run, pane rename on older builds) print nothing on success
    try:
        d = json.loads(r.stdout)
    except ValueError:
        raise RuntimeError(f"herdr {' '.join(args)} returned non-JSON: {r.stdout.strip()[:300]}")
    if "error" in d and "result" not in d:
        raise RuntimeError(f"herdr {' '.join(args)}: {d['error']}")
    return d.get("result", d)


def split(pane: str, direction: str, ratio: float, cwd: pathlib.Path, env: str | None = None) -> str:
    args = ["pane", "split", pane, "--direction", direction, "--ratio", f"{ratio:.3f}", "--cwd", str(cwd), "--no-focus"]
    if env:
        args += ["--env", env]
    d = herdr(*args)
    time.sleep(0.4)
    return d["pane"]["pane_id"]


def split_even(pane: str, direction: str, k: int, cwd: pathlib.Path, env: str | None = None) -> list[str]:
    """Split `pane` into k equal parts along `direction`. herdr's ratio is the share kept by the original pane."""
    panes = [pane]
    cur = pane
    for i in range(k - 1):
        new = split(cur, direction, 1 / (k - i), cwd, env)
        panes.append(new)
        cur = new
    return panes


def arrange_tab(run: Run, focus: bool) -> None:
    ws = os.environ.get("HERDR_WORKSPACE_ID", "")
    n = len(run.order)
    label = f"⚖ {run.cfg['question_preview'][:34]}"
    tab_args = ["tab", "create", "--cwd", str(run.dir), "--label", label, "--focus" if focus else "--no-focus"]
    if ws:
        tab_args += ["--workspace", ws]
    t = herdr(*tab_args)
    root = t["root_pane"]["pane_id"]
    time.sleep(0.4)
    # members on top, moderator across the bottom
    mod_pane = split(root, "down", 0.55 if n <= 4 else 0.62, run.dir)
    ncols = n if n <= 4 else (n + 1) // 2
    nrows = (n + ncols - 1) // ncols
    row_panes = split_even(root, "down", nrows, run.dir)
    grid: list[str] = []
    for r, rp in enumerate(row_panes):
        in_row = min(ncols, n - r * ncols)
        grid += split_even(rp, "right", in_row, run.dir)
    cmd_base = f"clear; {PY} {SCRIPT}"
    for name, pane in zip(run.order, grid):
        herdr("pane", "rename", pane, run.display(name))
        herdr("pane", "run", pane, f"{cmd_base} member --run {run.dir} --name {name}")
    herdr("pane", "rename", mod_pane, f"Moderator · {run.cfg['moderator']['label']}")
    herdr("pane", "run", mod_pane, f"{cmd_base} moderate --run {run.dir}")
    out(f"{GREEN}council convened{RESET} in tab {t['tab']['tab_id']} · {n} members · run {run.dir.name}")


def run_inline(run: Run) -> int:
    """No herdr: members run as background processes, moderator streams here."""
    logs = run.dir / "logs"
    logs.mkdir(exist_ok=True)
    procs = []
    for name in run.order:
        log = open(logs / f"{name}.log", "w")
        procs.append(subprocess.Popen([PY, str(SCRIPT), "member", "--run", str(run.dir), "--name", name],
                                      stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL))
    out(f"{DIM}{len(procs)} members running in the background (logs in {logs}){RESET}")
    try:
        return cmd_moderate(argparse.Namespace(run=str(run.dir)))
    finally:
        for p in procs:
            if p.poll() is None:
                p.terminate()


# ----------------------------------------------------------------- ask etc ---
def cmd_ask(args) -> int:
    cfg = load_config()
    d = cfg["defaults"]
    question = args.question
    if question is None or question == "-":
        if sys.stdin.isatty():
            sys.exit("give a question as an argument, or pipe one on stdin")
        question = sys.stdin.read()
    if not question.strip():
        sys.exit("empty question")
    members = [m.strip() for m in (args.members or ",".join(d.get("members", []))).split(",") if m.strip()]
    moderator = args.moderator or d.get("moderator") or members[0]
    rounds = args.rounds if args.rounds is not None else int(d.get("rounds", 1))
    anonymous = args.anonymous or (not args.no_anonymous and bool(d.get("anonymous", False)))
    if rounds < 1:
        sys.exit("--rounds must be at least 1")
    run = create_run(cfg, question, args.file or [], members, moderator, rounds, anonymous)
    out(f"{DIM}run {run.dir}{RESET}")
    in_herdr = os.environ.get("HERDR_ENV") == "1" and shutil.which("herdr") and not args.inline
    if not in_herdr:
        if not args.inline:
            out(f"{YELLOW}not inside herdr; running inline{RESET}")
        return run_inline(run)
    try:
        arrange_tab(run, focus=not args.no_focus)
    except RuntimeError as e:
        out(f"{RED}{e}{RESET}")
        out(f"{YELLOW}falling back to inline mode{RESET}")
        return run_inline(run)
    return 0


def check_member(name: str, m: dict) -> tuple[bool, str]:
    b = m.get("backend")
    if b == "claude":
        if not shutil.which("claude"):
            return False, "claude CLI not on PATH"
        r = subprocess.run(["claude", "auth", "status"], capture_output=True, text=True, timeout=15)
        try:
            j = json.loads(r.stdout)
            return bool(j.get("loggedIn")), "logged in" if j.get("loggedIn") else "not logged in"
        except ValueError:
            return False, (r.stderr or r.stdout).strip()[:80]
    if b == "codex":
        if not shutil.which("codex"):
            return False, "codex CLI not on PATH"
        ok = (pathlib.Path.home() / ".codex" / "auth.json").exists()
        return ok, "auth.json present" if ok else "not logged in (run: codex login)"
    if b == "pi":
        if not shutil.which("pi"):
            return False, "pi CLI not on PATH"
        r = subprocess.run(["pi", "auth", "check", "--provider", m.get("provider", "openrouter"), "--json"],
                           capture_output=True, text=True, timeout=20)
        try:
            j = json.loads(r.stdout)
            ok = bool(j.get("ok", j.get("ready", r.returncode == 0)))
        except ValueError:
            ok = r.returncode == 0
        return ok, f"pi · provider {m.get('provider', 'openrouter')} {'ready' if ok else 'not ready'}"
    if b == "openai":
        base = m.get("base_url", "http://localhost:1234/v1").rstrip("/")
        key = m.get("api_key") or os.environ.get(m.get("api_key_env", ""), "") or "local"
        try:
            req = urllib.request.Request(base + "/models", headers={"Authorization": f"Bearer {key}"})
            with urllib.request.urlopen(req, timeout=5) as r:
                ids = [x.get("id") for x in json.load(r).get("data", [])]
        except (urllib.error.URLError, OSError, ValueError) as e:
            return False, f"server unreachable ({base})"
        if m["model"] in ids:
            return True, f"available at {base}"
        return False, f"model not listed at {base}"
    return False, f"unknown backend {b!r}"


def cmd_members(args) -> int:
    cfg = load_config()
    d = cfg["defaults"]
    out(f"{BOLD}Council members{RESET} {DIM}({CONFIG_PATH}){RESET}")
    defaults = d.get("members", [])
    for name, m in cfg["members"].items():
        ok, msg = check_member(name, m)
        mark = f"{GREEN}●{RESET}" if ok else f"{RED}○{RESET}"
        tag = f" {CYAN}default{RESET}" if name in defaults else ""
        tag += f" {MAGENTA}moderator{RESET}" if name == d.get("moderator") else ""
        out(f"  {mark} {BOLD}{name:<12}{RESET} {m.get('label', ''):<28} {DIM}{m.get('backend')}"
            f"{(' · ' + m['model']) if m.get('model') else ''} · {msg}{RESET}{tag}")
    out(f"{DIM}defaults: rounds={d.get('rounds', 1)} anonymous={d.get('anonymous', False)}{RESET}")
    return 0


def cmd_runs(args) -> int:
    if not RUNS.exists():
        out("no runs yet")
        return 0
    rows = sorted(RUNS.iterdir())
    if not rows:
        out("no runs yet")
        return 0
    for r in rows[-int(args.limit):]:
        try:
            run = Run(r)
        except (OSError, ValueError):
            continue
        v = r / "verdict.md"
        score = parse_score(v.read_text()) if v.exists() else None
        s = f"{score_color(score)}{score:>3}/100{RESET}" if score is not None else f"{DIM}   —   {RESET}"
        out(f"{s}  {DIM}{run.cfg['created'][:16]}{RESET}  {run.cfg['question_preview'][:70]}  "
            f"{DIM}{r.name}{RESET}")
    return 0


def cmd_show(args) -> int:
    if args.run:
        rdir = pathlib.Path(args.run)
        if not rdir.exists() and (RUNS / args.run).exists():
            rdir = RUNS / args.run
    else:
        cands = sorted(p for p in RUNS.glob("*/verdict.md")) if RUNS.exists() else []
        if not cands:
            sys.exit("no finished runs")
        rdir = cands[-1].parent
    target = rdir / ("transcript.md" if args.transcript else "verdict.md")
    if not target.exists():
        sys.exit(f"{target} does not exist yet")
    out(f"{DIM}{target}{RESET}\n")
    out(target.read_text())
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="council", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("ask", help="convene the council on a question")
    a.add_argument("question", nargs="?", help="the question; '-' or omitted reads stdin")
    a.add_argument("-f", "--file", action="append", help="attach a text file (repeatable)")
    a.add_argument("-m", "--members", help="comma-separated member names (default from council.toml)")
    a.add_argument("--moderator", help="member name to use as moderator")
    a.add_argument("-r", "--rounds", type=int, help="1 = independent answers; 2+ = members critique each other")
    a.add_argument("--anonymous", action="store_true", help="show members as Model A/B/C until the verdict")
    a.add_argument("--no-anonymous", action="store_true", help="override anonymous=true in config")
    a.add_argument("--inline", action="store_true", help="do not open herdr panes; run here")
    a.add_argument("--no-focus", action="store_true", help="create the herdr tab without switching to it")
    a.set_defaults(fn=cmd_ask)

    m = sub.add_parser("member")
    m.add_argument("--run", required=True)
    m.add_argument("--name", required=True)
    m.set_defaults(fn=cmd_member)

    md = sub.add_parser("moderate")
    md.add_argument("--run", required=True)
    md.set_defaults(fn=cmd_moderate)

    sub.add_parser("members", help="list configured members and check they are reachable").set_defaults(fn=cmd_members)

    r = sub.add_parser("runs", help="list past runs")
    r.add_argument("-n", "--limit", default=20)
    r.set_defaults(fn=cmd_runs)

    s = sub.add_parser("show", help="print a verdict (latest by default)")
    s.add_argument("run", nargs="?", help="run directory or name")
    s.add_argument("-t", "--transcript", action="store_true", help="print the full transcript instead")
    s.set_defaults(fn=cmd_show)

    import chat
    chat.add_subcommands(sub)

    args = ap.parse_args(argv)
    try:
        return int(args.fn(args) or 0)
    except KeyboardInterrupt:
        out(f"\n{DIM}interrupted{RESET}")
        return 130


if __name__ == "__main__":
    sys.exit(main())
