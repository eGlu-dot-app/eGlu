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
    @ObservationIgnored private var started = false

    init(source: Page, url: URL, allowed: @escaping () -> Bool) {
        self.source = source
        self.url = url
        title = source.title.isEmpty ? (url.host() ?? String(localized: "This page")) : source.title
        self.allowed = allowed
    }

    func read() async {
        guard !started else { return }
        started = true
        guard allowed(), let source, let mind = await PageMinds.mind(), !Task.isCancelled, allowed() else {
            fail()
            return
        }
        let outcome = await source.readingForHandoff(limit: Handoff.limit, into: FileManager.default.temporaryDirectory,
                                                    fetchDocuments: false)
        guard !Task.isCancelled, allowed(), case .content(let reading) = outcome else {
            fail()
            return
        }
        let question = PageQuestion(briefs: Handoff.briefs(title: title, url: url, reading: reading, candidates: []), picks: false)
        let answer = await mind.read(question, looks: false, picture: { nil }) { [weak self] words in
            guard let self, !Task.isCancelled, self.allowed() else { return }
            self.text = Handoff.hardened(words)
            self.state = .writing
        }
        guard !Task.isCancelled else { return }
        guard allowed(), let answer, !Handoff.hardened(answer.about).isEmpty else {
            fail()
            return
        }
        text = Handoff.hardened(answer.about)
        state = .ready
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
    @Environment(\.dismiss) private var dismiss

    @ViewBuilder
    private var copyButton: some View {
        let button = Button {
            UIPasteboard.general.string = job.text
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 14, weight: .medium))
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
                                Text(job.state == .reading ? "Reading the page…" : "Writing summary…")
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
        .task { await job.read() }
    }
}
