import Foundation

/// Which media server an item came from.
enum MediaSource: String, CaseIterable, Identifiable, Codable {
    case jellyfin, plex, youtube
    var id: String { rawValue }
    var label: String {
        switch self {
        case .jellyfin: return "Jellyfin"
        case .plex: return "Plex"
        case .youtube: return "YouTube"
        }
    }
}

/// Server-agnostic description of something playable. Both clients map into this so the
/// library UI, the player and the bass pipeline never care where a file lives.
struct MediaItem: Identifiable, Hashable {
    let id: String                 // "<source>:<server item id>"
    let source: MediaSource
    let title: String
    let subtitle: String?          // year, or "Show · S01E02"
    let overview: String?
    let runtimeMinutes: Int?
    let posterURL: URL?
    /// Direct-play URL of the original file (FFmpeg backend).
    var directURL: URL?
    /// URL that AVPlayer can handle (may be a server-side remux/transcode). Falls back to directURL.
    var avPlayerURL: URL?
    let container: String?
    let videoCodec: String?
    let audioCodec: String?
    let audioChannels: Int?
    let videoRange: String?        // "SDR", "HDR10", "HLG", "Dolby Vision"...
    let isEpisode: Bool
    let width: Int?
    let height: Int?
    /// Detected 3D packing (nil = 2D as far as we can tell). User overrides live in LibraryStore.
    let stereo: StereoFormat?
    /// Stream URLs must be fetched just before playback (YouTube links expire after ~6 h).
    var needsResolve = false
    /// YouTube video id, when this item came from YouTube (drives resolution + SponsorBlock).
    var youtubeId: String? = nil
    /// User-Agent the stream URLs were issued for; the player must send the same one.
    var userAgent: String? = nil

    var formatBadge: String {
        var parts: [String] = []
        if let c = container { parts.append(c.uppercased()) }
        if let v = videoCodec { parts.append(v.uppercased()) }
        if let r = videoRange, r.uppercased() != "SDR" { parts.append(r) }
        if let st = stereo { parts.append(st.label.replacingOccurrences(of: "3D · ", with: "3D ")) }
        if let a = audioCodec {
            var s = a.uppercased()
            if let ch = audioChannels { s += " \(channelLabel(ch))" }
            parts.append(s)
        }
        return parts.joined(separator: " · ")
    }

    private func channelLabel(_ ch: Int) -> String {
        switch ch {
        case 1: return "1.0"
        case 2: return "2.0"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(ch)ch"
        }
    }

    var runtimeText: String? {
        guard let m = runtimeMinutes else { return nil }
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Common surface for the two server clients.
@MainActor
protocol MediaServerClient: ObservableObject {
    var source: MediaSource { get }
    var isSignedIn: Bool { get }
    var isBusy: Bool { get }
    var items: [MediaItem] { get }
    var errorMessage: String? { get set }
    func loadLibrary() async
    func signOut()
}
