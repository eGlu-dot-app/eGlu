import PadCore
import SwiftUI
import UIKit

/// The command bar, on iPad: where an address is typed and everything else
/// is found, floating over the page as Arc's, Raycast's and Spotlight's do.
/// A new tab (⌘T, the + button) opens it empty with everything listed: the
/// open tabs, the spaces, every command with its keys (the cheat sheet of
/// the shortcuts), the parts of Settings. A click on the address, or ⌃⌥L,
/// opens it holding the page's address, selected, so typing replaces it.
/// What is typed goes to the tab on screen as an address or a search, or
/// narrows the rows to a tab to go to or a command to run (Suggestions).
///
/// It is the address field and the command palette in one: there is no
/// other place an address is typed on iPad, and no palette beside it. On a
/// phone the field is in the bar at the bottom instead (AddressEditor), with
/// the same rows over it.
struct CommandBar: View {
    let window: WindowModel
    let act: (BarAction) -> Void

    static let fieldHeight: CGFloat = 54
    /// The rows it shows before they scroll: enough to see what kinds there
    /// are, and little enough that the page still shows under it.
    static let rowsShown: CGFloat = 8.5

    var body: some View {
        // Each turn at the bar is a field of its own (WindowModel.addressTurn):
        // one that starts while another is still up (⌘T with the bar open)
        // gets a new field, with nothing of the last one's text or focus. The
        // old field loses the keys as the page is given them on the way to
        // the new tab, and kept, it would take that for being put away and
        // cancel the turn that had just begun.
        CommandBarTurn(window: window, suggestions: window.suggestions, act: act)
            .id(window.addressTurn)
    }
}

/// One turn at the command bar: its field and the rows under it.
private struct CommandBarTurn: View {
    let window: WindowModel
    @ObservedObject var suggestions: Suggestions
    let act: (BarAction) -> Void
    @State private var text = ""
    @State private var focused = false
    /// The text came over from the bar at the bottom (WindowModel.carriedAddress):
    /// kept as typed, the cursor after it, not all selected to type over.
    @State private var carried = false
    @State private var rowsHeight: CGFloat = 0
    @ScaledMetric(relativeTo: .subheadline) private var maximumRowsHeight = CommandBar.rowsShown * SuggestionRows.rowHeight
    @ObservedObject private var session = Session.shared
    @Environment(\.colorScheme) private var scheme

    /// The colour of the space the window is in.
    private var spaceColor: Color {
        (session.workspace.space(window.spaceID)?.color ?? .blue).color
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .frame(width: 22)
                TypingField(text: $text, placeholder: AddressEditor.placeholder, fontSize: 17, focused: $focused,
                            selectsAll: !carried) { typed in act(.go(typed)) }
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .clipped()
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Color.primary.opacity(0.3))
                            .frame(width: 32, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScale())
                    .hoverEffect(.highlight)
                    .accessibilityLabel("Clear")
                }
                Button("Cancel") { act(.cancelAddress) }
                    .font(.body)
                    .frame(minHeight: 44)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(minHeight: CommandBar.fieldHeight)
            if let destination = Destination.url(for: text, engine: session.preferences.engine), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { act(.goDirect(text)) } label: {
                    Label {
                        if Destination.searchWords(in: destination, engine: session.preferences.engine) != nil {
                            Text("Search \(Destination.engines.first(where: { $0.id == session.preferences.engine })?.name ?? String(localized: "the web")) for \(text)")
                        } else {
                            Text("Go to \(Destination.pretty(destination))")
                        }
                    } icon: { Image(systemName: "arrow.right.circle") }
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !suggestions.rows.isEmpty {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                SuggestionRows(rows: suggestions.rows, listing: suggestions.listing, selection: suggestions.selection,
                               heightChanged: { rowsHeight = $0 }) { row in act(.suggestion(row)) }
                    // As tall as its rows up to a point, and less where the
                    // window or the keyboard leaves less: then it scrolls.
                    .frame(idealHeight: min(rowsHeight, maximumRowsHeight), maxHeight: min(rowsHeight, maximumRowsHeight))
            }
        }
        // In Liquid Glass of the space's colour, as the Mac's command bar
        // is, firmer in the dark, where the colour is lighter; light or dark
        // as the system is. Frosted, and the colour faint, so its rows read
        // over a busy page. A soft shadow lifts it off the page.
        .floatingGlass(cornerRadius: 20, tint: spaceColor.opacity(scheme == .dark ? 0.26 : 0.22), frosted: true)
        .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.16), radius: 30, y: 14)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Command bar")
        .accessibilityAction(.escape) { act(.cancelAddress) }
        .onAppear { if window.editingAddress && !window.phone { begin() } }
        .onChange(of: text) { _, now in
            if !window.phone { suggestions.typed(now, in: window) }
        }
        .onChange(of: focused) { _, now in
            if !now && window.editingAddress && !window.phone { act(.cancelAddress) }
        }
        // Put away, the field lets go of the keys however typing ended.
        .onChange(of: window.editingAddress) { _, editing in if !editing { focused = false } }
    }

    /// The page's address, all of it selected, with the keys; or nothing,
    /// when everything is listed under the field; or what was typed in the
    /// bar at the bottom before the window widened.
    private func begin() {
        suggestions.begin(in: window)
        if let typed = window.carriedAddress {
            window.carriedAddress = nil
            carried = true
            text = typed
        } else {
            carried = false
            text = window.listsEverything ? "" : window.url.map { Destination.editable($0, engine: Session.shared.preferences.engine) } ?? ""
        }
        focused = true
    }
}
