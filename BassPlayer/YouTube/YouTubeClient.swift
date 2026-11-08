import Foundation
import SwiftUI
import Combine

/// YouTube as a library source: search, trending, pasted links. Streams are fetched lazily when
/// an item is played (`resolve`), and SponsorBlock segments ride along for the player to skip.
@MainActor
final class YouTubeClient: ObservableObject, MediaServerClient {
    let source: MediaSource = .youtube
    private let api = InnerTubeClient()
    private let sponsorBlock = SponsorBlockClient()
    private let defaults = UserDefaults.standard

    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published var query = ""
    @Published var sponsorBlockEnabled: Bool { didSet { defaults.set(sponsorBlockEnabled, forKey: "yt.sponsorblock") } }
    /// Highest variant height handed to FFmpeg (2160 / 1440 / 1080 / 720).
    @Published var maxHeight: Int { didSet { defaults.set(maxHeight, forKey: "yt.maxHeight") } }
    static let maxHeightChoices = [2160, 1440, 1080, 720]
    /// Take the HDR version of a video when YouTube has one.
    @Published var preferHDR: Bool { didSet { defaults.set(preferHDR, forKey: "yt.preferHDR") } }
    @Published private(set) var lastQuery = ""
    private var searchTask: Task<Void, Never>?

    /// Optional Google account (feeds only; playback stays anonymous).
    let account = YouTubeAccount()
    private var cancellables = Set<AnyCancellable>()

    /// Which list `items` currently shows.
    enum Feed: Hashable {
        case search, home, subscriptions, history, watchLater, liked, playlists
        case playlist(id: String, title: String)

        var label: String {
            switch self {
            case .search: return "Search"
            case .home: return "Home"
            case .subscriptions: return "Subscriptions"
            case .history: return "History"
            case .watchLater: return "Watch later"
            case .liked: return "Liked"
            case .playlists: return "Playlists"
            case .playlist(_, let title): return title
            }
        }

        var systemImage: String {
            switch self {
            case .search: return "magnifyingglass"
            case .home: return "house"
            case .subscriptions: return "rectangle.stack.badge.person.crop"
            case .history: return "clock"
            case .watchLater: return "bookmark"
            case .liked: return "hand.thumbsup"
            case .playlists, .playlist: return "music.note.list"
            }
        }

        var browseId: String? {
            switch self {
            case .search: return nil
            case .home: return "FEwhat_to_watch"
            case .subscriptions: return "FEsubscriptions"
            case .history: return "FEhistory"
            case .watchLater: return "VLWL"
            case .liked: return "VLLL"
            case .playlists: return "FElibrary"
            case .playlist(let id, _): return id.hasPrefix("VL") ? id : "VL" + id
            }
        }

        /// Tabs offered once signed in.
        static let accountFeeds: [Feed] = [.home, .subscriptions, .history, .watchLater, .liked, .playlists]
    }

    @Published private(set) var feed: Feed = .search
    @Published private(set) var playlists: [InnerTubeClient.Playlist] = []
    @Published private(set) var canLoadMore = false
    private var continuation: String?
    private var feedGeneration = 0

    init() {
        sponsorBlockEnabled = defaults.object(forKey: "yt.sponsorblock") as? Bool ?? true
        maxHeight = defaults.object(forKey: "yt.maxHeight") as? Int ?? 2160
        preferHDR = defaults.object(forKey: "yt.preferHDR") as? Bool ?? true
        account.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    // MARK: - Account feeds

    /// Load a feed or playlist (first page). Search results are replaced.
    func load(feed newFeed: Feed) async {
        guard !demoMode else { return }
        guard let browseId = newFeed.browseId else { feed = .search; return }
        feedGeneration += 1
        let generation = feedGeneration
        feed = newFeed
        isBusy = true; defer { if generation == feedGeneration { isBusy = false } }
        errorMessage = nil
        items = []
        playlists = []
        continuation = nil
        canLoadMore = false
        do {
            let page = try await api.browse(browseId, auth: account.authHeaders())
            guard generation == feedGeneration else { return }
            items = page.videos.map(mediaItem)
            playlists = newFeed == .playlists ? page.playlists : []
            continuation = page.continuation
            canLoadMore = continuation != nil && newFeed != .playlists
            if items.isEmpty && playlists.isEmpty {
                errorMessage = account.isSignedIn ? "YouTube: nothing in \(newFeed.label) yet." : "YouTube: sign in to see \(newFeed.label)."
            }
        } catch {
            guard generation == feedGeneration else { return }
            errorMessage = "YouTube: \(error.localizedDescription)"
        }
    }

    /// Next page of the current feed.
    func loadMore() async {
        guard let browseId = feed.browseId, let token = continuation, !isBusy else { return }
        let generation = feedGeneration
        isBusy = true; defer { if generation == feedGeneration { isBusy = false } }
        do {
            let page = try await api.browse(browseId, continuation: token, auth: account.authHeaders())
            guard generation == feedGeneration else { return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.videos.map(mediaItem).filter { !known.contains($0.id) })
            continuation = page.continuation
            canLoadMore = continuation != nil
        } catch {
            errorMessage = "YouTube: \(error.localizedDescription)"
        }
    }

    func signOutAccount() async {
        await account.signOut()
        if feed != .search { items = []; playlists = []; feed = .search }
    }

    /// No account needed.
    var isSignedIn: Bool { true }
    func signOut() {}

    /// Simulator screenshots: show sample results without the network (see DemoData).
    private(set) var demoMode = false
    func enableDemo(items: [MediaItem], query: String) {
        demoMode = true
        self.items = items
        lastQuery = query
    }

    /// Re-run the last search. YouTube retired the anonymous Trending page in 2025 (browse
    /// FEtrending answers HTTP 400), so with no query the list simply stays empty; the view shows
    /// recent searches instead. That is not an error.
    func loadLibrary() async {
        guard !demoMode else { return }
        if feed != .search { await load(feed: feed); return }
        if !lastQuery.isEmpty { await search(lastQuery); return }
        if !query.isEmpty { await search(query); return }
        errorMessage = nil
    }

    /// Debounced search; a pasted link or 11-character id becomes a single playable item.
    func scheduleSearch(_ text: String) {
        query = text
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            await self.search(text)
        }
    }

    func search(_ text: String) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { await loadLibrary(); return }
        feedGeneration += 1
        feed = .search
        playlists = []
        canLoadMore = false
        isBusy = true; defer { isBusy = false }
        errorMessage = nil
        do {
            if let id = InnerTubeClient.videoId(from: q) {
                let s = try await api.streams(videoId: id, maxHeight: maxHeight, preferHDR: preferHDR)
                items = [mediaItem(from: s, id: id)]
            } else {
                items = try await api.search(q).map(mediaItem)
            }
            lastQuery = q
        } catch {
            errorMessage = "YouTube: \(error.localizedDescription)"
        }
    }

    /// Fetch fresh stream URLs for playback.
    func resolve(_ item: MediaItem) async throws -> MediaItem {
        guard let id = item.youtubeId else { return item }
        let s = try await api.streams(videoId: id, maxHeight: maxHeight, preferHDR: preferHDR)
        var out = item
        out.directURL = Self.ffmpegURL(s)
        out.avPlayerURL = s.progressiveURL ?? s.hlsURL         // AVPlayer: progressive keeps the bass tap working
        out.container = s.variantLabel.map { "HLS \($0)" } ?? (s.hlsURL != nil ? "hls" : "mp4")
        out.userAgent = s.userAgent
        out.needsResolve = false
        return out
    }

    func sponsorSegments(for item: MediaItem) async -> [SponsorBlockClient.Segment] {
        guard sponsorBlockEnabled, let id = item.youtubeId else { return [] }
        return await sponsorBlock.segments(videoId: id)
    }

    // MARK: - Mapping

    /// FFmpeg gets the local single-variant master; YouTube's own master only if picking failed.
    private static func ffmpegURL(_ s: InnerTubeClient.Streams) -> URL? {
        s.ffmpegURL ?? s.hlsURL ?? s.progressiveURL
    }

    private func mediaItem(_ v: InnerTubeClient.Video) -> MediaItem {
        MediaItem(
            id: "youtube:\(v.id)", source: .youtube, title: v.title,
            subtitle: [v.channel, v.viewsText].compactMap { $0 }.joined(separator: " · "),
            overview: nil,
            runtimeMinutes: v.durationSeconds.map { $0 / 60 },
            posterURL: v.thumbnailURL, directURL: nil, avPlayerURL: nil,
            container: nil, videoCodec: nil, audioCodec: nil, audioChannels: nil, videoRange: nil,
            isEpisode: false, width: nil, height: nil, stereo: nil,
            needsResolve: true, youtubeId: v.id, userAgent: nil
        )
    }

    private func mediaItem(from s: InnerTubeClient.Streams, id: String) -> MediaItem {
        MediaItem(
            id: "youtube:\(id)", source: .youtube, title: s.title,
            subtitle: s.author, overview: nil,
            runtimeMinutes: s.lengthSeconds.map { $0 / 60 },
            posterURL: s.thumbnailURL,
            directURL: Self.ffmpegURL(s), avPlayerURL: s.progressiveURL ?? s.hlsURL,
            container: s.variantLabel.map { "HLS \($0)" } ?? (s.hlsURL != nil ? "hls" : "mp4"), videoCodec: nil, audioCodec: nil, audioChannels: nil, videoRange: nil,
            isEpisode: false, width: nil, height: nil, stereo: nil,
            needsResolve: false, youtubeId: id, userAgent: s.userAgent
        )
    }
}
