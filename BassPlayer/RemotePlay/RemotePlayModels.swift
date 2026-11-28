import Foundation
import Security

/// A PlayStation the app knows about. Paired once it has the registration keys the console
/// issued; those (and the account ID) are what every later connection and wake-up needs.
struct PSConsole: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var isPS5 = true
    /// Set by pairing.
    var nickname: String?
    var registKey: Data?      // 16 bytes (an 8-character hex string padded with zeros)
    var rpKey: Data?          // 16 bytes, "morning" in chiaki
    var mac: Data?
    /// 8 bytes, little-endian, of the PSN account that was signed in on the console at pairing.
    var accountID: Data?

    var isPaired: Bool { registKey?.count == 16 && rpKey?.count == 16 && accountID?.count == 8 }
    var displayName: String { nickname ?? name }
}

/// Stream quality the console is asked for. The PS5 sends at most 1080p over Remote Play.
struct RemotePlaySettings: Codable, Equatable {
    enum Resolution: Int, Codable, CaseIterable, Identifiable {
        case p720 = 720, p1080 = 1080
        var id: Int { rawValue }
        var label: String { "\(rawValue)p" }
        var size: (width: UInt32, height: UInt32) { self == .p720 ? (1280, 720) : (1920, 1080) }
    }
    enum Codec: Int, Codable, CaseIterable, Identifiable {
        case h264 = 0, h265 = 1, h265HDR = 2
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .h264: return "H.264"
            case .h265: return "H.265 (HEVC)"
            case .h265HDR: return "H.265 HDR"
            }
        }
    }

    var resolution: Resolution = .p1080
    var fps60 = true
    var codec: Codec = .h265
    /// kbit/s; 0 = chiaki's default for the resolution (10 Mbit/s at 720p, 15 at 1080p).
    var bitrateKbps: Int = 0
    /// Adaptive trigger effects (DualSense only).
    var dualSenseEffects = true
    /// Gyro and accelerometer from the controller (games that use motion aiming).
    var motion = false
}

/// The 8-byte account ID in the forms people have it: base64 (what the get-pin payload and
/// chiaki print, e.g. "AbCdEfGhIjA="), 0x-prefixed hex (OffAct), 16 hex digits (chiaki's helper scripts) or the
/// decimal number. Hex and decimal are the number; the console wants it little-endian.
enum PSNAccountID {
    static func parse(_ text: String) -> Data? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // OffAct shows and takes the ID as 0x… hex (leading zeros dropped).
        if s.lowercased().hasPrefix("0x") {
            let hex = s.dropFirst(2)
            guard !hex.isEmpty, hex.count <= 16, let v = UInt64(hex, radix: 16) else { return nil }
            return littleEndian(v)
        }
        if s.count == 16, s.allSatisfy(\.isHexDigit), let v = UInt64(s, radix: 16) {
            return littleEndian(v)
        }
        if s.allSatisfy(\.isNumber), let v = UInt64(s) {
            return littleEndian(v)
        }
        var b64 = s
        while b64.count % 4 != 0 { b64.append("=") }
        if let d = Data(base64Encoded: b64), d.count == 8 { return d }
        return nil
    }

    static func base64(_ data: Data) -> String { data.base64EncodedString() }

    private static func littleEndian(_ v: UInt64) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }
}

/// Consoles (with their pairing keys) live in the keychain; UserDefaults is the fallback if
/// the keychain refuses (it shouldn't, but a sideloaded build is re-signed on the device).
enum RemotePlayVault {
    private static let service = "com.muzam2.bassplayer.remoteplay"
    private static let account = "consoles"
    private static let fallbackKey = "rp.consoles.fallback"

    static func load() -> [PSConsole] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
           let list = try? JSONDecoder().decode([PSConsole].self, from: data) {
            return list
        }
        if let data = UserDefaults.standard.data(forKey: fallbackKey),
           let list = try? JSONDecoder().decode([PSConsole].self, from: data) {
            return list
        }
        return []
    }

    static func save(_ consoles: [PSConsole]) {
        guard let data = try? JSONEncoder().encode(consoles) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackKey)
        } else {
            DiagLog.log("keychain save failed (\(status)); consoles kept in app settings instead", "rp")
            UserDefaults.standard.set(data, forKey: fallbackKey)
        }
    }
}
