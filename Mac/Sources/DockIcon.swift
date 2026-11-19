import AppKit
import PadCore
import SwiftUI

/// The app's icon on the Mac, chosen in Settings › General › App Icon from
/// the ones the iPhone and iPad offer (AppIcon). macOS has no alternate icons,
/// and a picture put in the app's own folder would break its signature, so the
/// icon is drawn over the Dock's tile instead: by the app while it is open
/// (the About window takes it from there too), and by its Dock tile plug-in
/// (Mac/DockTile) while it isn't. Finder and Spotlight show the app's own.
@MainActor
final class DockIcon: ObservableObject {
    static let shared = DockIcon()

    @Published private(set) var current: AppIcon
    private var appearance: NSKeyValueObservation?

    /// Words the address bar finds App Icon by, as the iPhone and iPad's
    /// (SettingsAnchor.appIcon), with the Dock where they have the Home Screen.
    static let keywords = ["change icon", "change app icon", "dock icon", "alternate icon", "icon style", "logo"]

    private init() {
        // A name no icon has now (renamed since) is eGlu's own.
        current = AppIcon(alternateName: UserDefaults.standard.string(forKey: DockIconKeys.choice)) ?? .eGlu
    }

    /// At launch, once AppKit has put the app's own icon in the Dock, and
    /// from then on as the Mac turns light or dark: the Dock shows the picture
    /// it is given as it was drawn.
    func start() {
        show()
        appearance = NSApp.observe(\.effectiveAppearance) { _, _ in
            // Changes of appearance come on the main thread.
            MainActor.assumeIsolated { DockIcon.shared.show() }
        }
    }

    func choose(_ icon: AppIcon) {
        guard icon != current else { return }
        current = icon
        // Nil, for eGlu's own, takes the name away.
        UserDefaults.standard.set(icon.alternateName, forKey: DockIconKeys.choice)
        show()
        // For the plug-in: the tile stays as chosen once eGlu quits.
        DistributedNotificationCenter.default().postNotificationName(
            DockIconKeys.changed, object: Bundle.main.bundleIdentifier, userInfo: nil, deliverImmediately: true)
    }

    /// Settings, at General, with App Icon in view.
    func showInSettings() {
        SettingsPane.show(.appIcon)
    }

    /// The icon's picture, which takes the light or the dark look of where it is drawn.
    static func picture(_ icon: AppIcon) -> NSImage? {
        NSImage(named: DockIconKeys.picture(icon.rawValue))
    }

    private func show() {
        guard current != .eGlu, let picture = Self.picture(current) else {
            // The app's own, which the Dock draws in its own style.
            NSApp.applicationIconImage = nil
            return
        }
        // Drawn in the Mac's look now: the Dock keeps what it was given.
        let look = NSAppearance(named: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua)
            ?? NSApp.effectiveAppearance
        NSApp.applicationIconImage = NSImage(size: picture.size, flipped: false) { rect in
            look.performAsCurrentDrawingAppearance { picture.draw(in: rect) }
            return true
        }
    }
}

/// Settings › General › App Icon: the icons the iPhone and iPad offer, in
/// their order, each as the Dock shows it; choosing one puts it there at once.
struct AppIconSettings: View {
    @ObservedObject private var icon = DockIcon.shared

    var body: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 14) {
                ForEach(AppIcon.allCases) { choice in
                    let chosen = choice == icon.current
                    Button { icon.choose(choice) } label: {
                        VStack(spacing: 4) {
                            Group {
                                if let picture = DockIcon.picture(choice) {
                                    Image(nsImage: picture).resizable()
                                }
                            }
                            .frame(width: Self.picture, height: Self.picture)
                            // Around the icon's square, which macOS draws at
                            // 824 of 1,024 points with the shadow under it.
                            .overlay {
                                Ring(gap: 3, width: 2.5)
                                    .fill(chosen ? Color.accentColor : .clear)
                                    .frame(width: Self.square, height: Self.square)
                            }
                            Text(choice.title)
                                .font(.caption)
                                .foregroundStyle(chosen ? .primary : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.title)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("App Icon")
                .settingsMark(.appIcon)
        } footer: {
            // As Settings' notes are (SettingsView.swift's Note).
            Text("Finder and Spotlight keep showing eGlu's own icon.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let picture: CGFloat = 72
    private static let square = picture * 824 / 1024
}

/// The chosen icon's ring: a band `gap` out from the icon's square and `width`
/// wide, the same distance from the square all round, its corners too.
private struct Ring: Shape {
    let gap: CGFloat
    let width: CGFloat

    func path(in square: CGRect) -> Path {
        // macOS's icon square, as Icon Composer and macOS 27 draw it: continuous
        // corners of 0.26 of its side (measured on their pictures).
        let shape = RoundedRectangle(cornerRadius: square.width * 0.26, style: .continuous).path(in: square).cgPath
        // What lies within a distance of the square's edge, on either side of it.
        func within(_ distance: CGFloat) -> CGPath {
            shape.copy(strokingWithWidth: distance * 2, lineCap: .butt, lineJoin: .round, miterLimit: 10)
        }
        return Path(within(gap + width).subtracting(within(gap)).subtracting(shape))
    }
}
