import SwiftUI
import CouncilCore

@main
struct CouncilApp: App {
    @State private var environment = AppEnvironment()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    /// Shared with the sidebar's toggle; nil colour scheme means the system's.
    @AppStorage("appearance") private var appearance: Appearance = .system

    init() {
        // Developer entry points; each takes over the process and exits when done.
        if !SnapshotCommand.runIfRequested(), !DriveCommand.runIfRequested(), !SlotsCommand.runIfRequested() {
            _ = AskCommand.runIfRequested()
        }
    }

    var body: some Scene {
        WindowGroup("Open Council") {
            RootView()
                .environment(environment)
                .preferredColorScheme(appearance.colorScheme)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    delegate.liveSessionCount = { [weak environment] in environment?.live?.count ?? 0 }
                    delegate.stopAll = { [weak environment] in environment?.live?.stopAll() }
                    await environment.bootstrap()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CouncilCommands { openWindow(id: "environment") }
        }

        Window("Environment", id: "environment") {
            EnvironmentWindow()
                .environment(environment)
        }
        .defaultSize(width: 620, height: 420)
    }
}
