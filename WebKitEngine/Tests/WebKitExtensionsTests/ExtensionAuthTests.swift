#if os(macOS)
import AppKit
import WebKit
import XCTest
@testable import WebKitExtensions

private struct AuthFailure: LocalizedError {
    let why: String
    var errorDescription: String? { why }
}

/// Records requests without loading a page, using a store that keeps nothing.
@MainActor
private final class AuthPageView: WKWebView {
    var loads: [URLRequest] = []
    var stops = 0
    var address: URL?
    var onStop: (() -> Void)?
    override var url: URL? { address }
    override func load(_ request: URLRequest) -> WKNavigation? { loads.append(request); return nil }
    override func stopLoading() { onStop?(); stops += 1 }
}

/// Objective-C delegate inputs, with only the getters the flow reads.
/// No WebKit frame, origin, navigation or response needs a live page.
private final class AuthFrame: NSObject {
    @objc let isMainFrame: Bool
    init(_ main: Bool) { isMainFrame = main }
}

private final class AuthAction: NSObject {
    @objc let request: URLRequest
    @objc let targetFrame: AuthFrame?
    @objc let shouldPerformDownload: Bool
    init(_ url: URL?, main: Bool? = true, download: Bool = false) {
        var request = URLRequest(url: URL(string: "https://fixture.invalid/")!)
        request.url = url
        self.request = request
        targetFrame = main.map(AuthFrame.init)
        shouldPerformDownload = download
    }
}

private final class AuthResponse: NSObject {
    @objc let canShowMIMEType: Bool
    init(_ canShow: Bool) { canShowMIMEType = canShow }
}

private final class AuthChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

final class ExtensionAuthTests: XCTestCase {
    private typealias Quiet = WebKitExtensionAuth.Quiet

    @MainActor
    private func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.applicationNameForUserAgent = "Auth fixture"
        config.mediaTypesRequiringUserActionForPlayback = .audio
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        return config
    }

    @MainActor
    private func start(abortOnLoad: Bool = false, limit: TimeInterval = 60,
                       finish: @escaping (Result<URL, Error>) -> Void) -> (Quiet, AuthPageView) {
        let flow = Quiet(extensionID: "FiXtUrE", abortOnLoad: abortOnLoad,
                         unanswered: { AuthFailure(why: $0) }, finish: finish)
        let config = configuration()
        var web: AuthPageView!
        flow.start(URL(string: "https://provider.invalid/signin")!, configuration: { config }, limit: limit,
                   makeView: { frame, config in
            web = AuthPageView(frame: frame, configuration: config)
            return web
        })
        return (flow, web)
    }

    /// Call the real Objective-C delegate entry. Unused origin, frame and
    /// panel arguments may be nil here because refusals never read them.
    @MainActor
    private func entry<T>(_ flow: Quiet, _ name: String, _ type: T.Type) throws -> T {
        let selector = NSSelectorFromString(name)
        XCTAssertTrue(flow.responds(to: selector), name)
        return unsafeBitCast(try XCTUnwrap(flow.method(for: selector)), to: T.self)
    }

    @MainActor
    private func policy(_ flow: Quiet, _ web: AuthPageView, _ address: String?, main: Bool? = true,
                        download: Bool = false) throws -> WKNavigationActionPolicy {
        typealias Decide = @convention(c) (AnyObject, Selector, WKWebView, AnyObject, @convention(block) (Int) -> Void) -> Void
        let name = "webView:decidePolicyForNavigationAction:decisionHandler:"
        let call = try entry(flow, name, Decide.self)
        var answers: [Int] = []
        call(flow, NSSelectorFromString(name), web, AuthAction(address.flatMap(URL.init(string:)), main: main, download: download),
             { answers.append($0) })
        XCTAssertEqual(answers.count, 1)
        return try XCTUnwrap(answers.first.flatMap(WKNavigationActionPolicy.init(rawValue:)))
    }

    @MainActor
    func testAddressChecksKeepTheirExactRules() {
        let cases: [(String, String?, Bool, Bool)] = [
            ("https://fixture.chromiumapp.org/answer?q=1#x", "fixture", true, true),
            ("HTTPS://FiXtUrE.ChRoMiUmApP.OrG/", "fixture", true, true),
            ("https://fixture.chromiumapp.org:8443/", "fixture", true, true),
            ("https://user:fixture@fixture.chromiumapp.org:443/", "fixture", true, true),
            ("https://user@other.invalid/fixture.chromiumapp.org", nil, false, true),
            ("https://fixture.chromiumapp.org@other.invalid/", nil, false, true),
            ("https://chromiumapp.org/", nil, true, true),
            ("https://.chromiumapp.org/", nil, true, true),
            ("https://one.two.chromiumapp.org/", nil, true, true),
            ("https://fixture.chromiumapp.org./", nil, true, true),
            ("https://fixture.chromiumapp.org../", nil, false, true),
            ("http://fixture.chromiumapp.org/", nil, true, false),
            ("custom://fixture.chromiumapp.org/", nil, true, false),
            ("https://fakechromiumapp.org/", nil, false, true),
            ("https://fixture.chromiumapp.org.other.invalid/", nil, false, true),
            ("http://localhost/", nil, false, true),
            ("HTTP://LOCALHOST:8080/", nil, false, true),
            ("http://user:fixture@localhost:8080/", nil, false, true),
            ("http://127.0.0.1:1234/", nil, false, true),
            ("http://[::1]:8080/", nil, false, true),
            ("http://localhost./", nil, false, false),
            ("http://sub.localhost/", nil, false, false),
            ("http://localhost.other.invalid/", nil, false, false),
            ("http://127.0.0.2/", nil, false, false),
            ("http://127.1/", nil, false, false),
            ("http://2130706433/", nil, false, false),
            ("http://[0:0:0:0:0:0:0:1]/", nil, false, false),
            ("http://[::ffff:127.0.0.1]/", nil, false, false),
            ("https:relative", nil, false, true),
            ("http:relative", nil, false, false),
            ("file:///tmp/fixture", nil, false, false),
            ("about:blank", nil, false, false),
            ("data:text/plain,fixture", nil, false, false),
            ("blob:https://fixture.invalid/id", nil, false, false),
            ("//fixture.chromiumapp.org/path", nil, true, false)
        ]
        for (address, owner, chromiumapp, secure) in cases {
            let url = URL(string: address)
            XCTAssertNotNil(url, address)
            XCTAssertEqual(WebKitExtensionAuth.owner(of: url), owner, address)
            XCTAssertEqual(WebKitExtensionAuth.chromiumapp(url), chromiumapp, address)
            XCTAssertEqual(WebKitExtensionAuth.secure(url), secure, address)
        }
        XCTAssertNil(WebKitExtensionAuth.owner(of: nil))
        XCTAssertFalse(WebKitExtensionAuth.chromiumapp(nil))
        XCTAssertFalse(WebKitExtensionAuth.secure(nil))
    }

    @MainActor
    func testConfigurationChangesAndEndOnceBeforeFinishing() async throws {
        let config = configuration()
        let controllerConfig = WKWebExtensionController.Configuration.nonPersistent()
        controllerConfig.defaultWebsiteDataStore = config.websiteDataStore
        let controller = WKWebExtensionController(configuration: controllerConfig)
        config.webExtensionController = controller
        let store = config.websiteDataStore
        let scripts = config.userContentController
        let preferences = config.preferences
        var events: [String] = []
        var results: [Result<URL, Error>] = []
        var web: AuthPageView!
        var flow: Quiet? = Quiet(extensionID: "FiXtUrE", abortOnLoad: false,
                                 unanswered: { AuthFailure(why: $0) }) { result in
            XCTAssertNil(web.navigationDelegate)
            XCTAssertNil(web.uiDelegate)
            XCTAssertEqual(web.stops, 1)
            events.append("finish")
            results.append(result)
        }
        weak let lifetime = flow
        flow?.start(URL(string: "https://provider.invalid/")!, configuration: {
            events.append("configuration")
            XCTAssertTrue(config.webExtensionController === controller)
            XCTAssertEqual(config.mediaTypesRequiringUserActionForPlayback, .audio)
            return config
        }, limit: 60, makeView: { frame, supplied in
            events.append("view")
            XCTAssertTrue(supplied === config)
            XCTAssertNil(supplied.webExtensionController)
            XCTAssertEqual(supplied.mediaTypesRequiringUserActionForPlayback, .all)
            web = AuthPageView(frame: frame, configuration: supplied)
            return web
        })
        XCTAssertEqual(events, ["configuration", "view"])
        XCTAssertEqual(web.loads.map(\.url), [URL(string: "https://provider.invalid/")!])
        XCTAssertNil(web.window)
        XCTAssertEqual(web.frame, CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertFalse(web.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(web.configuration.websiteDataStore === store)
        XCTAssertTrue(web.configuration.userContentController === scripts)
        XCTAssertEqual(scripts.userScripts.count, 0)
        XCTAssertTrue(config.preferences === preferences)
        XCTAssertFalse(web.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertEqual(web.configuration.applicationNameForUserAgent, "Auth fixture")
        XCTAssertNil(web.configuration.webExtensionController)
        XCTAssertTrue(web.navigationDelegate === flow)
        XCTAssertTrue(web.uiDelegate === flow)
        web.onStop = {
            XCTAssertNil(web.navigationDelegate)
            XCTAssertNil(web.uiDelegate)
            events.append("stop")
            // A synchronous callback during cleanup cannot finish twice.
            flow?.webViewWebContentProcessDidTerminate(web)
        }
        let answer = URL(string: "https://fixture.chromiumapp.org/answer")!
        flow?.end(.success(answer))
        flow?.end(.failure(AuthFailure(why: "second")))
        XCTAssertEqual(events, ["configuration", "view", "stop", "finish"])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try results.first?.get(), answer)
        web.onStop = nil
        flow = nil
        let drained = expectation(description: "Delegate references released")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertNil(lifetime)
    }

    @MainActor
    func testOnlyAnOwnMainFrameAnswerFinishesSuccessfully() throws {
        var results: [Result<URL, Error>] = []
        let (flow, web) = start { results.append($0) }
        defer { flow.end(.failure(AuthFailure(why: "cleanup"))) }
        XCTAssertEqual(try policy(flow, web, "https://other.chromiumapp.org/answer", main: false), .cancel)
        XCTAssertEqual(try policy(flow, web, "https://fixture.chromiumapp.org/answer", main: false), .cancel)
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(web.stops, 0)
        let answer = "https://FiXtUrE.chromiumapp.org:8443/answer?q=1#x"
        XCTAssertEqual(try policy(flow, web, answer), .cancel)
        XCTAssertEqual(try results.first?.get().absoluteString, answer)
        flow.webView(web, didFinish: nil)
        flow.end(.failure(AuthFailure(why: "second")))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(web.stops, 1)
    }

    @MainActor
    func testNavigationRefusalsPreserveMainFrameAndSubframeExceptions() throws {
        for address in ["https://other.chromiumapp.org/answer", "http://fixture.chromiumapp.org/answer",
                        "https://fixture.chromiumapp.org./answer", "http://site.invalid/", "file:///tmp/fixture",
                        "custom://site.invalid/", "about:blank", "data:text/html,fixture", "blob:https://site.invalid/id"] {
            var results: [Result<URL, Error>] = []
            let (flow, web) = start { results.append($0) }
            XCTAssertEqual(try policy(flow, web, address), .cancel, address)
            XCTAssertEqual(results.count, 1, address)
            XCTAssertThrowsError(try results.first?.get()) { error in
                XCTAssertTrue(error is AuthFailure)
                XCTAssertEqual(error.localizedDescription, "Authorization page could not be loaded.")
            }
            XCTAssertEqual(web.stops, 1)
        }
        var results: [Result<URL, Error>] = []
        let (flow, web) = start { results.append($0) }
        defer { flow.end(.failure(AuthFailure(why: "cleanup"))) }
        for address in ["https://site.invalid/", "http://localhost:8080/", "http://127.0.0.1/", "http://[::1]/"] {
            XCTAssertEqual(try policy(flow, web, address), .allow, address)
        }
        for address in ["http://site.invalid/", "https://site.invalid/", "about:blank", "data:text/html,fixture", "blob:https://site.invalid/id"] {
            XCTAssertEqual(try policy(flow, web, address, main: false), .allow, address)
        }
        for address in [nil, "file:///tmp/fixture", "custom://site.invalid/", "https://other.chromiumapp.org/"] as [String?] {
            XCTAssertEqual(try policy(flow, web, address, main: false), .cancel)
        }
        XCTAssertEqual(try policy(flow, web, "https://site.invalid/", main: nil), .cancel)
        XCTAssertEqual(try policy(flow, web, "https://site.invalid/", download: true), .cancel)
        XCTAssertEqual(try policy(flow, web, "https://site.invalid/", main: false, download: true), .cancel)
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(web.loads.count, 1)
    }

    @MainActor
    func testResponsesRedirectsAndAuthenticationChallenges() throws {
        var results: [Result<URL, Error>] = []
        let (flow, web) = start { results.append($0) }
        defer { flow.end(.failure(AuthFailure(why: "cleanup"))) }
        typealias Response = @convention(c) (AnyObject, Selector, WKWebView, AnyObject, @convention(block) (Int) -> Void) -> Void
        let name = "webView:decidePolicyForNavigationResponse:decisionHandler:"
        let respond = try entry(flow, name, Response.self)
        for canShow in [false, true] {
            var answers: [Int] = []
            respond(flow, NSSelectorFromString(name), web, AuthResponse(canShow), { answers.append($0) })
            XCTAssertEqual(answers, [(canShow ? WKNavigationResponsePolicy.allow : .cancel).rawValue])
        }
        for method in [NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodHTTPBasic,
                       NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodClientCertificate] {
            let protection = URLProtectionSpace(host: "provider.invalid", port: 443, protocol: "https", realm: nil, authenticationMethod: method)
            let challenge = URLAuthenticationChallenge(protectionSpace: protection, proposedCredential: nil,
                                                        previousFailureCount: 0, failureResponse: nil, error: nil,
                                                        sender: AuthChallengeSender())
            var answers = 0
            flow.webView(web, didReceive: challenge) { disposition, credential in
                answers += 1
                XCTAssertEqual(disposition, method == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .rejectProtectionSpace)
                XCTAssertNil(credential)
            }
            XCTAssertEqual(answers, 1)
        }
        web.address = URL(string: "https://provider.invalid/redirect")!
        flow.webView(web, didReceiveServerRedirectForProvisionalNavigation: nil)
        XCTAssertTrue(results.isEmpty)
        web.address = URL(string: "https://fixture.chromiumapp.org/answer")!
        flow.webView(web, didReceiveServerRedirectForProvisionalNavigation: nil)
        XCTAssertEqual(try results.first?.get(), web.address)
        // end stops the view, then the redirect callback stops it again.
        XCTAssertEqual(web.stops, 2)
        for address in [nil, "https://other.chromiumapp.org/", "http://provider.invalid/"] as [String?] {
            var failure: Error?
            let (other, view) = start { if case .failure(let error) = $0 { failure = error } }
            view.address = address.flatMap(URL.init(string:))
            other.webView(view, didReceiveServerRedirectForProvisionalNavigation: nil)
            XCTAssertEqual(failure?.localizedDescription, "Authorization page could not be loaded.")
            XCTAssertEqual(view.stops, 2)
        }
    }

    @MainActor
    func testEveryQuestionAndNewWindowIsRefusedInline() throws {
        let (flow, web) = start { _ in }
        defer { flow.end(.failure(AuthFailure(why: "cleanup"))) }
        typealias Window = @convention(c) (AnyObject, Selector, WKWebView, AnyObject?, AnyObject?, AnyObject?) -> AnyObject?
        let windowName = "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:"
        let window = try entry(flow, windowName, Window.self)
        XCTAssertNil(window(flow, NSSelectorFromString(windowName), web, nil, nil, nil))

        typealias Alert = @convention(c) (AnyObject, Selector, WKWebView, NSString, AnyObject?, @convention(block) () -> Void) -> Void
        let alertName = "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:"
        var alerts = 0
        try entry(flow, alertName, Alert.self)(flow, NSSelectorFromString(alertName), web, "fixture", nil, { alerts += 1 })
        XCTAssertEqual(alerts, 1)

        typealias Confirm = @convention(c) (AnyObject, Selector, WKWebView, NSString, AnyObject?, @convention(block) (Bool) -> Void) -> Void
        let confirmName = "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:"
        var confirmations: [Bool] = []
        try entry(flow, confirmName, Confirm.self)(flow, NSSelectorFromString(confirmName), web, "fixture", nil, { confirmations.append($0) })
        XCTAssertEqual(confirmations, [false])

        typealias Prompt = @convention(c) (AnyObject, Selector, WKWebView, NSString, NSString?, AnyObject?, @convention(block) (NSString?) -> Void) -> Void
        let promptName = "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:"
        var prompts = 0
        try entry(flow, promptName, Prompt.self)(flow, NSSelectorFromString(promptName), web, "fixture", nil, nil, {
            prompts += 1; XCTAssertNil($0)
        })
        XCTAssertEqual(prompts, 1)

        typealias Picker = @convention(c) (AnyObject, Selector, WKWebView, AnyObject?, AnyObject?, @convention(block) (NSArray?) -> Void) -> Void
        let pickerName = "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:"
        var pickers = 0
        try entry(flow, pickerName, Picker.self)(flow, NSSelectorFromString(pickerName), web, nil, nil, {
            pickers += 1; XCTAssertNil($0)
        })
        XCTAssertEqual(pickers, 1)

        typealias Media = @convention(c) (AnyObject, Selector, WKWebView, AnyObject?, AnyObject?, Int, @convention(block) (Int) -> Void) -> Void
        let mediaName = "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:"
        for type in [WKMediaCaptureType.camera, .microphone, .cameraAndMicrophone] {
            var answers: [Int] = []
            try entry(flow, mediaName, Media.self)(flow, NSSelectorFromString(mediaName), web, nil, nil, type.rawValue, { answers.append($0) })
            XCTAssertEqual(answers, [WKPermissionDecision.deny.rawValue])
        }

        typealias Screen = @convention(c) (AnyObject, Selector, WKWebView, AnyObject?, AnyObject?, Bool, @convention(block) (Int) -> Void) -> Void
        let screenName = "_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:"
        for systemAudio in [false, true] {
            var answers: [Int] = []
            try entry(flow, screenName, Screen.self)(flow, NSSelectorFromString(screenName), web, nil, nil, systemAudio, { answers.append($0) })
            XCTAssertEqual(answers, [0])
        }

        typealias Location = @convention(c) (AnyObject, Selector, WKWebView, AnyObject?, AnyObject?, @convention(block) (Int) -> Void) -> Void
        let locationName = "_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:"
        var locations: [Int] = []
        try entry(flow, locationName, Location.self)(flow, NSSelectorFromString(locationName), web, nil, nil, { locations.append($0) })
        XCTAssertEqual(locations, [WKPermissionDecision.deny.rawValue])

        typealias Notifications = @convention(c) (AnyObject, Selector, WKWebView, AnyObject?, @convention(block) (Bool) -> Void) -> Void
        let notificationName = "_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:"
        var notifications: [Bool] = []
        try entry(flow, notificationName, Notifications.self)(flow, NSSelectorFromString(notificationName), web, nil, { notifications.append($0) })
        XCTAssertEqual(notifications, [false])
        XCTAssertNil(web.window)
        XCTAssertEqual(web.loads.count, 1)
        XCTAssertEqual(web.stops, 0)
    }

    @MainActor
    func testLoadFailureAbortAndProcessExitKeepTheirErrorsAndFinishOnce() {
        for abort in [false, true] {
            var results: [Result<URL, Error>] = []
            let (flow, web) = start(abortOnLoad: abort) { results.append($0) }
            for error in [NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), NSError(domain: "WebKitErrorDomain", code: 102)] {
                flow.webView(web, didFailProvisionalNavigation: nil, withError: error)
                flow.webView(web, didFail: nil, withError: error)
            }
            XCTAssertTrue(results.isEmpty)
            flow.webView(web, didFinish: nil)
            XCTAssertEqual(results.count, abort ? 1 : 0)
            if abort {
                XCTAssertThrowsError(try results.first?.get()) { XCTAssertEqual($0.localizedDescription, "User interaction required.") }
            }
            flow.webViewWebContentProcessDidTerminate(web)
            XCTAssertEqual(results.count, 1)
            XCTAssertThrowsError(try results.first?.get()) {
                XCTAssertEqual($0.localizedDescription, abort ? "User interaction required." : "Authorization page could not be loaded.")
            }
            XCTAssertEqual(web.stops, 1)
        }
        for provisional in [false, true] {
            var results: [Result<URL, Error>] = []
            let (flow, web) = start { results.append($0) }
            let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
            if provisional { flow.webView(web, didFailProvisionalNavigation: nil, withError: error) }
            else { flow.webView(web, didFail: nil, withError: error) }
            XCTAssertEqual(results.count, 1)
            XCTAssertThrowsError(try results.first?.get()) { XCTAssertEqual($0.localizedDescription, "Authorization page could not be loaded.") }
            XCTAssertEqual(web.stops, 1)
        }
    }

    @MainActor
    func testTimerEndsOnceWithTheOriginalErrorAndReleasesTheView() async throws {
        let finished = expectation(description: "The real timer finishes")
        var results: [Result<URL, Error>] = []
        let (flow, web) = start(limit: 0.01) { results.append($0); finished.fulfill() }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertThrowsError(try results.first?.get()) {
            XCTAssertTrue($0 is AuthFailure)
            XCTAssertEqual($0.localizedDescription, "User interaction required.")
        }
        // The flow lets go of its view when it ends.
        XCTAssertNil(flow.view)
        flow.webViewWebContentProcessDidTerminate(web)
        flow.end(.success(URL(string: "https://fixture.chromiumapp.org/late")!))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(web.stops, 1)
        XCTAssertNil(web.navigationDelegate)
        XCTAssertNil(web.uiDelegate)
    }

    @MainActor
    func testQuietlyRefusesAnInsecureURLBeforeConfigurationOrViewCreation() async {
        do {
            _ = try await WebKitExtensionAuth.quietly(URL(string: "http://provider.invalid/")!, extension: "fixture", in: UUID(),
                                                      abortOnLoad: false, timeout: nil, configuration: {
                XCTFail("An insecure URL must not ask for a configuration")
                return self.configuration()
            }, unanswered: { AuthFailure(why: $0) }, makeView: { frame, config in
                XCTFail("An insecure URL must not make a view")
                return AuthPageView(frame: frame, configuration: config)
            })
            XCTFail("The URL was accepted")
        } catch {
            XCTAssertTrue(error is AuthFailure)
            XCTAssertEqual(error.localizedDescription, "Authorization page could not be loaded.")
        }
    }

    @MainActor
    func testQuietlySupersedesOnlyTheSameExtensionAndSpaceBeforeGettingConfiguration() async throws {
        let space = UUID()
        let loaded = expectation(description: "First flow made")
        var firstView: AuthPageView!
        let first = Task { @MainActor in
            try await WebKitExtensionAuth.quietly(URL(string: "https://provider.invalid/first")!, extension: "FiXtUrE", in: space,
                                                  abortOnLoad: false, timeout: nil, configuration: { self.configuration() },
                                                  unanswered: { AuthFailure(why: $0) }, makeView: { frame, config in
                firstView = AuthPageView(frame: frame, configuration: config)
                loaded.fulfill()
                return firstView
            })
        }
        await fulfillment(of: [loaded], timeout: 5)
        weak let firstLifetime = firstView.navigationDelegate as? Quiet
        defer { firstLifetime?.end(.failure(AuthFailure(why: "cleanup"))) }

        // Rejection precedes supersession, too.
        do {
            _ = try await WebKitExtensionAuth.quietly(URL(string: "http://provider.invalid/")!, extension: "fixture", in: space,
                                                      abortOnLoad: false, timeout: nil, configuration: {
                XCTFail("An invalid replacement must not get a configuration")
                return self.configuration()
            }, unanswered: { AuthFailure(why: $0) })
            XCTFail("An invalid replacement was accepted")
        } catch { XCTAssertEqual(error.localizedDescription, "Authorization page could not be loaded.") }
        XCTAssertNotNil(firstLifetime)
        XCTAssertEqual(firstView.stops, 0)

        var independent: [(Task<URL, Error>, AuthPageView)] = []
        for (id, otherSpace) in [("other", space), ("fixture", UUID())] {
            let made = expectation(description: "Independent flow made")
            var view: AuthPageView!
            let task = Task { @MainActor in
                try await WebKitExtensionAuth.quietly(URL(string: "https://provider.invalid/independent")!, extension: id, in: otherSpace,
                                                      abortOnLoad: false, timeout: nil, configuration: { self.configuration() },
                                                      unanswered: { AuthFailure(why: $0) }, makeView: { frame, config in
                    view = AuthPageView(frame: frame, configuration: config)
                    made.fulfill()
                    return view
                })
            }
            await fulfillment(of: [made], timeout: 5)
            independent.append((task, try XCTUnwrap(view)))
        }
        defer {
            for (_, view) in independent { (view.navigationDelegate as? Quiet)?.end(.failure(AuthFailure(why: "cleanup"))) }
        }
        XCTAssertEqual(firstView.stops, 0)

        let replacementMade = expectation(description: "Replacement made")
        var replacementView: AuthPageView!
        var configurationReads = 0
        let replacement = Task { @MainActor in
            try await WebKitExtensionAuth.quietly(URL(string: "https://provider.invalid/replacement")!, extension: "fixture", in: space,
                                                  abortOnLoad: false, timeout: 60, configuration: {
                configurationReads += 1
                XCTAssertNil(firstView.navigationDelegate)
                XCTAssertNil(firstView.uiDelegate)
                XCTAssertEqual(firstView.stops, 1)
                return self.configuration()
            }, unanswered: { AuthFailure(why: $0) }, makeView: { frame, config in
                replacementView = AuthPageView(frame: frame, configuration: config)
                replacementMade.fulfill()
                return replacementView
            })
        }
        await fulfillment(of: [replacementMade], timeout: 5)
        weak let replacementLifetime = replacementView.navigationDelegate as? Quiet
        defer { replacementLifetime?.end(.failure(AuthFailure(why: "cleanup"))) }
        do { _ = try await first.value; XCTFail("The first flow was not superseded") }
        catch {
            XCTAssertTrue(error is AuthFailure)
            XCTAssertEqual(error.localizedDescription, "User interaction required.")
        }
        XCTAssertEqual(configurationReads, 1)
        for (_, view) in independent {
            XCTAssertNotNil(view.navigationDelegate)
            XCTAssertEqual(view.stops, 0)
        }
        let answer = "https://fixture.chromiumapp.org/answer"
        XCTAssertEqual(try policy(try XCTUnwrap(replacementLifetime), replacementView, answer), .cancel)
        let result = try await replacement.value
        XCTAssertEqual(result.absoluteString, answer)
        for (task, view) in independent {
            (view.navigationDelegate as? Quiet)?.end(.failure(AuthFailure(why: "cleanup")))
            _ = await task.result
        }
        let drained = expectation(description: "Flow references released")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertNil(firstLifetime)
        XCTAssertNil(replacementLifetime)
    }

    @MainActor
    func testQuietlyClampsShortTimeoutsAndUsesTheSameTimeoutError() async throws {
        for limit in [-1.0, 0, 0.01] {
            let began = Date()
            var view: AuthPageView?
            do {
                _ = try await WebKitExtensionAuth.quietly(URL(string: "https://provider.invalid/")!, extension: "fixture", in: UUID(),
                                                          abortOnLoad: false, timeout: limit, configuration: { self.configuration() },
                                                          unanswered: { AuthFailure(why: $0) }, makeView: { frame, config in
                    let web = AuthPageView(frame: frame, configuration: config)
                    view = web
                    return web
                })
                XCTFail("The flow did not time out")
            } catch {
                XCTAssertTrue(error is AuthFailure)
                XCTAssertEqual(error.localizedDescription, "User interaction required.")
            }
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), 0.5)
            let web = try XCTUnwrap(view)
            XCTAssertNil(web.window)
            XCTAssertEqual(web.loads.count, 1)
            XCTAssertEqual(web.stops, 1)
            XCTAssertNil(web.navigationDelegate)
            XCTAssertNil(web.uiDelegate)
        }
        XCTAssertEqual(Quiet.longest, 60)
    }
}
#endif
