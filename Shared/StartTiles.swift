import PadCore
import SwiftUI

// A new tab's page, the iPad's and the Mac's alike: one column with the
// space's mark and name (SpaceMark), the way to an address, and the space's
// bookmarks as tiles (BookmarkFace) whose squares reach both edges of the
// column, as the field above them does (TileGrid); then the pages last gone
// to here and on the other devices (RecentPages); each part coming in after
// the one before it (arriving), and each but the field on or off from the
// page's foot (StartCustomize).

nonisolated enum StartMetrics {
    /// The column everything stands in, at its widest, and the least room on either side of it.
    static let column: CGFloat = 600
    static let margin: CGFloat = 32
    /// A tile's square and the icon in it.
    static let square: CGFloat = 64
    static let icon: CGFloat = 34
    static let corner = cornerRadius(icon: icon, in: square)
    /// The least distance from one square's centre to the next.
    static let pitch: CGFloat = 96
    static let rowGap: CGFloat = 18
    /// The field's height.
    static let field: CGFloat = 44

    /// How far down the page the column starts: a little above the middle
    /// of a tall page, so it stands where the eye goes, and still near the
    /// top of a short one.
    static func top(in height: CGFloat) -> CGFloat {
        max(40, height * 0.14)
    }

    /// The corner of a square an icon stands in: the icon's (0.225 of its
    /// side) and the padding round it, so the two curves run side by side.
    static func cornerRadius(icon: CGFloat, in square: CGFloat) -> CGFloat {
        icon * 0.225 + (square - icon) / 2
    }
}

/// The space's symbol on its colour, and its name under it.
struct SpaceMark: View {
    let space: Space
    /// Scaled, so at a large text size the page's own name is never smaller
    /// than the bookmarks and history headings under it.
    @ScaledMetric(relativeTo: .title) private var nameSize: CGFloat = 24
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: space.symbol)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(space.color.ink)
                .frame(width: 52, height: 52)
                .background(space.color.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(space.name)
                .font(.system(size: nameSize, weight: .bold))
                // At the accessibility sizes a long name wraps rather than being cut short.
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A bookmark or a folder as a tile: the site's icon, or a folder in the
/// space's colour, on a rounded square that darkens a little under the
/// pointer, and its name under it in two lines at most.
struct BookmarkFace: View {
    let item: Bookmark
    let colour: SpaceColor
    let hovering: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: StartMetrics.corner, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.09 : 0.05))
                if item.isFolder {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 27))
                        .foregroundStyle(colour.color)
                        .accessibilityHidden(true)
                } else {
                    SiteIconView(url: item.url, size: StartMetrics.icon)
                }
            }
            .frame(width: StartMetrics.square, height: StartMetrics.square)
            Text(item.label)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .contentShape(Rectangle())
    }
}

/// Tiles in rows whose squares reach both edges of the column, as the field
/// and the heading above them do: as many to a row as stand `pitch` apart or
/// more, spread so the first square starts at the column's left edge and a
/// full row's last ends at its right; a row that isn't full, from the left.
/// Each tile is offered the room between its neighbours for its name.
struct TileGrid: Layout {
    var square = StartMetrics.square
    var pitch = StartMetrics.pitch
    var rowGap = StartMetrics.rowGap

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? square + pitch * CGFloat(max(subviews.count - 1, 0))
        let heights = rowHeights(of: subviews, in: width)
        return CGSize(width: width, height: max(heights.reduce(0, +) + rowGap * CGFloat(heights.count - 1), 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (count, step) = columns(in: bounds.width)
        let offer = ProposedViewSize(width: room(step), height: nil)
        var y = bounds.minY
        for (row, height) in rowHeights(of: subviews, in: bounds.width).enumerated() {
            for column in 0..<count {
                let index = row * count + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: bounds.minX + square / 2 + CGFloat(column) * step, y: y),
                                      anchor: .top, proposal: offer)
            }
            y += height + rowGap
        }
    }

    /// How many squares stand in a row, and how far apart their centres are.
    private func columns(in width: CGFloat) -> (count: Int, step: CGFloat) {
        let count = max(1, Int((width - square) / pitch) + 1)
        return (count, count > 1 ? (width - square) / CGFloat(count - 1) : pitch)
    }

    /// The width a tile's name has: the step less a little, so neighbours' names never touch.
    private func room(_ step: CGFloat) -> CGFloat {
        max(square, step - 6)
    }

    /// Each row as high as its tallest tile: a name in two lines makes its row taller.
    private func rowHeights(of subviews: Subviews, in width: CGFloat) -> [CGFloat] {
        let (count, step) = columns(in: width)
        let offer = ProposedViewSize(width: room(step), height: nil)
        return stride(from: 0, to: subviews.count, by: count).map { start in
            subviews[start..<min(start + count, subviews.count)].map { $0.sizeThatFits(offer).height }.max() ?? 0
        }
    }
}

extension View {
    /// In after the parts before it: faded and a little lower until `shown`,
    /// then in place `delay` seconds later; where motion is reduced, faded in
    /// where it stands.
    func arriving(_ shown: Bool, after delay: Double) -> some View {
        modifier(Arriving(shown: shown, delay: delay))
    }
}

private struct Arriving: ViewModifier {
    let shown: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .animation(.bar.delay(delay), value: shown)
    }
}

// MARK: Pages gone to, and Customize

extension Preferences.StartSection {
    /// Its name, as its heading and in Customize.
    var title: String {
        switch self {
        case .bookmarks: return String(localized: "Bookmarks")
        case .history: return String(localized: "History")
        case .otherDevices: return String(localized: "From Other Devices")
        }
    }
}

/// A section of a new tab's page listing the pages last gone to in the
/// space, each once, at its last visit, newest first: on this device
/// (History), or on the person's other devices, as History in iCloud brings
/// them (From Other Devices). Each row is the site's icon, the page's name,
/// and the site and how long ago; a tap goes there, its menu opens it in a
/// new tab or copies its address.
struct RecentPages: View {
    let section: Preferences.StartSection
    let space: UUID
    /// As high as the page's Bookmarks heading.
    let headingHeight: CGFloat
    let shown: Bool
    let delay: Double
    /// The History list, from the heading.
    let showAll: () -> Void
    let open: (URL) -> Void
    let openInNewTab: (URL) -> Void
    let copy: (URL) -> Void
    @ObservedObject private var history = HistoryRecorder.shared
    @ObservedObject private var session = Session.shared
    /// Nil until first read, so an empty list isn't said before it is known.
    @State private var entries: [HistoryEntry]?

    private var others: Bool {
        section == .otherDevices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            heading
                .arriving(shown, after: delay)
            if let entries {
                if entries.isEmpty {
                    Text(emptyText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .arriving(shown, after: delay + 0.04)
                } else {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        RecentRow(entry: entry, open: open, openInNewTab: openInNewTab, copy: copy)
                            .arriving(shown, after: delay + 0.04 + min(Double(index) * 0.02, 0.12))
                    }
                }
            }
        }
        .task(id: Read(space: space, revision: history.revision)) {
            let (space, others, device) = (space, others, Sync.shared.deviceID)
            entries = await HistoryRecorder.shared.read { try await $0.recent(space: space, device: device, others: others) } ?? []
        }
    }

    /// What the list was read for: read again as history changes, here or as iCloud brings it.
    private struct Read: Equatable {
        let space: UUID
        let revision: Int
    }

    private var heading: some View {
        HStack {
            Text(section.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 8)
            if entries?.isEmpty == false {
                Button("Show All", action: showAll)
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.borderless)
            }
        }
        .frame(minHeight: headingHeight)
    }

    /// Where the list is empty: why, in a sentence.
    private var emptyText: String {
        guard others else { return String(localized: "Pages you go to in this space show here.") }
        let preferences = session.preferences
        guard preferences.iCloudSync, preferences.historySync else {
            return String(localized: "Turn on Sync history in Settings › iCloud to see the pages your other devices go to in this space.")
        }
        return String(localized: "Pages your other devices go to in this space show here.")
    }
}

/// A page in a new tab's History or From Other Devices.
private struct RecentRow: View {
    let entry: HistoryEntry
    let open: (URL) -> Void
    let openInNewTab: (URL) -> Void
    let copy: (URL) -> Void
    @State private var hovering = false

    /// Match the square's corner to the icon's curve and surrounding padding.
    private static let square: CGFloat = 36
    private static let icon: CGFloat = 20
    private static let corner = StartMetrics.cornerRadius(icon: icon, in: square)

    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter
    }()

    var body: some View {
        let page = entry.page
        let site = Destination.pretty(page.url)
        let when = Self.ago.localizedString(for: entry.time, relativeTo: Date())
        Button { open(page.url) } label: {
            HStack(spacing: 12) {
                SiteIconView(url: page.url, size: Self.icon)
                    .frame(width: Self.square, height: Self.square)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title.isEmpty ? site : page.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(site) · \(when)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(Color.primary.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: Self.corner + 5, style: .continuous))
            // The icon's edge on the column's, as the tiles' squares are: the highlight reaches out past it.
            .padding(.horizontal, -8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { inside in withAnimation(.bar) { hovering = inside } }
        .help(page.url.absoluteString)
        .contextMenu {
            Button("Open in New Tab", systemImage: "plus.square.on.square") { openInNewTab(page.url) }
            Button("Copy Address", systemImage: "doc.on.doc") { copy(page.url) }
        }
        .accessibilityLabel("\(page.title.isEmpty ? site : page.title), \(site), \(when)")
    }
}

/// The foot of a new tab's page: what it shows, each part on or off.
struct StartCustomize: View {
    @Binding var hidden: Set<Preferences.StartSection>

    var body: some View {
        Menu {
            // Names alone, each on one line: an icon beside each took the room for it.
            ForEach(Preferences.StartSection.allCases, id: \.self) { section in
                Toggle(section.title, isOn: Binding {
                    !hidden.contains(section)
                } set: { on in
                    if on { hidden.remove(section) } else { hidden.insert(section) }
                })
            }
        } label: {
            Label("Customize", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        // Grey, as the page's other quiet words are, not the accent the menu would tint it.
        .tint(.secondary)
        .menuIndicator(.hidden)
        #if os(iOS)
        // Several parts on or off in one go; the Mac's menus close as they always do.
        .menuActionDismissBehavior(.disabled)
        #endif
        .fixedSize()
        .accessibilityLabel("Customize This Page")
    }
}
