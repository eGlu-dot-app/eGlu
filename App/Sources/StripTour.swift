#if DEBUG
import Foundation
import os

/// A test run for the iPhone Duo's strip, in a build from Xcode on the
/// simulator (Docs/iPhoneDuoDesign.md §9): `-stripTour "<address> …"` opens
/// each address in turn in the first window's tab, waits for it, scrolls
/// down it a screen at a time, and logs under the category "strip" what
/// strip.js did with it: its state, and at each screen what can still be
/// pressed under the strip's items (leftovers()).
/// `-stripEarlyTouch YES` touches each document the moment it starts, as a
/// person does on a slow phone before the script has looked at anything:
/// it is settled from then, and only what keeps the page still is done.
@MainActor
enum StripTour {
    private static let log = Logger(subsystem: "net.taehee.safience", category: "strip")
    private static var started = false

    /// The touch put in with strip.js under -stripEarlyTouch (Page.prepare), nil without it.
    static var earlyTouch: String? {
        guard UserDefaults.standard.bool(forKey: "stripEarlyTouch") else { return nil }
        return """
            window.dispatchEvent(new TouchEvent('touchstart', { touches: [] }));
            window.dispatchEvent(new TouchEvent('touchend', { touches: [] }));
            """
    }

    static func start(in browser: Browser) {
        guard !started, let list = UserDefaults.standard.string(forKey: "stripTour") else { return }
        started = true
        let addresses = list.split(separator: " ").compactMap { URL(string: String($0)) }
        Task { @MainActor [weak browser] in
            try? await Task.sleep(for: .seconds(3))
            for (index, address) in addresses.enumerated() {
                guard let browser else { return }
                browser.open(address)
                try? await Task.sleep(for: .seconds(5))
                // A slow page is waited for, 20 seconds more at most, then given
                // the time a quick one had: the report is of the page asked for.
                var waited = 0
                while browser.page?.view.isLoading == true, waited < 40 {
                    try? await Task.sleep(for: .milliseconds(500))
                    waited += 1
                }
                if waited > 0 { try? await Task.sleep(for: .seconds(3)) }
                let report = await run(Self.report, in: browser) ?? "no page"
                // A line each: the log cuts long ones.
                for line in report.split(separator: "\n") {
                    log.info("tour \(index + 1)/\(addresses.count) \(address.absoluteString, privacy: .public): \(line, privacy: .public)")
                }
            }
            log.info("tour done")
        }
    }

    // Nothing for a page still loading. The address it is at (a redirect
    // may have taken it elsewhere), then down the page a screen at a time
    // (at most 14), what is left under the strip at each once the page has
    // been still a moment; then back up.
    private static let report = """
        if (document.readyState !== 'complete') return 'page did not finish loading';
        const strip = window.__egluStrip;
        if (!strip) return 'no strip script';
        const pause = (ms) => new Promise((done) => setTimeout(done, ms));
        const lines = [JSON.stringify({ url: location.href })];
        const seen = new Set();
        const step = Math.round(innerHeight * 0.8);
        for (let i = 0; i < 14; i++) {
            for (const one of strip.leftovers()) {
                const key = one.pattern + '|' + one.name + '|' + one.tag;
                if (seen.has(key)) continue;
                seen.add(key);
                lines.push(JSON.stringify({ y: Math.round(scrollY), ...one }));
            }
            const before = scrollY;
            scrollTo(0, before + step);
            await pause(1500);
            if (Math.abs(scrollY - before) < 2) break;
        }
        scrollTo(0, 0);
        return [JSON.stringify(strip.state()), ...lines].join('\\n');
        """

    private static func run(_ script: String, in browser: Browser) async -> String? {
        await browser.page?.tourLook(script)
    }
}
#endif
