import PadCore
import UIKit
import WebKit

/// A window a page opened at a size of its own: a sign-in with Google, a
/// single sign-on, a share dialog. It opens over the page as a sheet, with
/// its address always in view (it is almost always a sign-in), and closes
/// by itself when the page closes it, handing its answer back to the page
/// that opened it.
@MainActor
final class Popup: UIViewController, PageHost {
    let page: Page
    /// Called once the pop-up is gone, to give the keys back to the page.
    var closed: (() -> Void)?
    private let lock = UIImageView()
    private let address = UILabel()
    private let status = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let recovery = UIButton(type: .system)
    private let statusBox = UIStackView()
    private var announced: String?

    init(opener: Page, configuration: WKWebViewConfiguration) {
        page = Page(tab: UUID(), space: opener.space, configuration: configuration, keyboardByWindow: false)
        super.init(nibName: nil, bundle: nil)
        page.host = self
        modalPresentationStyle = .formSheet
        preferredContentSize = CGSize(width: 520, height: 680)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.UI.ground

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = Palette.UI.muted
        close.accessibilityLabel = String(localized: "Close")
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)

        lock.contentMode = .scaleAspectFit
        lock.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11)
        lock.isAccessibilityElement = true
        address.font = .preferredFont(forTextStyle: .footnote)
        address.adjustsFontForContentSizeCategory = true
        address.textColor = Palette.UI.ink
        address.lineBreakMode = .byTruncatingMiddle

        let header = UIStackView(arrangedSubviews: [lock, address, close])
        header.spacing = 8
        header.alignment = .center
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 8)
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let line = UIView()
        line.backgroundColor = Palette.UI.hairline

        status.font = .preferredFont(forTextStyle: .footnote)
        status.adjustsFontForContentSizeCategory = true
        status.numberOfLines = 0
        status.textColor = Palette.UI.ink
        recovery.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if page.googleRefused, page.view.canGoBack { page.view.goBack() } else { page.reload() }
        }, for: .primaryActionTriggered)
        recovery.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        statusBox.axis = .vertical
        statusBox.spacing = 4
        statusBox.isLayoutMarginsRelativeArrangement = true
        statusBox.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        [status, progress, recovery].forEach(statusBox.addArrangedSubview)
        let content = UIStackView(arrangedSubviews: [header, line, statusBox, page.view])
        content.axis = .vertical
        for part in [content] as [UIView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(part)
        }
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: safe.topAnchor),
            content.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.bar),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        pageDidChange(page)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        _ = page.view.becomeFirstResponder()
        page.reviewPendingDialog()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        page.tearDown()
        closed?()
        closed = nil
    }

    func pageDidChange(_ page: Page) {
        guard isViewLoaded else { return }
        let url = page.displayURL
        address.text = url.map(Destination.pretty) ?? String(localized: "Loading…")
        address.accessibilityLabel = url?.absoluteString ?? String(localized: "Loading page")
        let secure = url?.scheme == "https" && page.view.hasOnlySecureContent && page.failure == nil
        lock.image = UIImage(systemName: secure ? "lock.fill" : "exclamationmark.triangle")
        lock.tintColor = secure ? Palette.UI.safe : Palette.UI.unsafe
        lock.accessibilityLabel = secure ? String(localized: "Secure connection") : String(localized: "Connection is not verified as secure")
        lock.isHidden = url == nil
        let problem = page.googleRefused ? SignIn.fallback : page.failure
            ?? (page.exhausted ? String(localized: "This page stopped after repeated memory problems. Close another tab, then reload.") : nil)
        status.text = problem ?? (page.view.isLoading ? String(localized: "Loading page…") : nil)
        statusBox.isHidden = status.text == nil
        progress.isHidden = !page.view.isLoading || problem != nil
        progress.progress = Float(page.view.estimatedProgress)
        recovery.isHidden = problem == nil
        recovery.setTitle(page.googleRefused && page.view.canGoBack ? String(localized: "Go Back") : String(localized: "Reload"), for: .normal)
        if let problem, problem != announced {
            announced = problem
            UIAccessibility.post(notification: .announcement, argument: problem)
        } else if problem == nil { announced = nil }

    }

    func isShowing(_ page: Page) -> Bool {
        page === self.page && view.window != nil
    }

    /// A window opened from the pop-up opens in the pop-up.
    func page(_ page: Page, open configuration: WKWebViewConfiguration, for action: WKNavigationAction,
              features: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { page.load(url) }
        return nil
    }

    /// A pop-up has no tabs: a ⌘-click goes there in the pop-up.
    func page(_ page: Page, openInNewTab url: URL, inFront: Bool) -> Bool {
        false
    }

    var opensTabs: Bool {
        false
    }

    func page(_ page: Page, share url: URL) {
        let sheet = UIActivityViewController(activityItems: [Tracking.clean(url)], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(sheet, animated: true)
    }

    func pageDidClose(_ page: Page) {
        dismiss(animated: true)
    }

    var presenter: UIViewController? {
        self
    }
}
