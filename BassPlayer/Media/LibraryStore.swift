import Foundation
import SwiftUI
import Combine

/// Player backend choice. FFmpeg (KSPlayer) direct-plays everything; AVPlayer is the fallback.
enum PlayerBackend: String, CaseIterable, Identifiable {
    case ffmpeg, avplayer
    var id: String { rawValue }
    var label: String { self == .ffmpeg ? "FFmpeg (all formats)" : "AVPlayer (MP4 only)" }
}

/// App-wide settings and the merged library from Jellyfin + Plex.
@MainActor
final class LibraryStore: ObservableObject {
    let jellyfin: JellyfinClient
    let plex: PlexClient
    let youtube: YouTubeClient
    let nas: NASClient
    private let defaults = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()

    @Published var selectedSource: MediaSource { didSet { defaults.set(selectedSource.rawValue, forKey: "lib.source") } }
    @Published var backend: PlayerBackend { didSet { defaults.set(backend.rawValue, forKey: "lib.backend") } }
    @Published var searchText = ""
    @Published var showEpisodes: Bool { didSet { defaults.set(showEpisodes, forKey: "lib.showEpisodes") } }

    init(jellyfin: JellyfinClient, plex: PlexClient, youtube: YouTubeClient, nas: NASClient) {
        self.jellyfin = jellyfin
        self.plex = plex
        self.youtube = youtube
        self.nas = nas
        selectedSource = MediaSource(rawValue: defaults.string(forKey: "lib.source") ?? "") ?? .jellyfin
        backend = PlayerBackend(rawValue: defaults.string(forKey: "lib.backend") ?? "") ?? .ffmpeg
        showEpisodes = defaults.object(forKey: "lib.showEpisodes") as? Bool ?? false
        // Re-publish when either client changes so views depending on `items` refresh.
        jellyfin.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        plex.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        youtube.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        nas.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    var currentIsSignedIn: Bool {
        switch selectedSource {
        case .jellyfin: return jellyfin.isSignedIn
        case .plex: return plex.isSignedIn && plex.hasServer
        case .youtube: return true
        case .nas: return true
        }
    }

    var currentIsBusy: Bool {
        switch selectedSource {
        case .jellyfin: return jellyfin.isBusy
        case .plex: return plex.isBusy
        case .youtube: return youtube.isBusy
        case .nas: return false
        }
    }

    var currentError: String? {
        switch selectedSource {
        case .jellyfin: return jellyfin.errorMessage
        case .plex: return plex.errorMessage
        case .youtube: return youtube.errorMessage
        case .nas: return nas.errorMessage
        }
    }

    var items: [MediaItem] {
        // YouTube's list is already the search result; local filtering applies to the servers.
        if selectedSource == .youtube { return youtube.items }
        if selectedSource == .nas { return [] }     // NAS has its own folder browser
        let all = selectedSource == .jellyfin ? jellyfin.items : plex.items
        return all.filter { item in
            (showEpisodes || !item.isEpisode) &&
            (searchText.isEmpty || item.title.localizedCaseInsensitiveContains(searchText) || (item.subtitle?.localizedCaseInsensitiveContains(searchText) ?? false))
        }
    }

    func refresh() async {
        switch selectedSource {
        case .jellyfin: await jellyfin.loadLibrary()
        case .plex: await plex.loadLibrary()
        case .youtube: await youtube.loadLibrary()
        case .nas: break
        }
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
