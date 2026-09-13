import SwiftUI
import AppKit
import CouncilCore

/// Starting a chat from the app: a name, the folder the members work in, and who is at the table. The roster
/// comes from `council.toml`; members whose backend has no terminal are shown but cannot be picked (R16).
/// Verdict runs still come from the CLI until the verdict unit lands.
struct NewChatSheet: View {
    let paths: CouncilPaths
    /// Called with the directory of the chat that was created.
    let onCreate: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var folder: URL
    @State private var selected: Set<String> = []
    @State private var effort = "medium"
    @State private var budget = 20
    @State private var config: CouncilConfig?
    @State private var error: String?

    static let efforts = ["default", "low", "medium", "high", "xhigh", "max"]

    init(paths: CouncilPaths, defaultFolder: URL? = nil, onCreate: @escaping (URL) -> Void) {
        self.paths = paths
        self.onCreate = onCreate
        _folder = State(initialValue: defaultFolder ?? paths.root)
    }

    private var members: [CouncilConfig.Member] { config?.orderedMembers ?? [] }
    private var canCreate: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && !selected.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New chat").font(Typography.font(19, .bold))
                .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)

            Form {
                Section {
                    TextField("Name", text: $title, prompt: Text("What is this chat about?"))
                        .onSubmit { if canCreate { create() } }
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            Text(folder.path).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                            Spacer()
                            Button("Choose…", action: pickFolder)
                        }
                    }
                } footer: {
                    Text("Members work in this folder — they read and edit files here on their own. "
                         + "Anything riskier, like running a command, they ask about in their own terminal.")
                        .font(Typography.caption).foregroundStyle(.secondary)
                }

                Section("Members") {
                    ForEach(members) { member in
                        MemberToggle(member: member, isOn: Binding(
                            get: { selected.contains(member.name) },
                            set: { on in
                                if on { selected.insert(member.name) } else { selected.remove(member.name) }
                            }))
                    }
                    if members.isEmpty {
                        Text("No members in council.toml").foregroundStyle(.secondary)
                    }
                }

                Section {
                    Picker("Reasoning effort", selection: $effort) {
                        ForEach(Self.efforts, id: \.self) { Text($0).tag($0) }
                    }
                    Stepper("Replies per member, per message: \(budget)", value: $budget, in: 1...99)
                }
            }
            .formStyle(.grouped)

            if let error {
                Text(error).font(Typography.callout).foregroundStyle(Palette.vermilion)
                    .padding(.horizontal, 22).padding(.bottom, 6)
            }

            HStack {
                Text(summary).font(Typography.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start chat", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
        }
        .frame(width: 540)
        .onAppear(perform: load)
    }

    private var summary: String {
        guard canCreate else { return "Name the chat and pick at least one member." }
        let n = selected.count
        return "\(n) member\(n == 1 ? "" : "s") · members are briefed when the chat opens"
    }

    private func load() {
        do {
            let cfg = try CouncilConfig.load(from: paths.configFile)
            config = cfg
            effort = cfg.chat.effort
            budget = cfg.chat.budget
            selected = Set(cfg.chat.members.filter { cfg.members[$0]?.isAvailable ?? false })
            // council.toml is the answer until this person has made one of their own.
            if let last = SheetMemory.load(SheetMemory.Chat.self, key: SheetMemory.chatKey) {
                let offered = SheetMemory.stillOffered(last.members, in: cfg)
                if !offered.isEmpty { selected = Set(offered) }
                if Self.efforts.contains(last.effort) { effort = last.effort }
                if last.budget > 0 { budget = last.budget }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Use folder"
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    private func create() {
        guard let config else { return }
        do {
            let factory = ChatSessionFactory(paths: paths, config: config)
            let order = config.memberOrder.filter { selected.contains($0) }
            let dir = try factory.create(title: title.trimmingCharacters(in: .whitespaces), members: order,
                                         cwd: folder, budget: budget, effort: effort)
            SheetMemory.save(SheetMemory.Chat(members: order, effort: effort, budget: budget),
                             key: SheetMemory.chatKey)
            onCreate(dir)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One row of the member checklist: avatar, label, backend, and why it cannot be picked when it cannot.
struct MemberToggle: View {
    let member: CouncilConfig.Member
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 9) {
                Avatar(label: member.label, color: Palette.mutedIcon, size: 22,
                       image: AvatarCatalog.imageName(member: member.name, backend: member.backendName, model: member.model))
                VStack(alignment: .leading, spacing: 1) {
                    Text(member.label).lineLimit(1)
                    Text(member.detail).font(Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .disabled(!member.isAvailable)
        .help(member.isAvailable ? member.model : "\(member.backendName) members have no terminal to run in")
    }
}

private extension CouncilConfig.Member {
    var detail: String {
        guard isAvailable else { return "\(backendName) · no terminal, not available in the app" }
        return model.isEmpty ? backendName : "\(backendName) · \(model)"
    }
}
