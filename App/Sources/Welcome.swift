import PadCore
import SwiftUI
import UniformTypeIdentifiers

/// The first launch's welcome, over the first window: what eGlu is, then
/// the choices other browsers ask for at the start that eGlu has too. A
/// space of your own (Arc's colour for a space), your bookmarks from another
/// browser (Arc's and Dia's import), the default browser (Arc Search's one
/// question) and iCloud. Each can be skipped, and every one is in Settings
/// afterwards.
///
/// What isn't here is what eGlu doesn't have: an account to make or sign
/// in to, and anything to learn before the first page. It says so, since a
/// browser that opens on a site's sign-in page reads as an app asking for one.
struct Welcome: View {
    @ObservedObject var session: Session
    let spaceID: UUID
    let done: () -> Void

    enum Step: Int, CaseIterable {
        case hello, space, bookmarks, writing, finish
    }

    @State private var step: Step = .hello
    /// Which way the step last went, so the pages move the way it did.
    @State private var forward = true
    @State private var name = ""
    @State private var importing = false
    @State private var imported: BookmarkImportOutcome?
    @State private var importWorking = false
    @ObservedObject private var browser = DefaultBrowser.shared
    @ObservedObject private var sync = Sync.shared
    /// The Writing step exists only where the engine can check (Decided 7).
    /// Not where the question was answered already: on a welcome left
    /// before its end and resumed at the next launch, it isn't asked twice
    /// (task 05 Decided 2).
    private let asksWriting = WritingChecker.canCheck
        && WritingAsk.decision(welcomePending: true, asked: WritingAsked.wasAsked) == .welcomeStep
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase

    private var space: Space? {
        session.workspace.space(spaceID)
    }

    /// The steps this welcome shows, in order: the ones forward and back go
    /// through, the dots count, and VoiceOver numbers.
    private var steps: [Step] {
        Step.allCases.filter { $0 != .writing || asksWriting }
    }

    /// The space's colour is the welcome's own: choosing one shows at once on
    /// every button here, as it will on the space's button in the bar.
    private var colour: SpaceColor {
        space?.color ?? .blue
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                page
                    .id(step)
                    .transition(turn)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // What scrolls under the button fades out before it, in place of a hard edge.
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [Palette.ground.opacity(0), Palette.ground], startPoint: .top, endPoint: .bottom)
                    .frame(height: 20)
                    .allowsHitTesting(false)
            }
            footer
        }
        .background(Palette.ground)
        .tint(colour.color)
        .animation(.bar, value: step)
        .onAppear { name = space?.name ?? "" }
        .onChange(of: name) { _, new in session.change { $0.renameSpace(spaceID, to: new) } }
        // Back from Settings: the answer may have changed there.
        .onChange(of: phase) { _, new in if new == .active { browser.refresh() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.html, .zip]) { result in
            guard case .success(let file) = result else { imported = .cancelled; return }
            importWorking = true
            // Readable until the import has read it, which it does away from the main thread.
            let scoped = file.startAccessingSecurityScopedResource()
            session.importBookmarks(from: file, into: spaceID) { outcome in
                if scoped { file.stopAccessingSecurityScopedResource() }
                imported = outcome
                importWorking = false
            }
        }
    }

    /// A short slide the way the step went, and a fade: the page before
    /// leaves by less than it arrived, so the new one is what the eye follows.
    private var turn: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let side: CGFloat = forward ? 1 : -1
        return .asymmetric(insertion: .offset(x: 28 * side).combined(with: .opacity),
                           removal: .offset(x: -12 * side).combined(with: .opacity))
    }

    private func go(to next: Step) {
        forward = next.rawValue > step.rawValue
        step = next
    }

    private func advance() {
        guard let at = steps.firstIndex(of: step), at + 1 < steps.count else { return done() }
        go(to: steps[at + 1])
    }

    // MARK: The frame around the pages

    private var header: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(steps, id: \.self) { each in
                    Capsule()
                        .fill(each == step ? colour.color : Palette.faint)
                        .frame(width: each == step ? 18 : 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \((steps.firstIndex(of: step) ?? 0) + 1) of \(steps.count)")
            HStack {
                Button {
                    if let at = steps.firstIndex(of: step), at > 0 { go(to: steps[at - 1]) }
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScale())
                .accessibilityLabel("Back")
                .opacity(step == .hello ? 0 : 1)
                .disabled(step == .hello)
                Spacer()
                Button("Skip Setup", action: done)
                    .font(.body)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .opacity(step == .finish ? 0 : 1)
                    .disabled(step == .finish)
            }
            .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Button(action: primaryAction) {
                Text(primary)
                    .font(.headline)
                    .foregroundStyle(colour.ink)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(colour.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .keyboardShortcut(.defaultAction)
            .disabled(importWorking || (step == .space && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                      || (step == .bookmarks && (imported?.parsed != nil || imported?.needsSave == true)))
            // The same height on every page, so the button never moves under the finger.
            // "Not Now" on the Writing step, "Skip This Step" on Bookmarks.
            Button(step == .writing ? String(localized: "Not Now") : String(localized: "Skip This Step")) {
                step == .writing ? answerWriting(false) : advance()
            }
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
                .opacity(step == .bookmarks || step == .writing ? 1 : 0)
                .disabled((step != .bookmarks && step != .writing) || importWorking)
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var primary: String {
        switch step {
        case .hello, .space: return String(localized: "Continue")
        case .bookmarks:
            if importWorking { return String(localized: "Importing Bookmarks…") }
            if imported?.isComplete == true { return String(localized: "Continue") }
            if imported?.parsed != nil { return String(localized: "Choose a Space Above") }
            if imported?.needsSave == true { return String(localized: "Save Bookmarks Above") }
            return imported == nil ? String(localized: "Choose a File…") : String(localized: "Choose Another File…")
        case .writing: return String(localized: "Check My Writing")
        case .finish: return String(localized: "Start Browsing")
        }
    }

    private func primaryAction() {
        if step == .bookmarks, imported?.isComplete != true { importing = true }
        else if step == .writing { answerWriting(true) }
        else { advance() }
    }

    /// The Writing step's answer: kept (the ask counted as made) either way.
    private func answerWriting(_ on: Bool) {
        if on { session.preferences.writing = true }
        WritingAsked.markAsked()
        advance()
    }

    @ViewBuilder private var page: some View {
        ScrollView {
            Group {
                switch step {
                case .hello: hello
                case .space: yourSpace
                case .bookmarks: bookmarks
                case .writing: writingAsk
                case .finish: finish
                }
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func heading(_ title: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.title.bold())
                .tracking(-0.4)
                .multilineTextAlignment(.center)
            Text(text)
                .font(.body)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Welcome

    private var hello: some View {
        VStack(spacing: 28) {
            Image("WelcomeIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
            heading(String(localized: "Welcome to eGlu"), String(localized: "A browser for desktop web apps."))
            VStack(alignment: .leading, spacing: 20) {
                if Device.phone {
                    Feature(symbol: "desktopcomputer", title: String(localized: "Trackpad View"),
                            text: String(localized: "Open a site's desktop version from the page's menu, with the screen as a trackpad."))
                } else {
                    Feature(symbol: "cursorarrow.motionlines", title: String(localized: "Trackpad and keyboard go to the page"),
                            text: String(localized: "Pinch to zoom a canvas at the pointer. ⌘ shortcuts go to the web app."))
                }
                Feature(symbol: "square.stack.3d.up", title: String(localized: "Spaces keep accounts apart"),
                        text: String(localized: "Each space has its own tabs, sign-ins and bookmarks."))
                Feature(symbol: "shield.lefthalf.filled", title: String(localized: "Ads and trackers are blocked"),
                        text: String(localized: "Before they load. You can allow a site from its menu."))
            }
            Text("There is no account to make. eGlu collects no data.")
                .font(.footnote)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: The first space

    private var yourSpace: some View {
        VStack(spacing: 24) {
            heading(String(localized: "Set up your first space"),
                    String(localized: "A space keeps its own tabs, sign-ins and bookmarks. Add one for each client or account later, in Settings › Spaces."))
            HStack(spacing: 12) {
                Image(systemName: space?.symbol ?? "briefcase")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(colour.ink)
                    .frame(width: 40, height: 40)
                    .background(colour.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .animation(.bar, value: colour)
                TextField("Name", text: $name)
                    .font(.body.weight(.medium))
                    .submitLabel(.done)
            }
            // The chip's corner (10) and the 8 points around it.
            .padding(8)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Enter a name. This space is still named \(space?.name ?? String(localized: "Space")) until a valid name is entered.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                label(String(localized: "Colour"))
                ColourRow(selected: colour) { chosen in
                    session.change { $0.setColor(spaceID, to: chosen) }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                label(String(localized: "Icon"))
                IconGrid(selected: space?.symbol ?? "", colour: colour) { symbol in
                    session.change { $0.setSymbol(spaceID, to: symbol) }
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Palette.muted)
    }

    // MARK: Bookmarks

    private var bookmarks: some View {
        VStack(spacing: 24) {
            badge("bookmark.fill")
            heading(String(localized: "Bring your bookmarks"),
                    String(localized: "Import a bookmarks file from Chrome, Firefox or Safari into \(space?.name ?? String(localized: "your space")). They show on every new tab."))
            if imported != nil {
                BookmarkImportStatusView(session: session, outcome: $imported, chooseFile: { importing = true }, showFileChoice: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Source(name: "Chrome", path: String(localized: "Bookmark Manager › Export Bookmarks"))
                    Source(name: "Firefox", path: String(localized: "Manage Bookmarks › Import and Backup › Export Bookmarks to HTML"))
                    Source(name: "Safari", path: String(localized: "Settings › Apps › Safari › Export, with Bookmarks chosen"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    // MARK: Checking English in pages

    /// The once-only question: its buttons are the footer's own, so the
    /// step's page is the question's words alone (WritingQuestion).
    private var writingAsk: some View {
        WritingQuestion(offersOtherApps: false,
                        check: { _ in self.answerWriting(true) },
                        notNow: { self.answerWriting(false) },
                        showsButtons: false)
    }

    // MARK: The default browser and iCloud

    private var finish: some View {
        VStack(spacing: 24) {
            heading(String(localized: "Two optional settings"), String(localized: "You can change both later in Settings."))
            VStack(alignment: .leading, spacing: 12) {
                choice("globe", String(localized: "Default browser"), String(localized: "Links you tap in other apps open in eGlu, each in a new tab."))
                // Under the words, in line with them: beside them it squeezed them into a narrow column.
                Group {
                    if browser.status == .isDefault {
                        // The words in ink, the check in the colour: yellow text on white doesn't read.
                        Label {
                            Text("eGlu is your default browser").foregroundStyle(Palette.ink)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(colour.color)
                        }
                        .font(.subheadline.weight(.medium))
                    } else {
                        Button("Open Settings") { browser.openSettings() }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(colour.ink)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 36)
                            .background(colour.color, in: Capsule())
                            // Drawn 36 points tall, answering a touch over 44, as the welcome's other buttons do.
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .buttonStyle(PressScale())
                        Text(browser.instructions)
                            .font(.footnote)
                            .foregroundStyle(Palette.muted)
                    }
                }
                .padding(.leading, 40)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $session.preferences.iCloudSync) {
                    choice("icloud", String(localized: "Sync with iCloud"),
                           String(localized: "Spaces, bookmarks and pinned tabs sync between your devices. Open tabs and sign-ins stay on each device."))
                }
                .toggleStyle(.switch)
                if session.preferences.iCloudSync { SyncStatusView() }
                if session.preferences.iCloudSync, let problem = sync.problem {
                    Label(problem, systemImage: "exclamationmark.icloud")
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                        .padding(.leading, 40)
                }
            }
            .padding(16)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .onAppear { browser.refresh() }
    }

    private func choice(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(colour.color)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(colour.ink)
            .frame(width: 72, height: 72)
            .background(colour.color, in: RoundedRectangle(cornerRadius: 72 * 0.225, style: .continuous))
            .animation(.bar, value: colour)
            .accessibilityHidden(true)
    }
}

/// One thing eGlu does, on the welcome's first page.
private struct Feature: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Palette.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Where a browser keeps its export, for the bookmarks page.
private struct Source: View {
    let name: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.subheadline.weight(.semibold))
            Text(path)
                .font(.subheadline)
                .foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .combine)
    }
}
