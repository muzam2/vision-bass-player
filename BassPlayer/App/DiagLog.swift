import Foundation
import KSPlayer
#if canImport(UIKit)
import UIKit
#endif

/// In-app diagnostics log. The owner has no Mac, so the device console is out of reach; this keeps
/// the last few thousand app + KSPlayer messages in memory (the source of truth), mirrors them to
/// a file in Caches, can post everything to a computer on the LAN (Settings → Diagnostics) and can
/// stream new lines there every couple of seconds ("Stream log live"), so the computer sees what
/// the headset is doing while it happens. Everything is best-effort and never throws into the caller.
final class DiagLog: LogHandler, @unchecked Sendable {
    static let shared = DiagLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines = 6000
    private var unsaved = 0
    private let fileURL: URL
    private let formatter: DateFormatter
    /// Bumped on every line; views that show the log can observe it cheaply.
    private(set) var revision = 0
    /// Identifies this process in the live stream so the receiver can mark a relaunch.
    let launchID = String(UUID().uuidString.prefix(8))

    // Live streaming
    private var liveURL: URL?
    private var livePending: [String] = []
    private var liveTimer: DispatchSourceTimer?
    private var liveInFlight = false
    private var _liveStatus = "off"
    /// "off", "starting", "streaming (hh:mm:ss)" or "retrying (…)"; safe from any thread.
    var liveStatus: String {
        lock.lock(); defer { lock.unlock() }
        return _liveStatus
    }

    private init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        fileURL = dir.appendingPathComponent("bassplayer.log")
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        // Previous launch's lines first, so a crash leaves a trail.
        if let old = try? String(contentsOf: fileURL, encoding: .utf8) {
            lines = old.split(separator: "\n", omittingEmptySubsequences: true).suffix(maxLines / 2).map(String.init)
        }
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        write("=== Bass Player \(v) (\(b)) launched \(Date()) [\(launchID)] ===")
    }

    /// Append one line. Safe from any thread.
    static func log(_ message: String, _ category: String = "app") {
        shared.write("\(category) | \(message)")
    }

    private func write(_ line: String) {
        let stamped = "\(formatter.string(from: Date())) \(line)"
        print(stamped)
        lock.lock()
        lines.append(stamped)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        if liveURL != nil {
            livePending.append(stamped)
            if livePending.count > 2000 { livePending.removeFirst(livePending.count - 2000) }
        }
        revision += 1
        unsaved += 1
        let flush = unsaved >= 20
        if flush { unsaved = 0 }
        let snapshot = flush ? lines : nil
        lock.unlock()
        if let snapshot { save(snapshot) }
    }

    private func save(_ snapshot: [String]) {
        let data = Data((snapshot.joined(separator: "\n") + "\n").utf8)
        DispatchQueue.global(qos: .utility).async { [fileURL] in
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Everything we have, oldest first.
    var fullText: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n") + "\n"
    }

    var lineCount: Int {
        lock.lock(); defer { lock.unlock() }
        return lines.count
    }

    /// The last `maxLines` lines, newest last.
    func tail(_ maxLines: Int = 60) -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        livePending.removeAll()
        revision += 1
        lock.unlock()
        try? Data().write(to: fileURL)
        write("(log cleared)")
    }

    /// Write the current buffer to disk now (before an upload or when backgrounding).
    func flush() {
        lock.lock(); let snapshot = lines; unsaved = 0; lock.unlock()
        try? Data((snapshot.joined(separator: "\n") + "\n").utf8).write(to: fileURL, options: .atomic)
    }

    private func request(_ url: URL, body: Data, live: Bool) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        #if canImport(UIKit)
        req.setValue(UIDevice.current.name, forHTTPHeaderField: "X-Device-Name")
        #endif
        req.setValue(launchID, forHTTPHeaderField: "X-Launch")
        if live { req.setValue("append", forHTTPHeaderField: "X-Log-Mode") }
        return req
    }

    /// POST the whole log to `url` (plain text body). Returns the server's reply text.
    func upload(to url: URL) async throws -> String {
        flush()
        let data = Data(fullText.utf8)
        let (body, resp) = try await URLSession.shared.upload(for: request(url, body: data, live: false), from: data)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw NSError(domain: "DiagLog", code: code, userInfo: [NSLocalizedDescriptionKey: "Server answered HTTP \(code)"]) }
        return String(data: body, encoding: .utf8) ?? "OK"
    }

    // MARK: Live stream

    /// Start (url != nil) or stop (nil) streaming new lines to the receiver every 2 s. Starting
    /// sends the whole current buffer first so the receiver has the context.
    func setLive(url: URL?) {
        lock.lock()
        if url == liveURL, url == nil || liveTimer != nil { lock.unlock(); return }   // already in that state
        liveURL = url
        livePending = url == nil ? [] : lines
        liveTimer?.cancel()
        liveTimer = nil
        _liveStatus = url == nil ? "off" : "starting"
        lock.unlock()
        guard let url else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 0.5, repeating: 2.0)
        t.setEventHandler { [weak self] in self?.pumpLive(url) }
        t.resume()
        lock.lock(); liveTimer = t; lock.unlock()
        write("app | live log stream → \(url.absoluteString)")
    }

    private func pumpLive(_ url: URL) {
        lock.lock()
        guard !liveInFlight, !livePending.isEmpty, liveURL == url else { lock.unlock(); return }
        let batch = livePending
        livePending.removeAll()
        liveInFlight = true
        lock.unlock()
        let data = Data((batch.joined(separator: "\n") + "\n").utf8)
        let task = URLSession.shared.uploadTask(with: request(url, body: data, live: true), from: data) { [weak self] _, resp, error in
            guard let self else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            self.lock.lock()
            self.liveInFlight = false
            if error != nil || !(200..<300).contains(code) {
                // Put the batch back (in front of anything newer) and try again next tick.
                self.livePending.insert(contentsOf: batch, at: 0)
                if self.livePending.count > 2000 { self.livePending.removeFirst(self.livePending.count - 2000) }
                self._liveStatus = "retrying (\(error?.localizedDescription ?? "HTTP \(code)"))"
            } else {
                self._liveStatus = "streaming (\(self.formatter.string(from: Date())))"
            }
            self.lock.unlock()
        }
        task.resume()
    }

    // MARK: KSPlayer LogHandler

    func log(level: LogLevel, message: CustomStringConvertible, file: String, function: String, line: UInt) {
        write("ks:\(level.description) | \(file):\(line) \(message.description)")
    }
}
