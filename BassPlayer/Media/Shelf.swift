import Foundation

/// One horizontal row on a server's Home page (Plex / Jellyfin), the way the native apps lay
/// out their libraries: Continue Watching, Recently Added, Recently Released, ...
/// Each client fills its rows from the server, so progress, watched state and ordering
/// match what the native apps show.
struct Shelf: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Hashable {
        case continueWatching, upNext
        case recentlyAddedMovies, recentlyAddedShows
        case recentlyReleasedMovies, recentlyReleasedEpisodes
        case recentlyWatched

        var title: String {
            switch self {
            case .continueWatching: return "Continue Watching"
            case .upNext: return "Up Next"
            case .recentlyAddedMovies: return "Recently Added Movies"
            case .recentlyAddedShows: return "Recently Added TV"
            case .recentlyReleasedMovies: return "Recently Released Movies"
            case .recentlyReleasedEpisodes: return "Recently Released Episodes"
            case .recentlyWatched: return "Recently Watched"
            }
        }

        /// 16:9 cards with a progress bar (stills/backdrops) rather than 2:3 posters.
        var isLandscape: Bool { self == .continueWatching || self == .upNext }
    }

    let kind: Kind
    var items: [MediaItem]
    var id: Kind { kind }
    var title: String { kind.title }
}

extension Array where Element == MediaItem {
    /// First occurrence of each id (rows merged from several requests can repeat an item,
    /// and SwiftUI's ForEach needs unique ids).
    var uniquedByID: [MediaItem] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

/// Navigation value for a shelf's "See all" page.
struct ShelfLink: Hashable {
    let source: MediaSource
    let kind: Shelf.Kind
}
