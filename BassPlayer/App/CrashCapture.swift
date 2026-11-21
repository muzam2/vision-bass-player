import Foundation
import Darwin

/// Records why the previous run died, so the next launch can put it in the diagnostic log (the
/// owner has no Mac, so device crash reports are hard to reach). Uncaught Objective-C exceptions
/// (AVAudioEngine raises these) are written with their reason and call stack; fatal signals
/// (Swift traps, aborts, bad memory access) with the signal number and a raw backtrace. Standard
/// error is kept in a file as well: system frameworks (Metal, Swift's own fatal errors) print
/// the reason for an abort there and nowhere else.
enum CrashCapture {
    fileprivate nonisolated(unsafe) static var fd: Int32 = -1

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("lastcrash.txt")
    }

    private static var stderrURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("laststderr.txt")
    }

    /// Install the handlers and return what the previous run left behind, if anything.
    static func install() -> String? {
        let url = fileURL
        var previous = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        // What the previous run printed on standard error, if it crashed; then send this run's
        // standard error to the same file.
        if let report = previous, !report.isEmpty, let data = try? Data(contentsOf: stderrURL), !data.isEmpty {
            let tail = String(decoding: data.suffix(3000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                previous = report + "\nLast lines on standard error:\n" + tail
            }
        }
        let errFile = open(stderrURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if errFile >= 0 {
            dup2(errFile, STDERR_FILENO)
            close(errFile)
        }
        fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        NSSetUncaughtExceptionHandler { exception in
            let text = "Uncaught exception \(exception.name.rawValue): \(exception.reason ?? "(no reason)")\n"
                + exception.callStackSymbols.prefix(40).joined(separator: "\n") + "\n"
            CrashCapture.writeRaw(text)
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig, crashCaptureSignalHandler)
        }
        return (previous?.isEmpty ?? true) ? nil : previous
    }

    fileprivate static func writeRaw(_ text: String) {
        guard fd >= 0 else { return }
        text.withCString { _ = write(fd, $0, strlen($0)) }
    }
}

/// Fatal-signal handler: allocation-free, writes the signal number and a backtrace, then lets the
/// signal take its normal course.
private func crashCaptureSignalHandler(_ sig: Int32) {
    let fd = CrashCapture.fd
    if fd >= 0 {
        let prefix: StaticString = "Fatal signal "
        _ = write(fd, prefix.utf8Start, prefix.utf8CodeUnitCount)
        var digits: (UInt8, UInt8, UInt8) = (UInt8(ascii: "0") + UInt8(truncatingIfNeeded: (sig / 10) % 10),
                                             UInt8(ascii: "0") + UInt8(truncatingIfNeeded: sig % 10),
                                             UInt8(ascii: "\n"))
        withUnsafeBytes(of: &digits) { _ = write(fd, $0.baseAddress, 3) }
        withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 64) { frames in
            let count = backtrace(frames.baseAddress, 64)
            backtrace_symbols_fd(frames.baseAddress, count, fd)
        }
    }
    signal(sig, SIG_DFL)
    raise(sig)
}
