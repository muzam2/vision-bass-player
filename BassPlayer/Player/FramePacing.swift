import Foundation
import KSPlayer

/// How the FFmpeg player puts frames on screen (Settings → Diagnostics).
///
/// Off, the default: KSPlayer's display-link loop on the main thread picks one frame per tick.
/// On: `MetalPlayView.PresentationMode.timestamped`: a pump on its own queue hands frames to the
/// display layer ahead of time with their timestamps and a timebase on the audio clock shows
/// them (Vendor/KSPlayer `TimestampedVideoPresenter`). `FFmpegSession` applies the choice at
/// every poll, so it also takes effect on a film that is playing.
enum FramePacing {
    /// UserDefaults key of the Settings switch. Persisted.
    static let timestampedKey = "diag.timestampedFrames"

    /// What to ask the player for right now.
    static var wantsTimestamped: Bool {
        uiTestOverride ?? UserDefaults.standard.bool(forKey: timestampedKey)
    }

    /// Simulator runs choose the mode from the launch environment (`BASSPLAYER_PACING` =
    /// `timestamped` or `display-link`); UI tests start with empty settings.
    private static let uiTestOverride: Bool? = {
        let env = ProcessInfo.processInfo.environment
        guard env["BASSPLAYER_UITEST"] == "1" else { return nil }
        switch env["BASSPLAYER_PACING"] {
        case "timestamped": return true
        case "display-link": return false
        default: return nil
        }
    }()
}

/// The acceptance test for timestamped pacing: block the main thread on purpose while a film
/// plays and see in the `render:` log lines which mode keeps its frames.
///
/// The switch lives in memory only: it is off at every launch, whatever it was before, so it
/// cannot be left on by accident. `FFmpegSession` calls `stallIfDue` from its poll timer and
/// reports the count in the `render:` line.
@MainActor
final class MainThreadStallTest: ObservableObject {
    static let shared = MainThreadStallTest()
    static let stallMilliseconds = 200
    static let interval = 2.0

    @Published var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            lastStall = Date()
            DiagLog.log(isOn
                ? "stall test ON: blocking the main thread for \(Self.stallMilliseconds) ms every \(Int(Self.interval)) s while a film plays (off again at the next launch)"
                : "stall test off", "player")
        }
    }

    private var lastStall = Date()
    private var stalls = 0

    private init() {
        // Only a simulator run can ask for it at launch.
        let env = ProcessInfo.processInfo.environment
        isOn = env["BASSPLAYER_UITEST"] == "1" && env["BASSPLAYER_STALL_TEST"] == "1"
    }

    /// Blocks the calling (main) thread if the test is on, a film is playing and the last
    /// stall was `interval` ago.
    func stallIfDue(playing: Bool) {
        guard isOn, playing else { return }
        let now = Date()
        guard now.timeIntervalSince(lastStall) >= Self.interval else { return }
        lastStall = now
        stalls += 1
        Thread.sleep(forTimeInterval: Double(Self.stallMilliseconds) / 1000)
    }

    /// Stalls since the last call.
    func takeCount() -> Int {
        defer { stalls = 0 }
        return stalls
    }
}
