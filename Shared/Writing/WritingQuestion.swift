import SwiftUI

/// The one question eGlu asks about grammar checking (task 05): on the
/// welcome's Writing step on iPad and iPhone, and on a small sheet on the
/// Mac and for people whose welcome is already done. Both buttons mark
/// WritingAsked before their closure runs, so whatever the answer the
/// question never returns; Settings › Writing changes it later.
struct WritingQuestion: View {
    /// The "in other apps too" offer, on the Mac once checking outside eGlu
    /// is in (task 03); false until then.
    let offersOtherApps: Bool
    /// "Check My Writing" pressed; `otherApps` is the checkbox's answer.
    let check: (Bool) -> Void
    /// "Not Now" pressed.
    let notNow: () -> Void
    /// The button row is drawn unless the view the question is in answers
    /// another way: the welcome's footer buttons do its step's asking, and
    /// mark WritingAsked the same.
    var showsButtons = true

    @State private var otherApps = false

    /// The grey of the words under the heading. On iPad and iPhone the
    /// system's secondary grey is 3.4:1 on white, under the 4.5:1 text
    /// needs; Palette.muted is the app's own grey made for that. The Mac's
    /// sheet keeps the system's.
    private static var note: Color {
        #if os(iOS)
        Palette.muted
        #else
        Color.secondary
        #endif
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "character.cursor.ibeam")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Check your English as you write?")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Harper, a grammar checker, underlines mistakes in what you type in pages and suggests fixes. It works on this device, in English only, and sends nothing anywhere.")
                .foregroundStyle(Self.note)
                .multilineTextAlignment(.center)
            if offersOtherApps {
                Toggle("In other apps too, such as Mail and Notes", isOn: $otherApps)
                if otherApps {
                    Text("eGlu will ask for Accessibility, which lets it read the field you type in.")
                        .font(.footnote)
                        .foregroundStyle(Self.note)
                }
            }
            Text("You can change this in Settings › Writing.")
                .font(.footnote)
                .foregroundStyle(Self.note)
            if showsButtons {
                HStack(spacing: 12) {
                    Button("Not Now") {
                        WritingAsked.markAsked()
                        notNow()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Check My Writing") {
                        WritingAsked.markAsked()
                        check(otherApps)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
        }
    }
}
