import SwiftUI
import Textual
import CouncilCore

/// A `council ask` run: the question, each round's answers, and the moderator's verdict — live while the
/// members are being asked, and a record of what happened once they are not.
struct VerdictView: View {
    let vm: SessionViewModel

    private var subtitle: String {
        guard let v = vm.verdict else { return vm.loadError ?? "Loading…" }
        var parts = ["\(v.config.order.count) members", "moderator \(v.moderatorLabel)"]
        if v.config.rounds > 1 { parts.append("\(v.config.rounds) rounds") }
        if v.config.anonymous { parts.append("anonymous") }
        if vm.isLive { parts.append("live") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(vm: vm, subtitle: subtitle)
            if let v = vm.verdict {
                RunActionBar(vm: vm, state: v.state)
                MemberCards(vm: vm)
                ScrollView {
                    VerdictBody(content: v, vm: vm)
                }
                .background(Palette.canvas)
            } else if let e = vm.loadError {
                EmptyState(title: "Could not read this run", detail: e, icon: .verdict)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.canvas)
        .sheet(isPresented: Binding(get: { vm.capReached }, set: { vm.capReached = $0 })) {
            LiveCapSheet(title: vm.title, sessions: vm.runningSessions,
                         onTake: { vm.takeSlot(from: $0) }) { vm.capReached = false }
        }
    }
}

/// What can be done with this run right now. A run is a directory, so this is the same whether the app made
/// it or the CLI did, and whether it was interrupted a minute ago or last week.
struct RunActionBar: View {
    let vm: SessionViewModel
    let state: RunState

    private var answered: String {
        let total = vm.verdict?.config.order.count ?? 0
        return "\(state.answered.count) of \(total) answers are in"
    }

    var body: some View {
        if vm.isLive {
            LiveRunLine(vm: vm)
        } else {
            switch state.phase {
            case .complete:
                EmptyView()
            case .notStarted:
                bar("The council has not been asked yet.", tint: Palette.accent) {
                    Button("Ask the council") { vm.startVerdict() }.buttonStyle(.borderedProminent)
                }
            case .answering, .awaitingModerator:
                bar("This run stopped part way · \(answered). Resuming asks only for what is missing.",
                    tint: Palette.amber) {
                    Button("Resume") { vm.startVerdict() }.buttonStyle(.borderedProminent)
                    Button("Discard") { vm.discardRun() }
                }
            case .moderatorFailed(let reason):
                bar("The moderator did not finish: \(reason). The answers are all here.", tint: Palette.amber) {
                    Button("Retry moderator") { vm.retryModerator() }.buttonStyle(.borderedProminent)
                    Button("Discard") { vm.discardRun() }
                }
            case .tooFewAnswers:
                bar("Fewer than two members answered, so there is nothing to synthesize.", tint: Palette.vermilion) {
                    Button("Discard") { vm.discardRun() }
                }
            }
        }
    }

    @ViewBuilder
    private func bar(_ text: String, tint: Color, @ViewBuilder actions: () -> some View) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                IconView(.verdict, size: 18).foregroundStyle(tint)
                Text(text).font(Typography.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                HStack(spacing: 8) { actions() }.controlSize(.small)
            }
            if let error = vm.startError {
                HStack {
                    Text(error).font(Typography.caption).foregroundStyle(Palette.vermilion)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(tint.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// One line while the run is being asked: which round, and who it is waiting on.
struct LiveRunLine: View {
    let vm: SessionViewModel

    private var text: String {
        switch vm.runPhase {
        case .asking(let round):
            let total = vm.verdict?.config.rounds ?? 1
            let waiting = vm.agents.filter { vm.isWaiting(on: $0.name) }.map(\.label)
            let who = waiting.isEmpty ? "everyone has answered" : "waiting for " + waiting.joined(separator: ", ")
            return total > 1 ? "Round \(round) of \(total) · \(who)" : who.prefix(1).uppercased() + who.dropFirst()
        case .moderating:
            return "The moderator is writing the verdict"
        case .complete, .abandoned, .idle, nil:
            return "Starting the members"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                Text(text).font(Typography.callout)
                Spacer(minLength: 8)
            }
            ForEach(vm.runNotes.suffix(3), id: \.self) { note in
                Text(note).font(Typography.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Palette.accent.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The cards of a verdict run, without a scroll container (shared by the live view and the snapshot tool).
struct VerdictBody: View {
    let content: VerdictContent
    /// Nil in the snapshot tool, which renders a finished run with nothing live behind it.
    var vm: SessionViewModel? = nil

    /// Rounds worth drawing: one that has recorded something, and the one being asked right now. A run nobody
    /// has started yet is a question, not a page of empty cards.
    private var visibleRounds: [Int] {
        var asking = 0
        if case .asking(let round)? = vm?.runPhase { asking = round }
        return (1...max(content.rounds.count, 1)).filter { round in
            round == asking || (content.rounds.indices.contains(round - 1)
                                && content.rounds[round - 1].contains { $0.done != nil })
        }
    }

    /// The moderator's card appears once there is something for it to be: a verdict, a synthesis under way, or
    /// a run whose answers are all in.
    private var showsModerator: Bool {
        if content.verdict != nil { return true }
        if case .moderating? = vm?.runPhase { return true }
        switch content.state.phase {
        case .awaitingModerator, .moderatorFailed, .complete: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            QuestionCard(question: content.question)
            ForEach(visibleRounds, id: \.self) { round in
                RoundSection(round: round, total: content.rounds.count,
                             answers: content.rounds.indices.contains(round - 1) ? content.rounds[round - 1] : [],
                             order: content.config.order, vm: vm)
            }
            if showsModerator { ModeratorCard(content: content, vm: vm) }
        }
        .padding(20)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline))
    }
}

private struct QuestionCard: View {
    let question: String
    @State private var expanded = false

    var body: some View {
        Card {
            HStack {
                HStack(spacing: 6) { IconView(.question, size: 15); Text("Question") }
                    .font(Typography.captionSemibold).foregroundStyle(.secondary)
                Spacer()
                if question.count > 600 {
                    Button(expanded ? "Show less" : "Show all") { expanded.toggle() }.buttonStyle(.link).font(Typography.caption)
                }
            }
            VerdictMarkdown(text: expanded || question.count <= 600 ? question : String(question.prefix(600)) + "…")
        }
    }
}

private struct RoundSection: View {
    let round: Int
    let total: Int
    let answers: [VerdictAnswer]
    let order: [String]
    var vm: SessionViewModel? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(total > 1 ? (round == 1 ? "Round 1 · independent answers" : "Round \(round) · critique and revise") : "Independent answers")
                .font(Typography.headline)
            ForEach(answers) { a in
                Card {
                    HStack(spacing: 10) {
                        Avatar(label: a.label, color: Palette.member(order.firstIndex(of: a.member) ?? 0), size: 30,
                               image: AvatarCatalog.imageName(member: a.member))
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(a.label).font(Typography.subheadlineSemibold)
                                if let alias = a.alias { Chip(text: alias) }
                            }
                            Text(meta(a)).font(Typography.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if a.text.isEmpty {
                        if isWaiting(a) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                                Text("thinking…").foregroundStyle(.secondary)
                            }
                        } else {
                            Text(a.done?.error.map { "Failed: \($0)" } ?? "No answer")
                                .italic().foregroundStyle(.secondary)
                        }
                    } else {
                        VerdictMarkdown(text: a.text)
                    }
                }
            }
        }
    }

    /// A member of the round being asked right now, with nothing written yet.
    private func isWaiting(_ a: VerdictAnswer) -> Bool {
        guard a.done == nil, let vm, case .asking(let asking)? = vm.runPhase, asking == round else { return false }
        return vm.isWaiting(on: a.member)
    }

    private func meta(_ a: VerdictAnswer) -> String {
        guard let d = a.done else { return isWaiting(a) ? "answering" : "no result" }
        var parts: [String] = []
        if let e = d.elapsed { parts.append(e >= 60 ? String(format: "%.0fm %02.0fs", (e / 60).rounded(.down), e.truncatingRemainder(dividingBy: 60)) : String(format: "%.0fs", e)) }
        if let w = d.words { parts.append("\(w) words") }
        if !d.isOK { parts.append("FAILED") }
        return parts.joined(separator: " · ")
    }
}

private struct ModeratorCard: View {
    let content: VerdictContent
    var vm: SessionViewModel? = nil

    private var isModerating: Bool {
        if case .moderating? = vm?.runPhase { return true }
        return false
    }

    var body: some View {
        Card {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Palette.orange)
                    IconView(.verdict, size: 20).foregroundStyle(.white)
                }.frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Verdict").font(Typography.subheadlineSemibold)
                    Text("Moderator · \(content.moderatorLabel)").font(Typography.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let s = content.score {
                    HStack(spacing: 8) {
                        IconView(.consensus, size: 16).foregroundStyle(Palette.scoreColor(s))
                        Text("Consensus").font(Typography.caption).foregroundStyle(.secondary)
                        ScoreBar(score: s).frame(width: 120)
                        Text("\(s)/100").font(Typography.tabular(12, .bold)).foregroundStyle(Palette.scoreColor(s))
                    }
                }
            }
            if isModerating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                    Text("synthesizing the verdict…").foregroundStyle(.secondary)
                }
            } else if let v = content.verdict, !v.isEmpty {
                VerdictMarkdown(text: v)
                if case .moderatorFailed = content.state.phase, let vm {
                    Button("Retry moderator") { vm.retryModerator() }
                        .controlSize(.small)
                }
            } else {
                Text("The moderator has not produced a verdict.").italic().foregroundStyle(.secondary)
            }
        }
    }
}

/// Markdown body used by every verdict card.
struct VerdictMarkdown: View {
    let text: String

    var body: some View {
        StructuredText(markdown: text)
            .textual.structuredTextStyle(.gitHub)
            .textual.codeBlockStyle(CouncilCodeBlockStyle())
            .textual.textSelection(.enabled)
    }
}

struct ScoreBar: View {
    let score: Int
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hairline)
                Capsule().fill(Palette.scoreColor(score)).frame(width: g.size.width * CGFloat(min(max(score, 0), 100)) / 100)
            }
        }
        .frame(height: 8)
    }
}

struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Typography.caption2Semibold)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Palette.accent.opacity(0.12)))
            .foregroundStyle(Palette.accent)
    }
}
