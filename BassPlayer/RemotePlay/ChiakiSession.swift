import Foundation
import ChiakiCore

/// Swift side of `ChiakiBridge.h`. chiaki calls back on its own threads; these types only
/// forward, the owners decide which queue to hop to.
enum Chiaki {
    private static let initResult: Int32 = {
        rp_init({ level, msg, _ in
            guard let msg else { return }
            // chiaki levels: 1 error, 2 warning, 4 info.
            let tag = level == 1 ? "E " : level == 2 ? "W " : ""
            DiagLog.log(tag + String(cString: msg), "chiaki")
        }, nil)
    }()

    /// Initialises the library once. Returns nil on success, otherwise the error text.
    @discardableResult
    static func ensureInitialised() -> String? {
        initResult == 0 ? nil : errorText(initResult)
    }

    static func errorText(_ code: Int32) -> String {
        guard let s = rp_error_string(code) else { return "error \(code)" }
        return String(cString: s)
    }

    enum HostState: Equatable { case unknown, ready, standby }

    struct ProbeResult {
        var state: HostState
        var name: String?
        var isPS5: Bool
    }

    /// Unicast discovery of one console. Blocking; call off the main thread.
    static func probe(host: String, timeoutMs: Int32 = 1500) -> ProbeResult? {
        ensureInitialised()
        var state: Int32 = 0
        var ps5 = false
        var name = [CChar](repeating: 0, count: 128)
        let r = name.withUnsafeMutableBufferPointer { buf in
            rp_probe(host, timeoutMs, &state, buf.baseAddress, buf.count, &ps5)
        }
        guard r == 0 else { return nil }
        let n = String(cString: name)
        return ProbeResult(state: state == 1 ? .ready : state == 2 ? .standby : .unknown,
                           name: n.isEmpty ? nil : n, isPS5: ps5)
    }

    /// Sends the wake-up packet. Blocking (briefly); call off the main thread.
    static func wake(_ console: PSConsole) -> String? {
        ensureInitialised()
        guard let key = console.registKey, key.count == 16 else { return "Not paired" }
        let r = key.withUnsafeBytes { raw -> Int32 in
            rp_wakeup(console.host, console.isPS5, raw.bindMemory(to: CChar.self).baseAddress)
        }
        return r == 0 ? nil : errorText(r)
    }
}

/// One pairing attempt. Keep it alive until `completion` has fired.
final class ChiakiRegistration {
    struct Result {
        var nickname: String
        var registKey: Data
        var rpKey: Data
        var mac: Data
        var isPS5: Bool
    }

    private var handle: OpaquePointer?
    private let box: Box
    private let lock = NSLock()

    private final class Box {
        let completion: (Swift.Result<Result, Error>) -> Void
        init(_ c: @escaping (Swift.Result<Result, Error>) -> Void) { completion = c }
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    /// `pin` is the 8-digit number from the console (spaces allowed).
    init?(host: String, isPS5: Bool, accountID: Data, pin: UInt32,
          completion: @escaping (Swift.Result<Result, Error>) -> Void) {
        Chiaki.ensureInitialised()
        box = Box(completion)
        let user = Unmanaged.passUnretained(box).toOpaque()
        let h = accountID.withUnsafeBytes { raw -> OpaquePointer? in
            rp_regist_start(host, isPS5, raw.bindMemory(to: UInt8.self).baseAddress, pin, { result, host, user in
                guard let user else { return }
                let box = Unmanaged<Box>.fromOpaque(user).takeUnretainedValue()
                if result == 0, let h = host?.pointee {
                    let nickname = withUnsafeBytes(of: h.nickname) { raw -> String in
                        let bytes = raw.bindMemory(to: UInt8.self)
                        let end = bytes.firstIndex(of: 0) ?? bytes.count
                        return String(decoding: bytes[..<end], as: UTF8.self)
                    }
                    let registKey = withUnsafeBytes(of: h.regist_key) { Data($0) }
                    let rpKey = withUnsafeBytes(of: h.rp_key) { Data($0) }
                    let mac = withUnsafeBytes(of: h.mac) { Data($0) }
                    box.completion(.success(Result(nickname: nickname, registKey: registKey, rpKey: rpKey,
                                                   mac: mac, isPS5: h.target >= 1_000_000)))
                } else if result == 2 {
                    box.completion(.failure(Failure(errorDescription: "Pairing cancelled")))
                } else {
                    box.completion(.failure(Failure(errorDescription:
                        "The console refused the pairing. Check the PIN (it expires after five minutes) and that the account ID is the one signed in on the console.")))
                }
            }, user)
        }
        guard let h else { return nil }
        handle = h
    }

    /// Stops the attempt (if still running) and waits for its thread. Blocking.
    func cancel() {
        lock.lock()
        let h = handle
        handle = nil
        lock.unlock()
        if let h { rp_regist_free(h) }
    }

    deinit {
        // The callback captures `box` unretained, so it must not outlive us.
        cancel()
    }
}

/// A live streaming session. Callbacks arrive on chiaki's threads.
final class ChiakiSession {
    struct Config {
        var console: PSConsole
        var settings: RemotePlaySettings
    }

    enum Event {
        case connected
        case loginPinRequested(incorrect: Bool)
        case quit(text: String, isError: Bool)
        case rumble(left: UInt8, right: UInt8)
        case triggerEffects(leftType: UInt8, left: [UInt8], rightType: UInt8, right: [UInt8])
        case led(r: UInt8, g: UInt8, b: UInt8)
        case nickname(String)
    }

    /// Return false when the frame could not be decoded (a keyframe is then requested).
    var onVideo: ((UnsafeBufferPointer<UInt8>, _ framesLost: Int32, _ recovered: Bool) -> Bool)?
    var onAudioFormat: ((_ channels: Int, _ rate: Double) -> Void)?
    var onAudio: ((UnsafeBufferPointer<Int16>, _ frames: Int) -> Void)?
    var onEvent: ((Event) -> Void)?

    private var handle: OpaquePointer?
    private let handleLock = NSLock()
    private var host: [CChar] = []

    init() {}

    /// Connects. Blocking (the handshake runs on chiaki's thread, but init resolves the host);
    /// call off the main thread. Throws with chiaki's error text.
    func start(_ config: Config) throws {
        if let e = Chiaki.ensureInitialised() { throw ChiakiRegistration.Failure(errorDescription: e) }
        let c = config.console
        guard let registKey = c.registKey, let rpKey = c.rpKey, let account = c.accountID, c.isPaired else {
            throw ChiakiRegistration.Failure(errorDescription: "This console isn't paired yet")
        }
        host = Array(c.host.utf8CString)

        var cfg = rp_session_config()
        cfg.ps5 = c.isPS5
        withUnsafeMutableBytes(of: &cfg.regist_key) { dst in registKey.prefix(16).copyBytes(to: dst.bindMemory(to: UInt8.self)) }
        withUnsafeMutableBytes(of: &cfg.rp_key) { dst in rpKey.prefix(16).copyBytes(to: dst.bindMemory(to: UInt8.self)) }
        withUnsafeMutableBytes(of: &cfg.account_id) { dst in account.prefix(8).copyBytes(to: dst.bindMemory(to: UInt8.self)) }
        let size = config.settings.resolution.size
        cfg.width = size.width
        cfg.height = size.height
        cfg.max_fps = config.settings.fps60 ? 60 : 30
        cfg.bitrate_kbps = UInt32(max(0, config.settings.bitrateKbps))
        cfg.codec = rp_codec(rawValue: UInt32(config.settings.codec.rawValue))
        cfg.enable_dualsense = config.settings.dualSenseEffects
        cfg.idr_on_fec_failure = true

        var cb = rp_callbacks()
        cb.user = Unmanaged.passUnretained(self).toOpaque()
        cb.video = { buf, size, lost, recovered, user in
            guard let user, let buf else { return true }
            let me = Unmanaged<ChiakiSession>.fromOpaque(user).takeUnretainedValue()
            return me.onVideo?(UnsafeBufferPointer(start: buf, count: size), lost, recovered) ?? true
        }
        cb.audio_format = { channels, rate, user in
            guard let user else { return }
            let me = Unmanaged<ChiakiSession>.fromOpaque(user).takeUnretainedValue()
            me.onAudioFormat?(Int(channels), Double(rate))
        }
        cb.audio = { pcm, frames, user in
            guard let user, let pcm else { return }
            let me = Unmanaged<ChiakiSession>.fromOpaque(user).takeUnretainedValue()
            me.onAudio?(UnsafeBufferPointer(start: pcm, count: frames), frames)
        }
        cb.haptics = nil
        cb.event = { ev, user in
            guard let user, let e = ev?.pointee else { return }
            let me = Unmanaged<ChiakiSession>.fromOpaque(user).takeUnretainedValue()
            guard let out = ChiakiSession.translate(e) else { return }
            me.onEvent?(out)
        }

        var err: Int32 = 0
        let h = host.withUnsafeBufferPointer { hostPtr -> OpaquePointer? in
            cfg.host = hostPtr.baseAddress
            return rp_session_start(&cfg, cb, &err)
        }
        guard let h else { throw ChiakiRegistration.Failure(errorDescription: Chiaki.errorText(err)) }
        handleLock.lock(); handle = h; handleLock.unlock()
    }

    private static func translate(_ e: rp_event) -> Event? {
        switch e.type {
        case RP_EVENT_CONNECTED: return .connected
        case RP_EVENT_LOGIN_PIN_REQUEST: return .loginPinRequested(incorrect: e.pin_incorrect)
        case RP_EVENT_QUIT:
            let text = e.quit_text.map { String(cString: $0) } ?? "Disconnected"
            return .quit(text: text, isError: e.quit_is_error)
        case RP_EVENT_RUMBLE: return .rumble(left: e.rumble_left, right: e.rumble_right)
        case RP_EVENT_TRIGGER_EFFECTS:
            let l = withUnsafeBytes(of: e.trigger_left) { Array($0) }
            let r = withUnsafeBytes(of: e.trigger_right) { Array($0) }
            return .triggerEffects(leftType: e.trigger_type_left, left: l, rightType: e.trigger_type_right, right: r)
        case RP_EVENT_LED: return .led(r: e.led.0, g: e.led.1, b: e.led.2)
        case RP_EVENT_NICKNAME:
            let name = withUnsafeBytes(of: e.nickname) { raw -> String in
                let bytes = raw.bindMemory(to: UInt8.self)
                let end = bytes.firstIndex(of: 0) ?? bytes.count
                return String(decoding: bytes[..<end], as: UTF8.self)
            }
            return .nickname(name)
        default: return nil
        }
    }

    private func withHandle(_ body: (OpaquePointer) -> Void) {
        handleLock.lock(); defer { handleLock.unlock() }
        if let handle { body(handle) }
    }

    func setController(_ state: inout rp_controller_state) {
        withHandle { rp_session_set_controller($0, &state) }
    }

    func setLoginPin(_ pin: String) {
        withHandle { rp_session_set_login_pin($0, pin) }
    }

    func requestKeyframe() {
        withHandle { rp_session_request_keyframe($0) }
    }

    func sleepConsole() {
        withHandle { rp_session_sleep_console($0) }
    }

    /// Stops and frees. Blocking (joins chiaki's threads); call off the main thread. The
    /// callbacks may still fire until this returns.
    func stop() {
        handleLock.lock()
        let h = handle
        handle = nil
        handleLock.unlock()
        if let h { rp_session_free(h) }
    }

    deinit { stop() }
}
