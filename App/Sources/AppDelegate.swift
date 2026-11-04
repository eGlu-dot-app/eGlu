import Combine
import OSLog
import PadCore
import SwiftUI
import UIKit
import WritingServiceKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        #if DEBUG
        // Proves the engines link (task 01 wires them in; nothing calls them
        // yet). Off the main thread: rules() builds Harper's whole rule set,
        // which launch need not wait for.
        Task.detached(priority: .utility) {
            Logger(subsystem: "net.taehee.safience", category: "engines")
                .log("engines linked: \((try? WritingChecker.engine.rules().count) ?? -1) grammar rules")
        }
        #endif
        Session.shared.start()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    /// The menus, without the system's own (see Menus.swift).
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        Menus.build(builder)
    }
}

/// One window: Stage Manager can show several side by side, each its own
/// scene with its own space and tab (WindowState), each restored as it was.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private var browser: Browser?
    private var workspaceWatch: AnyCancellable?
    private var initialState: WindowState?
    private var pendingURL: URL?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let asked = connectionOptions.userActivities.first { $0.activityType == WindowState.activityType }
        initialState = WindowState(activity: asked ?? session.stateRestorationActivity)
        let window = UIWindow(windowScene: scene)
        self.window = window
        if let url = connectionOptions.urlContexts.first?.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            pendingURL = url
        }
        showWorkspace()
        window.makeKeyAndVisible()
        workspaceWatch = Session.shared.$workspaceProblem
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showWorkspace() }
        NotificationCenter.default.addObserver(self, selector: #selector(becameKey(_:)),
                                               name: UIWindow.didBecomeKeyNotification, object: window)
    }

    private func showWorkspace() {
        guard let window else { return }
        guard Session.shared.canUseWorkspace else {
            window.rootViewController = UIHostingController(rootView: WorkspaceRecoveryView())
            return
        }
        guard browser == nil else { return }
        let browser = Browser(state: initialState ?? WindowState(activity: nil))
        self.browser = browser
        window.rootViewController = BrowserNavigation(browser: browser)
        if let pendingURL {
            self.pendingURL = nil
            browser.openLink(pendingURL)
        }
    }

    /// The keys go to the page whenever its window becomes the one you use:
    /// switching apps, clicking another Stage Manager window, closing a sheet.
    func sceneDidBecomeActive(_ scene: UIScene) {
        browser?.resumeWelcomeIfNeeded()
        browser?.askAboutWritingIfNeeded()
        browser?.focusPage()
    }

    @objc private func becameKey(_ notification: Notification) {
        browser?.focusPage()
    }

    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        browser?.state.activity
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        workspaceWatch?.cancel()
        workspaceWatch = nil
        browser?.disconnect()
        NotificationCenter.default.removeObserver(self)
    }

    /// A link opened with the app, from another app or the share sheet.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        if let browser { browser.openLink(url) } else { pendingURL = url }
    }
}

/// The window's root: the Browser in a navigation controller, the one
/// container whose bars the system stands in the iPhone Duo's vertical bar
/// beside the status bar (Docs/iPhoneDuoDesign.md §3). Both bars are hidden
/// unless the window has that strip; what the window shows of the system
/// (the status bar's style, the home indicator, the edges' gestures) stays
/// the Browser's to say.
final class BrowserNavigation: UINavigationController {
    init(browser: Browser) {
        super.init(rootViewController: browser)
        setNavigationBarHidden(true, animated: false)
        setToolbarHidden(true, animated: false)
        // The strip's tools in the ink the phone bar's are in.
        navigationBar.tintColor = Palette.UI.ink
        toolbar.tintColor = Palette.UI.ink
        // One page in it, never a stack to go back through.
        interactivePopGestureRecognizer?.isEnabled = false
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var childForStatusBarStyle: UIViewController? { topViewController }
    override var childForStatusBarHidden: UIViewController? { topViewController }
    override var childForHomeIndicatorAutoHidden: UIViewController? { topViewController }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { topViewController }
}
