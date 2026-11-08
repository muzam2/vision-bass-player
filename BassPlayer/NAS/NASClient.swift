import Foundation
import Security
import SwiftUI

/// A saved NAS share: SMB (libsmb2 behind the loopback `SMBBridge`) or WebDAV / plain HTTP
/// directory index.
struct NASShare: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case smb, webdav
        var id: String { rawValue }
        var label: String { self == .smb ? "SMB" : "WebDAV / HTTP" }
    }
    var id = UUID()
    var name: String
    var kind: Kind
    /// SMB: `host` or `host/share`. WebDAV: full base URL `https://nas:5006/video`.
    var address: String
    var username: String
    var domain: String = ""
    // Password lives in the Keychain under `id`.
}

struct NASEntry: Identifiable, Hashable {
    let name: String
    let isDirectory: Bool
    let size: Int64
    /// Path relative to the share root, components joined by "/".
    let path: String
    var id: String { path }

    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "ts", "m2ts", "mts", "mpg", "mpeg", "wmv", "webm", "flv", "vob", "iso", "ssif", "mk3d", "3gp", "rmvb", "ogv",
    ]
    var isVideo: Bool { !isDirectory && Self.videoExtensions.contains((name as NSString).pathExtension.lowercased()) }
}

/// Browses saved shares and turns files into playable `MediaItem`s.
@MainActor
final class NASClient: ObservableObject {
    private let defaults = UserDefaults.standard
    @Published private(set) var shares: [NASShare] { didSet { save() } }
    @Published var errorMessage: String?

    init() {
        if let data = UserDefaults.standard.data(forKey: "nas.shares"),
           let decoded = try? JSONDecoder().decode([NASShare].self, from: data) {
            shares = decoded
        } else {
            shares = []
        }
        publishToBridge()
        if shares.isEmpty, let host = ProcessInfo.processInfo.environment["BASSPLAYER_E2E_NAS_HOST"], !host.isEmpty {
            shares = [NASShare(name: "CI", kind: .smb, address: host, username: "")]
        }
    }

    /// The bridge serves files off the main actor, so it keeps its own copy of the shares.
    private func publishToBridge() {
        SMBBridge.shared.update(shares.filter { $0.kind == .smb }.map { ($0, password(for: $0)) })
    }

    private func save() {
        publishToBridge()
        if let data = try? JSONEncoder().encode(shares) { defaults.set(data, forKey: "nas.shares") }
    }

    // MARK: - Shares

    func add(_ share: NASShare, password: String) {
        Keychain.set(password, for: share.id.uuidString)
        shares.append(share)
    }

    func update(_ share: NASShare, password: String?) {
        if let password { Keychain.set(password, for: share.id.uuidString) }
        if let i = shares.firstIndex(where: { $0.id == share.id }) { shares[i] = share }
    }

    func remove(_ share: NASShare) {
        Keychain.delete(share.id.uuidString)
        shares.removeAll { $0.id == share.id }
    }

    func password(for share: NASShare) -> String { Keychain.get(share.id.uuidString) ?? "" }

    // MARK: - Browsing

    func list(share: NASShare, path: String) async throws -> [NASEntry] {
        switch share.kind {
        case .smb:
            return try await SMBBridge.shared.list(shareID: share.id, path: path)
        case .webdav:
            return try await WebDAVLister(share: share, password: password(for: share)).list(path: path)
        }
    }

    /// Playable item for a file. SMB files come through the loopback bridge, so both backends
    /// can open them; WebDAV with basic auth still needs FFmpeg.
    func mediaItem(share: NASShare, entry: NASEntry) -> MediaItem {
        let url: URL?
        switch share.kind {
        case .smb: url = SMBBridge.shared.url(shareID: share.id, path: entry.path)
        case .webdav: url = WebDAVLister(share: share, password: password(for: share)).fileURL(path: entry.path)
        }
        let title = (entry.name as NSString).deletingPathExtension
        var mi = MediaItem(
            id: "nas:\(share.id.uuidString):\(entry.path)", source: .nas, title: title,
            subtitle: "\(share.name) · \(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))",
            overview: nil, runtimeMinutes: nil, posterURL: nil,
            directURL: url, avPlayerURL: share.kind == .smb ? url : nil,
            container: (entry.name as NSString).pathExtension.lowercased(), videoCodec: nil, audioCodec: nil, audioChannels: nil, videoRange: nil,
            isEpisode: false, width: nil, height: nil,
            stereo: StereoFormat.detect(name: entry.name, path: entry.path, width: nil, height: nil, codecTag: nil),
            needsResolve: false, youtubeId: nil, userAgent: nil
        )
        mi.projection = ScreenProjection.detect(name: entry.name, path: entry.path)
        if mi.projection != nil, mi.stereo == nil { mi.stereo = ScreenProjection.detectStereoForVR(name: entry.name, path: entry.path) }
        return mi
    }

    // MARK: - URLs
}

private func join(_ base: String, _ name: String) -> String {
    base.isEmpty ? name : base + "/" + name
}

// MARK: - WebDAV / HTTP index

/// PROPFIND (depth 1) for WebDAV; falls back to scraping `<a href>` from an autoindex page.
struct WebDAVLister {
    let share: NASShare
    let password: String

    private var baseURL: URL? {
        var s = share.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("http") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    private func authHeader() -> String? {
        guard !share.username.isEmpty else { return nil }
        let raw = Data("\(share.username):\(password)".utf8).base64EncodedString()
        return "Basic \(raw)"
    }

    func fileURL(path: String) -> URL? {
        guard let base = baseURL else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !share.username.isEmpty {
            comps?.user = share.username
            comps?.password = password
        }
        return comps?.url
    }

    func list(path: String) async throws -> [NASEntry] {
        guard let base = baseURL else { throw URLError(.badURL) }
        let dirURL = path.isEmpty ? base : base.appendingPathComponent(path)
        var req = URLRequest(url: dirURL.appendingPathComponent(""))   // trailing slash
        req.httpMethod = "PROPFIND"
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        if let a = authHeader() { req.setValue(a, forHTTPHeaderField: "Authorization") }
        req.httpBody = Data("""
        <?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>
        """.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 207 {
            return parsePropfind(data, dirPath: path)
        }
        // Not WebDAV: try a plain GET and scrape links (nginx/Apache autoindex, Jellyfin/Plex don't apply).
        var get = URLRequest(url: dirURL.appendingPathComponent(""))
        if let a = authHeader() { get.setValue(a, forHTTPHeaderField: "Authorization") }
        let (html, resp2) = try await URLSession.shared.data(for: get)
        guard (200..<300).contains((resp2 as? HTTPURLResponse)?.statusCode ?? 0) else { throw URLError(.userAuthenticationRequired) }
        return parseIndexHTML(html, dirPath: path)
    }

    private func parsePropfind(_ data: Data, dirPath: String) -> [NASEntry] {
        let parser = PropfindParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()

        func normalise(_ p: String) -> String {
            var t = p
            if let u = URL(string: t), u.scheme != nil { t = u.path }      // absolute href → path only
            t = t.removingPercentEncoding ?? t
            while t.hasSuffix("/") { t.removeLast() }
            if !t.hasPrefix("/") { t = "/" + t }
            return t
        }
        let basePath = normalise(baseURL?.path ?? "/")
        let dirAbs = normalise(dirPath.isEmpty ? basePath : basePath + "/" + dirPath)

        var out: [NASEntry] = []
        var seen = Set<String>()
        for r in parser.responses {
            let abs = normalise(r.href)
            guard abs != dirAbs, abs.hasPrefix(dirAbs + "/") else { continue }   // skip self and anything outside
            let name = String(abs.dropFirst(dirAbs.count + 1))
            guard !name.isEmpty, !name.contains("/") else { continue }           // depth 1 only
            let path = join(dirPath, name)
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            out.append(NASEntry(name: name, isDirectory: r.isCollection, size: r.size, path: path))
        }
        return out.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func parseIndexHTML(_ data: Data, dirPath: String) -> [NASEntry] {
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        var out: [NASEntry] = []
        let regex = try! NSRegularExpression(pattern: #"href="([^"?#]+)""#, options: .caseInsensitive)
        for m in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range(at: 1), in: html) else { continue }
            var href = String(html[r])
            guard !href.hasPrefix("/"), !href.hasPrefix(".."), !href.hasPrefix("http") else { continue }
            let isDir = href.hasSuffix("/")
            if isDir { href.removeLast() }
            guard let name = href.removingPercentEncoding, !name.isEmpty else { continue }
            out.append(NASEntry(name: name, isDirectory: isDir, size: 0, path: join(dirPath, name)))
        }
        return out
    }
}

private final class PropfindParser: NSObject, XMLParserDelegate {
    struct Response { var href = ""; var isCollection = false; var size: Int64 = 0 }
    var responses: [Response] = []
    private var current: Response?
    private var text = ""
    private var inResourceType = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch name.lowercased() {
        case "response": current = Response()
        case "resourcetype": inResourceType = true
        case "collection": if inResourceType { current?.isCollection = true }
        default: break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch name.lowercased() {
        case "href": current?.href = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "getcontentlength": current?.size = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        case "resourcetype": inResourceType = false
        case "response": if let c = current { responses.append(c) }; current = nil
        default: break
        }
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "com.muzam2.bassplayer.nas"

    static func set(_ value: String, for account: String) {
        delete(account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
