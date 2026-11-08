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
    /// Episodes fetched per series (`showKey`), for the series page and autoplay-next.
    @Published private(set) var episodesByShow: [String: [MediaItem]] = [:]
    /// Bumped by each library load so a superseded load stops publishing.
    private var loadGeneration = 0

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
        // CI end-to-end tests can't complete the plex.tv/link PIN flow; they inject a token.
        // (After all stored properties are set, so `token` may be read.)
        if token.isEmpty, let t = ProcessInfo.processInfo.environment["BASSPLAYER_PLEX_TOKEN"], !t.isEmpty {
            token = t
        }
    }

    var isSignedIn: Bool { demoMode || !token.isEmpty }
    var hasServer: Bool { demoMode || !serverURL.isEmpty }

    /// Simulator screenshots: show sample items without plex.tv (see DemoData).
    private(set) var demoMode = false
    func enableDemo(items: [MediaItem], serverName: String) {
        demoMode = true
        self.serverName = serverName
        self.items = items
    }

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

    /// Nonisolated so that decoding (megabytes of JSON for a big library) happens off the main
    /// thread; decoding on the main actor froze the UI.
    nonisolated private func send<T: Decodable & Sendable>(_ req: URLRequest, as: T.Type) async throws -> T {
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
                    // Preference order: LAN, then any direct, then relay. Which one is actually
                    // reachable is decided by probing in connect(to:); plex.tv's "local" flag
                    // also covers Docker-internal and stale addresses.
                    let conns = r.connections ?? []
                    let ordered = conns.filter { $0.local && !$0.relay } + conns.filter { !$0.local && !$0.relay } + conns.filter(\.relay)
                    // Each LAN https://a-b-c-d.<id>.plex.direct address also gets a plain
                    // http://a.b.c.d:port twin: routers with DNS-rebinding protection (OpenWrt's
                    // default) refuse to resolve plex.direct names to private IPs.
                    var uris: [String] = []
                    for c in ordered {
                        uris.append(c.uri)
                        if c.local, !c.relay, c.IPv6 != true, let ip = c.address, let port = c.port {
                            uris.append("http://\(ip):\(port)")
                        }
                    }
                    var seen = Set<String>()
                    uris = uris.filter { seen.insert($0).inserted }
                    return PlexServer(id: r.clientIdentifier, name: r.name, uri: uris.first ?? "", accessToken: r.accessToken, connections: uris)
                }
                .filter { !$0.uri.isEmpty }
            let current = servers.first { $0.name == serverName } ?? servers.first
            if let current {
                await connect(to: current)
            }
        } catch {
            errorMessage = "Plex: could not list servers: \(error.localizedDescription)"
        }
    }

    func select(server: PlexServer) {
        Task { await connect(to: server) }
    }

    /// Probe every connection of the server at once and use the first, in preference order,
    /// that answers /identity. Fixes "no route to host" from an unreachable advertised address.
    func connect(to server: PlexServer) async {
        serverName = server.name
        serverToken = server.accessToken ?? ""
        let candidates = server.connections.isEmpty ? [server.uri] : server.connections
        let reachable = await withTaskGroup(of: (Int, Bool).self) { group in
            for (i, uri) in candidates.enumerated() {
                group.addTask { (i, await Self.answers(uri)) }
            }
            var ok = Set<Int>()
            for await (i, up) in group where up { ok.insert(i) }
            return ok
        }
        guard let index = candidates.indices.first(where: reachable.contains) else {
            let hosts = candidates.compactMap { URL(string: $0)?.host }.joined(separator: ", ")
            errorMessage = "Plex: \(server.name) didn't answer on any of its addresses (\(hosts))."
            return
        }
        serverURL = candidates[index]
        await loadLibrary(rediscoverOnNetworkError: false)
    }

    nonisolated private static func answers(_ uri: String) async -> Bool {
        guard let url = URL(string: uri)?.appendingPathComponent("identity") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = "GET"
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse).map { (200..<500).contains($0.statusCode) } ?? false
    }

    // MARK: - Library

    /// MediaServerClient entry point (protocol requirements can't carry default arguments).
    func loadLibrary() async {
        await loadLibrary(rediscoverOnNetworkError: true)
    }

    /// Series are listed as one card each (episodes load when a series is opened) and movies
    /// arrive in pages that are shown as they land. The old single request for every episode
    /// of every show was 134 MB of JSON on the owner's server: the spinner never ended.
    func loadLibrary(rediscoverOnNetworkError: Bool) async {
        guard isSignedIn, !demoMode, let base = URL(string: serverURL) else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isBusy = true
        defer { if generation == loadGeneration { isBusy = false } }
        errorMessage = nil
        // A refresh keeps the current grid until the new list is complete; a first load
        // shows each page as it arrives.
        let progressive = items.isEmpty
        do {
            let sections = try await send(request(base.appendingPathComponent("library/sections")), as: PlexContainer<PlexDirectory>.self)
            let dirs = (sections.MediaContainer.Directory ?? []).filter { $0.type == "movie" || $0.type == "show" }
            var all: [MediaItem] = []
            func publish() {
                guard generation == loadGeneration else { return }
                items = all.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            }
            // Series first: one small request per section, and the grid fills in under a second.
            for dir in dirs.sorted(by: { ($0.type == "show" ? 0 : 1) < ($1.type == "show" ? 0 : 1) }) {
                let isShow = dir.type == "show"
                var start = 0
                while true {
                    try Task.checkCancellation()
                    guard generation == loadGeneration else { return }
                    let url = Self.listURL(base: base, section: dir.key, type: isShow ? 2 : 1, start: start, size: Self.pageSize)
                    let page = try await send(request(url), as: PlexContainer<PlexMetadata>.self)
                    let metas = page.MediaContainer.Metadata ?? []
                    for m in metas {
                        if let item = isShow ? showItem(from: m, base: base) : mediaItem(from: m, base: base) { all.append(item) }
                    }
                    if progressive { publish() }
                    start += metas.count
                    let total = page.MediaContainer.totalSize ?? start
                    if metas.isEmpty || start >= total { break }
                }
            }
            publish()
        } catch is CancellationError {
        } catch {
            // A saved address can go stale (server moved, Docker IP, VPN off): re-probe once.
            if rediscoverOnNetworkError, error is URLError {
                isBusy = false
                await discoverServers()
                return
            }
            errorMessage = "Plex: could not load library: \(error.localizedDescription)"
        }
    }

    nonisolated static let pageSize = 500

    /// `/library/sections/<key>/all` for one page, title-sorted, without the cast/genre/etc.
    /// elements the app never shows.
    nonisolated private static func listURL(base: URL, section: String, type: Int, start: Int, size: Int) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent("library/sections/\(section)/all"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "type", value: String(type)),          // 1 = movie, 2 = show
            .init(name: "sort", value: "titleSort"),
            .init(name: "includeGuids", value: "0"),
            .init(name: "excludeElements", value: "Genre,Country,Director,Writer,Role,Collection,Label,Producer,Similar,Field,Image,UltraBlurColors,Guid"),
            .init(name: "X-Plex-Container-Start", value: String(start)),
            .init(name: "X-Plex-Container-Size", value: String(size)),
        ]
        return comps.url!
    }

    private func tokened(_ path: String, base: URL) -> URL? {
        guard var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        comps.queryItems = [.init(name: "X-Plex-Token", value: effectiveServerToken)]
        return comps.url
    }

    private func showItem(from m: PlexMetadata, base: URL) -> MediaItem? {
        guard m.type == "show" else { return nil }
        let count = m.leafCount.map { "\($0) episode\($0 == 1 ? "" : "s")" }
        var mi = MediaItem(
            id: "plex:show:\(m.ratingKey)", source: .plex, title: m.title,
            subtitle: [m.year.map(String.init), count].compactMap { $0 }.joined(separator: " · "),
            overview: m.summary, runtimeMinutes: nil, posterURL: m.thumb.flatMap { tokened($0, base: base) },
            directURL: nil, avPlayerURL: nil, container: nil, videoCodec: nil, audioCodec: nil,
            audioChannels: nil, videoRange: nil, isEpisode: false, width: nil, height: nil, stereo: nil)
        mi.showKey = m.ratingKey
        return mi
    }

    /// Every episode of a series in season/episode order (cached; refetched on `refresh`).
    func episodes(of show: MediaItem, refresh: Bool = false) async throws -> [MediaItem] {
        guard let key = show.showKey ?? show.parentShowKey else { return [] }
        return try await episodes(showKey: key, refresh: refresh)
    }

    func episodes(showKey key: String, refresh: Bool = false) async throws -> [MediaItem] {
        if !refresh, let cached = episodesByShow[key] { return cached }
        guard let base = URL(string: serverURL) else { return [] }
        var comps = URLComponents(url: base.appendingPathComponent("library/metadata/\(key)/allLeaves"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "includeGuids", value: "0")]
        let page = try await send(request(comps.url!), as: PlexContainer<PlexMetadata>.self)
        let eps = (page.MediaContainer.Metadata ?? []).compactMap { mediaItem(from: $0, base: base) }
        episodesByShow[key] = eps
        return eps
    }

    /// The episode after `item` in its series, if that series' episodes have been fetched.
    func nextEpisode(after item: MediaItem) -> MediaItem? {
        guard let key = item.parentShowKey, let eps = episodesByShow[key],
              let i = eps.firstIndex(where: { $0.id == item.id }), i + 1 < eps.count else { return nil }
        return eps[i + 1]
    }

    private func mediaItem(from m: PlexMetadata, base: URL) -> MediaItem? {
        guard let media = m.Media?.first, let part = media.Part?.first else { return nil }
        func tokened(_ path: String) -> URL? { self.tokened(path, base: base) }
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

        var subs: [URL] = []
        for st in part.Stream ?? [] where st.streamType == 3 {
            if let k = st.key, let u = tokened(k) { subs.append(u) }
        }
        var mi = MediaItem(
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
            isEpisode: m.type == "episode",
            width: media.width,
            height: media.height,
            stereo: StereoFormat.detect(name: m.title, path: part.file, width: media.width, height: media.height, codecTag: nil)
        )
        mi.projection = ScreenProjection.detect(name: m.title, path: part.file)
        if mi.projection != nil, mi.stereo == nil { mi.stereo = ScreenProjection.detectStereoForVR(name: m.title, path: part.file) }
        mi.subtitleURLs = subs
        if m.type == "episode" {
            mi.parentShowKey = m.grandparentRatingKey
            mi.season = m.parentIndex
            mi.episodeNumber = m.index
        }
        if let vo = m.viewOffset, vo > 0 { mi.serverResumeSeconds = Double(vo) / 1000 }
        return mi
    }

    // MARK: - Playback reporting (On Deck / resume on the server)

    func reportPlayback(ratingKey: String, positionSeconds: Double, durationSeconds: Double, state: PlaybackReportState) async {
        guard isSignedIn, let base = URL(string: serverURL) else { return }
        var comps = URLComponents(url: base.appendingPathComponent(":/timeline"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "ratingKey", value: ratingKey),
            .init(name: "key", value: "/library/metadata/\(ratingKey)"),
            .init(name: "state", value: state == .stopped ? "stopped" : "playing"),
            .init(name: "time", value: "\(Int(positionSeconds * 1000))"),
            .init(name: "duration", value: "\(Int(durationSeconds * 1000))"),
        ]
        guard let url = comps.url else { return }
        _ = try? await URLSession.shared.data(for: request(url))
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

private struct PlexPin: Decodable, Sendable {
    let id: Int
    let code: String
    let authToken: String?
}

private struct PlexResource: Decodable, Sendable {
    let name: String
    let clientIdentifier: String
    let provides: String
    let accessToken: String?
    let connections: [Connection]?
    struct Connection: Decodable, Sendable {
        let uri: String
        let local: Bool
        let relay: Bool
        let address: String?
        let port: Int?
        let IPv6: Bool?
    }
}

private struct PlexContainer<T: Decodable & Sendable>: Decodable, Sendable {
    let MediaContainer: Inner
    struct Inner: Decodable, Sendable {
        let Directory: [T]?
        let Metadata: [T]?
        let totalSize: Int?
    }
}

private struct PlexDirectory: Decodable, Sendable {
    let key: String
    let title: String
    let type: String
}

private struct PlexMetadata: Decodable, Sendable {
    let ratingKey: String
    let title: String
    let type: String
    let year: Int?
    let summary: String?
    let thumb: String?
    let duration: Int?
    let grandparentTitle: String?
    let grandparentRatingKey: String?
    let leafCount: Int?
    let parentIndex: Int?
    let index: Int?
    let viewOffset: Int?
    let Media: [Media]?

    struct Media: Decodable, Sendable {
        let container: String?
        let videoCodec: String?
        let audioCodec: String?
        let audioChannels: Int?
        let width: Int?
        let height: Int?
        let Part: [Part]?
    }
    struct Part: Decodable, Sendable {
        let key: String
        let file: String?
        let container: String?
        let Stream: [Stream]?
    }
    struct Stream: Decodable, Sendable {
        let streamType: Int
        let key: String?
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
