import Foundation
import SwiftUI

/// Plex client: PIN sign-in via plex.tv (no password typed into the app), server discovery
/// through plex.tv resources, then library listing and direct-play URLs from the server.
///
/// Sign-in flow: `beginPinSignIn()` shows a 4-character code; the user enters it at
/// https://plex.tv/link on any device; we poll until the PIN is claimed and keep the token.
@MainActor
final class PlexClient: ObservableObject, MediaServerClient {
    let source: MediaSource = .plex
    private let defaults = UserDefaults.standard
    private let clientId: String

    @Published private var token: String { didSet { defaults.set(token, forKey: "plex.token") } }
    @Published var serverURL: String { didSet { defaults.set(serverURL, forKey: "plex.server") } }
    @Published var serverName: String { didSet { defaults.set(serverName, forKey: "plex.serverName") } }
    /// Per-server token (differs from the account token for servers shared with you).
    @Published private var serverToken: String { didSet { defaults.set(serverToken, forKey: "plex.serverToken") } }

    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var servers: [PlexServer] = []
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    // PIN flow state.
    @Published private(set) var pinCode: String?
    @Published private(set) var isAwaitingPin = false
    private var pinId: Int?
    private var pinTask: Task<Void, Never>?

    init() {
        token = defaults.string(forKey: "plex.token") ?? ""
        serverURL = defaults.string(forKey: "plex.server") ?? ""
        serverName = defaults.string(forKey: "plex.serverName") ?? ""
        serverToken = defaults.string(forKey: "plex.serverToken") ?? ""
        if let id = defaults.string(forKey: "plex.clientId") {
            clientId = id
        } else {
            clientId = UUID().uuidString
            defaults.set(clientId, forKey: "plex.clientId")
        }
    }

    var isSignedIn: Bool { !token.isEmpty }
    var hasServer: Bool { !serverURL.isEmpty }

    private var plexHeaders: [String: String] {
        [
            "Accept": "application/json",
            "X-Plex-Product": "Bass Player",
            "X-Plex-Version": "0.2.0",
            "X-Plex-Client-Identifier": clientId,
            "X-Plex-Platform": "Apple",
            "X-Plex-Device": "Apple",
            "X-Plex-Device-Name": "Bass Player",
        ]
    }

    /// Token to use against the selected media server.
    private var effectiveServerToken: String { serverToken.isEmpty ? token : serverToken }

    private func request(_ url: URL, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        for (k, v) in plexHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let isPlexTV = url.host?.hasSuffix("plex.tv") ?? false
        let t = isPlexTV ? token : effectiveServerToken
        if !t.isEmpty { req.setValue(t, forHTTPHeaderField: "X-Plex-Token") }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PlexError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw PlexError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - PIN sign-in

    func beginPinSignIn() {
        pinTask?.cancel()
        errorMessage = nil
        isAwaitingPin = true
        pinCode = nil
        pinTask = Task { [weak self] in
            guard let self else { return }
            do {
                var comps = URLComponents(string: "https://plex.tv/api/v2/pins")!
                comps.queryItems = [.init(name: "strong", value: "false")]
                let created = try await send(request(comps.url!, method: "POST"), as: PlexPin.self)
                pinId = created.id
                pinCode = created.code
                // Poll until claimed (plex.tv PINs live ~15 minutes).
                for _ in 0..<180 {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .seconds(5))
                    let url = URL(string: "https://plex.tv/api/v2/pins/\(created.id)")!
                    let pin = try await send(request(url), as: PlexPin.self)
                    if let t = pin.authToken, !t.isEmpty {
                        token = t
                        isAwaitingPin = false
                        pinCode = nil
                        await discoverServers()
                        return
                    }
                }
                errorMessage = "Plex code expired. Try again."
            } catch is CancellationError {
            } catch {
                errorMessage = "Plex sign-in failed: \(error.localizedDescription)"
            }
            isAwaitingPin = false
        }
    }

    func cancelPinSignIn() {
        pinTask?.cancel()
        isAwaitingPin = false
        pinCode = nil
    }

    func signOut() {
        pinTask?.cancel()
        token = ""
        serverURL = ""
        serverName = ""
        serverToken = ""
        servers = []
        items = []
    }

    // MARK: - Servers

    func discoverServers() async {
        guard isSignedIn else { return }
        isBusy = true; defer { isBusy = false }
        do {
            var comps = URLComponents(string: "https://plex.tv/api/v2/resources")!
            comps.queryItems = [.init(name: "includeHttps", value: "1"), .init(name: "includeRelay", value: "1")]
            let resources = try await send(request(comps.url!), as: [PlexResource].self)
            servers = resources
                .filter { $0.provides.split(separator: ",").contains("server") }
                .map { r in
                    // Prefer a local (LAN) connection, then any direct, then relay.
                    let conns = r.connections ?? []
                    let best = conns.first { $0.local && !$0.relay } ?? conns.first { !$0.relay } ?? conns.first
                    return PlexServer(id: r.clientIdentifier, name: r.name, uri: best?.uri ?? "", accessToken: r.accessToken, connections: conns.map(\.uri))
                }
                .filter { !$0.uri.isEmpty }
            if serverURL.isEmpty, let first = servers.first {
                select(server: first)
            } else {
                await loadLibrary()
            }
        } catch {
            errorMessage = "Plex: could not list servers: \(error.localizedDescription)"
        }
    }

    func select(server: PlexServer) {
        serverURL = server.uri
        serverName = server.name
        serverToken = server.accessToken ?? ""
        Task { await loadLibrary() }
    }

    // MARK: - Library

    func loadLibrary() async {
        guard isSignedIn, let base = URL(string: serverURL) else { return }
        isBusy = true; defer { isBusy = false }
        errorMessage = nil
        do {
            let sections = try await send(request(base.appendingPathComponent("library/sections")), as: PlexContainer<PlexDirectory>.self)
            var all: [MediaItem] = []
            for dir in sections.MediaContainer.Directory ?? [] {
                guard dir.type == "movie" || dir.type == "show" else { continue }
                var comps = URLComponents(url: base.appendingPathComponent("library/sections/\(dir.key)/all"), resolvingAgainstBaseURL: false)!
                comps.queryItems = [.init(name: "type", value: dir.type == "movie" ? "1" : "4")]   // 1 = movie, 4 = episode
                let page = try await send(request(comps.url!), as: PlexContainer<PlexMetadata>.self)
                for m in page.MediaContainer.Metadata ?? [] {
                    if let item = mediaItem(from: m, base: base) { all.append(item) }
                }
            }
            items = all.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        } catch {
            errorMessage = "Plex: could not load library: \(error.localizedDescription)"
        }
    }

    private func mediaItem(from m: PlexMetadata, base: URL) -> MediaItem? {
        guard let media = m.Media?.first, let part = media.Part?.first else { return nil }
        func tokened(_ path: String) -> URL? {
            guard var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
            comps.queryItems = [.init(name: "X-Plex-Token", value: effectiveServerToken)]
            return comps.url
        }
        let direct = tokened(part.key)
        let poster = m.thumb.flatMap { tokened($0) }

        var subtitle: String?
        if m.type == "episode" {
            let s = m.parentIndex.map { String(format: "S%02d", $0) } ?? ""
            let e = m.index.map { String(format: "E%02d", $0) } ?? ""
            subtitle = "\(m.grandparentTitle ?? "") · \(s)\(e)"
        } else if let y = m.year {
            subtitle = String(y)
        }

        let videoStream = part.Stream?.first { $0.streamType == 1 }
        let audioStream = part.Stream?.first { $0.streamType == 2 && ($0.selected ?? false) } ?? part.Stream?.first { $0.streamType == 2 }
        var range: String? = nil
        if let cp = videoStream?.colorPrimaries, cp.contains("2020") {
            if let tf = videoStream?.colorTrc, tf.contains("arib") { range = "HLG" }
            else if videoStream?.DOVIPresent == true { range = "Dolby Vision" }
            else { range = "HDR10" }
        } else if videoStream?.DOVIPresent == true {
            range = "Dolby Vision"
        }

        return MediaItem(
            id: "plex:\(m.ratingKey)",
            source: .plex,
            title: m.title,
            subtitle: subtitle,
            overview: m.summary,
            runtimeMinutes: m.duration.map { $0 / 60_000 },
            posterURL: poster,
            directURL: direct,
            avPlayerURL: direct,     // Plex transcoding for AVPlayer is not wired; use the FFmpeg backend.
            container: part.container ?? media.container,
            videoCodec: media.videoCodec,
            audioCodec: media.audioCodec,
            audioChannels: media.audioChannels,
            videoRange: range,
            isEpisode: m.type == "episode"
        )
    }
}

// MARK: - Models

struct PlexServer: Identifiable, Hashable {
    let id: String
    let name: String
    let uri: String
    let accessToken: String?
    let connections: [String]
}

private struct PlexPin: Decodable {
    let id: Int
    let code: String
    let authToken: String?
}

private struct PlexResource: Decodable {
    let name: String
    let clientIdentifier: String
    let provides: String
    let accessToken: String?
    let connections: [Connection]?
    struct Connection: Decodable {
        let uri: String
        let local: Bool
        let relay: Bool
    }
}

private struct PlexContainer<T: Decodable>: Decodable {
    let MediaContainer: Inner
    struct Inner: Decodable {
        let Directory: [T]?
        let Metadata: [T]?
    }
}

private struct PlexDirectory: Decodable {
    let key: String
    let title: String
    let type: String
}

private struct PlexMetadata: Decodable {
    let ratingKey: String
    let title: String
    let type: String
    let year: Int?
    let summary: String?
    let thumb: String?
    let duration: Int?
    let grandparentTitle: String?
    let parentIndex: Int?
    let index: Int?
    let Media: [Media]?

    struct Media: Decodable {
        let container: String?
        let videoCodec: String?
        let audioCodec: String?
        let audioChannels: Int?
        let Part: [Part]?
    }
    struct Part: Decodable {
        let key: String
        let container: String?
        let Stream: [Stream]?
    }
    struct Stream: Decodable {
        let streamType: Int
        let codec: String?
        let channels: Int?
        let selected: Bool?
        let colorPrimaries: String?
        let colorTrc: String?
        let DOVIPresent: Bool?
    }
}

enum PlexError: LocalizedError {
    case badResponse, http(Int, String)
    var errorDescription: String? {
        switch self {
        case .badResponse: return "Unexpected response from Plex."
        case .http(let code, let body): return "HTTP \(code) \(body.prefix(200))"
        }
    }
}
