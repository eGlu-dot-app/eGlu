"""Tests for engine-inventory.py.

Verifies detection of WebKit imports, reach-ins, declarations, private APIs,
constructions, and script bridges using small code snippets.
"""

import importlib.util
from pathlib import Path
import unittest
import tempfile

# Import engine-inventory.py via importlib because of the hyphen in its filename.
SCRIPT_PATH = Path(__file__).resolve().parent / "engine-inventory.py"
spec = importlib.util.spec_from_file_location("engine_inventory", SCRIPT_PATH)
if spec is None or spec.loader is None:
    raise ImportError(f"Cannot load module from {SCRIPT_PATH}")
inv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inv)


class EngineInventoryTests(unittest.TestCase):
    """Test suite for engine inventory scanner functions."""

    def test_import_lines(self):
        snippet = """
        import Foundation
        import WebKit
        @testable import Engines
        // import WebKit
        /*
        import WebKit
        */
        import WebKitCustom
        """
        findings = inv.find_imports(snippet, "Mac/Sources/Test.swift")
        self.assertEqual(len(findings), 2)
        self.assertEqual(findings[0].line_number, 3)
        self.assertEqual(findings[0].detail, "WebKit")
        self.assertEqual(findings[1].line_number, 4)
        self.assertEqual(findings[1].detail, "Engines")

    def test_reach_in_alias_and_uses(self):
        snippet = """
        func show(page: Page?) {
            let view = page?.view
            view.load(request)
            view?.reload()
        }

        func other() {
            view.doSomething()
        }
        """
        findings = inv.find_reach_ins(snippet, "Mac/Sources/Test.swift")
        # Should match the definition (line 3) and two uses (lines 4 and 5).
        # Should not match line 9 in other() because view is out of scope.
        self.assertEqual(len(findings), 3)
        lines = [f.line_number for f in findings]
        self.assertEqual(lines, [3, 4, 5])

    def test_reach_in_guard_alias(self):
        snippet = """
        func setup(page: Page?) {
            guard let view = page?.view else { return }
            view.frame = .zero
        }
        """
        findings = inv.find_reach_ins(snippet, "Mac/Sources/Test.swift")
        self.assertEqual(len(findings), 2)
        lines = [f.line_number for f in findings]
        self.assertEqual(lines, [3, 4])

    def test_multi_line_guard_alias_outlives_its_else(self):
        snippet = """
        func reload(_ toolsPage: Page?) {
            guard let view = toolsPage?.view else {
                return
            }
            view.reload()
        }
        """
        findings = inv.find_reach_ins(snippet, "Mac/Sources/Test.swift")
        self.assertEqual([f.line_number for f in findings], [3, 6])

    def test_type_headers_and_modifiers_with_arguments(self):
        snippet = """
        final class PageView: WKWebView {
        private(set) var lists: [WKContentRuleList] = []
        extension Page: WKNavigationDelegate, WKUIDelegate {
        """
        findings = inv.find_declarations(snippet, "Mac/Sources/Test.swift")
        self.assertEqual([f.line_number for f in findings], [2, 3, 4])

    def test_private_selectors_but_not_link_targets(self):
        snippet = """
        let swipe = "_webView:didNotHandleWheelEvent:"
        let target = "_blank"
        @objc(_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:)
        view.setValue(true, forKey: "_rubberBand")
        """
        findings = inv.find_private_apis(snippet, "Mac/Sources/Test.swift")
        self.assertEqual(sorted({f.line_number for f in findings}), [2, 4, 5])

    def test_qualified_alias_passed_as_argument(self):
        # Menus.tool: the little window's page view, handed to the inspector.
        snippet = """
        private func tool(_ command: Command) {
            let view = little.page.view
            switch command {
            case .inspector: if !WebInspector.show(.inspector, for: view) { NSSound.beep() }
            case .reload: other(view: nil)
            }
        }
        """
        findings = inv.find_reach_ins(snippet, "Mac/Sources/Test.swift")
        # The alias and its use as an argument; not the `view:` label.
        self.assertEqual([f.line_number for f in findings], [3, 5])

    def test_property_of_the_view_is_no_alias(self):
        snippet = """
        func focus(page: Page) {
            guard let window = page.view.window else { return }
            window.makeKeyAndOrderFront(nil)
        }
        """
        findings = inv.find_reach_ins(snippet, "Mac/Sources/Test.swift")
        # Only the reach-in itself: `window` is the view's window, not the view.
        self.assertEqual([f.line_number for f in findings], [3])

    def test_declarations_with_wk_type(self):
        snippet = """
        private let view: WKWebView
        func make() -> WKWebView? { return nil }
        init(configuration: WKWebViewConfiguration) {}
        case webView(WKWebView)
        protocol PageHost: WKNavigationDelegate {}
        typealias NativeView = WKWebView
        let count: Int = 10
        // var commented: WKWebView?
        """
        findings = inv.find_declarations(snippet, "Mac/Sources/Test.swift")
        self.assertEqual(len(findings), 6)
        matched_lines = [f.line_number for f in findings]
        self.assertEqual(matched_lines, [2, 3, 4, 5, 6, 7])

    def test_private_selector_and_api(self):
        snippet = """
        let sel = "_setApplicationNameForUserAgent:"
        let fn = NSSelectorFromString("_provisionalURL")
        @objc func _webViewWebProcessDidCrash(_ webView: WKWebView) {}
        let val = webView.value(forKey: "_provisionalURL")
        let cls = "_WKWebExtensionMenuItem"
        let normal = "hello"
        """
        findings = inv.find_private_apis(snippet, "Mac/Sources/Test.swift")
        self.assertEqual(len(findings), 5)
        matched_lines = [f.line_number for f in findings]
        self.assertEqual(matched_lines, [2, 3, 4, 5, 6])

    def test_hidden_web_view_constructions(self):
        snippet = """
        let v = WKWebView(frame: .zero)
        let config = WKWebViewConfiguration()
        var view: WKWebView? = nil
        // let skipped = WKWebView()
        """
        findings = inv.find_hidden_web_views(snippet, "Mac/Sources/Test.swift")
        self.assertEqual(len(findings), 2)
        self.assertEqual([f.line_number for f in findings], [2, 3])

    def test_plugin_script_bridges_are_counted_apart(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = ["Mac/Sources/Inline.swift", "PadCore/Scripts/app.js",
                     "WebKitEngine/Sources/WebKitSupport/Scripts/bridge.js",
                     "WebKitEngine/Sources/WebKitMacPlugin/Inline.swift",
                     "Tests/MacPage/Reads.swift"]
            for path in paths:
                file = root / path
                file.parent.mkdir(parents=True, exist_ok=True)
                source = 'webkit.messageHandlers.test.postMessage({});'
                if path.endswith(".swift"):
                    source = 'let script = "' + source + '"'
                file.write_text(source)
            # JavaScript outside the Mac inventory is not scanned.
            excluded = root / "Extension/runtime.js"
            excluded.parent.mkdir()
            excluded.write_text('webkit.messageHandlers.excluded.postMessage({});')
            data = inv.run_inventory(root)
            self.assertEqual({f.path for f in data["script_bridges"]}, set(paths[:2]))
            self.assertEqual({f.path for f in data["plugin_script_bridges"]}, set(paths[2:4]))
            self.assertEqual({f.path for f in data["test_script_bridges"]}, set(paths[4:]))
            summary = inv.build_summary_table(data)
            self.assertIn("| f. Script bridges (app) | 2 | 2 |", summary)
            self.assertIn("| f. Script bridges (WebKit plugin) | 2 | 2 |", summary)
            self.assertIn("| f. Script bridges (tests) | 1 | 1 |", summary)
            self.assertIn("#### WebKit plugin (2 lines in 2 files)", inv.build_full_report(data))

    def test_script_bridges(self):
        swift_snippet = """
        let script = \"\"\"
        window.webkit.messageHandlers.bridge.postMessage(payload);
        \"\"\"
        let regularSwift = "normal string"
        """
        findings = inv.find_script_bridges(swift_snippet, "Mac/Sources/Test.swift")
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0].line_number, 3)

        js_snippet = """
        // comment with webkit.messageHandlers
        root.webkit.messageHandlers.test.postMessage("ok");
        """
        js_findings = inv.find_script_bridges(js_snippet, "PadCore/Scripts/test.js")
        self.assertEqual(len(js_findings), 1)
        self.assertEqual(js_findings[0].line_number, 3)

        # A WebKit-prefixed name that is no message bridge.
        other = inv.find_script_bridges("if (root.webkitRequestFileSystem) {}", "x.js")
        self.assertEqual(other, [])


if __name__ == "__main__":
    unittest.main()
