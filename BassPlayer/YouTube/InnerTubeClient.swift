import Foundation

/// Talks to YouTube's internal "InnerTube" API the way NewPipe / yt-dlp / Invidious do:
/// search, trending and the `player` endpoint that returns stream URLs. No API key, no login.
///
/// YouTube changes which clients hand out un-ciphered URLs every few months, so `player`
/// tries a list of client identities in order and uses the first that works. When this breaks,
/// update `Client.playbackOrder` from yt-dlp's `youtube/_base.py` (INNERTUBE_CLIENTS) and
/// `_video.py` (`_DEFAULT_JSLESS_CLIENTS` is the list that works without a JS runtime, as here).
///
/// Every player request carries a visitor id (`VisitorID`); without one YouTube answers
/// "Sign in to confirm you're not a bot".
///
/// Ad-free by construction: the player endpoint returns the media streams only.
struct InnerTubeClient {
    static let endpoint = URL(string: "https://www.youtube.com/youtubei/v1")!

    // MARK: - Client identities

    struct Client {
        let name: String            // clientName
        let version: String         // clientVersion
        let id: Int                 // X-YouTube-Client-Name
        let userAgent: String
        var extra: [String: Any] = [:]
        var thirdPartyEmbed = false

        /// Order of preference for the `player` call (state as of 2026-11, checked against
        /// yt-dlp 2026-10-21 and live responses):
        /// - VISIONOS: yt-dlp's only JS-less default. HLS up to 2160p60 incl. HDR, full-length
        ///   segments without a PO token. Not available for "made for kids" videos.
        /// - IOS: HLS for some videos only; when it has none, its adaptive URLs 403 after ~1 MB
        ///   (PO token enforced), so it is only a fallback.
        /// Dropped: ANDROID_VR (403 on every format since 2026-08), TVHTML5_SIMPLY_EMBEDDED_PLAYER
        /// ("no longer supported"), WEB (needs a PO token).
        static let playbackOrder: [Client] = [visionOS, ios]

        static let visionOS = Client(
            name: "VISIONOS", version: "1.02", id: 101,
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
            extra: ["deviceMake": "Apple", "deviceModel": "RealityDevice17,1", "osName": "visionOS", "osVersion": "26.5.23O471"])

        static let ios = Client(
            name: "IOS", version: "20.10.38", id: 5,
            userAgent: "com.google.ios.youtube/20.10.38 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
            extra: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82"])

        static let web = Client(
            name: "WEB", version: "2.20250312.04.00", id: 1,
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36")

        /// Used for search / browse (doesn't need stream URLs).
        static let browse = web
    }

    // MARK: - Models

    struct Video: Identifiable, Hashable {
        let id: String
        let title: String
        let channel: String?
        let durationText: String?
        let durationSeconds: Int?
        let viewsText: String?
        let thumbnailURL: URL?
    }

    struct Streams {
        let title: String
        let author: String?
        let lengthSeconds: Int?
        let thumbnailURL: URL?
        /// HLS master playlist as YouTube serves it (every variant; what AVPlayer gets).
        let hlsURL: URL?
        /// Local single-variant master (one SDR video variant + its audio) for FFmpeg; see
        /// `HLSVariantPicker`. Nil when the master couldn't be fetched or had nothing usable.
        var ffmpegURL: URL? = nil
        /// e.g. "2160p60 VP9", for the status chip.
        var variantLabel: String? = nil
        /// Best muxed progressive MP4 (video+audio in one file; what AVPlayer + the tap want).
        let progressiveURL: URL?
        let progressiveLabel: String?
        /// Client whose identity the URLs were issued to; requests should reuse its User-Agent.
        let userAgent: String
        let clientName: String
    }

    enum Error: LocalizedError {
        case unplayable(String), noStreams, badResponse
        var errorDescription: String? {
            switch self {
            case .unplayable(let why): return why
            case .noStreams: return "YouTube returned no playable streams for any client."
            case .badResponse: return "Unexpected response from YouTube."
            }
        }
    }

    // MARK: - Requests

    private func request(_ path: String, client: Client, body: [String: Any], visitorData: String? = nil) throws -> URLRequest {
        var comps = URLComponents(url: Self.endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "prettyPrint", value: "false")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("\(client.id)", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("en-GB,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        var clientCtx: [String: Any] = ["clientName": client.name, "clientVersion": client.version, "hl": "en", "gl": "GB"]
        for (k, v) in client.extra { clientCtx[k] = v }
        if let visitorData {
            clientCtx["visitorData"] = visitorData
            req.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        var context: [String: Any] = ["client": clientCtx]
        if client.thirdPartyEmbed {
            context["thirdParty"] = ["embedUrl": "https://www.youtube.com/"]
        }
        var payload = body
        payload["context"] = context
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return req
    }

    private func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw Error.badResponse }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Error.badResponse }
        return json
    }

    // MARK: - Search / browse

    func search(_ query: String) async throws -> [Video] {
        let req = try request("search", client: .browse, body: ["query": query, "params": "EgIQAQ%3D%3D"])   // videos only
        let json = try await send(req)
        return Self.videos(in: json)
    }

    func trending() async throws -> [Video] {
        let req = try request("browse", client: .browse, body: ["browseId": "FEtrending"])
        let json = try await send(req)
        return Self.videos(in: json)
    }

    /// Resolve a pasted URL or bare id to a video id.
    static func videoId(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil { return t }
        guard let url = URL(string: t), let host = url.host?.lowercased() else { return nil }
        if host.contains("youtu.be") { return url.pathComponents.dropFirst().first }
        if host.contains("youtube.com") {
            if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value { return v }
            let parts = url.pathComponents
            if let i = parts.firstIndex(where: { ["shorts", "embed", "live", "v"].contains($0) }), i + 1 < parts.count { return parts[i + 1] }
        }
        return nil
    }

    // MARK: - Player

    /// Stream URLs for a video. `maxHeight` caps the variant picked for FFmpeg.
    func streams(videoId: String, maxHeight: Int = 2160) async throws -> Streams {
        var lastError: Swift.Error = Error.noStreams
        // One retry with a fresh visitor id if every client got the bot check.
        for attempt in 0..<2 {
            let visitor = await VisitorID.shared.get(refresh: attempt > 0)
            var botChecked = false
            for client in Client.playbackOrder {
                do {
                    let req = try request("player", client: client, body: [
                        "videoId": videoId,
                        "contentCheckOk": true,
                        "racyCheckOk": true,
                        "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]],
                    ], visitorData: visitor)
                    let json = try await send(req)
                    if Self.isBotCheck(json) { botChecked = true; continue }
                    guard var s = try Self.parseStreams(json, client: client) else { continue }
                    if let hls = s.hlsURL,
                       let picked = await HLSVariantPicker.localMaster(for: hls, videoId: videoId, userAgent: client.userAgent, maxHeight: maxHeight) {
                        s.ffmpegURL = picked.url
                        s.variantLabel = picked.label
                    }
                    return s
                } catch {
                    lastError = error
                }
            }
            if !botChecked { break }
            lastError = Error.unplayable("YouTube asked to confirm this isn't a bot. Try again in a minute.")
        }
        throw lastError
    }

    /// "Sign in to confirm you're not a bot" — LOGIN_REQUIRED without an age gate.
    private static func isBotCheck(_ json: [String: Any]) -> Bool {
        guard let p = json["playabilityStatus"] as? [String: Any], p["status"] as? String == "LOGIN_REQUIRED" else { return false }
        return (p["reason"] as? String ?? "").localizedCaseInsensitiveContains("bot")
    }

    private static func parseStreams(_ json: [String: Any], client: Client) throws -> Streams? {
        let playability = json["playabilityStatus"] as? [String: Any]
        let status = playability?["status"] as? String ?? "UNKNOWN"
        guard status == "OK" else {
            let reason = playability?["reason"] as? String ?? status
            // Age-gated or login-required: let the next client try.
            if ["LOGIN_REQUIRED", "UNPLAYABLE", "CONTENT_CHECK_REQUIRED", "AGE_CHECK_REQUIRED"].contains(status) { return nil }
            throw Error.unplayable(reason)
        }
        let details = json["videoDetails"] as? [String: Any]
        let streaming = json["streamingData"] as? [String: Any]
        let hls = (streaming?["hlsManifestUrl"] as? String).flatMap(URL.init(string:))

        // Best muxed progressive format with a plain URL (no signatureCipher).
        var bestProgressive: (URL, String, Int)?
        for f in streaming?["formats"] as? [[String: Any]] ?? [] {
            guard let u = f["url"] as? String, let url = URL(string: u) else { continue }
            let mime = (f["mimeType"] as? String ?? "")
            guard mime.hasPrefix("video/mp4") else { continue }
            let h = f["height"] as? Int ?? 0
            if bestProgressive == nil || h > bestProgressive!.2 {
                bestProgressive = (url, f["qualityLabel"] as? String ?? "\(h)p", h)
            }
        }
        guard hls != nil || bestProgressive != nil else { return nil }

        let thumbs = (details?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]] ?? []
        let thumb = (thumbs.last?["url"] as? String).flatMap(URL.init(string:))
        return Streams(
            title: details?["title"] as? String ?? "YouTube",
            author: details?["author"] as? String,
            lengthSeconds: (details?["lengthSeconds"] as? String).flatMap(Int.init),
            thumbnailURL: thumb,
            hlsURL: hls,
            progressiveURL: bestProgressive?.0,
            progressiveLabel: bestProgressive?.1,
            userAgent: client.userAgent,
            clientName: client.name
        )
    }

    // MARK: - JSON walking

    /// Finds every `videoRenderer` anywhere in a response. Layouts change often; this doesn't care.
    private static func videos(in json: Any) -> [Video] {
        var out: [Video] = []
        var seen = Set<String>()
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let vr = dict["videoRenderer"] as? [String: Any] ?? dict["compactVideoRenderer"] as? [String: Any],
                   let id = vr["videoId"] as? String, !seen.contains(id) {
                    seen.insert(id)
                    out.append(Video(
                        id: id,
                        title: text(vr["title"]) ?? "Untitled",
                        channel: text(vr["ownerText"]) ?? text(vr["longBylineText"]) ?? text(vr["shortBylineText"]),
                        durationText: text(vr["lengthText"]),
                        durationSeconds: seconds(text(vr["lengthText"])),
                        viewsText: text(vr["shortViewCountText"]) ?? text(vr["viewCountText"]),
                        thumbnailURL: ((vr["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]])?.last?["url"]
                            .flatMap { $0 as? String }.flatMap(URL.init(string:))
                    ))
                }
                for v in dict.values { walk(v) }
            } else if let arr = node as? [Any] {
                for v in arr { walk(v) }
            }
        }
        walk(json)
        return out
    }

    /// InnerTube text objects are either {"simpleText": "..."} or {"runs": [{"text": "..."}]}.
    private static func text(_ node: Any?) -> String? {
        guard let d = node as? [String: Any] else { return nil }
        if let s = d["simpleText"] as? String { return s }
        if let runs = d["runs"] as? [[String: Any]] {
            let s = runs.compactMap { $0["text"] as? String }.joined()
            return s.isEmpty ? nil : s
        }
        return nil
    }

    private static func seconds(_ t: String?) -> Int? {
        guard let t else { return nil }
        let parts = t.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
