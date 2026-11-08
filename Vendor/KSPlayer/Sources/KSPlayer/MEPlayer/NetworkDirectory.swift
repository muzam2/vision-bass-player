//
//  NetworkDirectory.swift
//  KSPlayer (vendored fork, Bass Player)
//
//  Directory listing through FFmpeg's AVIO (libsmbclient for smb://, plus anything else
//  libavformat can open a directory on). Lets a host browse a NAS without a separate SMB stack.
//
import Foundation
import Libavformat

public enum NetworkDirectory {
    public struct Entry: Hashable, Sendable {
        public let name: String
        public let isDirectory: Bool
        public let size: Int64
        public let modified: Date?
    }

    public enum ListError: LocalizedError {
        case open(Int32, String), read(Int32)
        public var errorDescription: String? {
            switch self {
            case .open(let code, let url): return "Could not open \(url) (\(Self.message(code)))"
            case .read(let code): return "Could not read directory (\(Self.message(code)))"
            }
        }
        static func message(_ code: Int32) -> String {
            var buf = [CChar](repeating: 0, count: 256)
            av_strerror(code, &buf, buf.count)
            return String(cString: buf)
        }
    }

    /// Lists `url` (e.g. `smb://user:pass@host/share/folder`). Blocking; call off the main thread.
    public static func list(url: String, options: [String: String] = [:]) throws -> [Entry] {
        avformat_network_init()
        var dict: OpaquePointer?
        for (k, v) in options { av_dict_set(&dict, k, v, 0) }
        defer { av_dict_free(&dict) }

        var ctx: UnsafeMutablePointer<AVIODirContext>?
        let openRet = avio_open_dir(&ctx, url, &dict)
        guard openRet >= 0, ctx != nil else { throw ListError.open(openRet, url) }
        defer { avio_close_dir(&ctx) }

        var out: [Entry] = []
        while true {
            var entry: UnsafeMutablePointer<AVIODirEntry>?
            let ret = avio_read_dir(ctx, &entry)
            guard ret >= 0 else { throw ListError.read(ret) }
            guard let e = entry else { break }           // NULL entry = end of listing
            let name = e.pointee.name.map { String(cString: $0) } ?? ""
            let isDir = e.pointee.type == Int32(AVIO_ENTRY_DIRECTORY.rawValue)
            let size = e.pointee.size
            let mod = e.pointee.modification_timestamp
            let date: Date? = mod > 0 ? Date(timeIntervalSince1970: TimeInterval(mod) / 1_000_000) : nil
            avio_free_directory_entry(&entry)
            if name.isEmpty || name == "." || name == ".." { continue }
            out.append(Entry(name: name, isDirectory: isDir, size: size, modified: date))
        }
        return out.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
