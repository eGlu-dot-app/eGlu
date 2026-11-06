import Foundation

/// A copy of the catalog entry. Loading keeps this value across preparation;
/// only the original post-read check asks for the current entry again.
public struct WebExtensionInstallation: Equatable, Sendable {
    public enum Source: String, Sendable { case store, file, unsigned, unpacked }
    public enum SiteAccess: String, Sendable { case allSites, onClick }
    public let id: String
    public let name: String
    public let version: String
    public let source: Source
    public let siteAccess: SiteAccess
    public let spaces: [UUID]
    public let granted: [String]?
    public let folder: String?
    public let looksWrong: String?
    public let readsCookies: Bool?

    public init(id: String, name: String, version: String, source: Source, siteAccess: SiteAccess,
                spaces: [UUID], granted: [String]? = nil, folder: String? = nil,
                looksWrong: String? = nil, readsCookies: Bool? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.source = source
        self.siteAccess = siteAccess
        self.spaces = spaces
        self.granted = granted
        self.folder = folder
        self.looksWrong = looksWrong
        self.readsCookies = readsCookies
    }
}

/// Controllers, loaded membership and grants, composed by the last hub slice.
/// Cookie callbacks run inline for each context, before the next is changed.
@MainActor public protocol WebExtensionControllers: AnyObject {
    func isLoaded(_ id: String, in space: UUID) -> Bool
    func extensionID(for url: URL?) -> String?
    @discardableResult func load(_ item: WebExtensionInstallation, in space: UUID) async -> Bool
    func unload(_ id: String, in space: UUID)
    func setSiteAccess(_ id: String, _ access: WebExtensionInstallation.SiteAccess)
    func setReadsCookies(_ id: String, _ on: Bool, changed: (UUID) -> Void)
}
