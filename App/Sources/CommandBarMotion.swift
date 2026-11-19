import SwiftUI
import UIKit

/// Touch can introduce the palette gently; a keyboard command must be ready
/// at once. Keep the input source for the whole synchronous command, including
/// a command that closes the old field and opens another one.
@MainActor
final class CommandBarMotion {
    private(set) var shown = false
    private var keyboard = false
    private let reducesMotion: () -> Bool

    init(reducesMotion: @escaping () -> Bool = { UIAccessibility.isReduceMotionEnabled }) {
        self.reducesMotion = reducesMotion
    }

    private var instant: Bool { keyboard || reducesMotion() }

    func change(usingKeyboard: Bool = false, _ changes: () -> Void) {
        let previous = keyboard
        keyboard = keyboard || usingKeyboard
        defer { keyboard = previous }
        guard instant else { changes(); return }
        // The hosting view and SwiftUI's field/rows belong to one transaction:
        // removing only the initial transform still leaves a UIKit fade.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { UIView.performWithoutAnimation(changes) }
    }

    func setShown(_ shows: Bool, in bar: UIView) {
        let changed = shown != shows
        shown = shows
        // A keyboard command during a touch spring must finish that spring,
        // even when the palette was already logically open.
        if instant {
            bar.layer.removeAllAnimations()
            UIView.performWithoutAnimation {
                bar.alpha = shows ? 1 : 0
                bar.transform = .identity
                bar.isHidden = !shows
                bar.isUserInteractionEnabled = shows
            }
            return
        }
        guard changed else { return }
        bar.isUserInteractionEnabled = shows
        if shows {
            if bar.isHidden {
                bar.isHidden = false
                bar.alpha = 0
                bar.transform = CGAffineTransform(translationX: 0, y: -8).scaledBy(x: 0.97, y: 0.97)
            }
            UIView.animate(springDuration: 0.28, bounce: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                bar.alpha = 1
                bar.transform = .identity
            }
        } else {
            UIView.animate(withDuration: 0.14, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                bar.alpha = 0
            } completion: { [weak self] _ in
                // An interrupted dismissal must not hide a freshly reopened bar.
                if self?.shown == false { bar.isHidden = true }
            }
        }
    }
}
