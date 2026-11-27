import Foundation
import Network

/// One-tap pairing for a jailbroken PS5: sends idlesauce's `rp-get-pin.elf` payload
/// (https://github.com/idlesauce/ps5-remoteplay-get-pin) to the console's ELF loader on port
/// 9021 and reads what it prints back over the same connection:
///
///     Pin code: 1234 5678
///     Account ID: AbCdEfGhIjA=
///     Timeout: 300 seconds
///
/// The account ID is the one the console accepts for pairing (the logged-in, offline-activated
/// user), so no PSN account is involved. The payload has no licence file, so the app does not
/// ship it: it downloads the release asset from GitHub on request (or takes a file you pick)
/// and keeps it in Application Support.
///
/// The connection stays open until `close()`: the payload keeps the PIN valid while it runs.
final class PayloadPairing {
    struct Code: Equatable {
        var pin: UInt32
        var pinText: String
        var accountID: Data
        var accountText: String
    }

    struct Failure: LocalizedError { var errorDescription: String? }

    static let port: UInt16 = 9021
    static let releaseURL = URL(string: "https://github.com/idlesauce/ps5-remoteplay-get-pin/releases/latest/download/rp-get-pin.elf")!
    static let releasesAPI = URL(string: "https://api.github.com/repos/idlesauce/ps5-remoteplay-get-pin/releases/latest")!

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "rp.payload")

    // MARK: - The payload file

    static var cachedURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("rp-get-pin.elf")
    }

    static var hasCachedPayload: Bool {
        (try? Data(contentsOf: cachedURL)).map(isELF) ?? false
    }

    static func isELF(_ d: Data) -> Bool { d.count > 64 && d.prefix(4) == Data([0x7F, 0x45, 0x4C, 0x46]) }

    /// Downloads the latest release's ELF (direct asset URL first, then the release API).
    static func downloadPayload() async throws -> Data {
        var lastError = "no .elf in the latest release"
        if let direct = try? await URLSession.shared.data(from: releaseURL),
           (direct.1 as? HTTPURLResponse)?.statusCode == 200, isELF(direct.0) {
            try store(direct.0)
            return direct.0
        }
        var req = URLRequest(url: releasesAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (json, resp) = try await URLSession.shared.data(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 { lastError = "GitHub answered \(code)" }
        if let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
           let assets = obj["assets"] as? [[String: Any]],
           let asset = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".elf") == true }),
           let s = asset["browser_download_url"] as? String, let url = URL(string: s) {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard isELF(data) else { throw Failure(errorDescription: "The downloaded file is not an ELF payload") }
            try store(data)
            return data
        }
        throw Failure(errorDescription: "Couldn't download the payload (\(lastError)). Pick rp-get-pin.elf from Files instead.")
    }

    static func importPayload(from url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard isELF(data) else { throw Failure(errorDescription: "That file is not an ELF payload") }
        try store(data)
        return data
    }

    private static func store(_ data: Data) throws {
        let url = cachedURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Sending and reading the code

    /// Sends the payload and waits (up to `timeout`) for the PIN and account ID.
    func run(host: String, payload: Data, timeout: TimeInterval = 25) async throws -> Code {
        close()
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Self.port)!, using: .tcp)
        connection = conn
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Code, Error>) in
            let state = RunState(cont)
            queue.asyncAfter(deadline: .now() + timeout) {
                state.finish(.failure(Failure(errorDescription: state.output.isEmpty
                    ? "No answer from the ELF loader on port 9021. Is the payload loader running on the PS5?"
                    : "The payload didn't print a PIN. It said: \(state.output.suffix(200))")))
            }
            conn.stateUpdateHandler = { s in
                switch s {
                case .ready:
                    DiagLog.log("payload: connected to \(host):\(Self.port), sending \(payload.count) bytes", "rp")
                    conn.send(content: payload, completion: .contentProcessed { error in
                        if let error { state.finish(.failure(error)) }
                    })
                    Self.receive(conn, state)
                case .failed(let e), .waiting(let e):
                    state.finish(.failure(Failure(errorDescription: "Can't reach the ELF loader on \(host):\(Self.port) (\(e.localizedDescription))")))
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    private static func receive(_ conn: NWConnection, _ state: RunState) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            if let data, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                state.output += text
                if let code = parse(state.output) {
                    DiagLog.log("payload: PIN and account ID received", "rp")
                    state.finish(.success(code))
                    return
                }
            }
            if let error { state.finish(.failure(error)); return }
            if isComplete {
                state.finish(.failure(Failure(errorDescription: "The payload ended without a PIN: \(state.output.suffix(200))")))
                return
            }
            receive(conn, state)
        }
    }

    /// Keeps the payload's PIN alive until pairing is done; then call this.
    func close() {
        connection?.cancel()
        connection = nil
    }

    static func parse(_ text: String) -> Code? {
        guard let pinLine = text.range(of: #"Pin code:\s*([0-9]{4})\s*([0-9]{4})"#, options: .regularExpression),
              let idLine = text.range(of: #"Account ID:\s*([A-Za-z0-9+/=]{8,})"#, options: .regularExpression)
        else { return nil }
        let pinDigits = text[pinLine].filter(\.isNumber)
        let idText = text[idLine].replacingOccurrences(of: "Account ID:", with: "").trimmingCharacters(in: .whitespaces)
        guard pinDigits.count == 8, let pin = UInt32(pinDigits), let account = PSNAccountID.parse(idText) else { return nil }
        return Code(pin: pin, pinText: String(pinDigits.prefix(4)) + " " + String(pinDigits.suffix(4)),
                    accountID: account, accountText: idText)
    }

    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Code, Error>?
        var output = ""
        init(_ c: CheckedContinuation<Code, Error>) { cont = c }
        func finish(_ r: Result<Code, Error>) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(with: r)
        }
    }
}
