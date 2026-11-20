import PadCore
import SwiftUI
import UIKit

@MainActor
@Observable
final class PageSummaryJob {
    enum State: Equatable { case reading, writing, ready, failed }

    let title: String
    let url: URL
    private(set) var text = ""
    private(set) var state = State.reading
    @ObservationIgnored private weak var source: Page?
    @ObservationIgnored private let allowed: () -> Bool
    @ObservationIgnored private var generation = UUID()

    init(source: Page, url: URL, allowed: @escaping () -> Bool) {
        self.source = source
        self.url = url
        title = source.title.isEmpty ? (url.host() ?? String(localized: "This page")) : source.title
        self.allowed = allowed
    }

    func read(skill: PageSkill) async {
        guard !Task.isCancelled else { return }
        let run = UUID()
        generation = run
        text = ""
        state = .reading
        guard allowed(), let source else {
            fail()
            return
        }
        let mind = await PageMinds.mind()
        guard isCurrent(run) else { return }
        guard allowed(), let mind else {
            fail()
            return
        }
        let outcome = await source.readingForHandoff(limit: Handoff.limit, into: FileManager.default.temporaryDirectory,
                                                    fetchDocuments: false)
        guard isCurrent(run) else { return }
        guard allowed(), case .content(let reading) = outcome else {
            fail()
            return
        }
        let question = PageQuestion(briefs: Handoff.briefs(title: title, url: url, reading: reading, candidates: []), picks: false, skill: skill)
        let answer = await mind.read(question, looks: false, picture: { nil }) { [weak self] words in
            guard let self, self.isCurrent(run), self.allowed() else { return }
            self.text = Self.formatted(words, skill: skill)
            self.state = .writing
        }
        guard isCurrent(run) else { return }
        guard allowed(), let answer, !Self.formatted(answer.about, skill: skill).isEmpty else {
            fail()
            return
        }
        text = Self.formatted(answer.about, skill: skill)
        state = .ready
    }

    private static func formatted(_ words: String, skill: PageSkill) -> String {
        if skill == .summary { return Handoff.hardened(words) }
        return words.components(separatedBy: .newlines)
            .map { Handoff.hardened($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isCurrent(_ run: UUID) -> Bool {
        generation == run && !Task.isCancelled
    }

    private func fail() {
        text = ""
        state = .failed
    }
}

struct PageSummarySheet: View {
    @State var job: PageSummaryJob
    let handoff: () -> Void
    @State private var copied = false
    @State private var skill = PageSkill.summary
    @Environment(\.dismiss) private var dismiss

    @ViewBuilder
    private var copyButton: some View {
        let button = Button {
            UIPasteboard.general.string = job.text
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .disabled(job.state != .ready)
        .accessibilityLabel("Copy summary")
        .accessibilityValue(copied ? "Copied" : "")
        .accessibilityIdentifier("summary-copy")

        if #available(iOS 26.0, *) {
            button
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        } else {
            button
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(job.title)
                            .font(.title3.weight(.semibold))
                            .accessibilityIdentifier("summary-page-title")
                        Text(job.url.host() ?? String(localized: "On this device"))
                            .font(.subheadline)
                            .foregroundStyle(Palette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Picker("Page skill", selection: $skill) {
                        ForEach(PageSkill.allCases, id: \.self) { skill in
                            Text(skill.title)
                                .tag(skill)
                                .accessibilityIdentifier("summary-skill-\(skill.rawValue)")
                        }
                    }
                    .pickerStyle(.segmented)

                    if job.state == .failed {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Couldn't summarize this page", systemImage: "exclamationmark.bubble")
                                .font(.headline)
                                .accessibilityIdentifier("summary-failure")
                            Text("Apple Intelligence couldn't read this page. You can still try Handoff.")
                                .font(.subheadline)
                                .foregroundStyle(Palette.muted)
                        }
                    } else {
                        if !job.text.isEmpty {
                            Text(job.text)
                                .font(.system(.title3, design: .serif))
                                .lineSpacing(6)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("summary-text")
                        }
                        if job.state != .ready {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(job.state == .reading ? "Reading the page…" : "Writing…")
                                    .font(.subheadline)
                                    .foregroundStyle(Palette.muted)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("summary-progress")
                        }
                    }
                }
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .background(Palette.ground)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 16) {
                    Label("Apple Intelligence · On-device", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                    HStack(spacing: 12) {
                        copyButton
                        Button(action: handoff) {
                            Label("Handoff…", systemImage: Command.handoff.symbol)
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(Palette.ground)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("summary-handoff")
                    }
                    .controlSize(.large)
                    .font(.subheadline.weight(.medium))
                    .tint(Palette.ink)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .background(.regularMaterial)
            }
            .navigationTitle("Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("summary-close")
                }
            }
        }
        .task(id: skill) {
            copied = false
            await job.read(skill: skill)
        }
    }
}
