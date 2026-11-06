import Foundation
import WebKit

extension PageHistory {
    /// A main-frame navigation WebKit is about to make. A redirect, or a
    /// request sent again (with another user agent, or the screen's light
    /// or dark), comes back here as `.other`, and keeps what the first said.
    // Kept for the iOS app while the Mac supplies the contract's kind.
    mutating func decided(_ type: WKNavigationType, url: URL?) {
        let kind: NavigationKind
        switch type {
        case .linkActivated: kind = .link
        case .formSubmitted: kind = .form
        case .formResubmitted: kind = .formResubmission
        case .backForward: kind = .history
        case .reload: kind = .reload
        case .other: kind = .other
        @unknown default: kind = .unknown(type.rawValue)
        }
        decided(kind, url: url)
    }
}
