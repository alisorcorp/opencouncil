import SwiftUI
import CouncilCore

/// Diagnostics window (menu: Council ▸ Environment…): the resolved folder, tool paths and configured members.
struct EnvironmentWindow: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Form {
            Section("Council folder") {
                LabeledContent("Root", value: env.paths?.root.path ?? "–")
                LabeledContent("PATH source", value: env.shell?.source == .loginShell ? "login shell" : "fallback")
            }
            Section("Tools") {
                ForEach(AppEnvironment.tools, id: \.self) { tool in
                    LabeledContent(tool) {
                        if let url = env.toolLocations[tool] ?? nil {
                            Text(url.path).textSelection(.enabled)
                        } else {
                            Text("not found").foregroundStyle(Palette.vermilion)
                        }
                    }
                }
            }
            Section("Members in council.toml") {
                ForEach(env.config?.orderedMembers ?? []) { m in
                    LabeledContent(m.label) {
                        HStack {
                            Text(m.backendName).foregroundStyle(.secondary)
                            if !m.model.isEmpty { Text(m.model).foregroundStyle(Palette.faintText) }
                            if !m.isAvailable { Text("unavailable").foregroundStyle(Palette.orange) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 380)
    }
}
