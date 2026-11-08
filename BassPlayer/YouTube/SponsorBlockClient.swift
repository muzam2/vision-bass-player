import Foundation
import CryptoKit

/// SponsorBlock: community-submitted segments to skip (sponsors, intros, self-promo…).
/// Uses the privacy-preserving hashed-prefix lookup so the full video id is never sent.
/// https://wiki.sponsor.ajay.app/w/API_Docs
struct SponsorBlockClient {
    struct Segment: Hashable {
        let start: Double
        let end: Double
        let category: String
    }

    static let defaultCategories = ["sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "music_offtopic"]
    var categories = SponsorBlockClient.defaultCategories
    var baseURL = URL(string: "https://sponsor.ajay.app")!

    func segments(videoId: String) async -> [Segment] {
        let hash = SHA256.hash(data: Data(videoId.utf8)).map { String(format: "%02x", $0) }.joined()
        let prefix = String(hash.prefix(4))
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/skipSegments/\(prefix)"), resolvingAgainstBaseURL: false)!
        let cats = "[" + categories.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        comps.queryItems = [.init(name: "categories", value: cats)]
        guard let url = comps.url else { return [] }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return [] }   // 404 = no segments
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            guard let entry = arr.first(where: { $0["videoID"] as? String == videoId }),
                  let segs = entry["segments"] as? [[String: Any]] else { return [] }
            return segs.compactMap { s in
                guard let times = s["segment"] as? [Double], times.count == 2,
                      let cat = s["category"] as? String,
                      (s["actionType"] as? String ?? "skip") == "skip" else { return nil }
                return Segment(start: times[0], end: times[1], category: cat)
            }
            .sorted { $0.start < $1.start }
        } catch {
            return []
        }
    }
}

/// Runtime helper: given the current playback time, says where to jump to (if inside a segment).
struct SponsorSkipper {
    var segments: [SponsorBlockClient.Segment] = []
    private var lastSkipEnd: Double = -1

    /// Returns a seek target when `time` is inside a segment we haven't just skipped.
    mutating func skipTarget(at time: Double) -> Double? {
        for s in segments where time >= s.start && time < s.end - 0.2 {
            if abs(s.end - lastSkipEnd) < 0.01 { return nil }     // user seeked back into it on purpose
            lastSkipEnd = s.end
            return s.end
        }
        return nil
    }

    mutating func reset() { lastSkipEnd = -1 }
}
