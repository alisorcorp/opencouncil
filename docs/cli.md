# The terminal version

Open Council started as two Python files driving [herdr](https://herdr.dev) panes, and that version still runs.
The command is `council`. It shares `council.toml`, `chats/` and `runs/` with the macOS app, so a chat you start
in one opens in the other.

The app is the better experience for most things now. Use this if you live in a terminal multiplexer, or if you
want the verdict mode's non-interactive path, which the app doesn't have.

Kimi Code is the one member this can't host. herdr has no kimi agent kind, so kimi members are app only.

## What you need

1. **Python 3.11+** (for `tomllib`) and `prompt_toolkit` for the chat window: `pip3 install prompt_toolkit`.
2. **herdr** on your PATH. The chat and verdict layouts are herdr panes, and `council session` starts and
   attaches herdr sessions.
3. **Claude Code** (`claude`) logged in. `council members` checks `claude auth status`. Verdict mode runs
   `claude -p` with `ANTHROPIC_API_KEY` stripped from the environment, so it uses your claude.ai login rather
   than an API key.
4. **Codex CLI** (`codex`) logged in, which means `~/.codex/auth.json` exists. Run `codex login` if it doesn't.
5. **pi** ([pi-mono](https://github.com/badlogic/pi-mono)) for the OpenRouter member, which gets the same file
   and shell tools as the other two. It came from the npm package `@earendil-works/pi-coding-agent` on the
   machine this was built on.
6. **An OpenRouter API key** in pi's own config at `~/.pi/agent/models.json`. council never reads the key. pi
   does. Copy `pi-openrouter-models.example.json` as a starting point, put your key in
   `providers.openrouter.apiKey`, and keep the entry for `deepseek/deepseek-v4.1-flash`. Check it with:

   ```bash
   pi -p --provider openrouter --model deepseek/deepseek-v4.1-flash --no-session "say hello"
   ```

Then:

```bash
./install.sh            # writes ~/.local/bin/council pointing at this folder
council members         # every row should show a green dot
council session test    # opens herdr session "test", then type something
```

## Chat

```bash
council session planning          # from a plain terminal: opens herdr session "planning" with everything loaded
council session planning          # again later: re-attaches, or resumes the chat if herdr was restarted
council session planning --new    # start a fresh chat under the same name
council chat                      # same layout as a new tab, when you're already inside herdr
```

The chat pane is on the left and the members are stacked on the right, so you can watch them read files and run
commands while they think.

- What you type goes to every member. `@codex …` goes only to Codex.
- A member's message that mentions someone is delivered to them, and they reply. A message with no mentions is
  visible to everyone but triggers nothing, so exchanges end on their own.
- Say "wrap it up" (or `/wrap`) and everyone posts a final position without mentions. Your next message resumes
  normal routing.
- A budget, 12 member replies per message you send by default, stops runaway loops. `/budget N` changes it.
- `/mute name`, `/unmute name`, `/who`, `/help`, `/quit`. Quitting leaves the chat, and the members keep running.

Members speak by running `council post --as NAME "…"` in their own pane. `council log` prints the chat so far,
and `transcript.md` in the chat directory is kept up to date.

Each chat lives in `chats/<timestamp>_<name>/` with `chat.jsonl`, `config.json` and `transcript.md`.
`chats/current` points at the latest one.

Resuming works by name: `council session NAME` reuses the latest chat called NAME. If herdr itself was restarted,
it brings back the layout and the Claude Code and Codex sessions on its own, and council relaunches the chat
window with the history, starts whatever herdr couldn't restore with a note telling it to read `transcript.md`
first, and re-briefs the rest. Members are read from the current `council.toml`, so a changed roster takes
effect on resume.

## Verdict

```bash
council ask "Should we migrate this service from Postgres to SQLite?"
council ask -f plan.md "Critique this plan"            # attach files (repeatable)
council ask -r 2 --anonymous "..."                     # members critique each other, shown as Model A/B/C
council ask -m claude,codex,gemini --moderator codex "..."
council ask --inline "..."                             # no panes, verdict prints here
council runs                                           # past runs with consensus scores
council show [run]                                     # print a verdict, -t for the transcript
```

Members go across the top and the moderator across the bottom. Round 1 answers are independent. With `-r 2` each
member sees the others' answers, anonymized, and revises before the moderator synthesizes. Runs are saved under
`runs/`.

`council ask` is the one command that doesn't need herdr. Outside a herdr session it prints "not inside herdr;
running inline" and runs the members as background processes, streaming the moderator to your terminal.

## Backends

`council members` checks that each configured member is reachable. Members live in `council.toml`, which is
created with defaults on first run.

| backend | verdict mode | chat mode |
|---|---|---|
| `claude` | `claude -p`, tools off, claude.ai login | interactive Claude Code in a herdr pane |
| `codex` | `codex exec`, read-only sandbox | interactive Codex in a herdr pane |
| `pi` | `pi -p`, tools off, any provider pi knows | interactive pi in a herdr pane, with tools and nothing gating them |
| `kimi` | not supported | app only |
| `openai` | any OpenAI-compatible chat endpoint | a small streaming client, no tools |

`pi` members take `provider` and `model`, and pi's own `~/.pi/agent/models.json` supplies the keys. For `openai`
members the key comes from `api_key`, `$api_key_env`, or a dotted path into a JSON file (`api_key_file` plus
`api_key_json`).

Interactive members start in their CLI's asking mode, the same as in the app, so a member may stop and wait for
you to approve something in its own pane. pi is the exception. It has no permission system at all, which is why
the shipped roster doesn't name a pi member and why `council ask` runs pi with `--no-tools`. See the README's
permissions section for what each one is started with and how to change it.

## Notes

- The Gemini CLI isn't used. Google retired its individual tier, so Gemini goes through OpenRouter, driven by pi.
- Coordination is a JSONL file plus `herdr agent prompt`. Nothing scrapes terminal output for content. A member
  that dies or stays silent shows up as a dim note in the chat.
