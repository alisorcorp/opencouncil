import SwiftUI
import AppKit
import CouncilCore

/// Asking the council: a question, who answers it, who merges the answers, and how the run is shaped. The
/// roster is `council.toml`'s; only members the app can host as terminals can be picked, because a run it
/// cannot finish is worse than one it never started (R16).
struct NewVerdictSheet: View {
    let paths: CouncilPaths
    /// Called with the directory of the run that was created.
    let onCreate: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var folder: URL
    @State private var selected: Set<String> = []
    @State private var moderator = ""
    @State private var rounds = 1
    @State private var anonymous = false
    @State private var attachments: [URL] = []
    @State private var config: CouncilConfig?
    @State private var error: String?

    init(paths: CouncilPaths, defaultFolder: URL? = nil, onCreate: @escaping (URL) -> Void) {
        self.paths = paths
        self.onCreate = onCreate
        _folder = State(initialValue: defaultFolder ?? paths.root)
    }

    private var members: [CouncilConfig.Member] { config?.orderedMembers ?? [] }
    /// The moderator merges the answers; it does not have to be at the table, but it does need a terminal.
    private var moderators: [CouncilConfig.Member] { members.filter(\.isAvailable) }
    private var canCreate: Bool {
        !question.trimmingCharacters(in: .whitespaces).isEmpty && selected.count >= 2 && !moderator.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Ask the council").font(Typography.font(19, .bold))
                .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)

            Form {
                Section {
                    // The label is hidden so the field spans the row: a question is a paragraph, not a
                    // one-line value sitting to the right of its name.
                    TextField("Question", text: $question, prompt: Text("What should the council decide?"),
                              axis: .vertical)
                        .labelsHidden()
                        .lineLimit(3...8)
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            Text(folder.path).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                            Spacer()
                            Button("Choose…", action: pickFolder)
                        }
                    }
                } footer: {
                    // Claude Code asks whether you trust a folder the first time it runs in one, and answers
                    // "No, exit" by default — a run given a folder of its own would stop on that every time.
                    Text("Every member answers this on its own, without seeing the others. They run in the "
                         + "folder above; pick one you have used them in before, or they will ask whether you "
                         + "trust it.")
                        .font(Typography.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Members") {
                    ForEach(members) { member in
                        MemberToggle(member: member, isOn: Binding(
                            get: { selected.contains(member.name) },
                            set: { on in
                                if on { selected.insert(member.name) } else { selected.remove(member.name) }
                            }))
                    }
                    if members.isEmpty { Text("No members in council.toml").foregroundStyle(.secondary) }
                }

                Section {
                    Picker("Moderator", selection: $moderator) {
                        ForEach(moderators) { Text($0.label).tag($0.name) }
                    }
                    Stepper("Rounds: \(rounds)", value: $rounds, in: 1...4)
                    Toggle("Anonymous", isOn: $anonymous)
                } footer: {
                    Text(anonymous
                         ? "Members and the moderator see “Model A”, “Model B”… You see the real names, and the "
                           + "verdict ends with who was who."
                         : "More than one round lets members critique each other's answers and revise.")
                        .font(Typography.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Attachments") {
                    ForEach(attachments, id: \.self) { url in
                        HStack {
                            IconView(.question, size: 14).foregroundStyle(.secondary)
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Button("Remove") { attachments.removeAll { $0 == url } }
                                .buttonStyle(.link).font(Typography.caption)
                        }
                    }
                    Button("Add file…", action: pickFiles)
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
                Button("Ask the council", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
        }
        .frame(width: 560)
        .onAppear(perform: load)
    }

    private var summary: String {
        guard canCreate else { return "Write a question and pick at least two members." }
        let n = selected.count
        return "\(n) members · \(rounds) round\(rounds == 1 ? "" : "s") · they start answering straight away"
    }

    private func load() {
        do {
            let cfg = try CouncilConfig.load(from: paths.configFile)
            config = cfg
            rounds = max(cfg.defaults.rounds, 1)
            anonymous = cfg.defaults.anonymous
            let defaults = cfg.defaults.members.isEmpty ? cfg.chat.members : cfg.defaults.members
            selected = Set(defaults.filter { cfg.members[$0]?.isAvailable ?? false })
            let preferred = cfg.defaults.moderator.flatMap { cfg.members[$0]?.isAvailable == true ? $0 : nil }
            moderator = preferred ?? cfg.memberOrder.first { cfg.members[$0]?.isAvailable ?? false } ?? ""
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

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        if panel.runModal() == .OK {
            for url in panel.urls where !attachments.contains(url) { attachments.append(url) }
        }
    }

    private func create() {
        guard let config else { return }
        do {
            let factory = RunFactory(paths: paths, config: config)
            let order = config.memberOrder.filter { selected.contains($0) }
            let dir = try factory.create(question: question, members: order, moderator: moderator,
                                         rounds: rounds, anonymous: anonymous, attachments: attachments)
            // Where the members work is app-owned state, so it goes in app.json next to the CLI's config.json
            // and survives a resume.
            try SessionAppState.update(in: dir) { $0.cwdOverride = folder.path }
            // The members' own directory is written now, so a run created here is startable even if
            // council.toml changes before anybody presses Ask.
            try factory.prepareSessions(in: dir, cwd: folder)
            onCreate(dir)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
