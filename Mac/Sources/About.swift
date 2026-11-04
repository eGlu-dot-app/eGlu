import AppKit
import SwiftUI

/// eGlu › About eGlu: Apple's own About panel, with the engines' licences
/// as its credits, where a Mac app keeps its acknowledgements. In the menu
/// from the launch on, before the workspace is ready too.
struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About eGlu") { AboutPanel.show() }
        }
    }
}

@MainActor
enum AboutPanel {
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// `Licenses.txt` from the Engines package (licenses.sh writes it):
    /// every crate built into the engines, its licence and copyright
    /// notices, and each licence's full text. The panel scrolls it. A line
    /// over a row of "=" or "-" is a heading: bold, without the row. Made
    /// once, the first time the panel opens.
    private static let credits: NSAttributedString = {
        let size = NSFont.smallSystemFontSize
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size),
                                                   .foregroundColor: NSColor.labelColor]
        var heading = body
        heading[.font] = NSFont.boldSystemFont(ofSize: size)

        let lines = PluginLicences.text.components(separatedBy: "\n")
        let text = NSMutableAttributedString()
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let next = index + 1 < lines.count ? lines[index + 1] : ""
            let underlined = !line.isEmpty && next.count >= 3
                && (next.allSatisfy { $0 == "=" } || next.allSatisfy { $0 == "-" })
            let end = index + 1 < lines.count ? "\n" : ""
            text.append(NSAttributedString(string: line + end, attributes: underlined ? heading : body))
            index += underlined ? 2 : 1
        }
        return text
    }()
}
