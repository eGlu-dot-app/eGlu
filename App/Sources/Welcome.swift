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
    let done: (SetupProgress.Completion) async -> Bool

    typealias Step = SetupProgress.Step

    @State private var step: Step
    @State private var name = ""
    @State private var importing = false
    @State private var imported: BookmarkImportOutcome?
    @State private var importWorking = false
    @State private var importDestination: UUID?
    @State private var save = SetupSaveState()
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
    @Environment(\.dynamicTypeSize) private var typeSize

    init(session: Session, spaceID: UUID, step: Step, done: @escaping (SetupProgress.Completion) async -> Bool) {
        self.session = session
        self.spaceID = spaceID
        _step = State(initialValue: step)
        self.done = done
    }

    private var space: Space? {
        session.workspace.space(spaceID)
    }

    /// The steps this welcome shows, in order: the ones forward and back go
    /// through, the dots count, and VoiceOver numbers.
    private var steps: [Step] {
        Step.offered(asksWriting: asksWriting)
    }

    /// The space's colour is the welcome's own: choosing one shows at once on
    /// every button here, as it will on the space's button in the bar.
    private var colour: SpaceColor {
        space?.color ?? .blue
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // At accessibility sizes a banner and footer can be taller
                // than the sheet. One scroll keeps every action reachable.
                ScrollView {
                    VStack(spacing: 0) {
                        saveBanner
                        header
                        page
                        footer
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                VStack(spacing: 0) {
                    header
                    ScrollView {
                        VStack(spacing: 0) {
                            saveBanner
                            page
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // What scrolls under the button fades out before it.
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [Palette.ground.opacity(0), Palette.ground], startPoint: .top, endPoint: .bottom)
                            .frame(height: 20)
                            .allowsHitTesting(false)
                    }
                    footer
                }
            }
        }
        // A step is a new accessibility screen, including its controls. Reusing
        // the activated footer across steps makes VoiceOver restore focus to
        // that same element under its new label instead of the new heading.
        .id(step)
        .background(Palette.ground)
        .tint(colour.color)
        .onAppear { name = space?.name ?? "" }
        .onChange(of: name) { _, new in session.change { $0.renameSpace(spaceID, to: new) } }
        .onChange(of: save) { _, next in
            if next.retryReason != nil {
                AccessibilityNotification.Announcement(String(localized: "Setup hasn't finished. Your choices are still here. Retry saving to finish.")).post()
            }
        }
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
                outcome.announceResult()
            }
        }
    }

    private var saveBanner: some View {
        WorkspaceSaveStatusView(showsRetry: false)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func go(to next: Step) {
        guard !save.isSaving, !importWorking else { return }
        // SwiftUI's default-action Button does not distinguish Return from
        // a tap. Snap both paths rather than decorate keyboard navigation;
        // the progress geometry and page swap share the same transaction.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            step = next
            save = SetupSaveState()
            session.visitWelcome(next)
        }
    }

    private func advance() {
        guard let at = steps.firstIndex(of: step), at + 1 < steps.count else { return finishSetup(.completed) }
        go(to: steps[at + 1])
    }

    private func finishSetup(_ reason: SetupProgress.Completion) {
        let intent = save.retryReason ?? reason
        guard !importWorking, save.begin(intent) else { return }
        Task { @MainActor in save.acknowledge(await done(intent)) }
    }

    private var bookmarkAction: SetupBookmarkAction {
        SetupBookmarkAction.resolve(outcome: imported, working: importWorking,
                                    hasDestination: importDestination.map { session.workspace.space($0) != nil } == true)
    }

    // MARK: The frame around the pages

    private var stepTitle: String {
        switch step {
        case .hello: return String(localized: "Welcome")
        case .space: return String(localized: "Space")
        case .bookmarks: return String(localized: "Bookmarks")
        case .writing: return String(localized: "Writing")
        case .finish: return String(localized: "Finish")
        }
    }

    private var stepProgress: String {
        String(localized: "Step \((steps.firstIndex(of: step) ?? 0) + 1) of \(steps.count)")
    }

    private var header: some View {
        VStack(spacing: 4) {
            controls
            HStack(spacing: 6) {
                ForEach(steps, id: \.self) { each in
                    Capsule()
                        .fill(each == step ? colour.color : Palette.faint)
                        .frame(width: each == step ? 18 : 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \((steps.firstIndex(of: step) ?? 0) + 1) of \(steps.count)")
            Text("\(stepTitle) · \((steps.firstIndex(of: step) ?? 0) + 1) of \(steps.count)")
                .font(.caption)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                // The dots already expose the current step to VoiceOver.
                .accessibilityHidden(true)
        }
    }

    private var controls: some View {
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
            .disabled(step == .hello || save.isSaving || importWorking)
            Spacer()
            Button("Skip Setup") { finishSetup(.skipped) }
                .font(.body)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .opacity(step == .finish ? 0 : 1)
                .disabled(step == .finish || importWorking || save.isSaving)
        }
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            if save.retryReason != nil {
                Label("Setup hasn't finished. Your choices are still here. Retry saving to finish.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
            Button(action: primaryAction) {
                HStack(spacing: 8) {
                    if save.isSaving || importWorking { ProgressView().tint(colour.ink) }
                    Text(primary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                    .font(.headline)
                    .foregroundStyle(colour.ink)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(colour.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .keyboardShortcut(.defaultAction)
            .disabled(save.isSaving || importWorking || (save.retryReason == nil &&
                      ((step == .space && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                       || (step == .bookmarks && bookmarkAction == .chooseDestination))))
            // The same height on every page, so the button never moves under the finger.
            // "Not Now" on the Writing step, "Skip This Step" on Bookmarks.
            Button(step == .writing ? String(localized: "Not Now") : String(localized: "Skip This Step")) {
                step == .writing ? answerWriting(false) : advance()
            }
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
                .opacity(showsSecondary ? 1 : 0)
                .accessibilityHidden(!showsSecondary)
                .disabled(!showsSecondary || importWorking || save.isSaving)
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var showsSecondary: Bool {
        save.retryReason == nil && (step == .writing || (step == .bookmarks && imported?.isComplete != true && imported?.needsSave != true))
    }

    private var primary: String {
        if save.isSaving { return String(localized: "Saving Setup…") }
        if save.retryReason != nil { return String(localized: "Retry Saving") }
        switch step {
        case .hello, .space: return String(localized: "Continue")
        case .bookmarks:
            switch bookmarkAction {
            case .wait: return String(localized: "Importing Bookmarks…")
            case .continueSetup: return String(localized: "Continue")
            case .chooseDestination: return String(localized: "Choose a Space Above")
            case .importSelected: return String(localized: "Import into Selected Space")
            case .retrySave: return String(localized: "Retry Saving")
            case .chooseFile: return imported == nil ? String(localized: "Choose a File…") : String(localized: "Choose Another File…")
            }
        case .writing: return String(localized: "Check My Writing")
        case .finish: return String(localized: "Start Browsing")
        }
    }

    private func primaryAction() {
        guard !save.isSaving, !importWorking else { return }
        if let reason = save.retryReason { finishSetup(reason) }
        else if step == .bookmarks {
            switch bookmarkAction {
            case .chooseFile: importing = true
            case .retrySave:
                guard let imported else { return }
                importWorking = true
                session.retryBookmarkImport(imported) { outcome in
                    self.imported = outcome
                    importWorking = false
                    outcome.announceResult()
                }
            case .importSelected:
                guard let parsed = imported?.parsed, let importDestination else { return }
                importWorking = true
                session.importBookmarks(parsed, into: importDestination) { outcome in
                    imported = outcome
                    importWorking = false
                    outcome.announceResult()
                }
            case .continueSetup: advance()
            case .wait, .chooseDestination: break
            }
        }
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
        .disabled(save.isSaving || importWorking)
    }

    private func heading(_ title: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            ScreenHeading(title: title, progress: stepProgress)
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
                VStack(alignment: .leading, spacing: 8) {
                    BookmarkImportStatusView(session: session, outcome: $imported, chooseFile: { importing = true }, showFileChoice: false, showRecoveryActions: false)
                    if imported?.parsed != nil {
                        Picker("Import into", selection: $importDestination) {
                            Text("Choose a Space").tag(UUID?.none)
                            ForEach(session.workspace.spaces) { space in
                                Text(space.name).tag(Optional(space.id))
                            }
                        }
                    }
                }
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
                        showsButtons: false, focusesHeading: true, headingProgress: stepProgress)
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
            .animation(reduceMotion ? nil : .bar, value: colour)
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
