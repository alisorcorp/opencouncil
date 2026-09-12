// Open Council pi extension: reports the agent's state to the app.
// Loaded per launch with `pi -e <path to this file>`; the app sets COUNCIL_CHAT and COUNCIL_AS in the environment.
// Appends one JSON line per event to <COUNCIL_CHAT>/events.jsonl, the same file `council event` writes for
// Claude Code and Codex. Does nothing when the variables are missing, so it is safe in a normal pi session.
import * as fs from "node:fs";
import * as path from "node:path";

type Api = {
  on: (event: string, handler: (ev: any, ctx: any) => void | Promise<void>) => void;
};

export default function councilEvents(pi: Api) {
  const dir = process.env.COUNCIL_CHAT;
  const member = process.env.COUNCIL_AS;
  if (!dir || !member) return;
  const file = path.join(dir, "events.jsonl");

  const write = (hook: string, payload: Record<string, unknown>) => {
    // Local time with second precision, the same shape `council event` writes (Python's isoformat(timespec="seconds")).
    const d = new Date();
    const pad = (n: number) => String(n).padStart(2, "0");
    const ts = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
    const rec = { ts, member, backend: "pi", hook, payload };
    try {
      fs.appendFileSync(file, JSON.stringify(rec) + "\n");
    } catch {
      // never disturb the agent
    }
  };

  pi.on("session_start", (ev, ctx) => {
    let sessionId: string | undefined;
    try {
      sessionId = ctx?.sessionManager?.getSessionId?.() ?? ctx?.sessionManager?.sessionId;
    } catch {}
    write("session_start", { reason: ev?.reason, session_id: sessionId, previousSessionFile: ev?.previousSessionFile });
  });
  pi.on("session_shutdown", (ev) => write("session_shutdown", { reason: ev?.reason }));
  pi.on("agent_start", () => write("agent_start", {}));
  pi.on("agent_end", (ev) => {
    const msgs = Array.isArray(ev?.messages) ? ev.messages : [];
    const last = msgs.length ? msgs[msgs.length - 1] : undefined;
    let text: string | undefined;
    if (last && Array.isArray(last.content)) {
      text = last.content.filter((c: any) => c?.type === "text").map((c: any) => c.text).join("\n");
    } else if (typeof last?.content === "string") {
      text = last.content;
    }
    write("agent_end", { messages: msgs.length, lastMessage: text?.slice(0, 4000) });
  });
  pi.on("turn_start", (ev) => write("turn_start", { turnIndex: ev?.turnIndex }));
  pi.on("turn_end", (ev) => write("turn_end", { turnIndex: ev?.turnIndex }));
  pi.on("tool_execution_start", (ev) => write("tool_execution_start", { toolName: ev?.toolName, args: ev?.args ?? ev?.input }));
  pi.on("tool_execution_end", (ev) => write("tool_execution_end", { toolName: ev?.toolName, isError: !!ev?.isError }));
  pi.on("input", (ev) => write("input", { source: ev?.source }));
  pi.on("project_trust", (ev) => write("project_trust", { path: ev?.path }));
}
