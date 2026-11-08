import Foundation
import SwiftUI

/// Minimal Jellyfin REST client: sign in, list movies + episodes, build stream URLs.
/// Jellyfin API reference: https://api.jellyfin.org
@MainActor
final class JellyfinClient: ObservableObject, MediaServerClient {
    let source: MediaSource = .jellyfin
    private let defaults = UserDefaults.standard

    @Published var serverURL: String { didSet { defaults.set(serverURL, forKey: "jf.server") } }
    @Published var username: String { didSet { defaults.set(username, forKey: "jf.username") } }
    @Published private var storedToken: String { didSet { defaults.set(storedToken, forKey: "jf.token") } }
    @Published private var storedUserId: String { didSet { defaults.set(storedUserId, forKey: "jf.userId") } }
    private let deviceId: String

    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    /// Episodes fetched per series (`showKey` = Jellyfin series id).
    @Published private(set) var episodesByShow: [String: [MediaItem]] = [:]
    private var loadGeneration = 0

    init() {
        serverURL = defaults.string(forKey: "jf.server") ?? ""
        username = defaults.string(forKey: "jf.username") ?? ""
        storedToken = defaults.string(forKey: "jf.token") ?? ""
        storedUserId = defaults.string(forKey: "jf.userId") ?? ""
        if let id = defaults.string(forKey: "jf.deviceId") {
            deviceId = id
        } else {
            deviceId = UUID().uuidString
            defaults.set(deviceId, forKey: "jf.deviceId")
        }
    }

    var isSignedIn: Bool { demoMode || (!storedToken.isEmpty && !storedUserId.isEmpty) }

    /// Simulator screenshots: show sample items without a server (see DemoData).
    private(set) var demoMode = false
    func enableDemo(items: [MediaItem], server: String) {
        demoMode = true
        serverURL = server
        self.items = items
    }
    var accessToken: String? { storedToken.isEmpty ? nil : storedToken }

    private var baseURL: URL? {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.hasPrefix("http") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    private var authorizationHeader: String {
        var h = "MediaBrowser Client=\"BassPlayer\", Device=\"Apple\", DeviceId=\"\(deviceId)\", Version=\"0.2.0\""
        if let t = accessToken { h += ", Token=\"\(t)\"" }
        return h
    }

    private func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Encodable? = nil) throws -> URLRequest {
        guard let base = baseURL else { throw JellyfinError.noServer }
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        return req
    }

    /// Nonisolated so large JSON pages decode off the main thread.
    nonisolated private func send<T: Decodable & Sendable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw JellyfinError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Auth

    func signIn(password: String) async {
        isBusy = true; defer { isBusy = false }
        errorMessage = nil
        do {
            struct Body: Encodable { let Username: String; let Pw: String }
            let req = try request("Users/AuthenticateByName", method: "POST", body: Body(Username: username, Pw: password))
            let result = try await send(req, as: AuthResult.self)
            storedToken = result.AccessToken
            storedUserId = result.User.Id
            await loadLibrary()
        } catch {
            errorMessage = "Jellyfin sign-in failed: \(error.localizedDescription)"
        }
    }

    func signOut() {
        storedToken = ""
        storedUserId = ""
        items = []
    }

    // MARK: - Library

    static let pageSize = 500
    private static let itemFields = "MediaSources,Overview,ProductionYear,RunTimeTicks,SeriesName,ParentIndexNumber,IndexNumber,Path,Video3DFormat,UserData"

    /// Series come as one card each (episodes load when a series is opened); movies arrive in
    /// pages of 500 and are shown as they land. Fetching every episode of every show in one
    /// request, as before, meant minutes of spinner on a large library.
    func loadLibrary() async {
        guard isSignedIn, !demoMode else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isBusy = true
        defer { if generation == loadGeneration { isBusy = false } }
        errorMessage = nil
        let progressive = items.isEmpty
        do {
            var all: [MediaItem] = []
            func publish() {
                guard generation == loadGeneration else { return }
                items = all.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            }
            // Series first (small), then movies page by page.
            let seriesReq = try request("Users/\(storedUserId)/Items", query: [
                .init(name: "IncludeItemTypes", value: "Series"),
                .init(name: "Recursive", value: "true"),
                .init(name: "SortBy", value: "SortName"),
                .init(name: "SortOrder", value: "Ascending"),
                .init(name: "Fields", value: "Overview,ProductionYear,ChildCount,RecursiveItemCount,UserData"),
            ])
            let series = try await send(seriesReq, as: ItemsPage.self)
            guard generation == loadGeneration else { return }
            all.append(contentsOf: series.Items.compactMap { showItem(from: $0) })
            if progressive { publish() }

            var start = 0
            while true {
                try Task.checkCancellation()
                let req = try request("Users/\(storedUserId)/Items", query: [
                    .init(name: "IncludeItemTypes", value: "Movie"),
                    .init(name: "Recursive", value: "true"),
                    .init(name: "SortBy", value: "SortName"),
                    .init(name: "SortOrder", value: "Ascending"),
                    .init(name: "StartIndex", value: String(start)),
                    .init(name: "Limit", value: String(Self.pageSize)),
                    .init(name: "Fields", value: Self.itemFields),
                ])
                let page = try await send(req, as: ItemsPage.self)
                guard generation == loadGeneration else { return }
                all.append(contentsOf: page.Items.compactMap { mediaItem(from: $0) })
                if progressive { publish() }
                start += page.Items.count
                let total = page.TotalRecordCount ?? start
                if page.Items.isEmpty || start >= total { break }
            }
            publish()
        } catch is CancellationError {
        } catch {
            errorMessage = "Jellyfin: could not load library: \(error.localizedDescription)"
        }
    }

    private func showItem(from item: JellyfinItem) -> MediaItem? {
        guard let base = baseURL, let token = accessToken else { return nil }
        var poster = URLComponents(url: base.appendingPathComponent("Items/\(item.Id)/Images/Primary"), resolvingAgainstBaseURL: false)!
        poster.queryItems = [.init(name: "maxHeight", value: "450"), .init(name: "quality", value: "90"), .init(name: "api_key", value: token)]
        let count = (item.RecursiveItemCount ?? item.ChildCount).map { "\($0) episode\($0 == 1 ? "" : "s")" }
        var mi = MediaItem(
            id: "jellyfin:show:\(item.Id)", source: .jellyfin, title: item.Name,
            subtitle: [item.ProductionYear.map(String.init), count].compactMap { $0 }.joined(separator: " · "),
            overview: item.Overview, runtimeMinutes: nil, posterURL: poster.url,
            directURL: nil, avPlayerURL: nil, container: nil, videoCodec: nil, audioCodec: nil,
            audioChannels: nil, videoRange: nil, isEpisode: false, width: nil, height: nil, stereo: nil)
        mi.showKey = item.Id
        return mi
    }

    /// Every episode of a series in season/episode order (cached; `refresh` refetches).
    func episodes(showKey key: String, refresh: Bool = false) async throws -> [MediaItem] {
        if !refresh, let cached = episodesByShow[key] { return cached }
        let req = try request("Shows/\(key)/Episodes", query: [
            .init(name: "userId", value: storedUserId),
            .init(name: "Fields", value: Self.itemFields),
        ])
        let page = try await send(req, as: ItemsPage.self)
        let eps = page.Items.compactMap { mediaItem(from: $0) }
            .sorted { ($0.season ?? 0, $0.episodeNumber ?? 0) < ($1.season ?? 0, $1.episodeNumber ?? 0) }
        episodesByShow[key] = eps
        return eps
    }

    func nextEpisode(after item: MediaItem) -> MediaItem? {
        guard let key = item.parentShowKey, let eps = episodesByShow[key],
              let i = eps.firstIndex(where: { $0.id == item.id }), i + 1 < eps.count else { return nil }
        return eps[i + 1]
    }

    private func mediaItem(from item: JellyfinItem) -> MediaItem? {
        guard let base = baseURL, let token = accessToken else { return nil }
        let mediaSource = item.MediaSources?.first
        let streams = mediaSource?.MediaStreams ?? []
        let video = streams.first { $0.Type == "Video" }
        let audio = streams.first { $0.Type == "Audio" && ($0.IsDefault ?? false) } ?? streams.first { $0.Type == "Audio" }
        let container = (mediaSource?.Container ?? item.Container)?.lowercased()

        var poster = URLComponents(url: base.appendingPathComponent("Items/\(item.Id)/Images/Primary"), resolvingAgainstBaseURL: false)!
        poster.queryItems = [.init(name: "maxHeight", value: "450"), .init(name: "quality", value: "90")]

        // Direct play of the original file.
        var direct = URLComponents(url: base.appendingPathComponent("Videos/\(item.Id)/stream"), resolvingAgainstBaseURL: false)!
        direct.queryItems = [
            .init(name: "static", value: "true"),
            .init(name: "mediaSourceId", value: mediaSource?.Id ?? item.Id),
            .init(name: "api_key", value: token),
        ]

        // AVPlayer path: MP4/MOV play directly, everything else is remuxed/transcoded server-side.
        let avFriendly = ["mp4", "m4v", "mov"].contains(container ?? "")
        var av = direct
        if !avFriendly {
            av = URLComponents(url: base.appendingPathComponent("Videos/\(item.Id)/stream.mp4"), resolvingAgainstBaseURL: false)!
            av.queryItems = [
                .init(name: "static", value: "false"),
                .init(name: "mediaSourceId", value: mediaSource?.Id ?? item.Id),
                .init(name: "api_key", value: token),
                .init(name: "DeviceId", value: deviceId),
                .init(name: "Container", value: "mp4"),
                .init(name: "VideoCodec", value: "hevc,h264"),
                .init(name: "AudioCodec", value: "eac3,ac3,aac"),
                .init(name: "MaxAudioChannels", value: "6"),
                .init(name: "AllowVideoStreamCopy", value: "true"),
                .init(name: "AllowAudioStreamCopy", value: "true"),
            ]
        }

        var subtitle: String?
        if item.Type == "Episode", let series = item.SeriesName {
            let s = item.ParentIndexNumber.map { String(format: "S%02d", $0) } ?? ""
            let e = item.IndexNumber.map { String(format: "E%02d", $0) } ?? ""
            subtitle = "\(series) · \(s)\(e)"
        } else if let y = item.ProductionYear {
            subtitle = String(y)
        }

        // External subtitle files the server can deliver as-is.
        var subs: [URL] = []
        for (i, st) in streams.enumerated() where st.Type == "Subtitle" && (st.IsExternal ?? false) {
            let idx = st.Index ?? i
            let ext = (st.Codec ?? "srt").lowercased() == "ass" ? "ass" : "srt"
            var c = URLComponents(url: base.appendingPathComponent("Videos/\(item.Id)/\(mediaSource?.Id ?? item.Id)/Subtitles/\(idx)/Stream.\(ext)"), resolvingAgainstBaseURL: false)!
            c.queryItems = [.init(name: "api_key", value: token)]
            if let u = c.url { subs.append(u) }
        }
        let name = item.Name
        let path = item.Path ?? mediaSource?.Path
        var mi = MediaItem(
            id: "jellyfin:\(item.Id)",
            source: .jellyfin,
            title: item.Name,
            subtitle: subtitle,
            overview: item.Overview,
            runtimeMinutes: item.RunTimeTicks.map { Int($0 / 10_000_000 / 60) },
            posterURL: poster.url,
            directURL: direct.url,
            avPlayerURL: av.url,
            container: container,
            videoCodec: video?.Codec,
            audioCodec: audio?.Codec,
            audioChannels: audio?.Channels,
            videoRange: video?.VideoRangeType ?? video?.VideoRange,
            isEpisode: item.Type == "Episode",
            width: video?.Width,
            height: video?.Height,
            stereo: StereoFormat.fromJellyfin(item.Video3DFormat)
                ?? StereoFormat.detect(name: name, path: path, width: video?.Width, height: video?.Height, codecTag: video?.CodecTag)
        )
        mi.projection = ScreenProjection.detect(name: name, path: path)
        if mi.projection != nil, mi.stereo == nil { mi.stereo = ScreenProjection.detectStereoForVR(name: name, path: path) }
        mi.subtitleURLs = subs
        if item.Type == "Episode" {
            mi.parentShowKey = item.SeriesId
            mi.season = item.ParentIndexNumber
            mi.episodeNumber = item.IndexNumber
        }
        if let ticks = item.UserData?.PlaybackPositionTicks, ticks > 0 { mi.serverResumeSeconds = Double(ticks) / 10_000_000 }
        return mi
    }

    // MARK: - Playback reporting (Continue Watching on the server)

    func reportPlayback(itemId: String, positionSeconds: Double, state: PlaybackReportState) async {
        guard isSignedIn else { return }
        let ticks = Int64(positionSeconds * 10_000_000)
        let path: String
        switch state {
        case .started: path = "Sessions/Playing"
        case .progress: path = "Sessions/Playing/Progress"
        case .stopped: path = "Sessions/Playing/Stopped"
        }
        struct Body: Encodable { let ItemId: String; let PositionTicks: Int64; let IsPaused: Bool; let PlayMethod: String }
        guard let req = try? request(path, method: "POST", body: Body(ItemId: itemId, PositionTicks: ticks, IsPaused: false, PlayMethod: "DirectPlay")) else { return }
        _ = try? await URLSession.shared.data(for: req)
    }
}

// MARK: - Wire models

struct JellyfinItem: Decodable, Sendable {
    let Id: String
    let Name: String
    let `Type`: String?
    let ProductionYear: Int?
    let Overview: String?
    let Container: String?
    let RunTimeTicks: Int64?
    let SeriesName: String?
    let SeriesId: String?
    let ChildCount: Int?
    let RecursiveItemCount: Int?
    let ParentIndexNumber: Int?
    let IndexNumber: Int?
    let Path: String?
    let Video3DFormat: String?
    let UserData: UserData?
    let MediaSources: [MediaSource]?

    struct UserData: Decodable, Sendable {
        let PlaybackPositionTicks: Int64?
        let Played: Bool?
    }

    struct MediaSource: Decodable, Sendable {
        let Id: String?
        let Container: String?
        let Path: String?
        let MediaStreams: [MediaStream]?
    }

    struct MediaStream: Decodable, Sendable {
        let `Type`: String?
        let Codec: String?
        let Channels: Int?
        let Language: String?
        let IsDefault: Bool?
        let VideoRange: String?
        let VideoRangeType: String?
        let Width: Int?
        let Height: Int?
        let CodecTag: String?
        let Index: Int?
        let IsExternal: Bool?
    }
}

private struct ItemsPage: Decodable, Sendable { let Items: [JellyfinItem]; let TotalRecordCount: Int? }
private struct AuthResult: Decodable, Sendable {
    let AccessToken: String
    let User: User
    struct User: Decodable, Sendable { let Id: String; let Name: String? }
}

enum JellyfinError: LocalizedError {
    case noServer, badResponse, http(Int, String)
    var errorDescription: String? {
        switch self {
        case .noServer: return "Enter your Jellyfin server address first."
        case .badResponse: return "Unexpected response from server."
        case .http(let code, let body): return "HTTP \(code) \(body.prefix(200))"
        }
    }
}

struct AnyEncodable: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeFn = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}
