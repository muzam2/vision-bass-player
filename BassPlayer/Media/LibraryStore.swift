import Foundation
import SwiftUI
import Combine

/// Player backend choice. FFmpeg (KSPlayer) direct-plays everything; AVPlayer is the fallback.
enum PlayerBackend: String, CaseIterable, Identifiable {
    case ffmpeg, avplayer
    var id: String { rawValue }
    var label: String { self == .ffmpeg ? "FFmpeg (all formats)" : "AVPlayer (MP4 only)" }
}

/// Top-level destinations of the app (tab bar / sidebar).
enum AppTab: String, CaseIterable, Identifiable {
    case home, jellyfin, plex, youtube, nas, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .jellyfin: return "Jellyfin"
        case .plex: return "Plex"
        case .youtube: return "YouTube"
        case .nas: return "NAS"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .jellyfin: return "film.stack"
        case .plex: return "play.rectangle.on.rectangle.fill"
        case .youtube: return "play.tv.fill"
        case .nas: return "externaldrive.connected.to.line.below.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var source: MediaSource? {
        switch self {
        case .jellyfin: return .jellyfin
        case .plex: return .plex
        case .youtube: return .youtube
        case .nas: return .nas
        default: return nil
        }
    }

    init(source: MediaSource) {
        switch source {
        case .jellyfin: self = .jellyfin
        case .plex: self = .plex
        case .youtube: self = .youtube
        case .nas: self = .nas
        }
    }
}

/// App-wide settings and the merged library from Jellyfin + Plex.
@MainActor
final class LibraryStore: ObservableObject {
    let jellyfin: JellyfinClient
    let plex: PlexClient
    let youtube: YouTubeClient
    let nas: NASClient
    /// The one running playback (player + bass pipeline), shared by the player window and the
    /// cinema screen so the window can close while the film keeps playing.
    let playback = PlaybackController()
    private let defaults = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()

    @Published var selectedSource: MediaSource { didSet { defaults.set(selectedSource.rawValue, forKey: "lib.source") } }
    @Published var selectedTab: AppTab { didSet { defaults.set(selectedTab.rawValue, forKey: "lib.tab") } }
    @Published var backend: PlayerBackend { didSet { defaults.set(backend.rawValue, forKey: "lib.backend") } }
    @Published var searchText = ""
    /// The item being played (tvOS presents it full screen; visionOS opens the player window).
    @Published var nowPlaying: MediaItem?
    /// Bumped on every `play(_:)` so the same item can be played again.
    @Published private(set) var playCounter = 0
    @Published var showEpisodes: Bool { didSet { defaults.set(showEpisodes, forKey: "lib.showEpisodes") } }
    @Published var autoplayNext: Bool { didSet { defaults.set(autoplayNext, forKey: "lib.autoplayNext") } }
    @Published var resumePlayback: Bool { didSet { defaults.set(resumePlayback, forKey: "lib.resume") } }
    /// When set, playback pauses at this time (sleep timer).
    @Published var sleepTimerEnd: Date?
    @Published private(set) var recents: [MediaItem] = []

    init(jellyfin: JellyfinClient, plex: PlexClient, youtube: YouTubeClient, nas: NASClient) {
        self.jellyfin = jellyfin
        self.plex = plex
        self.youtube = youtube
        self.nas = nas
        selectedSource = MediaSource(rawValue: defaults.string(forKey: "lib.source") ?? "") ?? .jellyfin
        selectedTab = AppTab(rawValue: defaults.string(forKey: "lib.tab") ?? "") ?? .home
        backend = PlayerBackend(rawValue: defaults.string(forKey: "lib.backend") ?? "") ?? .ffmpeg
        showEpisodes = defaults.object(forKey: "lib.showEpisodes") as? Bool ?? false
        autoplayNext = defaults.object(forKey: "lib.autoplayNext") as? Bool ?? true
        resumePlayback = defaults.object(forKey: "lib.resume") as? Bool ?? true
        if let data = defaults.data(forKey: "lib.recents"), let r = try? JSONDecoder().decode([MediaItem].self, from: data) { recents = r }
        // Re-publish when either client changes so views depending on `items` refresh.
        jellyfin.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        plex.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        youtube.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        nas.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        playback.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    // MARK: - Per-source state

    func isSignedIn(_ source: MediaSource) -> Bool {
        switch source {
        case .jellyfin: return jellyfin.isSignedIn
        case .plex: return plex.isSignedIn && plex.hasServer
        case .youtube: return true
        case .nas: return true
        }
    }

    func isBusy(_ source: MediaSource) -> Bool {
        switch source {
        case .jellyfin: return jellyfin.isBusy
        case .plex: return plex.isBusy
        case .youtube: return youtube.isBusy
        case .nas: return false
        }
    }

    func error(for source: MediaSource) -> String? {
        switch source {
        case .jellyfin: return jellyfin.errorMessage
        case .plex: return plex.errorMessage
        case .youtube: return youtube.errorMessage
        case .nas: return nas.errorMessage
        }
    }

    /// Everything a source currently offers, unfiltered (YouTube: the current search result).
    func items(for source: MediaSource) -> [MediaItem] {
        switch source {
        case .jellyfin: return jellyfin.items
        case .plex: return plex.items
        case .youtube: return youtube.items
        case .nas: return []          // NAS has its own folder browser
        }
    }

    func refresh(_ source: MediaSource) async {
        switch source {
        case .jellyfin: await jellyfin.loadLibrary()
        case .plex: await plex.loadLibrary()
        case .youtube: await youtube.loadLibrary()
        case .nas: break
        }
    }

    /// One-line connection summary for the Home and Settings screens.
    func status(of source: MediaSource) -> String {
        switch source {
        case .jellyfin:
            return jellyfin.isSignedIn ? "\(jellyfin.items.count) titles · \(jellyfin.serverURL)" : "Not signed in"
        case .plex:
            if !plex.isSignedIn { return "Not signed in" }
            return plex.hasServer ? "\(plex.items.count) titles · \(plex.serverName)" : "Signed in · no server chosen"
        case .youtube:
            return "No account needed"
        case .nas:
            return nas.shares.isEmpty ? "No shares added" : "\(nas.shares.count) share\(nas.shares.count == 1 ? "" : "s")"
        }
    }

    // Convenience for the current `selectedSource` (older call sites).
    var currentIsSignedIn: Bool { isSignedIn(selectedSource) }
    var currentIsBusy: Bool { isBusy(selectedSource) }
    var currentError: String? { error(for: selectedSource) }

    var items: [MediaItem] {
        let all = items(for: selectedSource)
        guard selectedSource == .jellyfin || selectedSource == .plex else { return all }
        return all.filter { item in
            (showEpisodes || !item.isEpisode) &&
            (searchText.isEmpty || item.title.localizedCaseInsensitiveContains(searchText) || (item.subtitle?.localizedCaseInsensitiveContains(searchText) ?? false))
        }
    }

    func refresh() async { await refresh(selectedSource) }

    // MARK: - Playback

    /// Start playing an item. tvOS presents it full screen; visionOS opens the player window
    /// (RootView watches `playCounter`).
    func play(_ item: MediaItem) {
        // Make autoplay-next work for an episode started from Continue Watching too.
        if let key = item.parentShowKey, item.source == .plex || item.source == .jellyfin {
            Task { _ = try? await episodes(showKey: key, source: item.source) }
        }
        nowPlaying = item
        playCounter += 1
    }

    /// Fraction watched (0...1) from the locally saved position, or nil when unknown/unstarted.
    func progress(for item: MediaItem) -> Double? {
        guard let minutes = item.runtimeMinutes, minutes > 0 else { return nil }
        let pos = defaults.double(forKey: "pos.\(item.id)")
        guard pos > 0 else { return nil }
        return min(1, pos / (Double(minutes) * 60))
    }

    /// Recently played items that were left part-way through.
    var continueWatching: [MediaItem] {
        recents.filter { (progress(for: $0) ?? 0) > 0.02 }
    }

    /// Fetch anything the item needs just before playback (YouTube stream URLs expire).
    func resolve(_ item: MediaItem) async throws -> MediaItem {
        guard item.needsResolve else { return item }
        switch item.source {
        case .youtube: return try await youtube.resolve(item)
        default: return item
        }
    }

    func url(for item: MediaItem) -> URL? {
        effectiveBackend(for: item) == .ffmpeg ? (item.directURL ?? item.avPlayerURL) : (item.avPlayerURL ?? item.directURL)
    }

    // MARK: - Recents & progress

    func noteStarted(_ item: MediaItem) {
        recents.removeAll { $0.id == item.id }
        recents.insert(item, at: 0)
        if recents.count > 20 { recents.removeLast(recents.count - 20) }
        if let data = try? JSONEncoder().encode(recents) { defaults.set(data, forKey: "lib.recents") }
    }

    /// Locally remembered position (seconds); server-known position wins when newer is unknown.
    func savedPosition(for item: MediaItem) -> Double? {
        let local = defaults.double(forKey: "pos.\(item.id)")
        if local > 0 { return local }
        return item.serverResumeSeconds
    }

    func savePosition(_ seconds: Double, duration: Double, for item: MediaItem) {
        // Near the end counts as finished: clear so the next play starts fresh.
        if duration > 0, seconds > duration * 0.95 || seconds < 15 {
            defaults.removeObject(forKey: "pos.\(item.id)")
        } else {
            defaults.set(seconds, forKey: "pos.\(item.id)")
        }
    }

    /// Tell the server where we are (Jellyfin Continue Watching, Plex On Deck).
    func report(_ item: MediaItem, position: Double, duration: Double, state: PlaybackReportState) async {
        switch item.source {
        case .jellyfin:
            await jellyfin.reportPlayback(itemId: String(item.id.dropFirst("jellyfin:".count)), positionSeconds: position, state: state)
        case .plex:
            await plex.reportPlayback(ratingKey: String(item.id.dropFirst("plex:".count)), positionSeconds: position, durationSeconds: duration, state: state)
        default: break
        }
    }

    /// The item after `item` in its source's list (for autoplay).
    /// Episodes of a series, from whichever server it lives on.
    func episodes(of show: MediaItem, refresh: Bool = false) async throws -> [MediaItem] {
        guard let key = show.showKey ?? show.parentShowKey else { return [] }
        return try await episodes(showKey: key, source: show.source, refresh: refresh)
    }

    func episodes(showKey key: String, source: MediaSource, refresh: Bool = false) async throws -> [MediaItem] {
        switch source {
        case .plex: return try await plex.episodes(showKey: key, refresh: refresh)
        case .jellyfin: return try await jellyfin.episodes(showKey: key, refresh: refresh)
        default: return []
        }
    }

    func next(after item: MediaItem) -> MediaItem? {
        if item.isEpisode, item.source == .plex { return plex.nextEpisode(after: item) }
        if item.isEpisode, item.source == .jellyfin { return jellyfin.nextEpisode(after: item) }
        let list = items(for: item.source).filter { (showEpisodes || !$0.isEpisode) && !$0.isShow }
        guard let i = list.firstIndex(of: item), i + 1 < list.count else { return nil }
        return list[i + 1]
    }

    // MARK: - Projection (VR)

    func projectionOverride(for item: MediaItem) -> ScreenProjection? {
        ScreenProjection(rawValue: defaults.string(forKey: "proj.\(item.id)") ?? "")
    }

    func setProjectionOverride(_ p: ScreenProjection?, for item: MediaItem) {
        objectWillChange.send()
        if let p { defaults.set(p.rawValue, forKey: "proj.\(item.id)") } else { defaults.removeObject(forKey: "proj.\(item.id)") }
    }

    func effectiveProjection(for item: MediaItem) -> ScreenProjection {
        projectionOverride(for: item) ?? item.projection ?? .flat
    }

    // MARK: - 3D

    /// Per-item user override for the stereo format (`.auto` = use detection).
    func stereoOverride(for item: MediaItem) -> StereoFormat {
        StereoFormat(rawValue: defaults.string(forKey: "stereo.\(item.id)") ?? "") ?? .auto
    }

    func setStereoOverride(_ f: StereoFormat, for item: MediaItem) {
        objectWillChange.send()
        if f == .auto { defaults.removeObject(forKey: "stereo.\(item.id)") } else { defaults.set(f.rawValue, forKey: "stereo.\(item.id)") }
    }

    /// What we will actually use for playback.
    func effectiveStereo(for item: MediaItem) -> StereoFormat {
        let o = stereoOverride(for: item)
        if o != .auto { return o }
        return item.stereo ?? .mono
    }

    /// MV-HEVC needs AVPlayer (FFmpeg 6.1 decodes only the base view); everything else honours the setting.
    func effectiveBackend(for item: MediaItem) -> PlayerBackend {
        if effectiveStereo(for: item) == .mvHEVC { return .avplayer }
        if item.source == .nas { return .ffmpeg }          // smb:// and basic-auth URLs need FFmpeg
        return backend
    }
}
