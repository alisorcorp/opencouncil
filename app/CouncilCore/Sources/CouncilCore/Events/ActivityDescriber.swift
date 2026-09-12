import Foundation

/// Turns a tool call into the short phrase the activity line shows: "reading chat.py", "ran pytest -q".
public enum ActivityDescriber {
    public static func describe(tool: String, input: JSONValue?) -> String {
        let name = tool.lowercased()
        func file(_ keys: [String]) -> String? {
            for k in keys { if let p = input?.path(k)?.stringValue, !p.isEmpty { return (p as NSString).lastPathComponent } }
            return nil
        }
        func command(_ keys: [String]) -> String? {
            for k in keys {
                if let c = input?.path(k)?.stringValue { return shorten(c) }
                if case .array(let parts)? = input?.path(k) {
                    let s = parts.compactMap(\.stringValue).joined(separator: " ")
                    if !s.isEmpty { return shorten(s) }
                }
            }
            return nil
        }
        switch name {
        case "read", "read_file", "readfile", "view", "cat":
            return file(["file_path", "path", "target_file"]).map { "reading \($0)" } ?? "reading a file"
        case "edit", "write", "multiedit", "notebookedit", "write_file", "edit_file", "apply_patch", "str_replace_editor":
            return file(["file_path", "path", "target_file"]).map { "editing \($0)" } ?? "editing files"
        case "bash", "shell", "exec", "execute", "run_command", "container.exec", "shell_command", "terminal":
            return command(["command", "cmd", "args", "argv"]).map { "ran \($0)" } ?? "running a command"
        case "grep", "glob", "search", "rg", "find", "ls", "list_dir", "codebase_search":
            return "searching the project"
        case "webfetch", "websearch", "fetch", "web_search", "browser", "open_url":
            return "browsing the web"
        case "task", "agent", "subagent", "spawn_agent":
            return "delegating to a subagent"
        case "todowrite", "todoread", "update_plan":
            return "planning"
        default:
            return "using \(tool)"
        }
    }

    static func shorten(_ command: String, limit: Int = 40) -> String {
        let flat = command.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}
