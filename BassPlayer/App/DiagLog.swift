import Foundation
import KSPlayer
#if canImport(UIKit)
import UIKit
#endif

/// In-app diagnostics log. The owner has no Mac, so the device console is out of reach; this keeps
/// the last few thousand app + KSPlayer messages in memory (the source of truth), mirrors them to
/// a file in Caches, and can post everything to a computer on the LAN (Settings → Diagnostics).
/// Everything is best-effort and never throws into the caller.
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
        write("=== Bass Player \(v) (\(b)) launched \(Date()) ===")
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

    /// The last `maxLines` lines, newest last.
    func tail(_ maxLines: Int = 60) -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        revision += 1
        lock.unlock()
        try? Data().write(to: fileURL)
    }

    /// Write the current buffer to disk now (before an upload or when backgrounding).
    func flush() {
        lock.lock(); let snapshot = lines; unsaved = 0; lock.unlock()
        try? Data((snapshot.joined(separator: "\n") + "\n").utf8).write(to: fileURL, options: .atomic)
    }

    /// POST the whole log to `url` (plain text body). Returns the server's reply text.
    func upload(to url: URL) async throws -> String {
        flush()
        let data = Data(fullText.utf8)
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        #if canImport(UIKit)
        req.setValue(UIDevice.current.name, forHTTPHeaderField: "X-Device-Name")
        #endif
        let (body, resp) = try await URLSession.shared.upload(for: req, from: data)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw NSError(domain: "DiagLog", code: code, userInfo: [NSLocalizedDescriptionKey: "Server answered HTTP \(code)"]) }
        return String(data: body, encoding: .utf8) ?? "OK"
    }

    // MARK: KSPlayer LogHandler

    func log(level: LogLevel, message: CustomStringConvertible, file: String, function: String, line: UInt) {
        write("ks:\(level.description) | \(file):\(line) \(message.description)")
    }
}
