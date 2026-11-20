import Foundation

/// The parts of Settings a search finds: what Settings' own search field
/// lists and what the address bar and the command bar offer, from one index,
/// each going to its section as SettingsAnchor routes it.
public struct SettingsSearch: Sendable {
    /// A part of Settings as the app names it. The Mac calls some parts by
    /// names of its own (App Icon is the Dock's), so each name can be given.
    public struct Destination: Equatable, Sendable {
        public let anchor: SettingsAnchor
        public let title: String
        public let detail: String
        public let keywords: [String]

        public init(_ anchor: SettingsAnchor, title: String? = nil, detail: String? = nil, keywords: [String]? = nil) {
            self.anchor = anchor
            self.title = title ?? anchor.title
            self.detail = detail ?? anchor.detail
            self.keywords = keywords ?? anchor.keywords
        }

        /// Its row in the address bar and the command bar.
        public var candidate: Autocomplete.Candidate {
            Autocomplete.Candidate(id: "setting-\(anchor.rawValue)", source: .setting, action: .setting(anchor),
                                   title: title, keywords: keywords, detail: detail)
        }
    }

    public let destinations: [Destination]
    private let index: Autocomplete.Index

    public init(_ destinations: [Destination]) {
        self.destinations = destinations
        index = Autocomplete.Index(destinations.map(\.candidate))
    }

    /// The parts, each by the names SettingsAnchor gives it.
    public init(anchors: [SettingsAnchor]) {
        self.init(anchors.map { Destination($0) })
    }

    public var candidates: [Autocomplete.Candidate] {
        index.candidates
    }

    /// The parts `query` finds, best first, by name or by the words for what
    /// is changed there. A letter is enough, as in a list of a few dozen
    /// there is nothing for a part to crowd out; nothing typed finds nothing.
    public func find(_ query: String) -> [Destination] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return index.local(query: query, wide: true).compactMap { row in
            guard case .setting(let anchor) = row.action else { return nil }
            return destinations.first { $0.anchor == anchor }
        }
    }
}
