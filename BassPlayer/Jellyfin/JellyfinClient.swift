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

    var isSignedIn: Bool { !storedToken.isEmpty && !storedUserId.isEmpty }
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

    private func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
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

    func loadLibrary() async {
        guard isSignedIn else { return }
        isBusy = true; defer { isBusy = false }
        errorMessage = nil
        do {
            let req = try request("Users/\(storedUserId)/Items", query: [
                .init(name: "IncludeItemTypes", value: "Movie,Episode"),
                .init(name: "Recursive", value: "true"),
                .init(name: "SortBy", value: "SortName"),
                .init(name: "SortOrder", value: "Ascending"),
                .init(name: "Fields", value: "MediaSources,MediaStreams,Overview,ProductionYear,RunTimeTicks,SeriesName,ParentIndexNumber,IndexNumber"),
            ])
            let page = try await send(req, as: ItemsPage.self)
            items = page.Items.compactMap { mediaItem(from: $0) }
        } catch {
            errorMessage = "Jellyfin: could not load library: \(error.localizedDescription)"
        }
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

        return MediaItem(
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
            isEpisode: item.Type == "Episode"
        )
    }
}

// MARK: - Wire models

struct JellyfinItem: Decodable {
    let Id: String
    let Name: String
    let `Type`: String?
    let ProductionYear: Int?
    let Overview: String?
    let Container: String?
    let RunTimeTicks: Int64?
    let SeriesName: String?
    let ParentIndexNumber: Int?
    let IndexNumber: Int?
    let MediaSources: [MediaSource]?

    struct MediaSource: Decodable {
        let Id: String?
        let Container: String?
        let MediaStreams: [MediaStream]?
    }

    struct MediaStream: Decodable {
        let `Type`: String?
        let Codec: String?
        let Channels: Int?
        let Language: String?
        let IsDefault: Bool?
        let VideoRange: String?
        let VideoRangeType: String?
    }
}

private struct ItemsPage: Decodable { let Items: [JellyfinItem] }
private struct AuthResult: Decodable {
    let AccessToken: String
    let User: User
    struct User: Decodable { let Id: String; let Name: String? }
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
