import Foundation
import Network
import AMSMB2

/// SMB without FFmpeg: shares are read with libsmb2 (AMSMB2) and handed to the players over a
/// loopback HTTP server that understands byte ranges:
///
///     http://127.0.0.1:<port>/smb/<share id>/<path in share>
///
/// FFmpeg and AVPlayer both speak HTTP ranges, so one bridge serves every backend (an MV-HEVC
/// file on the NAS can go to AVPlayer, which cannot open smb:// itself) and FFmpeg no longer
/// has to be built with libsmbclient, which FFmpegKit 9 dropped.
///
/// Each HTTP request takes an SMB connection from a small per-share pool (one libsmb2 context
/// per in-flight request, so parallel range requests never share a context), streams the
/// requested range chunk by chunk with back-pressure, and returns the connection when done.
final class SMBBridge: @unchecked Sendable {
    static let shared = SMBBridge()

    struct Entry: Sendable {
        let share: NASShare
        let password: String
        /// host[:port] and, if the address was host/share, the share name.
        var host: String {
            var a = share.address.trimmingCharacters(in: .whitespacesAndNewlines)
            if a.lowercased().hasPrefix("smb://") { a.removeFirst(6) }
            return String(a.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first ?? "")
        }
        var fixedShare: String? {
            var a = share.address.trimmingCharacters(in: .whitespacesAndNewlines)
            if a.lowercased().hasPrefix("smb://") { a.removeFirst(6) }
            let parts = a.split(separator: "/", omittingEmptySubsequences: true)
            return parts.count > 1 ? String(parts[1]) : nil
        }
        /// Split an app-level path ("Films/x.mkv", or "video/Films/x.mkv" when the address
        /// named no share) into the SMB share and the path inside it.
        func locate(_ path: String) -> (shareName: String, path: String)? {
            if let s = fixedShare { return (s, path) }
            let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let first = comps.first else { return nil }
            return (first, comps.dropFirst().joined(separator: "/"))
        }
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var idle: [String: [SMB2Manager]] = [:]     // key: share id + share name
    private let server = LoopbackHTTPServer()

    private init() {
        server.handler = { [weak self] request, responder in self?.serve(request, responder) }
    }

    // MARK: Registry

    /// Called by `NASClient` whenever its saved shares change.
    func update(_ shares: [(NASShare, String)]) {
        lock.lock()
        let gone = Set(entries.keys).subtracting(shares.map { $0.0.id })
        entries = Dictionary(uniqueKeysWithValues: shares.map { ($0.0.id, Entry(share: $0.0, password: $0.1)) })
        for id in gone { idle = idle.filter { !$0.key.hasPrefix(id.uuidString) } }
        lock.unlock()
    }

    private func entry(_ id: UUID) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[id]
    }

    // MARK: URLs

    /// Loopback URL for a file. Starts the server on first use.
    func url(shareID: UUID, path: String) -> URL? {
        guard let port = server.ensureStarted() else { return nil }
        let encoded = path.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;?#"))) ?? String($0) }
            .joined(separator: "/")
        return URL(string: "http://127.0.0.1:\(port)/smb/\(shareID.uuidString)/\(encoded)")
    }

    // MARK: Browsing

    /// Directory listing (or the list of shares when the address named only a host).
    func list(shareID: UUID, path: String) async throws -> [NASEntry] {
        guard let entry = entry(shareID) else { throw BridgeError.unknownShare }
        if entry.fixedShare == nil, path.isEmpty {
            let m = try manager(for: entry)
            let shares = try await m.listShares(enumerateHidden: false)   // connects IPC$ itself
            m.disconnectShare(completionHandler: nil)
            return shares.map { NASEntry(name: $0.name, isDirectory: true, size: 0, path: $0.name) }
        }
        guard let loc = entry.locate(path) else { throw BridgeError.badPath }
        let (shareName, inner) = loc
        let m = try await acquire(entry, shareName: shareName)
        defer { release(m, entry: entry, shareName: shareName) }
        let items = try await m.contentsOfDirectory(atPath: inner)
        return items.compactMap { attrs in
            guard let name = attrs[.nameKey] as? String, name != ".", name != ".." else { return nil }
            let isDir = (attrs[.isDirectoryKey] as? Bool) ?? false
            let size = (attrs[.fileSizeKey] as? Int64) ?? Int64((attrs[.fileSizeKey] as? Int) ?? 0)
            return NASEntry(name: name, isDirectory: isDir, size: size, path: path.isEmpty ? name : path + "/" + name)
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    // MARK: Connections

    private func manager(for entry: Entry) throws -> SMB2Manager {
        guard let url = URL(string: "smb://\(entry.host)") else { throw BridgeError.badAddress }
        let credential = entry.share.username.isEmpty ? nil
            : URLCredential(user: entry.share.username, password: entry.password, persistence: .forSession)
        guard let m = SMB2Manager(url: url, domain: entry.share.domain, credential: credential) else { throw BridgeError.badAddress }
        return m
    }

    private func connect(_ entry: Entry, shareName: String) async throws -> SMB2Manager {
        let m = try manager(for: entry)
        try await m.connectShare(name: shareName)
        return m
    }

    private func acquire(_ entry: Entry, shareName: String) async throws -> SMB2Manager {
        let key = entry.share.id.uuidString + "/" + shareName
        lock.lock()
        if var list = idle[key], let m = list.popLast() {
            idle[key] = list
            lock.unlock()
            return m
        }
        lock.unlock()
        return try await connect(entry, shareName: shareName)
    }

    private func release(_ m: SMB2Manager, entry: Entry, shareName: String) {
        let key = entry.share.id.uuidString + "/" + shareName
        lock.lock()
        idle[key, default: []].append(m)
        let extra = idle[key]!.count > 3 ? idle[key]!.removeFirst() : nil
        lock.unlock()
        extra?.disconnectShare(completionHandler: nil)
    }

    // MARK: HTTP

    enum BridgeError: LocalizedError {
        case unknownShare, badPath, badAddress
        var errorDescription: String? {
            switch self {
            case .unknownShare: return "This share is no longer saved."
            case .badPath: return "Bad SMB path."
            case .badAddress: return "Bad SMB address."
            }
        }
    }

    private func serve(_ request: LoopbackHTTPServer.Request, _ responder: LoopbackHTTPServer.Responder) {
        // /smb/<uuid>/<percent-encoded path>
        let comps = request.path.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard comps.count == 3, comps[0] == "smb", let id = UUID(uuidString: comps[1]),
              let entry = entry(id), let path = comps[2].removingPercentEncoding,
              let loc = entry.locate(path), !loc.path.isEmpty else {
            responder.send(status: 404, headers: ["Content-Length": "0"], body: nil); return
        }
        let (shareName, inner) = loc
        Task.detached(priority: .userInitiated) { [self] in
            var manager: SMB2Manager?
            do {
                let m = try await acquire(entry, shareName: shareName)
                manager = m
                let attrs = try await m.attributesOfItem(atPath: inner)
                let size = (attrs[.fileSizeKey] as? Int64) ?? Int64((attrs[.fileSizeKey] as? Int) ?? 0)
                let range = request.range(fileSize: size)
                var headers = [
                    "Accept-Ranges": "bytes",
                    "Content-Type": Self.contentType(for: inner),
                    "Content-Length": "\(range.map { $0.upperBound - $0.lowerBound + 1 } ?? size)",
                    "Connection": "close",
                ]
                if let r = range { headers["Content-Range"] = "bytes \(r.lowerBound)-\(r.upperBound)/\(size)" }
                let status = range == nil ? 200 : 206
                if request.method == "HEAD" || size == 0 || (range.map { $0.isEmpty } ?? false) {
                    responder.send(status: status, headers: headers, body: nil)
                    release(m, entry: entry, shareName: shareName)
                    return
                }
                responder.sendHead(status: status, headers: headers)
                let start = range?.lowerBound ?? 0
                let end = range?.upperBound ?? (size - 1)
                let budget = ByteBudget(remaining: end - start + 1)
                let streamError: Error? = await withCheckedContinuation { cont in
                    m.contents(atPath: inner, offset: start, fetchedData: { _, _, data in
                        guard responder.isOpen, let chunk = budget.take(data) else { return false }
                        // Back-pressure: one chunk in flight; the SMB read loop waits for the socket.
                        return responder.sendBlocking(chunk) && budget.hasMore
                    }, completionHandler: { error in cont.resume(returning: error) })
                }
                let wasOpen = responder.isOpen
                responder.finish()
                if let streamError, wasOpen {
                    DiagLog.log("smb stream ended early: \(streamError.localizedDescription)", "nas")
                }
                // A connection whose read was cut short mid-file is still healthy; reuse it.
                release(m, entry: entry, shareName: shareName)
            } catch {
                DiagLog.log("smb request failed (\(inner)): \(error.localizedDescription)", "nas")
                responder.send(status: 404, headers: ["Content-Length": "0", "Connection": "close"], body: nil)
                if let manager { manager.disconnectShare(completionHandler: nil) }
            }
        }
    }

    /// Bytes still owed to the client; shared between the SMB read loop and the sender.
    private final class ByteBudget: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int64
        init(remaining: Int64) { self.remaining = remaining }
        var hasMore: Bool { lock.lock(); defer { lock.unlock() }; return remaining > 0 }
        /// The part of `data` that still fits, or nil when nothing is owed.
        func take(_ data: Data) -> Data? {
            lock.lock(); defer { lock.unlock() }
            guard remaining > 0 else { return nil }
            let n = min(Int64(data.count), remaining)
            remaining -= n
            return n == Int64(data.count) ? data : Data(data.prefix(Int(n)))
        }
    }

    private static func contentType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv", "mk3d": return "video/x-matroska"
        case "webm": return "video/webm"
        case "ts", "m2ts", "mts": return "video/mp2t"
        case "avi": return "video/x-msvideo"
        case "srt": return "application/x-subrip"
        case "vtt": return "text/vtt"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Loopback HTTP server

/// Minimal HTTP/1.1 server on 127.0.0.1 (Network.framework): one request per connection,
/// GET/HEAD with Range. Just enough for FFmpeg's and AVPlayer's HTTP clients.
final class LoopbackHTTPServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]

        /// Closed byte range from a `Range: bytes=a-b` / `bytes=a-` / `bytes=-n` header, clamped
        /// to the file; nil when there is no (usable) Range header.
        func range(fileSize: Int64) -> ClosedRange<Int64>? {
            guard let raw = headers["range"]?.lowercased(), raw.hasPrefix("bytes=") else { return nil }
            let spec = raw.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, fileSize > 0 else { return nil }
            if parts[0].isEmpty, let n = Int64(parts[1]) {                       // bytes=-n (suffix)
                return max(0, fileSize - n)...(fileSize - 1)
            }
            guard let start = Int64(parts[0]), start < fileSize else { return 0...(-1) }
            let end = Int64(parts[1]).map { min($0, fileSize - 1) } ?? (fileSize - 1)
            return start...max(start - 1, end)
        }
    }

    /// Writes the response for one connection.
    final class Responder: @unchecked Sendable {
        private let connection: NWConnection
        private let lock = NSLock()
        private var open = true
        fileprivate init(connection: NWConnection) { self.connection = connection }

        var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
        fileprivate func markClosed() { lock.lock(); open = false; lock.unlock() }

        private func headData(status: Int, headers: [String: String]) -> Data {
            let reason = [200: "OK", 206: "Partial Content", 404: "Not Found", 416: "Range Not Satisfiable", 500: "Internal Server Error"][status] ?? "OK"
            var s = "HTTP/1.1 \(status) \(reason)\r\n"
            for (k, v) in headers { s += "\(k): \(v)\r\n" }
            s += "\r\n"
            return Data(s.utf8)
        }

        func sendHead(status: Int, headers: [String: String]) {
            connection.send(content: headData(status: status, headers: headers), completion: .contentProcessed { _ in })
        }

        /// Complete response (head + optional body) then close.
        func send(status: Int, headers: [String: String], body: Data?) {
            var data = headData(status: status, headers: headers)
            if let body { data.append(body) }
            connection.send(content: data, isComplete: true, completion: .contentProcessed { [self] _ in finish() })
        }

        /// Send one body chunk and wait until the socket has taken it. False once the client is gone.
        func sendBlocking(_ data: Data) -> Bool {
            guard isOpen else { return false }
            let sem = DispatchSemaphore(value: 0)
            connection.send(content: data, completion: .contentProcessed { [self] error in
                if error != nil { markClosed() }
                sem.signal()
            })
            sem.wait()
            return isOpen
        }

        func finish() {
            markClosed()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
        }
    }

    var handler: ((Request, Responder) -> Void)?
    private let queue = DispatchQueue(label: "bassplayer.smb.http", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16?
    private var ready = DispatchSemaphore(value: 0)

    /// Start listening if needed; returns the port (nil if the listener could not start).
    func ensureStarted() -> UInt16? {
        lock.lock()
        if let port { lock.unlock(); return port }
        if listener == nil {
            do {
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
                params.allowLocalEndpointReuse = true
                let l = try NWListener(using: params)
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                l.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.lock.lock(); self.port = l.port?.rawValue; self.lock.unlock()
                        DiagLog.log("smb bridge listening on 127.0.0.1:\(l.port?.rawValue ?? 0)", "nas")
                        self.ready.signal()
                    case .failed(let e):
                        DiagLog.log("smb bridge listener failed: \(e)", "nas")
                        self.lock.lock(); self.listener = nil; self.lock.unlock()
                        self.ready.signal()
                    default: break
                    }
                }
                listener = l
                lock.unlock()
                l.start(queue: queue)
            } catch {
                lock.unlock()
                DiagLog.log("smb bridge could not start: \(error)", "nas")
                return nil
            }
        } else {
            lock.unlock()
        }
        _ = ready.wait(timeout: .now() + 3)
        lock.lock(); defer { lock.unlock() }
        return port
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed(let e) = state { DiagLog.log("smb http connection failed: \(e)", "nas") }
        }
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
                self.dispatch(head: head, connection: connection)
            } else if isComplete || error != nil || buf.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buf)
            }
        }
    }

    private func dispatch(head: String, connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let reqParts = lines.first?.split(separator: " ").map(String.init) ?? []
        let responder = Responder(connection: connection)
        guard reqParts.count >= 2 else { responder.send(status: 500, headers: ["Content-Length": "0"], body: nil); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let i = line.firstIndex(of: ":") {
                headers[line[..<i].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let path = reqParts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? reqParts[1]
        let request = Request(method: reqParts[0].uppercased(), path: path, headers: headers)
        if let handler { handler(request, responder) } else { responder.send(status: 500, headers: ["Content-Length": "0"], body: nil) }
    }
}
