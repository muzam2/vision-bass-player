import Foundation
import KSPlayer

/// In-app diagnostics log. The owner has no Mac, so the device console is out of reach; this keeps
/// the last ~1 MB of app + KSPlayer messages in a file and can post it to a computer on the LAN
/// (Settings → Diagnostics). Everything is best-effort and never throws into the caller.
final class DiagLog: LogHandler, @unchecked Sendable {
    static let shared = DiagLog()

    private let queue = DispatchQueue(label: "bassplayer.diaglog", qos: .utility)
    private let fileURL: URL
    private var handle: FileHandle?
    private let formatter: DateFormatter
    private let maxBytes = 1_500_000
    private var written = 0

    private init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        fileURL = dir.appendingPathComponent("bassplayer.log")
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        open()
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        write("=== Bass Player \(v) (\(b)) launched \(Date()) ===")
    }

    private func open() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        written = Int((try? handle?.seekToEnd()) ?? 0)
    }

    /// Append one line. Safe from any thread.
    static func log(_ message: String, _ category: String = "app") {
        shared.write("\(category) | \(message)")
    }

    private func write(_ line: String) {
        let stamped = "\(formatter.string(from: Date())) \(line)\n"
        print(stamped, terminator: "")
        queue.async {
            guard let data = stamped.data(using: .utf8) else { return }
            if self.written + data.count > self.maxBytes { self.trim() }
            self.handle?.write(data)
            self.written += data.count
        }
    }

    /// Keep the newest half of the file when it grows past the limit.
    private func trim() {
        handle?.closeFile()
        if let all = try? Data(contentsOf: fileURL), all.count > maxBytes / 2 {
            let tail = all.suffix(maxBytes / 2)
            try? tail.write(to: fileURL)
        }
        open()
    }

    /// The last `maxLines` lines, newest last.
    func tail(_ maxLines: Int = 60) -> String {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(maxLines).joined(separator: "\n")
    }

    func clear() {
        queue.sync {
            handle?.closeFile()
            try? Data().write(to: fileURL)
            open()
        }
    }

    /// POST the whole log to `url` (plain text body). Returns the server's reply text.
    func upload(to url: URL) async throws -> String {
        let data = try Data(contentsOf: fileURL)
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue(UIDevice.current.name, forHTTPHeaderField: "X-Device-Name")
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

#if canImport(UIKit)
import UIKit
#endif
