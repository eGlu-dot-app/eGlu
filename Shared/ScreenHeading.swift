#if os(iOS)
import SwiftUI
import UIKit

/// A real accessibility target for a new setup screen. SwiftUI's focus state
/// can lose to VoiceOver restoring the activated footer during a page swap.
/// UIKit's screen-change notification names the new element explicitly.
struct ScreenHeading: UIViewRepresentable {
    let title: String
    var progress = ""
    var style: UIFont.TextStyle = .title1

    func makeUIView(context: Context) -> Label {
        let label = Label()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.isAccessibilityElement = true
        label.accessibilityTraits = [.header, .staticText]
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: Label, context: Context) {
        let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: label.traitCollection)
        let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor
        label.attributedText = NSAttributedString(string: title, attributes: [
            .font: UIFont(descriptor: descriptor, size: 0),
            .kern: style == .title1 ? -0.4 : 0
        ])
        label.accessibilityLabel = title
        label.accessibilityValue = progress
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Label, context: Context) -> CGSize? {
        uiView.sizeThatFits(CGSize(width: proposal.width ?? 420, height: .greatestFiniteMagnitude))
    }

    final class Label: UILabel {
        private var requested = false
        private var focusTask: Task<Void, Never>?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                focusTask?.cancel()
                focusTask = nil
            }
            focusWhenReady()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            focusWhenReady()
        }

        private func focusWhenReady() {
            guard !requested, focusTask == nil, window != nil, !bounds.isEmpty else { return }
            focusTask = Task { @MainActor [weak self] in
                // The hosting view's accessibility tree and VoiceOver's button
                // activation settle after UIKit's layout. This is a one-shot
                // focus handoff, not an input delay or an editing observer.
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
                guard let self else { return }
                self.focusTask = nil
                guard !self.requested, self.window != nil, !self.bounds.isEmpty else { return }
                self.requested = true
                if UIAccessibility.isVoiceOverRunning {
                    UIAccessibility.post(notification: .screenChanged, argument: self)
                }
            }
        }
    }
}
#endif
