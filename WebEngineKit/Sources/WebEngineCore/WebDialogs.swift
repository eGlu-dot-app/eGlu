import Foundation

/// A script's alert, confirm or prompt, or a file field's panel. The host
/// answers each exactly once, now or later (a background tab holds its
/// dialog until it is shown). `host` is the asking frame's origin's host,
/// empty where it has none.
@MainActor public protocol WebDialogPresenter: AnyObject {
    func alert(_ message: String, host: String, done: @escaping @MainActor () -> Void)
    func confirm(_ message: String, host: String, done: @escaping @MainActor (Bool) -> Void)
    func prompt(_ message: String, defaultText: String?, host: String,
                done: @escaping @MainActor (String?) -> Void)
    func openFiles(allowsMultiple: Bool, allowsDirectories: Bool,
                   done: @escaping @MainActor ([URL]?) -> Void)
}
