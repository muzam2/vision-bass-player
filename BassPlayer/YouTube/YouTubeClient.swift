import Foundation
import SwiftUI

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
    @Published private(set) var lastQuery = ""
    private var searchTask: Task<Void, Never>?

    init() {
        sponsorBlockEnabled = defaults.object(forKey: "yt.sponsorblock") as? Bool ?? true
    }

    /// No account needed.
    var isSignedIn: Bool { true }
    func signOut() {}

    /// Default view: trending.
    func loadLibrary() async {
        if !query.isEmpty { await search(query); return }
        isBusy = true; defer { isBusy = false }
        errorMessage = nil
        do {
            items = try await api.trending().map(mediaItem)
            lastQuery = ""
        } catch {
            errorMessage = "YouTube: \(error.localizedDescription)"
        }
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
        isBusy = true; defer { isBusy = false }
        errorMessage = nil
        do {
            if let id = InnerTubeClient.videoId(from: q) {
                let s = try await api.streams(videoId: id)
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
        let s = try await api.streams(videoId: id)
        var out = item
        out.directURL = s.hlsURL ?? s.progressiveURL           // FFmpeg: HLS has every quality
        out.avPlayerURL = s.progressiveURL ?? s.hlsURL         // AVPlayer: progressive keeps the bass tap working
        out.userAgent = s.userAgent
        out.needsResolve = false
        return out
    }

    func sponsorSegments(for item: MediaItem) async -> [SponsorBlockClient.Segment] {
        guard sponsorBlockEnabled, let id = item.youtubeId else { return [] }
        return await sponsorBlock.segments(videoId: id)
    }

    // MARK: - Mapping

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
            directURL: s.hlsURL ?? s.progressiveURL, avPlayerURL: s.progressiveURL ?? s.hlsURL,
            container: s.hlsURL != nil ? "hls" : "mp4", videoCodec: nil, audioCodec: nil, audioChannels: nil, videoRange: nil,
            isEpisode: false, width: nil, height: nil, stereo: nil,
            needsResolve: false, youtubeId: id, userAgent: s.userAgent
        )
    }
}
