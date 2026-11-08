import Foundation

/// The visitor id ("visitorData") YouTube gives every browser on its first page load. Player
/// requests without one get "Sign in to confirm you're not a bot"; with one, the VISIONOS
/// client answers normally. Fetched from the home page (same as yt-dlp's webpage step),
/// cached for a week, refreshed when YouTube bot-checks anyway.
actor VisitorID {
    static let shared = VisitorID()

    private var value: String?
    private var fetchedAt: Date?
    private static let valueKey = "yt.visitorData"
    private static let dateKey = "yt.visitorDataDate"

    init() {
        value = UserDefaults.standard.string(forKey: Self.valueKey)
        fetchedAt = UserDefaults.standard.object(forKey: Self.dateKey) as? Date
    }

    func get(refresh: Bool = false) async -> String? {
        if !refresh, let value, let fetchedAt, Date().timeIntervalSince(fetchedAt) < 7 * 86_400 { return value }
        guard let fresh = await Self.fetch() else { return value }
        value = fresh
        fetchedAt = Date()
        UserDefaults.standard.set(fresh, forKey: Self.valueKey)
        UserDefaults.standard.set(fetchedAt, forKey: Self.dateKey)
        return fresh
    }

    private static func fetch() async -> String? {
        var req = URLRequest(url: URL(string: "https://www.youtube.com/")!)
        req.setValue(InnerTubeClient.Client.visionOS.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-GB,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return HLSVariantPicker.firstCapture(#""VISITOR_DATA":"([^"]+)""#, in: html)
    }
}

/// Turns YouTube's HLS master (~30 variants) into a local master with exactly one video
/// variant and its audio rendition, for FFmpeg.
///
/// Why not hand FFmpeg the master directly:
/// - FFmpeg 6.1 opens every variant while probing (slow start: the 4K ones are ~25 MB a segment).
/// - HDR (PQ) variants carry both `mdcv` and `SmDm` boxes in the init segment, which FFmpeg 6.1
///   rejects as invalid data (fixed in FFmpeg 7.1), and one bad variant fails the whole open.
///   So only SDR variants are picked until FFmpegKit is rebuilt with that fix.
/// AV1 is skipped: neither the Vision Pro (M2) nor the Apple TV decodes it in hardware.
///
/// The local file needs `protocol_whitelist` to include https (set in `FFmpegSession`). FFmpeg
/// then requests segments with its own User-Agent; googlevideo accepts that for HLS.
enum HLSVariantPicker {
    struct Picked {
        let url: URL
        let label: String
    }

    static func localMaster(for master: URL, videoId: String, userAgent: String, maxHeight: Int) async -> Picked? {
        var req = URLRequest(url: master)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8),
              let picked = pick(master: text, maxHeight: maxHeight) else { return nil }

        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("youtube-hls", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeId = videoId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let file = dir.appendingPathComponent("\(safeId).m3u8")
        do {
            try picked.playlist.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return Picked(url: file, label: picked.label)
    }

    /// Pure part, kept separate so it is easy to reason about: returns the new master text.
    static func pick(master: String, maxHeight: Int) -> (playlist: String, label: String)? {
        let lines = master.components(separatedBy: .newlines)
        struct Candidate { let height: Int; let fps: Double; let avc: Bool; let bandwidth: Int; let inf: String; let uri: String; let audio: String?; let codecs: String }
        var best: Candidate?
        for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") && i + 1 < lines.count {
            let attrs = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
            let codecs = attribute("CODECS", in: attrs) ?? ""
            let range = attribute("VIDEO-RANGE", in: attrs) ?? "SDR"
            guard range == "SDR", !codecs.contains("av01") else { continue }
            let size = (attribute("RESOLUTION", in: attrs) ?? "0x0").split(separator: "x").compactMap { Int($0) }
            let height = size.count == 2 ? size[1] : 0
            guard height > 0, height <= maxHeight else { continue }
            let uri = lines[i + 1].trimmingCharacters(in: .whitespaces)
            guard !uri.isEmpty, !uri.hasPrefix("#") else { continue }
            let c = Candidate(
                height: height,
                fps: Double(attribute("FRAME-RATE", in: attrs) ?? "") ?? 0,
                avc: codecs.hasPrefix("avc1"),          // at equal size H.264 wins: guaranteed hardware decode
                bandwidth: Int(attribute("BANDWIDTH", in: attrs) ?? "") ?? 0,
                inf: line, uri: uri, audio: attribute("AUDIO", in: attrs), codecs: codecs)
            if let b = best {
                let better = (c.height, c.fps, c.avc ? 1 : 0, c.bandwidth) > (b.height, b.fps, b.avc ? 1 : 0, b.bandwidth)
                if better { best = c }
            } else {
                best = c
            }
        }
        guard let best else { return nil }

        var out = ["#EXTM3U", "#EXT-X-INDEPENDENT-SEGMENTS"]
        if let group = best.audio {
            let renditions = lines.filter { $0.hasPrefix("#EXT-X-MEDIA:") && $0.contains("TYPE=AUDIO") && $0.contains("GROUP-ID=\"\(group)\"") }
            if let audio = renditions.first(where: { $0.contains("DEFAULT=YES") }) ?? renditions.first {
                out.append(audio)
            }
        }
        out.append(best.inf)
        out.append(best.uri)

        let codec = best.codecs.hasPrefix("avc1") ? "H.264" : best.codecs.hasPrefix("vp09") ? "VP9" : (best.codecs.split(separator: ".").first.map(String.init) ?? "?")
        let fps = best.fps > 31 ? "\(Int(best.fps.rounded()))" : ""
        return (out.joined(separator: "\n") + "\n", "\(best.height)p\(fps) \(codec)")
    }

    /// Value of `KEY=value` or `KEY="value"` in an HLS attribute list.
    static func attribute(_ key: String, in attrs: String) -> String? {
        if let quoted = firstCapture("(?:^|,)\(key)=\"([^\"]*)\"", in: attrs) { return quoted }
        return firstCapture("(?:^|,)\(key)=([^,]*)", in: attrs)
    }

    static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
