import Foundation

/// Maps raw hook records to `MemberEvent`s per backend. Unknown hooks produce nothing, never errors, so a
/// newer CLI adding events cannot break the app.
public enum EventNormalizer {
    public static func normalize(_ raw: RawEvent) -> [MemberEvent] {
        switch raw.backend {
        case "claude": return claude(raw)
        case "codex": return codex(raw)
        case "pi": return pi(raw)
        // Kimi Code emits the Claude Code hook contract almost unchanged — `hook_event_name`, `session_id`,
        // `cwd`, `source` on SessionStart, `stop_hook_active` on Stop — so it is read the same way. Its Stop
        // carries no `last_assistant_message`, which the Claude reading already treats as absent, and its
        // StopFailure names the reason `error_message` rather than `error`, which the Claude reading takes.
        case "kimi": return claude(raw)
        default: return []
        }
    }

    // MARK: Claude Code hooks (https://code.claude.com/docs/en/hooks)

    static func claude(_ raw: RawEvent) -> [MemberEvent] {
        let p = raw.payload
        switch raw.hook {
        case "SessionStart":
            return [.started(sessionId: p["session_id"]?.stringValue, reason: p["source"]?.stringValue ?? p["reason"]?.stringValue)]
        case "UserPromptSubmit":
            return [.turnStarted]
        case "PreToolUse":
            let tool = p["tool_name"]?.stringValue ?? "tool"
            return [.toolStarted(tool: tool, activity: ActivityDescriber.describe(tool: tool, input: p["tool_input"]))]
        case "PostToolUse":
            return [.toolEnded(tool: p["tool_name"]?.stringValue ?? "tool", failed: false)]
        case "PostToolUseFailure":
            return [.toolEnded(tool: p["tool_name"]?.stringValue ?? "tool", failed: true)]
        case "PermissionRequest":
            return [.blocked(reason: "permission requested for \(p["tool_name"]?.stringValue ?? "a tool")")]
        case "Notification":
            let type = p["notification_type"]?.stringValue ?? p["type"]?.stringValue ?? ""
            switch type {
            case "permission_prompt": return [.blocked(reason: "permission prompt")]
            case "agent_needs_input": return [.blocked(reason: "needs input")]
            case "elicitation_dialog", "elicitation_url_dialog": return [.blocked(reason: "dialog")]
            case "auth_success", "elicitation_complete", "elicitation_response": return [.unblocked]
            default:
                let msg = (p["message"]?.stringValue ?? "").lowercased()
                if msg.contains("login") || msg.contains("sign in") || msg.contains("authenticate") { return [.blocked(reason: "login required")] }
                return []
            }
        case "Stop":
            return [.turnEnded(lastMessage: p["last_assistant_message"]?.stringValue)]
        case "StopFailure":
            // Claude Code names the reason `error`; Kimi Code sends `error_message` with an `error_type`
            // beside it. Reading only the first two turned the one sentence that says what went wrong into
            // "turn failed" and left it in events.jsonl — a provider rejecting a request looked like a crash.
            let reason = p["error"]?.stringValue ?? p["message"]?.stringValue
                ?? p["error_message"]?.stringValue ?? p["error_type"]?.stringValue
            return [.failed(message: reason ?? "turn failed")]
        case "SessionEnd":
            return [.ended(reason: p["reason"]?.stringValue)]
        default:
            return []
        }
    }

    // MARK: Codex CLI hooks (https://learn.chatgpt.com/docs/hooks); same names as Claude Code.

    static func codex(_ raw: RawEvent) -> [MemberEvent] {
        let p = raw.payload
        switch raw.hook {
        case "SessionStart":
            return [.started(sessionId: p["session_id"]?.stringValue ?? p["thread_id"]?.stringValue, reason: p["source"]?.stringValue)]
        case "UserPromptSubmit":
            return [.turnStarted]
        case "PreToolUse":
            let tool = p["tool_name"]?.stringValue ?? "tool"
            return [.toolStarted(tool: tool, activity: ActivityDescriber.describe(tool: tool, input: p["tool_input"]))]
        case "PostToolUse":
            return [.toolEnded(tool: p["tool_name"]?.stringValue ?? "tool", failed: false)]
        case "PermissionRequest":
            return [.blocked(reason: "approval requested for \(p["tool_name"]?.stringValue ?? "a command")")]
        case "Stop":
            return [.turnEnded(lastMessage: p["last_assistant_message"]?.stringValue ?? p.path("last-assistant-message")?.stringValue)]
        case "Interrupt":
            return [.turnEnded(lastMessage: nil)]
        case "SessionEnd":
            return [.ended(reason: p["reason"]?.stringValue)]
        case "agent-turn-complete":            // legacy `notify` payload, if ever routed here
            return [.turnEnded(lastMessage: p.path("last-assistant-message")?.stringValue)]
        default:
            return []
        }
    }

    // MARK: pi extension events (app/Resources/pi-council-events.ts)

    static func pi(_ raw: RawEvent) -> [MemberEvent] {
        let p = raw.payload
        switch raw.hook {
        case "session_start":
            return [.started(sessionId: p["session_id"]?.stringValue, reason: p["reason"]?.stringValue)]
        case "agent_start":
            return [.turnStarted]
        case "tool_execution_start":
            let tool = p["toolName"]?.stringValue ?? p["tool"]?.stringValue ?? "tool"
            return [.toolStarted(tool: tool, activity: ActivityDescriber.describe(tool: tool, input: p["args"] ?? p["input"]))]
        case "tool_execution_end":
            return [.toolEnded(tool: p["toolName"]?.stringValue ?? "tool", failed: p["isError"]?.boolValue ?? false)]
        case "agent_end":
            return [.turnEnded(lastMessage: p["lastMessage"]?.stringValue)]
        case "project_trust":
            return [.blocked(reason: "trust prompt")]
        case "session_shutdown":
            return [.ended(reason: p["reason"]?.stringValue)]
        default:
            return []
        }
    }
}
