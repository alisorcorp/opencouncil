#!/bin/sh
# Scenario tests for the delivery chain (Unit 6). Each one builds a throwaway council folder, runs the app's
# drive harness against the scripted stand-in instead of a real CLI, and checks what the ledger and the bus say
# happened — so "every routed message ends in a reply, a note, or a card" (R14) is a test rather than a hope.
#
#   app/Tools/integration/fake-member-flows.sh              # every scenario
#   app/Tools/integration/fake-member-flows.sh crash deaf   # some of them
#
# No model calls and no quota: the members are `app/Tools/fake-member.py`. The temporary council folder lives
# outside ~/Documents on purpose, so macOS does not ask for file-access permission on every run.
set -e
cd "$(dirname "$0")/../../.."          # repo root
ROOT_REPO="$PWD"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
DERIVED="${DERIVED:-$ROOT_REPO/app/.build/DerivedData}"
APP="$DERIVED/Build/Products/Debug/Council.app/Contents/MacOS/Council"
WORK="${WORK:-$(mktemp -d /private/tmp/council-flows.XXXXXX)}"
MEMBERS="claude codex"
PASS=0
FAIL=0

echo "building…"
sh app/build.sh build >/dev/null

# A fresh council folder with one chat in it, so scenarios cannot contaminate each other.
new_chat() {
  root="$WORK/$1"
  chat="$root/chats/2026-01-01_000000_$1"
  mkdir -p "$chat/inbox" "$chat/status" "$root/runs" "$root/app/Tools"
  cp council.toml council.py chat.py "$root/"
  cp app/Tools/fake-member.py "$root/app/Tools/"
  : > "$chat/chat.jsonl"
  python3 - "$chat" "$root" <<'PY'
import json, sys
chat, root = sys.argv[1], sys.argv[2]
members = {n: {"name": n, "backend": b, "label": n, "chat_args": [], "chat_kind": "herdr"}
           for n, b in (("claude", "claude"), ("codex", "codex"))}
json.dump({"created": "2026-01-01T00:00:00", "cwd": root, "title": "flow", "members": members,
           "order": ["claude", "codex"], "budget": 20, "effort": "medium"},
          open(f"{chat}/config.json", "w"), indent=2, sort_keys=True)
PY
  echo "$chat"
}

# Another chat inside a council folder `new_chat` already made. The live cap is a property of the folder, not
# of one chat, so that scenario needs several in the same place.
add_chat() {
  root="$1"; chat="$root/chats/2026-01-01_000000_$2"
  mkdir -p "$chat/inbox" "$chat/status"
  : > "$chat/chat.jsonl"
  python3 - "$chat" "$root" "$2" <<'PY'
import json, sys
chat, root, title = sys.argv[1], sys.argv[2], sys.argv[3]
members = {n: {"name": n, "backend": b, "label": n, "chat_args": [], "chat_kind": "herdr"}
           for n, b in (("claude", "claude"), ("codex", "codex"))}
json.dump({"created": "2026-01-01T00:00:00", "cwd": root, "title": title, "members": members,
           "order": ["claude", "codex"], "budget": 20, "effort": "medium"},
          open(f"{chat}/config.json", "w"), indent=2, sort_keys=True)
PY
  echo "$chat"
}

# A verdict run inside a council folder `new_chat` already made. Runs hold slots under the same cap as chats,
# so the live-cap scenario needs both kinds in one folder.
add_run() {
  root="$1"; run="$root/runs/2026-01-01_000000_$2"
  mkdir -p "$run/r1"
  python3 - "$run" <<'PY'
import json, sys
run = sys.argv[1]
names = ["claude", "codex", "deepseek"]
members = {n: {"name": n, "backend": b, "label": n.title(), "alias": n.title()}
           for n, b in (("claude", "claude"), ("codex", "codex"), ("deepseek", "pi"))}
json.dump({"created": "2026-01-01T00:00:00", "question_preview": "Is the ledger enough?",
           "members": members, "order": names,
           "moderator": {"name": "deepseek", "backend": "pi", "label": "Deepseek"},
           "rounds": 1, "anonymous": False, "length": "about 50 words", "attachments": []},
          open(f"{run}/config.json", "w"), indent=2, sort_keys=True)
open(f"{run}/question.md", "w").write("Is the ledger enough?\n")
PY
  echo "$run"
}

# checklog <file> <literal needle> <description> — for harnesses that check themselves and say so line by line.
checklog() {
  if grep -qF "$2" "$1"; then
    echo "  ✓ $3"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $3"
    echo "    log: $(tail -20 "$1")"
    FAIL=$((FAIL + 1))
  fi
}

# check <chat> <python expression over `deliveries`, `notes`, `posts`> <description>
check() {
  chat="$1"; expr="$2"; what="$3"
  if python3 - "$chat" "$expr" <<'PY'
import json, os, re, sys
chat, expr = sys.argv[1], sys.argv[2]
def load(name):
    """The same rule the app has: a line nothing can decode is still a message that exists. A reader that
    threw here would fail every check in a scenario about exactly that."""
    path = os.path.join(chat, name)
    if not os.path.exists(path):
        return []
    out = []
    for line in open(path, errors="surrogateescape"):
        if not line.strip():
            continue
        try:
            out.append(json.loads(line))
        except ValueError:
            who = re.search(r'"from": "([^"]+)"', line)
            out.append({"from": who.group(1) if who else "?", "kind": "unreadable",
                        "text": "(unreadable record)"})
    return out
records, order, latest = load("deliveries.jsonl"), [], {}
for d in records:
    if d["id"] not in latest: order.append(d["id"])
    latest[d["id"]] = d
deliveries = [latest[i] for i in order]
bus = load("chat.jsonl")
notes = [m["text"] for m in bus if m.get("kind") == "note"]
posts = [m for m in bus if m.get("kind") != "note" and m["from"] != "user"]
outcomes = [d["outcome"] for d in deliveries]
sys.exit(0 if eval(expr) else 1)
PY
  then
    echo "  ✓ $what"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $what"
    echo "    ledger: $(cat "$chat/deliveries.jsonl" 2>/dev/null | tail -4)"
    echo "    notes:  $(python3 -c "
import json, sys
out = []
for l in open(sys.argv[1], errors='surrogateescape'):
    try:
        m = json.loads(l)
    except ValueError:
        continue
    if m.get('kind') == 'note':
        out.append(m['text'])
print(out)" "$chat/chat.jsonl" 2>/dev/null)"
    FAIL=$((FAIL + 1))
  fi
}

# drive <chat> <timeout> [env VAR=1 ...] [-- <extra drive flags>]
drive() {
  chat="$1"; shift
  timeout="$1"; shift
  pre=""
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do pre="$pre $1"; shift; done
  [ "${1:-}" = "--" ] && shift
  # shellcheck disable=SC2086
  COUNCIL_FAKE_MEMBERS=1 $pre "$APP" --drive "$chat" "Say something short." --timeout "$timeout" "$@" \
      >"$chat/drive.log" 2>&1 || true
}

run_happy() {
  echo "happy path: both members answer"
  chat=$(new_chat happy)
  drive "$chat" 40
  check "$chat" "len(deliveries) >= 4 and set(outcomes) == {'posted'}" "every delivery ends posted"
  check "$chat" "not notes" "no notes: nothing went missing"
}

run_nopost() {
  echo "no post: the member finishes its turn without saying anything"
  chat=$(new_chat nopost)
  drive "$chat" 40 env FAKE_NO_POST=1
  check "$chat" "'nothingToAdd' in outcomes" "the delivery is recorded as nothing-to-add"
  check "$chat" "any('had nothing to add' in n for n in notes)" "the chat says so"
}

run_unreadable() {
  echo "a post that reaches the log unreadable: visible, attributed, and not silence"
  chat=$(new_chat unreadable)
  drive "$chat" 60 env FAKE_UNREADABLE=1 FAKE_ONLY=claude
  check "$chat" "any(m['from'] == 'claude' and m.get('kind') != 'note' for m in bus)" \
        "the record is in the chat, attributed to claude"
  check "$chat" "not any('had nothing to add' in n for n in notes)" \
        "the chat does not report silence: that was the falsehood"
  check "$chat" "'nothingToAdd' not in [d['outcome'] for d in deliveries if d['member'] == 'claude']" \
        "claude's deliveries close, rather than waiting for a post that already happened"
  # The stand-in quotes the first line of whatever it was handed, so what codex posts says what codex was shown.
  check "$chat" "not any('could not be read' in m['text'] for m in bus if m['from'] == 'codex')" \
        "codex was never handed the diagnostic as claude's words"
}

run_deaf() {
  echo "deaf: the prompt is never acknowledged"
  chat=$(new_chat deaf)
  drive "$chat" 70 env FAKE_DEAF=1
  check "$chat" "max(d['attempts'] for d in deliveries) == 3" "pasted three times"
  check "$chat" "'failed' in outcomes" "then given up on"
  check "$chat" "any('did not accept the prompt' in n for n in notes)" "and said so on the bus"
}

run_crash() {
  echo "crash: the CLI dies on the first prompt"
  chat=$(new_chat crash)
  drive "$chat" 40 env FAKE_CRASH=1
  check "$chat" "'failed' in outcomes" "the open delivery is closed as failed"
}

run_slowstart() {
  echo "slow start: the CLI takes its time before announcing itself"
  chat=$(new_chat slowstart)
  drive "$chat" 60 env FAKE_SLOW_START=4
  check "$chat" "set(outcomes) == {'posted'}" "a slow member still gets briefed and answers"
}

run_nostart() {
  echo "no start event: readiness has to come from a settled screen (Codex's case)"
  chat=$(new_chat nostart)
  drive "$chat" 90 env FAKE_NO_START=1
  check "$chat" "'posted' in outcomes" "the member is found ready anyway"
}

run_interrupted() {
  echo "interrupted: a delivery the app never finished is asked again"
  chat=$(new_chat interrupted)
  python3 - "$chat" <<'SEED'
import json, sys
record = {"id": "orphan", "member": "claude", "opened": "2026-01-01T00:00:00",
          "upToMessageId": 1, "attempts": 1, "text": "[user] finish this thought"}
open(f"{sys.argv[1]}/deliveries.jsonl", "w").write(json.dumps(record) + "\n")
SEED
  drive "$chat" 40
  check "$chat" "any((d.get('text') or '').startswith('The app restarted') for d in deliveries)" "the delivery goes out again"
  check "$chat" "any('will be asked again' in n for n in notes)" "and the chat says why"
  check "$chat" "[d for d in deliveries if d['id'] == 'orphan'][0]['outcome'] == 'interrupted'" "the old record is closed"
}

run_resumefails() {
  echo "resume fails: the CLI no longer has the session it was asked for"
  chat=$(new_chat resumefails)
  python3 - "$chat" <<'SEED'
import json, sys
state = {"live": True, "muted": [], "sessionIds": {"claude": "gone-1", "codex": "gone-2"}}
open(f"{sys.argv[1]}/app.json", "w").write(json.dumps(state))
SEED
  drive "$chat" 60 env FAKE_RESUME_FAILS=1 -- --resume
  check "$chat" "'posted' in outcomes" "the member starts fresh and answers anyway"
  check "$chat" "any('could not resume' in n for n in notes)" "and the chat says the session was gone"
}

run_blocked() {
  echo "blocked: a permission prompt nobody answers"
  chat=$(new_chat blocked)
  drive "$chat" 25 env FAKE_BLOCK=1
  check "$chat" "deliveries and all(d['outcome'] for d in deliveries)" "no delivery is left open"
}

run_permission() {
  echo "permission: a member asks before running a command, and only the user may answer"
  chat=$(new_chat permission)
  # Members no longer start with their CLI's stop-asking flag, so this is now an ordinary event rather than
  # an exotic one, and the app's own delivery is the thing most likely to answer it by accident.
  drive "$chat" 25 env FAKE_PERMISSION=1 FAKE_ONLY=claude
  check "$chat" "'attention claude: permission requested for Bash' in open(chat + '/drive.log').read()" \
        "the chat raises a card naming what was asked for"
  check "$chat" "not os.path.exists(chat + '/.fake-permission-claude')" \
        "nothing the app sent answered the prompt"
  check "$chat" "all(d['outcome'] for d in deliveries)" "no delivery is left open"
  check "$chat" "any(m['from'] == 'codex' for m in posts)" "the members that were not asked answer regardless"
}

run_slots() {
  echo "live cap: a verdict run takes a slot from a chat, and that chat's members stop"
  new_chat slots >/dev/null
  root="$WORK/slots"
  for extra in second third; do add_chat "$root" "$extra" >/dev/null; done
  add_run "$root" asking >/dev/null
  # The transfer with real processes on both sides: the unit tests can see which branch runs, but not that a
  # slot was freed and something else took it — nothing is running in them.
  COUNCIL_FAKE_MEMBERS=1 "$APP" --slots "$root" >"$root/slots.log" 2>&1 || true
  checklog "$root/slots.log" "ok   3 sessions hold slots" "three sessions fill the cap"
  checklog "$root/slots.log" "ok   the fourth session is offered the picker" "a fourth is offered the picker, not refused"
  checklog "$root/slots.log" "ok   and did not start behind the picker's back" "and nothing started behind it"
  checklog "$root/slots.log" "ok   the picker offers 3 sessions" "the picker names every slot-holder"
  checklog "$root/slots.log" "ok   its members' processes are gone" "taking the slot really stops the session that held it"
  checklog "$root/slots.log" "ok   the session that asked is live" "and starts the one that asked"
  checklog "$root/slots.log" "ok   and the cap still holds" "with the cap still held"
  # Several of the checks above pass vacuously when nothing started at all, so the harness's own verdict —
  # which counts every assertion, including the ones about the setup — has to be one of them.
  checklog "$root/slots.log" "] OK" "and the harness passed every one of its own checks"
}

run_trust() {
  echo "trust: a member that opens on a directory-trust dialog is never answered by the app"
  chat=$(new_chat trust)
  # claude holds Codex's trust dialog open and announces nothing, which is what the real one does. The app
  # used to call that settled screen ready and paste the briefing into it — and the Enter at the end of the
  # paste selected "1. Yes, continue", confirming a prompt-injection warning on the user's behalf. The dialog
  # records anything sent to it, so the marker file's absence is the assertion.
  drive "$chat" 20 env FAKE_TRUST_PROMPT=1 FAKE_ONLY=claude -- --to codex
  check "$chat" "not os.path.exists(chat + '/.fake-trust-claude')" "nothing the app sent answered the dialog"
  check "$chat" "'attention claude: folder trust dialog' in open(chat + '/drive.log').read()" \
        "the chat raises a card naming the dialog"
  check "$chat" "all(d['outcome'] for d in deliveries)" "no delivery is left open"
  check "$chat" "not any(d['member'] == 'claude' for d in deliveries)" "and claude was never sent anything"
  check "$chat" "any(m['from'] == 'codex' for m in posts)" "codex answers regardless"
}


# A fresh council folder with one verdict run in it, shaped exactly as council.py's `create_run` writes.
# new_run <name> [rounds] [anonymous]
new_run() {
  root="$WORK/$1"
  run="$root/runs/2026-01-01_000000_$1"
  mkdir -p "$run/r1" "$root/chats" "$root/app/Tools"
  cp council.toml council.py chat.py "$root/"
  cp app/Tools/fake-member.py "$root/app/Tools/"
  python3 - "$run" "${2:-1}" "${3:-0}" <<'MKRUN'
import json, os, sys
run, rounds, anon = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1"
names = ["claude", "codex", "deepseek"]
for r in range(1, rounds + 1):
    os.makedirs(f"{run}/r{r}", exist_ok=True)
aliases = {n: f"Model {chr(65 + i)}" for i, n in enumerate(names)}
members = {n: {"name": n, "backend": b, "label": n.title(),
               "alias": aliases[n] if anon else n.title()}
           for n, b in (("claude", "claude"), ("codex", "codex"), ("deepseek", "pi"))}
json.dump({"created": "2026-01-01T00:00:00", "question_preview": "Is the ledger enough?",
           "members": members, "order": names,
           "moderator": {"name": "deepseek", "backend": "pi", "label": "Deepseek"},
           "rounds": rounds, "anonymous": anon, "length": "about 50 words", "attachments": []},
          open(f"{run}/config.json", "w"), indent=2, sort_keys=True)
open(f"{run}/question.md", "w").write("Is the ledger enough?\n")
MKRUN
  echo "$run"
}

# ask <run> <timeout> [env VAR=1 ...]
ask() {
  run="$1"; shift
  timeout="$1"; shift
  # shellcheck disable=SC2086
  COUNCIL_FAKE_MEMBERS=1 "$@" "$APP" --ask "$run" --timeout "$timeout" ${ASK_EXTRA:-} >"$run/ask.log" 2>&1 || true
}

# checkrun <run> <python expression over `dones`, `verdict`, `transcript`, `log`, `notes`> <description>
checkrun() {
  run="$1"; expr="$2"; what="$3"
  if python3 - "$run" "$expr" <<'CHECKRUN'
import json, os, sys
run, expr = sys.argv[1], sys.argv[2]
cfg = json.load(open(f"{run}/config.json"))
dones = {}
for r in range(1, cfg["rounds"] + 1):
    for m in cfg["order"]:
        path = f"{run}/r{r}/{m}.done"
        if os.path.exists(path):
            dones[(r, m)] = json.load(open(path))
def answer(m, r=1):
    path = f"{run}/r{r}/{m}.md"
    return open(path).read() if os.path.exists(path) else ""
def read(name):
    path = f"{run}/{name}"
    return open(path).read() if os.path.exists(path) else None
verdict, transcript, log = read("verdict.md"), read("transcript.md"), read("ask.log") or ""
statuses = [d["status"] for d in dones.values()]
notes = []
for line in (read(".app/chat.jsonl") or "").splitlines():
    if not line.strip():
        continue
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("kind") == "note":
        notes.append(m.get("text") or "")
sys.exit(0 if eval(expr) else 1)
CHECKRUN
  then
    echo "  ✓ $what"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $what"
    echo "    tail: $(tail -6 "$run/ask.log" 2>/dev/null | tr '\n' '|')"
    FAIL=$((FAIL + 1))
  fi
}

run_verdict() {
  echo "verdict: three members answer and the moderator scores it"
  run=$(new_run verdict)
  ask "$run" 120
  checkrun "$run" "len(dones) == 3 and set(statuses) == {'ok'}" "every member's round is recorded ok"
  checkrun "$run" "all(d['words'] > 0 for d in dones.values())" "answers are counted in words"
  checkrun "$run" "verdict and 'Score: 73/100' in verdict" "the verdict is written and scored"
  checkrun "$run" "transcript and '# Round 1' in transcript and '# Verdict' in transcript" "the transcript is written"
  checkrun "$run" "'OK' in log" "the run reports itself complete"
}

run_verdictrounds() {
  echo "verdict rounds: a second round critiques the first"
  run=$(new_run verdictrounds 2)
  ask "$run" 150
  checkrun "$run" "len(dones) == 6" "both rounds are recorded for everybody"
  checkrun "$run" "'round 2 of 2' in log or dones[(2,'claude')]['status'] == 'ok'" "round two ran"
  checkrun "$run" "verdict is not None" "the moderator still produced a verdict"
}

run_verdictsilent() {
  echo "verdict with a member that never answers: the moderator proceeds with what it has"
  run=$(new_run verdictsilent)
  ask "$run" 120 env FAKE_NO_POST=1 FAKE_ONLY=claude
  checkrun "$run" "dones.get((1,'claude'), {}).get('status') == 'error'" "the silent member is recorded as failed"
  checkrun "$run" "len([s for s in statuses if s == 'ok']) == 2" "the other two answered"
  checkrun "$run" "verdict is not None" "two answers are enough to synthesize"
  checkrun "$run" "transcript and 'FAILED' in transcript" "the transcript says who did not answer"
}

run_verdictnudged() {
  echo "verdict: a member that ends its turn without posting is asked to post, and does"
  run=$(new_run verdictnudged)
  # The failure this is built from: a member wrote a complete answer, ended its turn without running
  # `council post`, and the round was recorded as unanswered — which dropped it from every later round.
  ask "$run" 120 env FAKE_NO_POST_TURNS=1 FAKE_ONLY=claude
  checkrun "$run" "dones.get((1,'claude'), {}).get('status') == 'ok'" "the answer it posted when asked is the round's answer"
  checkrun "$run" "len(dones) == 3 and set(statuses) == {'ok'}" "nobody is dropped"
  checkrun "$run" "any('ended its turn without posting' in n for n in notes)" "the bus says it had to be asked"
  checkrun "$run" "verdict is not None" "the run produced a verdict"
}

run_verdictunreadable() {
  echo "verdict: an answer that reaches the log unreadable is not an answer"
  run=$(new_run verdictunreadable)
  ask "$run" 120 env FAKE_UNREADABLE=1 FAKE_ONLY=claude
  checkrun "$run" "dones.get((1,'claude'), {}).get('status') == 'error'" "the unreadable answer is recorded as a failure"
  checkrun "$run" "'could not be read' not in answer('claude')" "the diagnostic is not filed as what claude said"
  checkrun "$run" "len([s for s in statuses if s == 'ok']) == 2" "the other two answered normally"
  checkrun "$run" "verdict is not None and 'could not be read' not in verdict" "two good answers still synthesize a verdict"
  checkrun "$run" "'OK' in log" "the run reports itself complete"
}

run_verdictmoderatorunreadable() {
  echo "verdict: a moderator's verdict that cannot be read does not finish the run"
  run=$(new_run verdictmoderatorunreadable)
  python3 - "$run" <<'SEEDVERDICT'
import json, sys
run = sys.argv[1]
for m in ("claude", "codex", "deepseek"):
    open(f"{run}/r1/{m}.md", "w").write(f"{m} answered before the moderator was asked")
    json.dump({"status": "ok", "error": None, "elapsed": 1.5, "words": 7,
               "finished": "2026-01-01T00:00:01"}, open(f"{run}/r1/{m}.done", "w"))
SEEDVERDICT
  ask "$run" 120 env FAKE_UNREADABLE=1 FAKE_ONLY=deepseek
  checkrun "$run" "verdict and 'moderator failed' in verdict" "the run ends as a moderator failure"
  checkrun "$run" "verdict and 'could not be read' in verdict" "and says what happened"
  checkrun "$run" "verdict and 'Score:' not in verdict" "the diagnostic did not become the verdict"
  checkrun "$run" "all(d['elapsed'] == 1.5 for d in dones.values())" "the answers already in are untouched"
}

run_verdictanon() {
  echo "anonymous verdict: the models see aliases, the file reveals who was who"
  run=$(new_run verdictanon 1 1)
  ask "$run" 120
  checkrun "$run" "verdict and '## Reveal' in verdict and 'Model A = Claude' in verdict" "the reveal footer is written"
  checkrun "$run" "transcript and '(as Model A)' in transcript" "the transcript carries both names"
}

run_verdictresume() {
  echo "resume: a run stopped part way asks only for what is missing"
  run=$(new_run verdictresume)
  python3 - "$run" <<'SEEDRUN'
import json, sys
run = sys.argv[1]
open(f"{run}/r1/claude.md", "w").write("claude answered before the app was quit")
json.dump({"status": "ok", "error": None, "elapsed": 3.0, "words": 7,
           "finished": "2026-01-01T00:00:01"}, open(f"{run}/r1/claude.done", "w"))
SEEDRUN
  ask "$run" 120
  checkrun "$run" "answer('claude') == 'claude answered before the app was quit'" "the answer already on disk is kept"
  checkrun "$run" "len(dones) == 3 and set(statuses) == {'ok'}" "only the missing answers were asked for"
  checkrun "$run" "verdict is not None" "the run finishes"
}


run_reopened() {
  echo "reopened: a chat that already has a transcript still delivers the next question"
  chat=$(new_chat reopened)
  # Ten messages already in the log, as any chat the app has been in before would have. This is the state the
  # unit tests never built and every fresh scenario skipped: the router used to count the whole log while
  # holding none of it, so the first question after reopening was sliced away and silently dropped.
  python3 - "$chat" <<'SEEDCHAT'
import json, sys
chat = sys.argv[1]
senders = ["user", "claude", "codex"]
with open(f"{chat}/chat.jsonl", "w") as f:
    for i in range(1, 11):
        f.write(json.dumps({"id": 1700000000000000000 + i, "ts": "2026-01-01T00:00:00",
                            "from": senders[i % 3], "kind": "msg",
                            "text": f"old message {i}", "to": []}) + "\n")
SEEDCHAT
  drive "$chat" 40
  check "$chat" "len([d for d in deliveries if 'Say something short.' in (d.get('text') or '')]) >= 2" \
        "both members are asked the new question"
  check "$chat" "not [d for d in deliveries if 'old message' in (d.get('text') or '')]" \
        "and none of the history is re-asked"
  check "$chat" "len(deliveries) >= 4 and set(outcomes) == {'posted'}" "briefing and question both end posted"
}

run_verdictmoderatorretry() {
  echo "moderator retry: a run whose moderator gave up is synthesized again, without re-asking anybody"
  run=$(new_run verdictmoderatorretry)
  python3 - "$run" <<'SEEDMOD'
import json, sys
run = sys.argv[1]
for m in ("claude", "codex", "deepseek"):
    open(f"{run}/r1/{m}.md", "w").write(f"{m} answered before the moderator fell over")
    json.dump({"status": "ok", "error": None, "elapsed": 1.5, "words": 7,
               "finished": "2026-01-01T00:00:01"}, open(f"{run}/r1/{m}.done", "w"))
# What the CLI leaves behind when the moderator itself fails; it makes the run read back as finished.
open(f"{run}/verdict.md", "w").write("(moderator failed: the model never answered)\n")
SEEDMOD
  ASK_EXTRA=--retry-moderator ask "$run" 120
  unset ASK_EXTRA
  checkrun "$run" "verdict and 'Score: 73/100' in verdict" "the verdict is written on the retry"
  checkrun "$run" "verdict and 'moderator failed' not in verdict" "and the failure marker is gone"
  checkrun "$run" "all(d['elapsed'] == 1.5 for d in dones.values())" "nobody who answered was asked again"
  checkrun "$run" "'OK' in log" "the run reports itself complete"
}


run_retryfailed() {
  echo "retry: a member that gave up is relaunched and asked again for what it dropped"
  chat=$(new_chat retryfailed)
  # claude answers its briefing and then goes deaf for the question, so the delivery that fails is a real
  # question rather than the briefing — which a relaunch would send again anyway. Its process stays alive
  # throughout: giving up never kills it, which is the whole reason Retry used to do nothing here.
  drive "$chat" 120 env FAKE_DEAF_TURN=2 FAKE_ONLY=claude -- --retry-failed
  check "$chat" "'failed' in outcomes" "the question it ignored is recorded as failed"
  check "$chat" "any('did not accept the prompt' in n for n in notes)" "and the chat says so"
  check "$chat" "'still alive' in open(chat + '/drive.log').read()" "its process was still running when Retry was pressed"
  check "$chat" "len([d for d in deliveries if d['member'] == 'claude' and d['outcome'] == 'posted']) >= 2" \
        "claude answers again after the retry"
  check "$chat" "any(m['from'] == 'codex' for m in bus if m.get('kind') != 'note')" "codex was unaffected throughout"
}
for scenario in ${*:-happy nopost unreadable reopened deaf crash slowstart nostart interrupted resumefails blocked permission trust \
                     slots retryfailed verdict verdictrounds verdictsilent verdictnudged verdictunreadable verdictmoderatorunreadable verdictanon verdictresume \
                     verdictmoderatorretry}; do
  "run_$scenario"
done

echo
echo "$PASS passed, $FAIL failed   (work: $WORK)"
[ "$FAIL" -eq 0 ]
