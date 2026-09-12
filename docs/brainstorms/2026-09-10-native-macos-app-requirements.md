---
date: 2026-09-10
topic: native-macos-app
---

# Council as a native macOS app

## Problem Frame

council today is two Python scripts driving herdr panes: a prompt_toolkit chat window on the left and the member CLIs (Claude Code, Codex, pi) stacked on the right. It works, but conversations read as wrapped terminal text, member state detection is fragile (pi especially), and the whole thing depends on herdr for layout, prompt injection, and restart recovery.

The goal is a native macOS app with a modern chat-client look: a sidebar listing the current session's agents and past sessions, and a main pane showing the conversation. Members still run as real interactive CLI sessions on their OAuth logins; the app hides those terminals by default and surfaces the conversation instead.

Reference look: two-column messaging app (sidebar + thread). Light, rounded, avatars, "typing" indicators, unread badges. The left navigation column from the reference is dropped.

```
┌──────────────┬──────────────────────────────────────────┐
│ AGENTS       │  Planning · 3 members · Codex is working… │
│ ● Claude     │──────────────────────────────────────────│
│ ◐ Codex      │  [Claude]  Here's what I'd do first …     │
│ ○ DeepSeek   │  [Codex]   @claude the loader is …        │
│              │  [you]     wrap it up                     │
│ SESSIONS     │                                          │
│ planning  2m │                                          │
│ verdict: pg… │                                          │
│ debt review  │──────────────────────────────────────────│
│              │  Type a message…            [wrap] [send] │
└──────────────┴──────────────────────────────────────────┘
```

## Requirements

### Layout and navigation
- R1. Two-column window: a sidebar and a main pane. No third navigation column.
- R2. Sidebar top section **Agents** lists the members of the currently open session with avatar, label (e.g. "Claude Fable 5.1"), and live status (idle / working / blocked / error / muted).
- R3. Sidebar bottom section **Sessions** lists past and current sessions, newest first, showing name, type (chat or verdict), last activity, and an unread badge when new posts arrived while the session was not open.
- R4. Clicking an agent in **Agents** toggles the main pane between the conversation and that agent's live terminal. Clicking it again, or clicking the session header, returns to the conversation.
- R5. Terminals are never shown unless the user asks (R4) or is prompted to (R13).

### Conversation view
- R6. Messages render as chat bubbles with sender avatar, label, timestamp, and full Markdown (headings, lists, code blocks with syntax highlighting, tables, links). Long replies stay readable; no terminal wrapping.
- R7. @mentions render as chips. Mentions typed in the composer autocomplete against the session's members plus `all`/`everyone`.
- R8. While a member is working, the session header and its sidebar row show an activity line naming what it is doing when known ("Claude is reading chat.py", "Codex ran pytest"), falling back to "working… 0:42" with elapsed time. The line disappears when the reply posts.
- R9. System notes (member silent, budget exhausted, nothing to add, retrying after API error) appear inline as dim notes, as today.
- R10. Composer supports: plain message to all, @mention routing, a **Wrap up** action, a budget control, and per-member mute/unmute (from the agent row's context menu). These replace `/wrap`, `/budget`, `/mute`, `/who`.
- R11. Typing in the composer while a member is blocked or errored still works; the app never locks the input.
- R11a. **Reaction pass.** After a user message, once every member it was delivered to has finished its turn (posted or had nothing to add), each of those members is prompted once more to read the replies of the others and respond only if it has something to add. A member already @mentioned in that first round is not prompted twice. The pass happens once per user message, counts against the budget, and does not run during wrap-up. After it, routing returns to mention-only, so exchanges still end on their own.

### Members and terminals
- R12. Claude Code and Codex run as real interactive terminal sessions using their normal OAuth logins. No print/headless mode for these two. pi also runs as an interactive terminal session so all members behave the same way.
- R13. When a member is blocked on a dialog (permission prompt, re-login) or exits with an error, the conversation shows a card naming the member and the problem with an **Open terminal** action that performs R4. Resolving it in the terminal clears the card.
- R14. Every message routed to a member ends in exactly one of: a posted reply, a "nothing to add" note, or a blocked/error card. Silent drops are a bug.
- R15. Members keep posting through the `council post` helper from their own shell tools, so the helper stays installed and on PATH for the member sessions.

### Sessions
- R16. **New session** asks for type (chat or verdict), a name, the project folder the members work in, and which configured members to include (default from council.toml).
- R17. Chat sessions and verdict runs share the Sessions list and the same reading experience. Verdict runs additionally show each member's independent answer, then a moderator card with the merged verdict and consensus score. Optional second round and anonymous mode are preserved.
- R18. Verdict runs use fresh hidden interactive sessions per member and for the moderator, using the same posting mechanism as chat. No `-p` / `exec` usage.
- R19. Quitting and reopening the app restores the open session: conversation history, member roster, and the Claude Code and Codex sessions resumed in place. Members that cannot be resumed (pi) restart with the transcript as context, as today.
- R20. Sessions, transcripts, and verdict runs stay in the existing on-disk layout (`chats/`, `runs/`, `council.toml`) so the CLI keeps working and existing chats open in the app.
- R21. macOS notifications when a member posts while the app is in the background, and when a verdict completes.

## Success Criteria
- You stop using `council session` under herdr for day-to-day work.
- In a week of use, fewer stalled prompts and missed completion detections than herdr, and none of them silent (R14).
- Conversations are readable enough that you reread transcripts in the app rather than opening `transcript.md`.
- After a reboot, opening the app and clicking the last session brings back the chat with Claude Code and Codex resumed, without manual steps.

## Scope Boundaries
- No editing of council.toml in the app (roster, models, effort). Read it, don't write it. A Members/Settings screen is a later phase.
- No herdr integration; the app replaces herdr for council, it does not drive it.
- No side-by-side terminal stacking. One terminal at a time, on request.
- No App Store distribution. The app spawns arbitrary CLIs with permission bypass flags and must run unsandboxed.
- No iOS, no sync, no multi-user.
- No headless/API mode for Claude Code or Codex.

## Key Decisions
- Two columns, not three: the reference's left nav adds nothing for a single-purpose app.
- Terminals hidden by default, one click away via the agent row: keeps the chat-app feel while preserving the ability to unblock dialogs and watch a member work.
- Reaction pass after the first round: today members reply once and never see each other's answers unless someone @mentions them, so the "council" rarely deliberates. One guaranteed read of the others' replies fixes that without reopening runaway loops.
- Live activity line over a full tool log: gives the "watching them work" feel at low clutter; a detailed log can be added later if missed.
- Verdicts reuse the chat mechanism with fresh hidden sessions: one delivery path to make reliable, and no API billing.
- Keep the on-disk format and the `council post` helper: members need a way to speak from inside their tools, and compatibility with the CLI is free.
- All three members as terminals (including pi): uniform handling; pi's weak state detection must be solved rather than avoided.

## Dependencies / Assumptions
- Claude Code and Codex TUIs run correctly inside an embedded terminal emulator (they do under herdr today).
- Each CLI exposes some reliable signal of turn start/end and blocked state that the app can consume without scraping screen text. Where it doesn't, output quiescence remains the fallback.
- Feature parity with the current chat (mentions, wrap, budget, mute, resume by name) is assumed as a baseline even though reliability, readability, and restart survival were named as the switching criteria.

## Outstanding Questions

### Resolve Before Planning
- (none)

### Deferred to Planning
- [Affects R8][Needs research] Which CLI events are available to drive the activity line for Claude Code, Codex, and pi in interactive mode, and how does the app receive them?
- [Affects R14][Technical] How does the app know a terminal session is ready to accept a pasted prompt, so injection never stalls?
- [Affects R19][Technical] How are Claude Code and Codex session ids captured so they can be resumed, and what happens when resume fails?
- [Affects R12][Needs research] pi's state detection: does pi expose hooks/extensions the app can use, or is quiescence detection the only option?
- [Affects R6][Technical] Markdown rendering approach for streaming and long transcripts.
- [Affects R20][Technical] Whether the Python router logic is ported to Swift or kept as a sidecar the app talks to; either satisfies the requirements.

## Next Steps
→ /ce:plan for structured implementation planning
