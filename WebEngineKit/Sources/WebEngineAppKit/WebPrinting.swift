import AppKit

@MainActor public protocol WebPrinting: AnyObject {
    /// An operation that prints the page as it is laid out now, ready to run.
    func printOperation(with info: NSPrintInfo) -> NSPrintOperation
}
