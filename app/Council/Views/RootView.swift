import SwiftUI
import CouncilCore

struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        switch env.phase {
        case .loading:
            ProgressView("Finding your council…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            SetupProblemView(message: message)
        case .ready:
            if let paths = env.paths {
                MainWindow(paths: paths, live: env.live)
                    .id(paths.root)   // a new root means a new store
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                        env.live?.stopAll()   // members get SIGTERM instead of a dead pty
                    }
            }
        }
    }
}

/// Shown when the council folder or config cannot be loaded.
struct SetupProblemView: View {
    @Environment(AppEnvironment.self) private var env
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(Typography.font(36, .semibold))
                .foregroundStyle(.secondary)
            Text("Open Council can't start").font(Typography.title2)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button("Choose council folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.prompt = "Use this folder"
                if panel.runModal() == .OK, let url = panel.url {
                    Task { await env.setRoot(url) }
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
