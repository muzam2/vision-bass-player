import Foundation
import SwiftUI

/// Minimal Jellyfin REST client: sign in, list movies, build a playable stream URL.
/// Jellyfin API reference: https://api.jellyfin.org
@MainActor
final class JellyfinClient: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var serverURL: String { didSet { defaults.set(serverURL, forKey: "jf.server") } }
    @Published var username: String { didSet { defaults.set(username, forKey: "jf.username") } }
    @Published private var storedToken: String { didSet { defaults.set(storedToken, forKey: "jf.token") } }
    @Published private var storedUserId: String { didSet { defaults.set(storedUserId, forKey: "jf.userId") } }
    private let deviceId: String

    @Published private(set) var items: [JellyfinItem] = []
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    init() {
        serverURL = defaults.string(forKey: "jf.server") ?? ""
        username = defaults.string(forKey: "jf.username") ?? ""
        storedToken = defaults.string(forKey: "jf.token") ?? ""
        storedUserId = defaults.string(forKey: "jf.userId") ?? ""
        // Pin the device id so Jellyfin sees one device across launches.
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

    /// Jellyfin's `Authorization: MediaBrowser ...` header.
    private var authorizationHeader: String {
        var h = "MediaBrowser Client=\"BassPlayer\", Device=\"Apple Vision Pro\", DeviceId=\"\(deviceId)\", Version=\"0.1.0\""
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
            await loadMovies()
        } catch {
            errorMessage = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    func signOut() {
        storedToken = ""
        storedUserId = ""
        items = []
    }

    // MARK: - Library

    func loadMovies() async {
        guard isSignedIn else { return }
        isBusy = true; defer { isBusy = false }
        errorMessage = nil
        do {
            let req = try request("Users/\(storedUserId)/Items", query: [
                .init(name: "IncludeItemTypes", value: "Movie"),
                .init(name: "Recursive", value: "true"),
                .init(name: "SortBy", value: "SortName"),
                .init(name: "SortOrder", value: "Ascending"),
                .init(name: "Fields", value: "MediaSources,Overview,ProductionYear,RunTimeTicks"),
            ])
            let page = try await send(req, as: ItemsPage.self)
            items = page.Items
        } catch {
            errorMessage = "Could not load library: \(error.localizedDescription)"
        }
    }

    func posterURL(for item: JellyfinItem, maxHeight: Int = 450) -> URL? {
        guard let base = baseURL else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("Items/\(item.Id)/Images/Primary"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "maxHeight", value: "\(maxHeight)"), .init(name: "quality", value: "90")]
        return comps.url
    }

    /// Phase 1 uses AVPlayer, which only handles MP4/MOV containers with H.264/HEVC + AAC/AC-3/E-AC-3.
    /// Anything else is remuxed/transcoded by the server into a progressive MP4.
    /// (Phase 2, KSPlayer/FFmpeg, will always direct-play the original file.)
    func streamURL(for item: JellyfinItem) -> URL? {
        guard let base = baseURL, let token = accessToken else { return nil }
        let source = item.MediaSources?.first
        let container = (source?.Container ?? item.Container ?? "").lowercased()
        let avPlayerFriendly = ["mp4", "m4v", "mov"].contains(container)

        var comps: URLComponents
        if avPlayerFriendly {
            comps = URLComponents(url: base.appendingPathComponent("Videos/\(item.Id)/stream"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [
                .init(name: "static", value: "true"),
                .init(name: "mediaSourceId", value: source?.Id ?? item.Id),
                .init(name: "api_key", value: token),
            ]
        } else {
            comps = URLComponents(url: base.appendingPathComponent("Videos/\(item.Id)/stream.mp4"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [
                .init(name: "static", value: "false"),
                .init(name: "mediaSourceId", value: source?.Id ?? item.Id),
                .init(name: "api_key", value: token),
                .init(name: "DeviceId", value: deviceId),
                .init(name: "Container", value: "mp4"),
                .init(name: "VideoCodec", value: "hevc,h264"),
                .init(name: "AudioCodec", value: "eac3,ac3,aac"),
                .init(name: "MaxAudioChannels", value: "6"),
                .init(name: "TranscodingMaxAudioChannels", value: "6"),
                .init(name: "AllowVideoStreamCopy", value: "true"),
                .init(name: "AllowAudioStreamCopy", value: "true"),
            ]
        }
        return comps.url
    }
}

// MARK: - Models

struct JellyfinItem: Decodable, Identifiable, Hashable {
    let Id: String
    let Name: String
    let ProductionYear: Int?
    let Overview: String?
    let Container: String?
    let RunTimeTicks: Int64?
    let MediaSources: [MediaSource]?

    var id: String { Id }

    var runtimeText: String? {
        guard let ticks = RunTimeTicks else { return nil }
        let minutes = Int(ticks / 10_000_000 / 60)
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    struct MediaSource: Decodable, Hashable {
        let Id: String?
        let Container: String?
        let MediaStreams: [MediaStream]?
    }

    struct MediaStream: Decodable, Hashable {
        let `Type`: String?
        let Codec: String?
        let Channels: Int?
        let Language: String?
    }

    static func == (lhs: JellyfinItem, rhs: JellyfinItem) -> Bool { lhs.Id == rhs.Id }
    func hash(into hasher: inout Hasher) { hasher.combine(Id) }
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

private struct AnyEncodable: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeFn = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}
